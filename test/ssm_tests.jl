# StandardStMan column-data tests against the sample MS.

_flat(x) = x isa AbstractArray ? collect(vec(x)) : [x]

@testset "SSM structural" begin
    ant = subtable(MeasurementSet(SAMPLE_MS), "ANTENNA")

    names = getcolumn(ant, "NAME")
    @test length(names) == 26
    @test names[1] == "ea01" && names[end] == "ea28"
    @test all(==("ALT-AZ"), getcolumn(ant, "MOUNT"))
    @test all(==(25.0), getcolumn(ant, "DISH_DIAMETER"))

    pos = getcolumn(ant, "POSITION")
    @test length(pos) == 26 && size(pos[1]) == (3,)
    @test getcell(ant, "POSITION", 1) == pos[1]

    t = readtable(SAMPLE_MS)
    a1 = getcolumn(t, "ANTENNA1")
    @test length(a1) == nrow(t)
    @test eltype(a1) == Int32
    @test extrema(a1) == (0, 24)
    @test eltype(getcolumn(t, "FLAG_ROW")) == Bool
end

if _HAVE_CASACORE
    function crosscheck_ssm(path, cols)
        t = readtable(path)
        ct = CCT.Table(path)
        @testset "$(basename(path))" begin
            for name in cols
                ours = getcolumn(t, name)
                col = ct[Symbol(name)]
                match = all(1:nrow(t)) do i
                    tv = ndims(col) == 1 ? col[i] :
                         col[ntuple(_ -> Colon(), ndims(col) - 1)..., i]
                    _flat(ours[i]) == _flat(tv)
                end
                @test match         # column $name matches casacore
            end
        end
    end

    @testset "SSM vs casacore" begin
        crosscheck_ssm(SAMPLE_MS,
            ["ANTENNA1", "ANTENNA2", "DATA_DESC_ID", "FLAG_ROW"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "ANTENNA"),
            ["NAME", "STATION", "MOUNT", "TYPE", "DISH_DIAMETER",
             "FLAG_ROW", "POSITION", "OFFSET"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "OBSERVATION"),
            ["TELESCOPE_NAME", "OBSERVER", "PROJECT", "SCHEDULE_TYPE",
             "TIME_RANGE", "RELEASE_DATE", "FLAG_ROW"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "SOURCE"),
            ["NAME", "CODE", "SOURCE_ID", "DIRECTION", "PROPER_MOTION",
             "NUM_LINES", "INTERVAL"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW"),
            ["NAME", "NUM_CHAN", "REF_FREQUENCY", "FREQ_GROUP_NAME",
             "TOTAL_BANDWIDTH", "NET_SIDEBAND"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "FEED"),
            ["ANTENNA_ID", "FEED_ID", "NUM_RECEPTORS", "INTERVAL", "TIME",
             "POSITION", "SPECTRAL_WINDOW_ID"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "STATE"),
            ["SIG", "REF", "CAL", "LOAD", "SUB_SCAN", "OBS_MODE"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "DATA_DESCRIPTION"),
            ["SPECTRAL_WINDOW_ID", "POLARIZATION_ID", "FLAG_ROW"])
    end
end

@testset "SSM fixed-array getcolumn — view, not copy (Phase 235)" begin
    # `getcolumn` for a fixed-shape direct-array column (e.g. a real MS's
    # SSM-bound `ANTENNA.POSITION`) used to build one shared flat backing
    # buffer and then take a COPYING slice of it per row
    # (`flat[(r-1)*nrelem+1:r*nrelem]`) before `reshape`-ing -- one extra
    # small allocation per row on top of the already-built backing array,
    # the same shape of bug Phase 234 fixed for tiled `Bool` columns.
    # `@view` makes each returned cell a zero-copy window into the ONE
    # backing buffer instead (matching `tiled.jl`'s `_read_cube_bulk`
    # precedent, already in production since Phase 35/68).
    dir = mktempdir()
    n = 20_000
    pos = [rand(3) for _ in 1:n]
    write_table(joinpath(dir, "t.ms"), "T", ["POS" => pos]; nrow=n)
    t = readtable(joinpath(dir, "t.ms"))
    @test columndesc(t, "POS").manager == "StandardStMan"

    c = getcolumn(t, "POS")
    @test length(c) == n
    @test all(c[r] == pos[r] for r in 1:n)               # correctness unchanged
    @test parent(c[1]) isa Vector{Float64}                # a real view, not a copy
    # THE regression guard: every row shares ONE backing buffer. A
    # `flat[range]` copy (the old bug) would give each row its own,
    # unrelated `Vector` -- `parent(c[1]) === parent(c[2])` would be
    # `false`. (A raw byte-count threshold isn't a reliable guard here:
    # the per-row VIEW wrapper itself still costs ~40 bytes/row on top of
    # the 24-byte payload, so the view-vs-copy saving for a *small* cell
    # like this 3-element position is real but modest — the dramatic win
    # is for large tiled cells (`FLAG`), covered in `tsm_tests.jl`.)
    @test parent(c[1]) === parent(c[end])
end

using Random

# Phase 451: the SSM index used to set the size of EVERY bucket, so once it outgrew a data bucket (more than about
# 2 * 1024^2 rows of two Float64 columns) the file grew with the square of the row count (12M rows: 1 GiB for 180 MiB of
# data).  A long index is now chained over several index buckets like casacore's writer does; the file is linear in the rows.
@testset "SSM index spanning several buckets; file size linear in the rows (Phase 451)" begin
    rng = Random.MersenneTwister(451)
    for endian in (:little, :big)
        n = 300_000                                   # 293 data buckets: an index of ~2.4 KB in 1152-byte buckets
        B = rand(rng, Bool, n); U = UInt8.(rand(rng, 0:255, n))
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["B" => B, "U" => U]; nrow = n, endian = endian)
        h = MeasurementSets.read_ssm_header!(MeasurementSets.AipsIO(IOBuffer(read(joinpath(d, "table.f0"))); endian = endian))
        @test h.indices >= 3                                        # the chain is really used
        t = readtable(d)
        @test column(t, "B")[:] == B && column(t, "U")[:] == U
        for i in rand(rng, 1:n, 200)
            @test getcell(t, "B", i) == B[i] && getcell(t, "U", i) == U[i]
        end
        # the file is the data plus a few buckets (it was 12x larger with an index-sized bucket)
        @test filesize(joinpath(d, "table.f0")) < 1.2 * (n ÷ 8 + n) + 20_000
        if @isdefined(_HAVE_CASACORE) && _HAVE_CASACORE
            ct = CCT.Table(d)
            @test ct[:B][:] == B && ct[:U][:] == U
        end
        edit(d) do e                                                # regenerate through the same writer
            e[:U][5] = 0x07; e[:B][n] = !B[n]; addrows!(e, 3)
        end
        t2 = readtable(d)
        U2 = copy(U); U2[5] = 0x07; B2 = copy(B); B2[n] = !B[n]
        @test column(t2, "U")[:] == vcat(U2, zeros(UInt8, 3)) && column(t2, "B")[:] == vcat(B2, falses(3))
    end
    # a strict upper bound on bytes per row for a two-Float64 column table well past the old quadratic knee
    n = 4_500_000
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["X" => zeros(n), "Y" => zeros(n)]; nrow = n)
    @test filesize(joinpath(d, "table.f0")) < 1.05 * 16 * n + 100_000
    @test column(readtable(d), "Y")[end] == 0.0
end

# Phase 453: StandardStMan and IncrementalStMan files are mapped, not read: the first cell read of a 20M-row table read
# the whole 610 MB file (0.4 s, 800 MB) and now touches the pages it needs (0.2 ms, 1 MB).  The table still sees an
# in-place cell patch (the mapping is shared) and a table replaced by an edit keeps reading the file it opened.
@testset "SSM / ISM files are mapped, not read (Phase 453)" begin
    n = 2_000_000
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["K" => Int32.(rand(1:50, n)), "B" => rand(n), "I" => Int32.(div.(0:n-1, 500))]; nrow = n, ism = ["I"])
    sz = sum(filesize(joinpath(d, f)) for f in readdir(d) if startswith(f, "table.f"))
    t = readtable(d); getcell(t, "K", 1); getcell(t, "I", 1)            # compile
    t = readtable(d)
    a = @allocated (getcell(t, "K", 12345); getcell(t, "B", 99); getcell(t, "I", n))
    @test a < 0.2 * sz           # the file is 24 MB; reading it whole allocated more than that
    # a cell patched in place is seen by the table that is already open (shared mapping)
    t = readtable(d)
    k0 = getcell(t, "K", 777)
    edit(d) do e; e[:K][777] = k0 + Int32(1); end
    @test getcell(t, "K", 777) == k0 + 1 && getcell(readtable(d), "K", 777) == k0 + 1
    # a structural edit replaces the files; the table opened before keeps reading the old ones
    t = readtable(d); B0 = column(t, "B")[:]
    edit(d) do e; addrows!(e, 5); removerows!(e, [1]); end
    @test column(t, "B")[:] == B0 && nrow(readtable(d)) == n + 4
end

# Phase 462: fixed-shape array cells are copied with one memcpy on a little-endian host.  The bytes must equal the
# element-by-element writer for every element type, both byte orders, dense and strided cells, and a short cell fails.
@testset "SSM direct array cells -- fast path equals the element writer (Phase 462)" begin
    rng = Random.MersenneTwister(462)
    for J in (Int16, Int32, Int64, UInt8, UInt32, Float32, Float64, ComplexF32, ComplexF64), endian in (:little, :big)
        shp = (3, 4); nel = 12
        v = J <: Complex ? rand(rng, J, shp...) : J <: AbstractFloat ? J.(rand(rng, shp...)) : rand(rng, J, shp...)
        for cell in (v, view(rand(rng, J, 3, 8), :, 1:2:8), reshape(vec(v), 4, 3), collect(vec(v)))
            a = zeros(UInt8, 16 * nel + 16); b = copy(a)
            MSv2._ssm_put_array!(a, 5, cell, J, nel, endian)
            MSv2._ssm_put_array_generic!(b, 5, cell, J, nel, endian)
            @test a == b
        end
    end
    @test_throws BoundsError MSv2._ssm_put_array!(zeros(UInt8, 40), 5, rand(Float64, 3, 4), Float64, 12, :little)
    @test_throws BoundsError MSv2._ssm_put_array!(zeros(UInt8, 400), 5, rand(Float64, 2, 2), Float64, 12, :little)
    # end to end: a table of fixed-shape array cells reads back in both byte orders
    for endian in (:little, :big)
        d = joinpath(mktempdir(), "t"); cells = [rand(rng, Float32, 4, 8) for _ in 1:3000]
        write_table(d, "T", ["A" => cells]; nrow = 3000, endian = endian)
        @test column(readtable(d), "A")[:] == cells
    end
end

# Phase 476: the index of a long StandardStMan table is chained over several index buckets (Phase 451).  A one-Bool-column
# table has 512-byte buckets, so the chain grows from ~60,000 rows; sweep row counts around the points where the number of
# index buckets changes (and around bucket multiples), read by us and Casacore.jl, then edit in place and add rows.
@testset "SSM chained index buckets: boundary sweep and edits (Phase 476)" begin
    rng = MersenneTwister(476)
    for N in vcat([k * 1024 + dlt for k in 58:64 for dlt in (-1, 0, 1)], [100_000]), endian in (:little, :big)
        d = joinpath(mktempdir(), "t")
        B = rand(rng, Bool, N); I = Int32.(rand(rng, 1:1000, N)); S = [i % 50 == 0 ? "long"^20 : "s$i" for i in 1:N]
        write_table(d, "T", Pair{String,Any}["B" => B, "I" => I, "S" => S]; nrow=N, endian)
        t = readtable(d)
        @test column(t, "B")[:] == B && column(t, "I")[:] == I && column(t, "S")[:] == S
        idx = sort(unique(vcat(rand(rng, 1:N, 20), N)))
        edit(d) do e; for i in idx; e[:B][i] = !B[i]; e[:I][i] = Int32(-i); end; end
        for i in idx; B[i] = !B[i]; I[i] = Int32(-i); end
        edit(d) do e; addrows!(e, 3); e[:I][N+1] = Int32(7); end
        t = readtable(d)
        @test MSv2.nrow(t) == N + 3 && column(t, "B")[1:N] == B && column(t, "I")[1:N] == I && column(t, "S")[1:N] == S
        if _HAVE_CASACORE && endian === :little
            c = joinpath(mktempdir(), "c"); cp(d, c); u = CCT.Table(c)
            @test collect(u[:I][1:N]) == I && collect(u[:B][1:N]) == B
        end
    end
end

# Phase 479: String cells around the inline limit (8 bytes) and the string-bucket size (512-byte buckets, with and without
# extra numeric columns), one or many strings, then a string grown to hundreds of bytes in an edit session: our reader
# and Casacore.jl agree and the other cells are untouched.
@testset "SSM strings: inline limit, bucket boundaries, growing a string (Phase 479)" begin
    rng = MersenneTwister(479)
    mk(len) = String(rand(rng, 'a':'z', len))
    for extra in (0, 3), (L, N) in vcat([(l, n) for l in vcat(0:2, 7:10) for n in (1, 4, 100)], [(l, 20) for l in vcat(496:500, 504:508, 1016:1020)])
        d = joinpath(mktempdir(), "t")
        S = [mk(L + (i - 1) % 3) for i in 1:N]
        cols = Pair{String,Any}["S" => S, "K" => Int32.(1:N)]
        for e in 1:extra; push!(cols, "X$e" => rand(rng, N)); end
        write_table(d, "T", cols; nrow=N)
        @test column(readtable(d), "S")[:] == S
        big = mk(L + 700)
        edit(d) do e; e[:S][1] = big; end
        t = readtable(d)
        @test column(t, "S")[1] == big && column(t, "S")[2:end] == S[2:end] && column(t, "K")[:] == Int32.(1:N)
        if _HAVE_CASACORE
            c = joinpath(mktempdir(), "c"); cp(d, c)
            @test collect(CCT.Table(c)[:S][:]) == vcat(big, S[2:end])
        end
    end
end
