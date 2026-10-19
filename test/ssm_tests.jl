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
