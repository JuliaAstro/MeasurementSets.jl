# Phase 8: IncrementalStMan writer + ISM indirect arrays.

using Random

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

# Phase 312: the "ISM writer round-trip" test above uses FIXED run-length
# change points (splits at exactly 20/40 of 60 rows, runs of exactly 12)
# for every column; "ISM writer multi-bucket" forces >1 bucket but with
# only ONE column, one pattern (changes every row). Neither exercises
# MULTIPLE columns with genuinely random, independent, simultaneous
# run-length patterns spanning several bucket boundaries at once --
# `_ism_colindex`'s per-column row-number/offset array construction
# (Phase 237/238's own allocation work sits right on top of this) is
# built per column independently, so misaligned bucket boundaries across
# columns with different change cadences is exactly the kind of thing a
# fixed single-pattern fixture can't catch. Spreads a random number of
# columns (2-4), random independent run-length patterns per column
# (a random "hold probability" per column, so each column changes value
# at unpredictable, uncorrelated points), random types
# (Int32/Float64/Bool/String), and row counts large enough to force
# multiple ISM buckets, cross-checked at both the whole-column and
# random-individual-row level against `Casacore.jl`.
@testset "ISM writer — random independent run-length patterns, multi-column, multi-bucket, vs Casacore.jl (Phase 312)" begin
    rng = MersenneTwister(312)
    for case in 1:5
        # Phase 452: buckets are filled to their real size now, so multiple buckets need real volume: the first column
        # changes on half of the rows and there are 20-30 thousand rows
        n = rand(rng, 20000:30000)
        ncol = rand(rng, 2:4)
        cols = Pair{String,Any}[]
        names = String[]
        expected = Dict{String,Any}()
        for c in 1:ncol
            J = rand(rng, (Int32, Float64, Bool, String))
            nm = "g$c"
            holdp = c == 1 ? 0.5 : rand(rng, 0.5:0.05:0.98)    # probability the value STAYS the same as the previous row
            vals = Vector{Any}(undef, n)
            cur = J === String ? randstring(rng, rand(rng, 0:6)) :
                  J === Bool  ? rand(rng, Bool) :
                  J === Int32 ? rand(rng, Int32(-1000):Int32(1000)) : randn(rng) * 100
            for i in 1:n
                if i > 1 && rand(rng) >= holdp
                    cur = J === String ? randstring(rng, rand(rng, 0:6)) :
                          J === Bool  ? rand(rng, Bool) :
                          J === Int32 ? rand(rng, Int32(-1000):Int32(1000)) : randn(rng) * 100
                end
                vals[i] = cur
            end
            vals = identity.(vals)     # narrow Vector{Any} -> the concrete J
            push!(cols, nm => vals)
            push!(names, nm)
            expected[nm] = vals
        end

        dir = joinpath(mktempdir(), "ism312_$case.tab")
        write_table(dir, "T", cols; nrow=n, ism=names)
        r = readtable(dir)
        inst = MSv2._dm_instance(r, 0)
        @test inst.buckets > 1    # genuinely forces multiple ISM buckets

        for nm in names
            @test getcolumn(r, nm) == expected[nm]
        end
        # random individual-row lookups, not just start/middle/end -- the
        # per-column `_ism_colindex` bucket-search path, not just the
        # bulk getcolumn fast path.
        for _ in 1:10
            row = rand(rng, 1:n)
            for nm in names
                @test getcell(r, nm, row) == expected[nm][row]
            end
        end

        if _HAVE_CASACORE
            ct = CCT.Table(dir)
            for nm in names
                got = expected[nm] isa Vector{String} ? String.(collect(ct[Symbol(nm)][:])) :
                                                        collect(ct[Symbol(nm)][:])
                @test got == expected[nm]
            end
        end
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

# Phase 215 (src/datamanagers sweep, continued): a variable-shape ISM
# column's indirect-array cell being genuinely undefined (never `put`, or
# explicitly written as an empty array) decodes via `_ism_decode`'s
# `foff == 0` branch (`incremental.jl`) -- a real casacore state (the same
# category as the `TiledCellStMan` null-cube state fixed in Phase 213),
# and directly reachable through this package's own writer (`_ism_encode!`
# stores offset 0 for an empty-array cell) -- but nothing in the suite had
# ever written one. Live-verified correct before adding as a permanent
# regression test.
@testset "ISM writer — an undefined (empty-array) indirect cell (Phase 215)" begin
    dir = joinpath(mktempdir(), "ism_undef")
    V = [Float64[1.0, 2.0, 3.0], Float64[], Float64[4.0, 5.0]]   # row 2: undefined
    write_table(dir, "T", ["V" => V]; nrow=3, ism=["V"])
    r = readtable(dir)
    @test r.managers[1].name == "IncrementalStMan"
    @test getcell(r, "V", 1) == [1.0, 2.0, 3.0]
    @test getcell(r, "V", 2) == Float64[]
    @test getcell(r, "V", 3) == [4.0, 5.0]
    @test getcolumn(r, "V") == V

    # the same state for an indirect *String* array column (ISM has no
    # separate string-bucket mechanism -- every non-Dims column, String or
    # not, goes through the array file, Phase 8)
    dir2 = joinpath(mktempdir(), "ism_undef_str")
    S = [["a", "b", "c"], String[], ["x", "y"]]
    write_table(dir2, "T", ["S" => S]; nrow=3, ism=["S"])
    r2 = readtable(dir2)
    @test getcell(r2, "S", 1) == ["a", "b", "c"]
    @test getcell(r2, "S", 2) == String[]
    @test getcell(r2, "S", 3) == ["x", "y"]
    @test getcolumn(r2, "S") == S

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:V][1] == V[1]
        @test isempty(ct[:V][2])
        @test ct[:V][3] == V[3]
        ct2 = CCT.Table(dir2)
        @test ct2[:S][1] == S[1]
        @test isempty(ct2[:S][2])
        @test ct2[:S][3] == S[3]
    end
end

# `getcell` on a large, multi-bucket, multi-column ISM instance --
# correctness across bucket boundaries and non-target-column skipping,
# plus an allocation regression guard for the two real bugs found and
# fixed while chasing a user-reported random-access `TIME` slowdown on a
# real 9.8M-row MS (Phase 237):
#
# 1. `_ism_bucket` was an O(used) linear scan over the bucket index; a
#    real MS with a handful of very large ISM buckets for a fast-changing
#    column (rather than this package's own ~100-row-per-bucket writer
#    target) made that scan itself cheap in isolation, but combined with
#    (2) below it compounded into a severe regression -- switched to
#    `searchsortedlast` (O(log used)).
# 2. `_ism_colindex`'s original per-cell path materialized full
#    `Vector{Int}` row-number/offset arrays for **every** column bound to
#    the ISM instance (not just the target one) on **every single**
#    `getcell` call -- live-measured ~123 KiB/call for a real MS's `TIME`
#    column. The first fix (skip non-target columns by pure pointer
#    arithmetic, scan the target column's entries directly without
#    materializing arrays) made allocation better but wall-clock ~23x
#    *worse* on a real MS with large buckets (thousands of stored-value
#    entries) -- the per-entry read was calling a `T`-parameterized
#    primitive with a *runtime*, not compile-time-constant, `T`
#    (`use64 ? UInt64 : UInt32`), forcing a full dynamic dispatch on every
#    loop iteration. Fixed with the standard Julia type-instability
#    barrier: branch on `use64` once, then call a `where {RT}`-specialized
#    inner function with a literal `UInt32`/`UInt64` at each call site.
#
# This table deliberately has TWO columns sharing one ISM instance (so
# `colnr != ncol`, exercising the "skip a non-target column" path) and
# enough rows, with a column that changes on (almost) every row, to force
# several large buckets with many stored-value entries each -- unlike the
# small committed sample MS fixture, which (by design, Phase 45) has too
# few rows to build more than one small, low-entry-count ISM bucket.
@testset "ISM random-access getcell — correctness + allocation (Phase 237)" begin
    n = 12000       # (Phase 452: buckets fill to their real size, so this many rows are needed for several buckets)
    # `A` changes almost every row (worst case for the per-entry scan,
    # like a real MS's TIME column); `B` changes rarely (a distinct
    # run-length pattern, so the two columns' entry counts differ).
    A = Float64[4.6e9 + (i ÷ 3) for i in 1:n]
    B = Int32[cld(i, 137) for i in 1:n]
    dir = joinpath(mktempdir(), "ism_bigrandom")
    write_table(dir, "T", ["A" => A, "B" => B]; nrow=n, ism=["A", "B"])

    r = readtable(dir)
    @test r.managers[1].name == "IncrementalStMan"
    inst = MSv2._dm_instance(r, 0)
    @test inst.index.used > 1        # genuinely multiple buckets

    colA = column(r, "A")
    colB = column(r, "B")

    # sequential + a fixed pseudo-random (not `Random`-seeded, to avoid a
    # stdlib-version-dependent sequence) access pattern crossing bucket
    # boundaries, both columns, both directions
    order = [((i * 2654435761) % n) + 1 for i in 1:n]    # a full permutation-ish walk
    @test all(colA[i] == A[i] for i in order)
    @test all(colB[i] == B[i] for i in order)
    @test getcolumn(r, "A") == A
    @test getcolumn(r, "B") == B

    # allocation regression guard: a single cached-column `getcell`
    # should be a small, fixed cost -- not scale with the bucket's entry
    # count (the ~123 KiB/call figure measured on the real MS before this
    # fix, or the correctness-preserving-but-23x-slower intermediate fix
    # that still allocated a comparable amount per call).
    colA[1]; colA[n]                          # warm up (compile)
    GC.gc()
    a1 = @allocated colA[n ÷ 2]
    @test a1 < 2048

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test collect(ct[:A][:]) == A
        @test collect(ct[:B][:]) == B
        for i in (1, n ÷ 3, 2n ÷ 3, n)
            @test ct[:A][i] == A[i]
            @test ct[:B][i] == B[i]
        end
    end
end

# `getcolumn` (whole-column read) — the same synthetic table as above,
# but the allocation regression this pins is a *different* bug from the
# `getcell` one Phase 237 fixed: `_ism_decode`'s general form returns
# `Bool | String | T | Array{T,N}` depending on `c` at *runtime* (its
# return type can't be inferred from a `ColumnDesc` argument), so
# `getcolumn`'s old `v = _ism_decode(...); out[r] = v` fill loop was
# never type-stable — live-profiled on a real MS: ~25 bytes/row of pure
# boxing overhead (not from the ~30K *decodes*, from the ~9.8M *row
# writes* re-boxing the same already-decoded value on every iteration of
# the run-length fill), on top of the unavoidable output-array bytes.
# Fixed the same way as Phase 237's `getcell` regression: a `where {D}`
# type-parameterized inner function (`_ism_getcolumn_scalar!`), so the
# on-disk element type is a compile-time constant inside the fill loop
# instead of a boxed runtime value (Phase 238).
@testset "ISM getcolumn — whole-column allocation regression (Phase 238)" begin
    n = 1_200_000   # (Phase 452: with runs this long a 32 KiB bucket holds ~500 000 rows)
    # a long-ish run length (changes every ~250 rows, like a real MS's
    # `TIME` column averaging ~325 rows/value on the real 9.8M-row ALMA
    # MS) -- NOT the "changes almost every row" pattern the Phase 237
    # `getcell` test above uses. `_ism_colindex`'s own row-number/offset
    # arrays (one small `Vector{Int}` pair per bucket, genuinely
    # unavoidable work, not part of either bug) scale with the number of
    # distinct-value ENTRIES, not with `n` -- a short run length inflates
    # that legitimate overhead disproportionately and would make this
    # bound meaningless (verified: `i ÷ 3` here needs a >4x-of-minimum
    # bound purely from that, swamping the actual regression this test
    # is meant to catch).
    A = Float64[4.6e9 + (i ÷ 250) for i in 1:n]
    dir = joinpath(mktempdir(), "ism_getcolumn_alloc")
    write_table(dir, "T", ["A" => A]; nrow=n, ism=["A"])

    r = readtable(dir)
    inst = MSv2._dm_instance(r, 0)
    @test inst.index.used > 1        # genuinely multiple buckets

    getcolumn(r, "A")                # warm up (compile)
    GC.gc()
    a = @allocated getcolumn(r, "A")
    # the theoretical minimum is just the output `Vector{Float64}` itself
    # (`n * sizeof(Float64)`); the old per-ROW-boxing bug allocated ~25
    # bytes/row *on top of* that (~4x the minimum on the real MS's
    # `TIME` column) -- a bound comfortably under that, but well above
    # the genuine `_ism_colindex` overhead at this run length, still
    # catches a real regression.
    @test a < 1.5 * n * sizeof(Float64)
    @test getcolumn(r, "A") == A
end

# Phase 262: the ISM per-cell lookup binary-searches a bucket's row-number list (it
# scanned it linearly, so a fast-changing column in a LARGE bucket cost O(entries)
# per cell -- 68 µs/cell at a 64 MiB bucket, 124× slower than now).  Correctness
# over every row of a column that changes on (almost) every row, so each bucket
# holds thousands of index entries.
@testset "ISM getcell — binary-searched entry lookup (Phase 262)" begin
    n = 30_000
    rng = MSv2.Random.MersenneTwister(7)
    fast = Int32.(rand(rng, 0:25, n)); slow = cumsum(rand(rng, n) .< 0.001) .* 1.0
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["F" => fast, "S" => slow, "X" => Int32.(1:n)]; nrow=n, ism=["F", "S"])
    t = readtable(dir)
    cf, cs = column(t, "F"), column(t, "S")
    @test all(i -> cf[i] == fast[i], 1:n)
    @test all(i -> cs[i] == slow[i], 1:n)
    @test cf[:] == fast && cs[:] == slow
end

# Phase 452: an ISM bucket was sized for the worst case (every value of every row changes), so a column of long runs --
# a TIME that changes every few hundred rows -- took as much space as one of random numbers (28 bytes a row for two
# columns; casacore's own file is a fraction of a byte).  Rows are now added to a bucket until its data and index would
# not fit, so buckets hold different numbers of rows.  Values, casacore's reading of the file, casacore editing it, and
# our own edit of it must all be unchanged.
@testset "ISM buckets fill to their real size (Phase 452)" begin
    rng = MersenneTwister(452)
    for endian in (:little, :big)
        n = 400_000
        A = Float64.(div.(0:n-1, 137)); B = Int32.(div.(0:n-1, 61)); S = ["s$(div(i, 523))" ^ (1 + div(i, 4000) % 5) for i in 0:n-1]
        Fb = Bool[div(i, 301) % 2 == 0 for i in 0:n-1]
        d = joinpath(mktempdir(), "t")
        cols = Pair{String,Any}["A" => A, "B" => B, "S" => S, "FL" => Fb]
        write_table(d, "T", cols; nrow = n, endian = endian, ism = ["A", "B", "S", "FL"])
        sz = filesize(joinpath(d, "table.f0"))
        @test sz < 4 * n                                   # was ~39 bytes a row
        t = readtable(d)
        inst = MSv2._dm_instance(t, 0)
        @test inst.index.used > 1
        starts = inst.index.rows
        @test length(unique(diff(starts[1:end-1]))) > 1 || inst.index.used == 2   # buckets of different sizes (not a fixed rows-per-bucket)
        for (nm, v) in cols
            @test column(t, nm)[:] == v
        end
        for i in rand(rng, 1:n, 300), (nm, v) in cols
            @test getcell(t, nm, i) == v[i]
        end
        if _HAVE_CASACORE
            ct = CCT.Table(d)
            for (nm, v) in cols
                @test ct[Symbol(nm)][:] == v
            end
        end
        if _HAVE_TAQL && endian === :little
            tc = _taqlcmd("UPDATE \$1 SET A = -1.0, S = 'zz', FL = TRUE WHERE rownumber() IN [7, 100000, 250001, 399999]", CCT.Table(d))
            CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            t2 = readtable(d)
            for i in (7, 100000, 250001, 399999)                 # rownumber() counts from 1
                @test getcell(t2, "A", i) == -1.0 && getcell(t2, "S", i) == "zz" && getcell(t2, "FL", i) == true
                A[i] = -1.0; S[i] = "zz"; Fb[i] = true
            end
            @test column(t2, "A")[:] == A && column(t2, "S")[:] == S && column(t2, "FL")[:] == Fb && column(t2, "B")[:] == B
        end
        edit(d) do e                                          # our own edit regenerates through the same writer
            e[:A][3] = 9.5; e[:S][n] = "last"; e[:B][200_000] = Int32(-7); addrows!(e, 2)
        end
        t3 = readtable(d)
        A3 = copy(A); A3[3] = 9.5; B3 = copy(B); B3[200_000] = -7; S3 = copy(S); S3[n] = "last"
        @test column(t3, "A")[:] == vcat(A3, fill(0.0, 2)) && column(t3, "B")[:] == vcat(B3, fill(Int32(0), 2))
        @test column(t3, "S")[:] == vcat(S3, ["", ""])
    end
end

# Phase 477: IncrementalStMan files of several buckets: row counts around the points where the number of buckets changes
# (columns that change on every row, so buckets fill by size), read by us / Casacore.jl, edited in place and extended.
@testset "ISM multi-bucket boundary sweep and edits (Phase 477)" begin
    rng = MersenneTwister(477)
    for N in vcat(collect(2640:2.:2700), collect(5380:5.:5420), [8100])
        N = Int(N)
        d = joinpath(mktempdir(), "t")
        X = Int32.(1:N); Y = rand(rng, N); R = Int32.(rand(rng, 1:3, N))
        write_table(d, "T", Pair{String,Any}["X" => X, "Y" => Y, "R" => R]; nrow=N, ism=["X", "Y", "R"])
        t = readtable(d)
        @test column(t, "X")[:] == X && column(t, "Y")[:] == Y && column(t, "R")[:] == R
        idx = sort(unique(vcat(rand(rng, 1:N, 10), 1, N)))
        edit(d) do e; for i in idx; e[:X][i] = Int32(-i); e[:R][i] = Int32(9); end; end
        for i in idx; X[i] = Int32(-i); R[i] = Int32(9); end
        edit(d) do e; addrows!(e, 2); end
        t = readtable(d)
        @test MSv2.nrow(t) == N + 2 && column(t, "X")[1:N] == X && column(t, "R")[1:N] == R && column(t, "Y")[1:N] == Y
        if _HAVE_CASACORE
            c = joinpath(mktempdir(), "c"); cp(d, c); u = CCT.Table(c)
            @test collect(u[:X][1:N]) == X && collect(u[:R][1:N]) == R
        end
    end
end

# Phase 480: a whole-column read of an array-valued IncrementalStMan column returned `Vector{Any}` (StandardStMan gives a
# concrete element type) and the cells of one stored run were the SAME array, so changing one changed its neighbours.
@testset "ISM array column: concrete eltype, independent cells (Phase 480)" begin
    V = [Float64[1, 2], Float64[1, 2], Float64[1, 2], Float64[3, 4, 5], Float64[]]
    d = joinpath(mktempdir(), "t"); write_table(d, "T", Pair{String,Any}["V" => V]; nrow=5, ism=["V"])
    a = column(readtable(d), "V")[:]
    @test a isa Vector{Vector{Float64}} && a == V
    @test !(a[1] === a[2]) && !(a[2] === a[3])
    a[1][1] = 99.0
    @test a[2] == [1.0, 2.0] && column(readtable(d), "V")[:][1] == [1.0, 2.0]
    S = [["a", "b"], ["a", "b"], ["c"]]
    d2 = joinpath(mktempdir(), "t"); write_table(d2, "T", Pair{String,Any}["V" => S]; nrow=3, ism=["V"])
    b = column(readtable(d2), "V")[:]
    @test b isa Vector{Vector{String}} && b == S && !(b[1] === b[2])
    # random edit sessions on ragged SSM-/ISM-indirect columns (all element types, both byte orders) equal a model
    rng = MersenneTwister(480)
    gen(T, n) = T === String ? [randstring(rng, rand(rng, 0:6)) for _ in 1:n] : T === Bool ? rand(rng, Bool, n) : rand(rng, T, n)
    for _ in 1:_fz(24)
        T = rand(rng, (Float64, Int32, ComplexF32, Bool, String)); N = rand(rng, [2, 5, 40, 700]); mgr = rand(rng, (:ssm, :ism))
        M = Vector{T}[rand(rng) < 0.15 ? T[] : gen(T, rand(rng, 1:12)) for _ in 1:N]; M[1] = gen(T, 3); M[2] = gen(T, 5)
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["V" => copy(M)]; nrow=N, endian=rand(rng, (:little, :big)), (mgr === :ism ? (; ism=["V"]) : (;))...)
        for _ in 1:rand(rng, 1:3)
            edit(d) do e
                for _ in 1:rand(rng, 1:25)
                    i = rand(rng, 1:length(M)); v = rand(rng) < 0.2 ? T[] : gen(T, rand(rng, 1:15)); e[:V][i] = v; M[i] = v
                end
                if rand(rng) < 0.5
                    k = rand(rng, 1:3); addrows!(e, k)
                    for _ in 1:k; v = rand(rng) < 0.3 ? T[] : gen(T, rand(rng, 1:15)); push!(M, v); e[:V][length(M)] = v; end
                end
                if rand(rng) < 0.4 && length(M) > 3
                    del = sort(unique(rand(rng, 1:length(M), 2))); removerows!(e, del); deleteat!(M, del)
                end
            end
        end
        @test collect(column(readtable(d), "V")[:]) == M
    end
end
