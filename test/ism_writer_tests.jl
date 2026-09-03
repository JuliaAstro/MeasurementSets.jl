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
