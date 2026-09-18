# Phase 8: IncrementalStMan writer + ISM indirect arrays.

@testset "ISM writer round-trip" begin
    n = 60
    a = Int32[i <= 20 ? 1 : (i <= 40 ? 2 : 3) for i in 1:n]   # long runs
    b = fill(3.0, n)                                           # never changes
    c = Bool[isodd(i) for i in 1:n]                            # changes every row
    d = ["scan$(cld(i, 12))" for i in 1:n]                     # runs of 12
    e = [Float64[i, i + 1, i + 2] for i in 1:n]                # fixed-shape array
    f = [fill(7.0, i <= 30 ? 2 : 5) for i in 1:n]              # ragged -> indirect

    dir = joinpath(mktempdir(), "ism")
    write_table(dir, "T", ["a" => a, "b" => b, "c" => c, "d" => d,
                           "e" => e, "f" => f];
                nrow=n, ism=["a", "b", "c", "d", "e", "f"])

    r = readtable(dir)
    @test only(unique(m.name for m in r.managers)) == "IncrementalStMan"
    @test getcolumn(r, "a") == a
    @test getcolumn(r, "b") == b
    @test getcolumn(r, "c") == c
    @test getcolumn(r, "d") == d
    @test getcolumn(r, "e") == e
    @test getcolumn(r, "f") == f
    @test getcell(r, "a", 25) == 2
    @test getcell(r, "d", 48) == "scan4"
    @test getcell(r, "f", 60) == fill(7.0, 5)

    # raw header / index sanity
    raw = read(joinpath(dir, "table.f0"))
    ai = MSv2.AipsIO(raw; endian=:little)
    @test MSv2.getstart(ai, "IncrementalStMan") == 5
    @test MSv2.read_scalar(ai, Bool) == false
    @test Int(MSv2.read_u32(ai)) >= 32768                       # bucket size
    inst = MSv2._dm_instance(r, 0)
    @test inst.buckets >= 1 && inst.index.used == inst.buckets
    fi = read(joinpath(dir, "table.f0i"))
    @test ltoh(reinterpret(UInt32, fi[1:4])[1]) == 1            # StManArrayFile version 1

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test collect(ct[:a][:]) == a
        @test collect(ct[:b][:]) == b
        @test collect(ct[:c][:]) == c
        @test collect(ct[:d][:]) == d
        em = ct[:e][:, :]
        @test [em[:, i] for i in 1:n] == e
        @test ct[:f][1] == f[1]
        @test ct[:f][60] == f[60]
    end
end

# Phase 211 (src/datamanagers sweep): a coverage-instrumented run showed
# `af_read`/`af_put!`'s `TpString` branches (`src/datamanagers/
# arrayfile.jl`) had zero coverage. Unlike StandardStMan -- whose
# `_ssmkind` always routes a variable-shape String column to the
# string-bucket mechanism (`:indstr`), never to `arrayfile.jl` --
# IncrementalStMan's `_ismkind` has no such split (every non-`Dims`
# column, String or not, is plain `:ind`), so a ragged String-array
# column bound to ISM genuinely does reach `af_read`/`af_put!` with
# `t == TpString` -- this was reachable, just never exercised (the
# existing "ragged -> indirect" ISM test above, `f`, is `Float64`, not
# `String`). Live-verified correct before adding this as a permanent
# regression test (same "close the gap, don't just note it" precedent
# as the TiledCellStMan testset above).
@testset "ISM writer — indirect (ragged) String array column (Phase 211)" begin
    n = 6
    s = [fill("r$(r)", r) for r in 1:n]                # ragged: 1..6 elements/row
    dir = joinpath(mktempdir(), "ism_indstr")
    write_table(dir, "T", ["s" => s]; nrow=n, ism=["s"])

    r = readtable(dir)
    @test r.managers[1].name == "IncrementalStMan"
    @test getcolumn(r, "s") == s
    @test getcell(r, "s", 4) == fill("r4", 4)

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:s][1] == s[1]
        @test ct[:s][6] == s[6]
    end

    # repeated (run-length) values -- exercises ISM's store-on-change with
    # an array value, and af_put!'s offset reuse for an unchanged cell
    dir2 = joinpath(mktempdir(), "ism_indstr_runs")
    s2 = [["a", "b"], ["a", "b"], ["a", "b"], ["x", "y", "z"], ["x", "y", "z"], ["q"]]
    write_table(dir2, "T", ["s" => s2]; nrow=n, ism=["s"])
    r2 = readtable(dir2)
    @test getcolumn(r2, "s") == s2

    # in-place edit of one row
    edit(dir2) do t
        t[:s][2] = ["changed"]
    end
    r3 = readtable(dir2)
    @test getcell(r3, "s", 2) == ["changed"]
    @test getcell(r3, "s", 1) == s2[1]   # siblings untouched
    @test getcell(r3, "s", 3) == s2[3]
end

# Phase 213 (src/datamanagers sweep, continued): `af_read`/`af_put!`'s
# empty-STRING-ELEMENT branches (`arrayfile.jl:94,181` -- an empty `""`
# element WITHIN an otherwise-written ragged string array, distinct from
# an entire array cell never being filled at all) had zero coverage --
# every existing indirect-String-array test uses only non-empty strings.
@testset "ISM writer — indirect String array with empty-string elements (Phase 213)" begin
    dir = joinpath(mktempdir(), "afempty")
    s = [["a", "", "c"], ["", "", ""], ["x"]]
    write_table(dir, "T", ["s" => s]; nrow=3, ism=["s"])
    r = readtable(dir)
    @test [getcell(r, "s", i) for i in 1:3] == s
    @test getcolumn(r, "s") == s
end

# Phase 213 (src/datamanagers sweep, continued): `getcolumn`'s
# array-valued-ISM-column `astype` post-convert branch (`incremental.jl:
# 233`, `[astype.(x) for x in out]`) had zero coverage -- every existing
# array-valued ISM test uses `Float64` data (narrowing only ever applies
# to `Float32`/`ComplexF32`), so no test combined a ragged ISM array
# column with precision narrowing.
@testset "ISM writer — narrowed getcolumn on a ragged array column (Phase 213)" begin
    dir = joinpath(mktempdir(), "ismnarrow")
    V = [Float32.(fill(10i, i <= 3 ? 2 : 4)) for i in 1:6]   # ragged Float32
    write_table(dir, "T", ["V" => V]; nrow=6, ism=["V"])

    r = readtable(dir)
    @test r.managers[1].name == "IncrementalStMan"
    out = column(r, "V"; precision=Float16)[:]
    @test eltype(out[1]) == Float16
    @test out == [Float16.(v) for v in V]
end

@testset "ISM writer multi-bucket" begin
    n = 15000
    g = Float64.(1:n)                                          # a change every row
    dir = joinpath(mktempdir(), "mb")
    write_table(dir, "T", ["g" => g]; nrow=n, ism=["g"])

    r = readtable(dir)
    inst = MSv2._dm_instance(r, 0)
    @test inst.buckets > 1
    @test inst.index.used == inst.buckets
    @test getcolumn(r, "g") == g
    @test getcell(r, "g", 1) == 1.0
    @test getcell(r, "g", n ÷ 2) == float(n ÷ 2)               # a later bucket
    @test getcell(r, "g", n) == float(n)
    if _HAVE_CASACORE
        @test collect(CCT.Table(dir)[:g][:]) == g
    end
end

@testset "ism= an unknown column name errors (Phase 202)" begin
    # `tsm=`/`tcm=`/`tcell=`/`dysco=` all validate every referenced name
    # and raise "unknown column ..." -- `ism=` was the one sibling with
    # no validation at all: `findall(c -> c.name in ism, descs)` simply
    # drops a name that matches no column with no error and no warning,
    # unlike every other group kwarg. Live-verified reachable:
    # `write_table(dir, "T", ["A"=>...]; nrow, ism=Set(["A","TYPO"]))`
    # used to succeed silently, writing "A" to ISM and just discarding
    # "TYPO". Fixed to error the same way its siblings already do.
    # (matches the pre-existing, unchanged `tsm=`/`tcm=`/`tcell=`/`dysco=`
    # behaviour: the error fires from inside `with_container_sink`, after
    # `_write_table_core`'s own `mkpath(dir)` — a stray empty directory
    # is left behind either way; not something this fix changes.)
    dir = joinpath(mktempdir(), "ism_bad")
    @test_throws ErrorException write_table(dir, "T", ["A" => collect(1:5)];
        nrow = 5, ism = Set(["A", "NOTACOLUMN"]))

    dir2 = joinpath(mktempdir(), "ism_ok")
    write_table(dir2, "T", ["A" => collect(1:5)]; nrow = 5, ism = Set(["A"]))
    @test columndesc(readtable(dir2), "A").manager == "IncrementalStMan"
end

if isdir(SAMPLE_MS)
    @testset "copyms keeps ISM columns" begin
        n = 150
        dst = joinpath(mktempdir(), "c.ms")
        copyms(SAMPLE_MS, dst; rows=1:n,
               subtables=["ANTENNA", "SPECTRAL_WINDOW", "POLARIZATION"])

        o = readtable(dst)
        src = MeasurementSet(SAMPLE_MS)
        @test "IncrementalStMan" in [m.name for m in o.managers]
        for cn in ("TIME", "INTERVAL", "FIELD_ID", "SCAN_NUMBER", "STATE_ID")
            @test getcolumn(o, cn) == [src[cn][i] for i in 1:n]
        end
        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test collect(ct[:TIME][:]) == [src["TIME"][i] for i in 1:n]
            @test collect(ct[:SCAN_NUMBER][:]) == [src["SCAN_NUMBER"][i] for i in 1:n]
        end
    end

    @testset "create_ms uses ISM" begin
        dst = joinpath(mktempdir(), "synth.ms")
        create_ms(dst; nrow=8, nchan=4, ncorr=2, nant=3)
        ms = MeasurementSet(dst)
        @test isempty(validate(ms))
        @test "IncrementalStMan" in [m.name for m in getfield(ms, :data).managers]
        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test collect(ct[:TIME][:]) == ms[:TIME][:]
            @test length(collect(ct[:FIELD_ID][:])) == 8
        end
    end
end
