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
