# Crash consistency of multi-file commits (Phase 398).
#
# An `edit` flush replaces several files (storage-manager files, table.dat, table.info) and then the sync blob.
# They are committed as a group: the new files are written under hidden names, a journal (`table.commit`) is
# renamed into place -- the commit point -- then the files are renamed and the journal removed.  A process that
# dies before the journal leaves the old table; one that dies after it is rolled forward by the next open.
# Before this, killing the process between those renames left every reader failing with "mismatch in #row".

const _CR_N = 40

function _cr_fixture(d)
    rm(d; recursive=true, force=true)
    write_table(d, "T", Pair{String,Any}[
        "I" => Int32.(1:_CR_N), "S" => ["s$(i)x"^(1 + i % 4) for i in 1:_CR_N], "B" => isodd.(1:_CR_N),
        "X" => Float64.(1:_CR_N) ./ 3, "Y" => Int32.(div.(1:_CR_N, 7)),
        "V" => [Float32.(i .+ (1:6)) for i in 1:_CR_N],
        "M" => [reshape(Float32.(i .+ (1:12)), 3, 4) for i in 1:_CR_N],
        "R" => [collect(1:(i % 3 + 1)) for i in 1:_CR_N]]; nrow=_CR_N, ism=["X", "Y"], tsm=[["M"]])
    return d
end

const _CR_OPS = Dict{String,Function}(
    "ssm" => d -> edit(d) do t; t[:S][3] = "a much longer replacement string than before"; t[:I][5] = Int32(555); end,
    "addrows" => d -> edit(d) do t
        addrows!(t, 5)
        for r in _CR_N+1:_CR_N+5; t[:I][r] = Int32(r); t[:S][r] = "new$r"; end
    end,
    "removerows" => d -> edit(d) do t; removerows!(t, [2, 5, 9]); end,
    "removecol" => d -> edit(d) do t; removecolumn!(t, "S"); end,
    "mixed" => d -> edit(d) do t
        t[:S][1] = "m"; t[:X][2] = 2.5; t[:M][3] = fill(1f0, 3, 4); addrows!(t, 2); t[:I][_CR_N+1] = Int32(-1)
    end)

_cr_snap(d) = (t = readtable(d; precision=:full); Dict(nm => collect(column(t, nm)[:]) for nm in columnnames(t)))
_cr_same(a, b) = keys(a) == keys(b) && all(isequal(a[k], b[k]) for k in keys(a))

struct _CrashSim <: Exception end

# run `op` on a fresh fixture, "killing" it at commit event `k` by throwing from the hook
function _cr_run(d, op, k)
    _cr_fixture(d)
    n = Ref(0)
    MSv2._COMMIT_HOOK[] = (stage, i) -> (n[] += 1; n[] == k && throw(_CrashSim()))
    try
        _CR_OPS[op](d)
    catch e
        e isa _CrashSim || rethrow()
    finally
        MSv2._COMMIT_HOOK[] = nothing
    end
end

@testset "a killed commit leaves the old table or finishes on the next open (Phase 398)" begin
    root = mktempdir()
    for (op, f) in sort(collect(_CR_OPS); by=first)
        old = _cr_snap(_cr_fixture(joinpath(root, "old")))
        events = String[]
        d = _cr_fixture(joinpath(root, "ev"))
        MSv2._COMMIT_HOOK[] = (stage, i) -> push!(events, string(stage))
        try f(d) finally MSv2._COMMIT_HOOK[] = nothing end
        new = _cr_snap(d)
        @test !isfile(joinpath(d, MSv2.COMMIT_JOURNAL))               # a finished commit leaves no journal
        @test isempty(filter(x -> startswith(x, ".") && endswith(x, ".tmp"), readdir(d)))
        @test !_cr_same(old, new)
        jidx = findfirst(==("journal"), events)
        @test jidx !== nothing
        for k in 1:length(events)
            dd = joinpath(root, "c")
            _cr_run(dd, op, k)
            want = k >= jidx ? new : old                              # past the commit point: rolled forward
            @test _cr_same(_cr_snap(dd), want)
            @test !isfile(joinpath(dd, MSv2.COMMIT_JOURNAL))          # the read finished the commit
            # the recovered table is editable and its content stays what it was
            edit(dd) do t; t[:I][1] = Int32(31337); end
            @test column(readtable(dd), "I")[1] == 31337
        end
    end
end

@testset "failed commit: no journal, no hidden files, table untouched (Phase 398)" begin
    root = mktempdir()
    old = _cr_snap(_cr_fixture(joinpath(root, "old")))
    d = joinpath(root, "t")
    _cr_fixture(d)
    # an error while the files are being written (a full disk) aborts the group
    # (the hook fires after a file is written; the file whose write itself fails is covered by the next testset)
    MSv2._COMMIT_HOOK[] = (stage, i) -> stage === :tmp && i == 2 && error("disk full")
    err = try _CR_OPS["mixed"](d); nothing catch e; e end
    MSv2._COMMIT_HOOK[] = nothing
    @test err isa ErrorException && occursin("disk full", err.msg)
    @test _cr_same(_cr_snap(d), old)
    @test isempty(filter(x -> startswith(x, ".") && endswith(x, ".tmp"), readdir(d)))
    @test !isfile(joinpath(d, MSv2.COMMIT_JOURNAL))
    @test isempty(MSv2._HELD_LOCKS)
end

@testset "hidden files of a writer killed before its commit point are cleaned (Phase 398)" begin
    d = _cr_fixture(joinpath(mktempdir(), "t"))
    write(joinpath(d, ".table.f0.tmp"), "junk"); write(joinpath(d, ".table.dat.tmp"), "junk")
    old = _cr_snap(d)
    @test _cr_same(_cr_snap(d), old)                                  # readers ignore them
    edit(d) do t; t[:I][2] = Int32(2); end
    @test isempty(filter(x -> startswith(x, ".") && endswith(x, ".tmp"), readdir(d)))
    # recovery is idempotent: a journal whose renames are all done (killed before it was removed) is just removed
    write(joinpath(d, MSv2.COMMIT_JOURNAL), "table.dat\n")
    @test MSv2._recover_commit(d)
    @test !isfile(joinpath(d, MSv2.COMMIT_JOURNAL))
    @test !MSv2._recover_commit(d)
    @test column(readtable(d), "I")[2] == 2
end

@testset "a process killed at a commit point (Phase 398)" begin
    root = mktempdir()
    for (stage, expect_new) in (("journal_pending", false), ("journal", true), ("rename", true), ("after", true))
        d = _cr_fixture(joinpath(root, stage))
        old = _cr_snap(d)
        code = """
            using MeasurementSets
            const MSv2 = MeasurementSets
            MSv2._COMMIT_HOOK[] = (stage, i) -> string(stage) == "$stage" && ccall(:_exit, Cvoid, (Cint,), 137)
            edit($(repr(d))) do t
                t[:S][1] = "m"; t[:X][2] = 2.5; t[:M][3] = fill(1f0, 3, 4); addrows!(t, 2); t[:I][$(_CR_N + 1)] = Int32(-1)
            end
            """
        p = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) --startup-file=no -e $code`);
                         stdout=devnull, stderr=devnull))
        @test p.exitcode == 137
        @test isfile(joinpath(d, MSv2.COMMIT_JOURNAL)) == (stage != "journal_pending")
        s = _cr_snap(d)
        if expect_new
            @test size(column(readtable(d), "I")) == (_CR_N + 2,)
            @test column(readtable(d), "S")[1] == "m"
        else
            @test _cr_same(s, old)
        end
        @test !isfile(joinpath(d, MSv2.COMMIT_JOURNAL))
        edit(d) do t; t[:I][1] = Int32(7); end                        # the killed process held the lock; the OS released it
        @test column(readtable(d), "I")[1] == 7
    end
end

@testset "a write that fails half way leaves no hidden file (Phase 398)" begin
    d = _cr_fixture(joinpath(mktempdir(), "t"))
    old = _cr_snap(d)
    # the second file's hidden name is taken by a directory, so its write fails: like a full disk, it throws
    # after the first file has been written
    mkdir(joinpath(d, ".table.dat.tmp"))
    err = try
        MSv2._with_commit(d, nothing) do
            MSv2._atomic_write(joinpath(d, "table.f0"), UInt8[9])
            MSv2._atomic_write(joinpath(d, "table.dat"), UInt8[9])
        end
        nothing
    catch e
        e
    end
    @test err isa Union{SystemError,Base.IOError}
    @test !isfile(joinpath(d, ".table.f0.tmp"))                     # the first file's hidden copy is removed
    @test !isfile(joinpath(d, MSv2.COMMIT_JOURNAL))
    rm(joinpath(d, ".table.dat.tmp"); recursive=true, force=true)
    @test _cr_same(_cr_snap(d), old)
end
