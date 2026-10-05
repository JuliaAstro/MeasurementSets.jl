# Phase 376: corrupted / truncated table files must give Julia errors -- never crash the process, never
# allocate gigabytes.  A random-corruption fuzz found (1) a segfault: IncrementalStMan's whole-column
# read wrote `out[r]` under `@inbounds` with row numbers taken from the file, (2) corrupt row counts in
# `table.dat` made every whole-column read try to allocate tens of gigabytes (casacore refuses such a
# table: "mismatch in #row"), (3) corrupt element / axis / hypercube counts in the AipsIO headers
# preallocated gigabytes or built enormous types (12-76 s per read).
@testset "row-count mismatch is an error (Phase 376)" begin
    N = 30
    for (nm, kw) in (("ssm", (;)), ("ism", (; ism=["X"])), ("tsm", (; tsm=[["X"]]))), endian in (:little, :big)
        d = joinpath(mktempdir(), "t")
        X = nm == "tsm" ? [fill(1.0i, 3) for i in 1:N] : Float64.(1:N)
        write_table(d, "T", Pair{String,Any}["X" => X, "K" => Int32.(1:N)]; nrow=N, endian, kw...)
        @test column(readtable(d), "X")[N] == (nm == "tsm" ? fill(30.0, 3) : 30.0)
        bytes = read(joinpath(d, "table.dat"))
        @test bytes[22:25] == reinterpret(UInt8, [hton(UInt32(N))])      # the row count in the "Table" object
        bytes[22:25] = reinterpret(UInt8, [hton(UInt32(N + 7))])
        write(joinpath(d, "table.dat"), bytes); rm(joinpath(d, "table.lock"); force=true)
        t = readtable(d)
        @test MSv2.nrow(t) == N + 7
        @test_throws ErrorException collect(column(t, "X")[:])
        @test_throws ErrorException collect(column(t, "K")[:])
    end
    # a count that would need gigabytes fails at once, not after allocating
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["X" => Float64.(1:N)]; nrow=N, ism=["X"])
    bytes = read(joinpath(d, "table.dat")); bytes[22:25] = reinterpret(UInt8, [hton(UInt32(4_000_000_000))])
    write(joinpath(d, "table.dat"), bytes); rm(joinpath(d, "table.lock"); force=true)
    t = readtable(d)
    @test (@elapsed(try collect(column(t, "X")[:]) catch; end)) < 5
end

@testset "corrupted table files never crash or exhaust memory (Phase 376)" begin
    child = joinpath(@__DIR__, "corrupt_fuzz_child.jl")
    proj = dirname(@__DIR__)
    for (kind, seed, n) in (("mixed", 11, 60), ("big", 12, 40), ("multifile", 13, 40), ("engines", 14, 40), ("dysco", 15, 40), ("refs", 16, 30), ("ismwords", 17, 0))
        r = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --project=$proj $child $kind $seed $n`); stdout=devnull, stderr=devnull))
        @test r.exitcode == 0          # 139 = segfault, 137 = killed (out of memory), 3 = a read took > 15 s
    end
end
