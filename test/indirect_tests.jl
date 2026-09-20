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

# `getcolumn`/`getcell` on an SSM-indirect array column (`CHAN_FREQ` and
# every other ragged-array subtable column -- `POLARIZATION.CORR_TYPE`,
# `FIELD.PHASE_DIR`, ...) -- the one MAIN/subtable-read path Phase
# 237-238's ISM/tiled sweep hadn't reached: `af_read` (`arrayfile.jl`)
# and `StandardStMan`'s own `_i32`/`_i64`/`_be_i32`/`_read_elems` byte
# readers all shared the same allocating `reinterpret(T,
# ::Vector{UInt8})`-via-`view` pattern already fixed elsewhere (Phase
# 68/234 for the tiled reader, Phase 237/238 for ISM) -- live-measured
# on the real ALMA MS's `SPECTRAL_WINDOW.CHAN_FREQ` (96 rows x 64
# `Float64` channels): 5.1x slower than real casacore C++
# (`Casacore.jl`), ~787 bytes/row against a 512-byte payload. Phase 239
# centralised the fix (a shared `datamanagers/bytes.jl`, reused by
# `standard.jl`/`tiled.jl`/`incremental.jl`/`arrayfile.jl`) rather than
# patching `arrayfile.jl` alone. Live-verified afterward: `CHAN_FREQ`
# whole-column read is now 0.38x of C++ (faster, not merely
# "comparable") -- pin the allocation side of that here.
@testset "SSM indirect array — whole-column allocation regression (Phase 239)" begin
    n = 2000
    # a RAGGED (non-uniform-shape) column -- `_infer_shape` (`create.jl`)
    # routes a column to the fast fixed-shape `:direct` path the moment
    # every cell shares one shape, which would silently test the WRONG
    # (already-fast, Phase 235/236) path instead of the SSM-indirect
    # `:indarr` mechanism this phase actually fixed. Lengths cycle
    # 63/64/65 -- close to `CHAN_FREQ`'s real 64-channel size, genuinely
    # ragged.
    V = [collect(Float64, 1:(63 + i % 3)) .+ i for i in 1:n]
    dir = joinpath(mktempdir(), "ssm_indarr_alloc")
    write_table(dir, "T", ["V" => V]; nrow=n)
    r = readtable(dir)
    @test columndesc(r, "V").manager == "StandardStMan"
    @test columndesc(r, "V").shape isa MSv2.VariableShape   # confirms :indarr, not :direct

    getcolumn(r, "V")           # warm up (compile)
    GC.gc()
    a = @allocated getcolumn(r, "V")
    # theoretical minimum: every cell array's own real payload, summed,
    # plus the `n`-length `Vector{Any}` wrapper `getcolumn` returns for a
    # non-scalar column -- the old per-element `reinterpret`/`view` waste
    # was several hundred bytes *on top of* each cell's own payload; a
    # loose bound well under that still catches a real regression.
    payload = sum(length, V) * sizeof(Float64)
    # not 1x -- `getcolumn` returns a `Vector{Any}` of `n` INDIVIDUALLY
    # allocated cell arrays for a non-scalar column (no shared backing
    # buffer, unlike the fixed-shape `BlockColumn` path), so `n` real
    # small-array headers are genuine, unavoidable overhead on top of the
    # raw payload -- live-measured ~1.5x here. 2x still catches the old
    # bug (which added several HUNDRED bytes of pure `reinterpret`/`view`
    # waste per element on top of that, not a fixed ~50%).
    @test a < 2.0 * payload
    @test getcolumn(r, "V") == V

    getcell(r, "V", 1)          # warm up
    GC.gc()
    a1 = @allocated getcell(r, "V", n ÷ 2)
    @test a1 < 4 * 65 * sizeof(Float64)   # one cell's worth, generously bounded
    @test getcell(r, "V", n ÷ 2) == V[n ÷ 2]

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:V][1] == V[1]
        @test ct[:V][n] == V[n]
        @test ct[:V][n ÷ 2] == V[n ÷ 2]
    end
end
