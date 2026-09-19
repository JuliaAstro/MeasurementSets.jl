# Phase 7: StandardStMan indirect (variable-shape) + string arrays.

using MeasurementSets: ArrayFileWriter, af_put!, arrayfile_bytes, open_arrayfile,
    af_read

@testset "StManArrayFile codec round-trip" begin
    for endian in (:little, :big)
        w = ArrayFileWriter(; endian, version=0)
        o1 = af_put!(w, MSv2.TpDouble, collect(1.0:10.0))
        o2 = af_put!(w, MSv2.TpInt, reshape(Int32.(1:6), 2, 3))
        o3 = af_put!(w, MSv2.TpComplex, ComplexF32[1+2im, 3+4im])
        o4 = af_put!(w, MSv2.TpBool, Bool[true, false, true, true, false])
        raw = arrayfile_bytes(w)

        af = open_arrayfile(raw, endian)
        @test af.version == 0
        @test af_read(af, MSv2.TpDouble, o1) == collect(1.0:10.0)
        @test af_read(af, MSv2.TpInt, o2) == reshape(Int32.(1:6), 2, 3)
        @test af_read(af, MSv2.TpComplex, o3) == ComplexF32[1+2im, 3+4im]
        @test af_read(af, MSv2.TpBool, o4) == Bool[true, false, true, true, false]
    end
end

if isdir(SAMPLE_MS)
    @testset "indirect-array header (SPECTRAL_WINDOW StManArrayFile)" begin
        spwdir = joinpath(SAMPLE_MS, "SPECTRAL_WINDOW")
        spw = readtable(spwdir)
        seq = columndesc(spw, "CHAN_FREQ").sequ           # CHAN_FREQ's SSM instance
        b = read(joinpath(spwdir, "table.f$(seq)i"))
        ver  = ltoh(reinterpret(UInt32, b[1:4])[1])       # little-endian
        leng = ltoh(reinterpret(Int64,  b[5:12])[1])
        @test ver == 0
        @test leng == length(b)
        ndim = ltoh(reinterpret(UInt32, b[17:20])[1])     # first record at byte 16
        dim0 = ltoh(reinterpret(Int32,  b[21:24])[1])
        @test ndim == 1
        @test dim0 == 64                                  # CHAN_FREQ: 64 channels
    end

    if _HAVE_CASACORE
        @testset "indirect columns vs casacore" begin
            cases = [
                ("SPECTRAL_WINDOW", ["CHAN_FREQ", "CHAN_WIDTH", "EFFECTIVE_BW"], Colon()),
                ("POLARIZATION",    ["CORR_TYPE", "CORR_PRODUCT"], Colon()),
                ("FEED",            ["BEAM_OFFSET", "POL_RESPONSE",
                                     "POLARIZATION_TYPE", "RECEPTOR_ANGLE"], Colon()),
                ("FIELD",           ["PHASE_DIR", "DELAY_DIR"], Colon()),
                ("OBSERVATION",     ["LOG", "SCHEDULE"], Colon()),
                ("POINTING",        ["DIRECTION", "TARGET"], 1:100),
            ]
            for (st, cols, rng) in cases
                t = readtable(joinpath(SAMPLE_MS, st))
                cc = CCT.Table(joinpath(SAMPLE_MS, st))
                for col in cols
                    c = column(t, col)
                    rows = rng === Colon() ? (1:length(c)) : rng
                    theirs = cc[Symbol(col)]
                    @test all(i -> collect(c[i]) == collect(theirs[i]), rows)
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

# Phase 215 (src/datamanagers sweep, continued): a variable-shape SSM
# indirect-array cell that was never `put` (or is explicitly an empty
# array) decodes via `getcell`'s `foff == 0` branch (`standard.jl`) --
# same real casacore state as the ISM case (`test/ism_writer_tests.jl`'s
# "an undefined (empty-array) indirect cell" testset), and reachable
# through this package's own SSM-indirect writer (`isempty(v) ? Int64(0)
# : af_put!(...)`) -- but never actually exercised. Covers both the
# numeric-array path (`arrayfile.jl`) and the indirect-*string*-array
# path (`_read_string_array`'s `total <= 0` branch, `standard.jl`).
@testset "SSM indirect — an undefined (empty-array) cell (Phase 215)" begin
    dir = joinpath(mktempdir(), "ssm_undef")
    V = [Float64[1.0, 2.0, 3.0], Float64[], Float64[4.0, 5.0]]   # row 2: undefined
    write_table(dir, "T", ["V" => V]; nrow=3)          # default: StandardStMan
    r = readtable(dir)
    @test r.managers[1].name == "StandardStMan"
    @test getcell(r, "V", 1) == [1.0, 2.0, 3.0]
    @test getcell(r, "V", 2) == Float64[]
    @test getcell(r, "V", 3) == [4.0, 5.0]
    @test getcolumn(r, "V") == V

    dir2 = joinpath(mktempdir(), "ssm_undef_str")
    S = [["a", "b", "c"], String[], ["x", "y"]]
    write_table(dir2, "T", ["S" => S]; nrow=3)
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
