using Random

# Performance regression guards (Phase 400).
#
# Wall-clock time cannot be asserted in CI, but allocation can: every large slowdown found so far (a 111x
# `FLAG` per-cell read, a 25x ISM random-access loop, a 10x CHAN_FREQ column) was an allocation bug first --
# a per-element wrapper, a re-boxed value, a copy per row.  The bounds below are about three times what the
# operations allocate today on the committed sample MS, so an ordinary change passes and a per-row
# allocation does not.

_pg_alloc(f) = (f(); f(); @allocated f())

@testset "allocation guards on the sample MS (Phase 400)" begin
    t = readtable(SAMPLE_MS; precision=:full)
    n = nrow(t)
    # whole-column reads cost about their payload
    for (nm, payload) in (("TIME", 8n), ("ANTENNA1", 4n), ("FLAG_ROW", n), ("UVW", 24n), ("FLAG", 4 * 64 * n ÷ 8 * 8), ("DATA", 8 * 4 * 64 * n))
        c = column(t, nm)
        @test _pg_alloc(() -> c[:]) <= 1.5 * payload + 4096
    end
    # a cell of an opened column: a few KiB at most
    for (nm, bound) in (("DATA", 8192), ("FLAG", 4096), ("TIME", 512), ("UVW", 4096), ("ANTENNA1", 512))
        c = column(t, nm)
        @test _pg_alloc(() -> c[n ÷ 2]) <= bound
    end
    # subtables: indirect arrays, strings
    ptg = readtable(joinpath(SAMPLE_MS, "POINTING")); spw = readtable(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW"))
    for (tb, nm, bound) in ((ptg, "DIRECTION", 150_000), (ptg, "NAME", 8_000), (ptg, "TIME", 8_000), (spw, "CHAN_FREQ", 200_000))
        c = column(tb, nm)
        @test _pg_alloc(() -> c[:]) <= bound
    end
    # opening and querying
    @test _pg_alloc(() -> readtable(SAMPLE_MS)) <= 300_000
    @test _pg_alloc(() -> query(t, "ANTENNA1 == 3")) <= 80_000
    @test _pg_alloc(() -> MSv2.groupby(t, "ANTENNA1"; select=["A" => :ANTENNA1, "N" => "gcount()"])) <= 150_000
end

# the whole-bit unpacker behind every Bool column read: eight Bools per store, against a bit-by-bit reference
@testset "bit unpacking matches the reference (Phase 400)" begin
    rng = MersenneTwister(400)
    function ref!(dest, doff, bytes, base, bitoff, n)
        for k in 0:n-1
            b = bitoff + k
            dest[doff + k + 1] = (bytes[base + (b >> 3) + 1] >> (b & 7)) & 0x01 == 0x01
        end
    end
    bad = 0; cases = 0
    for _ in 1:3000
        nb = rand(rng, 1:64); bytes = rand(rng, UInt8, nb)
        base = rand(rng, 0:min(nb - 1, 8)); bitoff = rand(rng, 0:20)
        maxn = (nb - base) * 8 - bitoff
        maxn <= 0 && continue
        n = rand(rng, 0:maxn); doff = rand(rng, 0:5)
        a = fill(true, doff + n + 3); b = copy(a); c = copy(a)
        MSv2._rd_bits!(a, doff, bytes, base, bitoff, n)                 # the Vector{Bool} fast path
        MSv2._rd_bits!(view(c, 1:length(c)), doff, bytes, base, bitoff, n)   # the generic path
        ref!(b, doff, bytes, base, bitoff, n)
        cases += 1
        (a == b && c == b) || (bad += 1)
    end
    @test cases > 2000 && bad == 0
    @test_throws BoundsError MSv2._rd_bits!(fill(false, 100), 0, UInt8[1, 2], 0, 0, 40)     # past the bytes: still checked
    # whole Bool columns of every size round trip (StandardStMan packs them eight to a byte)
    for N in (1, 7, 8, 9, 63, 64, 65, 100_003)
        v = rand(rng, Bool, N)
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["B" => v, "I" => Int32.(1:N)]; nrow=N)
        @test column(readtable(d), "B")[:] == v
        N > 70 && @test [getcell(readtable(d), "B", i) for i in (1, 8, 9, 64, 65, N)] == v[[1, 8, 9, 64, 65, N]]
    end
    # a fixed-shape Bool array column
    N = 1001; cells = [rand(rng, Bool, 3, 5) for _ in 1:N]
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["F" => cells]; nrow=N)
    @test [collect(x) for x in column(readtable(d), "F")[:]] == cells
end

# Phase 413: AipsIO's `io` field was abstractly typed (`::IO`), so every primitive read of a table
# description was a dynamic dispatch -- opening a table took ~4.5x longer (441 vs 98 us, 98 vs 65 KiB).
@testset "Phase 413 — table open stays cheap (AipsIO is concretely typed)" begin
    @test isconcretetype(fieldtype(typeof(MeasurementSets.AipsIO(UInt8[0, 0, 0, 0])), :io))
    readtable(SAMPLE_MS)
    @test (@allocated readtable(SAMPLE_MS)) < 90 * 1024
end

# Phase 415: copying a scalar column boxed every cell (`Vector{Any}`) and wrote it through a temporary array.
@testset "Phase 415 — scalar column copy stays cheap; _wrbytes! fast path agrees with the generic one" begin
    d = mktempdir(); p = joinpath(d, "t"); n = 50_000
    write_table(p, "T", Pair{String,Any}["A" => Int32.(1:n), "B" => collect(range(0, 1, length = n))]; nrow = n)
    t = readtable(p)
    copytable(joinpath(d, "w"), t)                                  # warm up
    @test (@allocated copytable(joinpath(d, "c"), t)) < 300 * n     # was ~450 B/row for two numeric columns
    c = readtable(joinpath(d, "c"))
    @test column(c, "A")[:] == 1:n && column(c, "B")[end] == 1.0
    for T in (Bool, UInt8, Int16, UInt16, Int32, UInt32, Int64, Float32, Float64), endian in (:little, :big)
        x = T === Bool ? true : T(3)
        a = zeros(UInt8, 16); b = zeros(UInt8, 16)
        MeasurementSets._wrbytes!(a, 3, x, endian)
        copyto!(b, 4, reinterpret(UInt8, [MeasurementSets._toendian(endian, x)]), 1, sizeof(x))
        @test a == b
    end
    @test_throws BoundsError MeasurementSets._wrbytes!(zeros(UInt8, 4), 2, Int32(1), :little)
end

# Phase 416: ORDER BY used a comparator closure (Dict lookup + two boxed reads per comparison): 1M rows, one
# numeric key, ~1.1 s and ~1.2 GiB.  The gathered-key `sortperm` passes need a few 8-byte vectors per key.
@testset "Phase 416 — ORDER BY allocates O(n) small vectors, not a boxed comparison per row" begin
    d = mktempdir(); p = joinpath(d, "t"); n = 100_000; rng = MersenneTwister(416)
    write_table(p, "T", Pair{String,Any}["K" => Int32.(rand(rng, 1:100, n)), "B" => rand(rng, n)]; nrow = n)
    t = readtable(p)
    query(t, "ORDER BY B"); query(t, "ORDER BY K, B DESC")           # warm up
    @test (@allocated query(t, "ORDER BY B")) < 120 * n               # was ~1200 B/row
    @test (@allocated query(t, "ORDER BY K, B DESC")) < 200 * n
end

# Phase 417: an aggregate argument was interpreted per row into a Vector{Any}; function calls in compiled
# predicates went through a dynamic call + tuple map.
@testset "Phase 417 — aggregate args and function calls in compiled expressions stay cheap" begin
    d = mktempdir(); p = joinpath(d, "t"); n = 100_000; rng = MersenneTwister(417)
    write_table(p, "T", Pair{String,Any}["K" => Int32.(rand(rng, 1:100, n)), "B" => rand(rng, n), "C" => rand(rng, n)]; nrow = n)
    t = readtable(p)
    f1() = groupby(t, "K"; select = ["K" => "K", "a" => "gsum(sqrt(B)+C)"])
    f2() = query(t, "sqrt(B) + C > 1")
    f1(); f2()                              # warm up
    @test (@allocated f1()) < 400 * n       # was ~900 B/row
    @test (@allocated f2()) < 150 * n       # was ~1400 B/row
end

# Phase 418: a whole-column update! rewrote its storage-manager file one boxed value at a time and built a
# million-entry Dict of current values; the SSM writer also copied every inline string.
@testset "Phase 418 — SSM scalar memcpy path == generic path; whole-column update! stays cheap" begin
    for J in (Int16, UInt16, Int32, UInt32, Int64, Float32, Float64), (r0, nr) in ((0, 7), (3, 5), (0, 1))
        col = J.(rand(MersenneTwister(418), 1:100, 12))
        a = zeros(UInt8, 8 + 12 * sizeof(J)); b = copy(a)
        MeasurementSets._ssm_put_scalars!(a, 8, sizeof(J), r0, nr, col, J, :little)
        MeasurementSets._ssm_put_scalars_generic!(b, 8, sizeof(J), r0, nr, col, J, :little)
        @test a == b
        # a column of Any, big-endian and a wider stride take the generic path and still agree with it
        c2 = zeros(UInt8, 8 + 12 * sizeof(J)); d2 = copy(c2)
        MeasurementSets._ssm_put_scalars!(c2, 8, sizeof(J), r0, nr, Any[x for x in col], J, :big)
        MeasurementSets._ssm_put_scalars_generic!(d2, 8, sizeof(J), r0, nr, col, J, :big)
        @test c2 == d2
    end
    @test_throws BoundsError MeasurementSets._ssm_put_scalars!(zeros(UInt8, 8), 4, 4, 0, 3, Int32[1, 2, 3], Int32, :little)
    d = mktempdir(); p = joinpath(d, "t"); n = 50_000; rng = MersenneTwister(418)
    write_table(p, "T", Pair{String,Any}["K" => Int32.(rand(rng, 1:100, n)), "B" => rand(rng, n),
                                         "S" => [string("s", rand(rng, 1:50)) for _ in 1:n]]; nrow = n)
    q = joinpath(d, "u"); cp(p, q); update!(q; set = ["B" => "B*2.0"])           # warm up
    B0 = column(readtable(p), "B")[:]
    q2 = joinpath(d, "u2"); cp(p, q2)
    @test (@allocated update!(q2; set = ["B" => "B*2.0"])) < 700 * n               # was ~1200 B/row
    r = readtable(q2)
    @test column(r, "B")[:] == B0 .* 2 && column(r, "S")[:] == column(readtable(p), "S")[:]
end

# Phase 420: an equi-join read its key column through the lazy Column (one cell read per left row) and boxed a
# tuple per row for the lookup: 1M x 100 N:1 join 426 ms; bulk-read typed keys need one small vector per side.
@testset "Phase 420 — equi-join key lookup allocates O(n) bytes, not a cell read per row" begin
    d = mktempdir(); n = 100_000; rng = MersenneTwister(420)
    write_table(joinpath(d, "l"), "L", Pair{String,Any}["K" => Int32.(rand(rng, 0:99, n)), "B" => rand(rng, n)]; nrow = n)
    write_table(joinpath(d, "r"), "R", Pair{String,Any}["K" => Int32.(0:99), "N" => ["n$i" for i in 0:99]]; nrow = 100)
    l = readtable(joinpath(d, "l")); r = readtable(joinpath(d, "r"))
    f() = join(l, r; on = "K" => "K", rightcols = ["N"])
    f(); f()
    @test (@allocated f()) < 250 * n          # was ~2000 B/row
end

# Phase 421: a random-access read of a plain numeric StandardStMan cell built a one-element vector and a dims
# tuple, and dispatched dynamically on the untyped data-manager instance (80-96 B, 160-200 ns per cell).
@testset "Phase 421 — numeric SSM cell read == generic getcell, allocation-free" begin
    n = 30_000; rng = MersenneTwister(421)      # several buckets
    cols = Pair{String,Any}[
        "I16" => Int16.(rand(rng, -999:999, n)), "U16" => UInt16.(rand(rng, 0:999, n)), "I32" => Int32.(rand(rng, -10^6:10^6, n)),
        "U32" => UInt32.(rand(rng, 0:10^6, n)), "I64" => rand(rng, Int64, n), "F32" => rand(rng, Float32, n),
        "F64" => rand(rng, n), "C32" => rand(rng, ComplexF32, n), "C64" => rand(rng, ComplexF64, n),
        "BO" => rand(rng, Bool, n), "ST" => [string("s", i % 97) for i in 1:n]]
    for endian in (:little, :big)
        p = joinpath(mktempdir(), "t")
        write_table(p, "T", cols; nrow = n, endian)
        t = readtable(p)
        for (nm, v) in cols
            c = column(t, nm)
            rows = unique!([1, 2, 3, 1000, 4095, 4096, 4097, n ÷ 2, n - 1, n, rand(rng, 1:n, 40)...])
            @test [c[i] for i in rows] == v[rows]
            @test [c[i] for i in rows] == [getcell(t, nm, i; precision = :full) for i in rows]
        end
        c = column(t, "F64"); c[5]
        @test (@allocated c[12345]) < 48          # 0 B in a function; a global's box costs 16 (was 80-96)
        c = column(t, "I32"); c[5]
        @test (@allocated c[12345]) < 48          # 0 B in a function; a global's box costs 16 (was 80-96)
    end
end

# Phase 422: removerows!/addrows! re-read every surviving cell through the row map (~1.5 s per million rows).
@testset "Phase 422 — removerows!/addrows! allocate O(n) small vectors, not a cell read per row" begin
    d = mktempdir(); n = 100_000; rng = MersenneTwister(422)
    write_table(joinpath(d, "t"), "T", Pair{String,Any}["K" => Int32.(rand(rng, 1:9, n)), "B" => rand(rng, n)]; nrow = n)
    run(f) = (q = joinpath(d, "u"); isdir(q) && rm(q; recursive = true); cp(joinpath(d, "t"), q); f(q))
    rem(q) = edit(e -> removerows!(e, 1:100:n), q)
    app(q) = edit(e -> addrows!(e, 100), q)
    run(rem); run(app)
    @test (run(q -> @allocated rem(q))) < 700 * n       # was ~1500 B/row
    @test (run(q -> @allocated app(q))) < 700 * n
end

# Phase 423: copying / indexing a lazy scalar column read it one cell at a time (DataFrame(t), a query result's
# column); a dense selection and `copy` are now one bulk read.
@testset "Phase 423 — dense column selections and copy are bulk reads" begin
    d = mktempdir(); p = joinpath(d, "t"); n = 60_000; rng = MersenneTwister(423)
    B = rand(rng, n); K = Int32.(rand(rng, 1:9, n)); S = [string("s", rand(rng, 1:20)) for _ in 1:n]
    write_table(p, "T", Pair{String,Any}["B" => B, "K" => K, "S" => S]; nrow = n)
    t = readtable(p); c = column(t, "B")
    @test copy(c) == B && copy(column(t, "S")) == S && copy(column(t, "K")) isa Vector{Int32}
    r = sort(unique(rand(rng, 1:n, 30_000))); shuf = reverse(r)
    @test c[r] == B[r] && c[shuf] == B[shuf]                       # dense: bulk path
    @test c[[7, 3, 59_999]] == B[[7, 3, 59_999]]                   # sparse: per-cell path
    @test_throws BoundsError c[vcat(r, n + 1)]
    q = query(t, "K > 3"); @test column(q, "B")[:] == B[K .> 3]
    copy(c); c[r]
    @test (@allocated copy(c)) < 20 * n
    @test (@allocated c[r]) < 40 * length(r)
end

# Phase 424: packing a row's plane into a tile dispatched dynamically on the element type for EVERY element
# (`juliatype(...)` was a runtime value): create_ms / copyms of a 20000 x 64 x 4 MS took ~1 s and 1 GiB.
@testset "Phase 424 — tile plane packing: memcpy path == element loop; create_ms / copyms stay cheap" begin
    TS = MeasurementSets
    for T in (Int16, UInt16, Int32, UInt32, Int64, Float32, Float64, ComplexF32, ComplexF64, Bool), endian in (:little, :big)
        plane = T === Bool ? rand(MersenneTwister(424), Bool, 12) : T.(rand(MersenneTwister(424), 1:100, 12))
        for within in (0, 5), views in (false, true)
            p = views ? reshape(view(plane, 1:12), 12) : plane              # a non-Vector plane takes the element loop
            a = zeros(UInt8, 8 + 40 * 16); b = copy(a)
            TS._pack_plane!(a, 8, within, 12, T, p, endian)
            if T === Bool
                for e in 0:11
                    plane[e+1] && (bi = 8 + ((within + e) >> 3) + 1; b[bi] |= 0x01 << ((within + e) & 7))
                end
            else
                for e in 1:12
                    TS._wrbytes!(b, 8 + within * sizeof(T) + (e - 1) * sizeof(T), plane[e], endian)
                end
            end
            @test a == b
        end
    end
    @test_throws BoundsError MeasurementSets._pack_plane!(zeros(UInt8, 10), 8, 0, 4, Int32, Int32[1, 2, 3, 4], :little)
    # marginal bytes per row (the difference of two sizes removes the fixed subtable cost)
    d = mktempdir(); perrow = 16 * 4 * (8 + 1 + 4)                                   # DATA + FLAG + WEIGHT_SPECTRUM bytes per row
    mk(n, nm) = (p = joinpath(d, nm); create_ms(p; nrow = n, nchan = 16, ncorr = 4, nant = 4); p)
    mk(500, "w"); copyms(joinpath(d, "w"), joinpath(d, "wc"))                       # warm up
    n1, n2 = 4000, 8000
    c1 = @allocated mk(n1, "a"); c2 = @allocated mk(n2, "b")
    @test (c2 - c1) / (n2 - n1) < 10 * perrow           # 6.5x now, was 17.5x
    k1 = @allocated copyms(joinpath(d, "a"), joinpath(d, "ac")); k2 = @allocated copyms(joinpath(d, "b"), joinpath(d, "bc"))
    @test (k2 - k1) / (n2 - n1) < 16 * perrow           # 11.7x now, was 22.7x
end
