# Phase 7: StandardStMan indirect (variable-shape) + string arrays.

using MeasurementSetv2: ArrayFileWriter, af_put!, arrayfile_bytes, open_arrayfile,
    af_read

@testset "StManArrayFile codec round-trip" begin
    for endian in (:little, :big)
        w = ArrayFileWriter(; endian, version=0)
        o1 = af_put!(w, MSv2.TpDouble, collect(1.0:10.0))
        o2 = af_put!(w, MSv2.TpInt, reshape(Int32.(1:6), 2, 3))
        o3 = af_put!(w, MSv2.TpComplex, ComplexF32[1+2im, 3+4im])
        o4 = af_put!(w, MSv2.TpBool, Bool[true, false, true, true, false])
        raw = arrayfile_bytes(w)

        mktemp() do path, io
            write(io, raw); close(io)
            af = open_arrayfile(path, endian)
            @test af.version == 0
            @test af_read(af, MSv2.TpDouble, o1) == collect(1.0:10.0)
            @test af_read(af, MSv2.TpInt, o2) == reshape(Int32.(1:6), 2, 3)
            @test af_read(af, MSv2.TpComplex, o3) == ComplexF32[1+2im, 3+4im]
            @test af_read(af, MSv2.TpBool, o4) == Bool[true, false, true, true, false]
        end
    end
end

if isdir(SAMPLE_MS)
    @testset "indirect-array header (SPECTRAL_WINDOW/table.f0i)" begin
        b = read(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW", "table.f0i"))
        ver  = ltoh(reinterpret(UInt32, b[1:4])[1])       # sample MS is little-endian
        leng = ltoh(reinterpret(Int64,  b[5:12])[1])
        @test ver == 0
        @test leng == length(b)
        ndim = ltoh(reinterpret(UInt32, b[17:20])[1])     # first record at byte 16
        dim0 = ltoh(reinterpret(Int32,  b[21:24])[1])
        @test ndim == 1
        @test dim0 == 64
    end

    if _HAVE_CASACORE
        _cc_cells(cc, n) =
            ndims(cc) == 1 ? [cc[i] for i in 1:n] : [cc[i] for i in 1:n]

        @testset "indirect columns vs casacore" begin
            cases = [
                ("SPECTRAL_WINDOW", ["CHAN_FREQ", "CHAN_WIDTH", "EFFECTIVE_BW"]),
                ("POLARIZATION",    ["CORR_TYPE", "CORR_PRODUCT"]),
                ("FEED",            ["BEAM_OFFSET", "POL_RESPONSE",
                                     "POLARIZATION_TYPE", "RECEPTOR_ANGLE"]),
                ("FIELD",           ["PHASE_DIR", "DELAY_DIR"]),
                ("OBSERVATION",     ["LOG", "SCHEDULE"]),
                ("POINTING",        ["DIRECTION"]),
            ]
            for (st, cols) in cases
                t = readtable(joinpath(SAMPLE_MS, st))
                cc = CCT.Table(joinpath(SAMPLE_MS, st))
                for col in cols
                    ours = getcolumn(t, col)
                    theirs = cc[Symbol(col)]
                    n = length(ours)
                    @test all(i -> collect(ours[i]) == collect(theirs[i]), 1:n)
                end
            end
        end
    end

    @testset "indirect round-trip (write_table, ragged)" begin
        dir = joinpath(mktempdir(), "spw")
        write_table(dir, "SPECTRAL_WINDOW",
            ["NUM_CHAN" => Int32[64, 32],
             "NAME" => ["a", "b"],
             "CHAN_FREQ" => [collect(1.0:64.0), collect(1.0:32.0)],
             "CHAN_WIDTH" => [fill(2.0, 64), fill(4.0, 32)],
             "CORR_TYPE_ISH" => [Int32[5, 6, 7, 8], Int32[9, 10]]]; nrow=2)
        r = readtable(dir)
        @test getcell(r, "CHAN_FREQ", 1) == collect(1.0:64.0)
        @test getcell(r, "CHAN_FREQ", 2) == collect(1.0:32.0)
        @test getcell(r, "CORR_TYPE_ISH", 2) == Int32[9, 10]
        if _HAVE_CASACORE
            ct = CCT.Table(dir)
            @test ct[:CHAN_FREQ][1] == collect(1.0:64.0)
            @test ct[:CHAN_FREQ][2] == collect(1.0:32.0)
        end
    end
end
