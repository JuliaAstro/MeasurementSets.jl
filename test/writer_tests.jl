# Phase 6: writers (AipsIO write side, write_table, copyms, create_ms).

using MeasurementSets: AipsWriter, putstart, putend, wr_u32, wr_i32, wr_string,
    wr_iposition, wr_block, wr_scalar, bytes, AipsIO, getstart, getend,
    read_u32, read_string, read_iposition, read_block, read_scalar

@testset "AipsIO write round-trip" begin
    for endian in (:big, :little)
        w = AipsWriter(; endian)
        putstart(w, "Outer", 2)
        wr_u32(w, 7)
        wr_string(w, "hello")
        wr_iposition(w, (4, 8))
        putstart(w, "Inner", 1)
        wr_i32(w, -3)
        wr_block(w, UInt32[10, 20, 30])
        putend(w)
        wr_scalar(w, 3.5)
        putend(w)
        raw = bytes(w)

        a = AipsIO(raw; endian)
        @test getstart(a, "Outer") == 2
        @test read_u32(a) == 7
        @test read_string(a) == "hello"
        @test read_iposition(a) == (4, 8)
        @test getstart(a, "Inner") == 1
        @test Int(read_scalar(a, Int32)) == -3
        @test Int.(read_block(a, UInt32)) == [10, 20, 30]
        getend(a)
        @test read_scalar(a, Float64) == 3.5
        getend(a)
        @test eof(a)
    end
end

if isdir(SAMPLE_MS)
    _rng(a, b) = a:b

    @testset "write_table round-trip (ANTENNA)" begin
        src = MeasurementSet(SAMPLE_MS).ANTENNA
        cols = Dict(n => getcolumn(src, n) for n in columnnames(src))
        dst = joinpath(mktempdir(), "ANTENNA")
        MSv2.write_table(dst, "ANTENNA", collect(cols); nrow=nrow(src), type="Antenna")

        back = readtable(dst)
        for (k, v) in cols
            @test getcolumn(back, k) == v
        end

        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test size(ct, 1) == nrow(src)
            @test ct[:NAME][:] == cols["NAME"]
        end
    end

    @testset "copyms slice" begin
        n = 200
        subs = ["ANTENNA", "DATA_DESCRIPTION", "FEED", "FIELD", "OBSERVATION",
                "POLARIZATION", "PROCESSOR", "SPECTRAL_WINDOW", "STATE"]
        dst = joinpath(mktempdir(), "slice.ms")
        copyms(SAMPLE_MS, dst; rows=_rng(1, n), subtables=subs)

        ours = MeasurementSet(dst)
        src = MeasurementSet(SAMPLE_MS)
        @test getfield(ours, :data).rows == n
        @test issubset(subs, subtablenames(ours))

        for name in ("TIME", "ANTENNA1", "ANTENNA2", "UVW", "DATA", "FLAG",
                     "WEIGHT", "SIGMA", "FLAG_ROW", "DATA_DESC_ID")
            @test ours[name][:] == [src[name][i] for i in 1:n]
        end

        # indirect subtable columns now copy in full
        for (st, col) in (("SPECTRAL_WINDOW", "CHAN_FREQ"),
                          ("POLARIZATION", "CORR_TYPE"),
                          ("FEED", "POLARIZATION_TYPE"),
                          ("FIELD", "PHASE_DIR"))
            o = readtable(joinpath(dst, st))
            s = readtable(joinpath(SAMPLE_MS, st))
            @test getcolumn(o, col) == getcolumn(s, col)
        end

        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test size(ct, 1) == n
            @test ct[:TIME][:] == [src["TIME"][i] for i in 1:n]
            @test ct[:DATA][1] == src["DATA"][1]
            @test CCT.Table(joinpath(dst, "SPECTRAL_WINDOW"))[:CHAN_FREQ][1] ==
                  getcell(readtable(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW")), "CHAN_FREQ", 1)
        end
    end
end

@testset "copyms stamps a missing FLAG_CATEGORY CATEGORY keyword (Phase 147)" begin
    # `MeasurementSet`'s own C++ constructor (`MeasurementSet.cc:89-99`)
    # requires FLAG_CATEGORY to carry a `CATEGORY` keyword; real MSes
    # commonly lack it (it self-heals on a WRITABLE open but throws
    # "Missing CATEGORY keyword" on a read-only one, Phase 121). The
    # committed sample fixture itself lacks it -- confirmed live while
    # chasing a `mscal.*` cross-check for Phase 147: every `derivedmscal`
    # UDF that constructs a full `MeasurementSet` (state/scan/array/obs)
    # threw that exact error against a plain `copyms` of the fixture,
    # even though the query never touched `FLAG_CATEGORY` at all.
    # `_copy_table_cols` now stamps the same empty `_flag_category_kw()`
    # `create_ms`/`addcolumn!` already use whenever the source lacks it.
    src = readtable(SAMPLE_MS)
    @test !haskey(columndesc(src, "FLAG_CATEGORY").keywords, "CATEGORY")

    dst = joinpath(mktempdir(), "flagcat.ms")
    copyms(SAMPLE_MS, dst; rows=1:5)
    kw = columndesc(readtable(dst), "FLAG_CATEGORY").keywords
    @test haskey(kw, "CATEGORY")
    @test kw["CATEGORY"] == String[]

    # NOTE: no real-TaQL cross-check here. `mscal.state()`/`scan()`/
    # `array()`/`obs()` each construct a full `MeasurementSet` inside
    # `UDFMSCal::setupSelection` -- live-verified (Phase 147) to
    # SEGFAULT the whole process in this environment's linked casacore
    # (`TableExprNodeBinary::getCommonTypes`, crashing via `newEQ`/
    # `newGE`), for ANY spec including a bare id -- NOT limited to
    # `>=`/`<=`. A segfault cannot be caught by Julia's `try`/`catch`,
    # so NEVER call `_taqlcmd`/`tableCommand` with `mscal.state`/`scan`/
    # `array`/`obs` in this environment; `mscal.field`/`spw`/`baseline`/
    # `corr`/`feed`/`uvdist` are unaffected (a different, working code
    # path) and are the only `mscal.<sel>` functions this test suite's
    # real-TaQL cross-checks ever exercise.

    # a source whose CATEGORY is already non-empty keeps its own value
    dst2 = joinpath(mktempdir(), "flagcat2.ms")
    copyms(dst, dst2; rows=1:5)   # dst's own (empty) value carries through
    kw2 = columndesc(readtable(dst2), "FLAG_CATEGORY").keywords
    @test kw2["CATEGORY"] == kw["CATEGORY"]
end

@testset "create_ms" begin
    dst = joinpath(mktempdir(), "synth.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)

    ms = MeasurementSet(dst)
    @test isempty(validate(ms))
    @test getfield(ms, :data).rows == 6
    @test size(ms[:DATA][1]) == (2, 4)
    @test ms.ANTENNA[:NAME][:] == ["ANT0", "ANT1", "ANT2"]
    @test length(subtablenames(ms)) == 12

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test size(ct, 1) == 6
        for st in ("ANTENNA", "SPECTRAL_WINDOW", "POLARIZATION", "FEED",
                   "FIELD", "OBSERVATION", "STATE", "PROCESSOR",
                   "DATA_DESCRIPTION", "HISTORY", "FLAG_CMD", "POINTING")
            @test isdir(joinpath(dst, st))
            @test size(CCT.Table(joinpath(dst, st)), 1) >= 1
        end
        @test all(iszero, ct[:DATA][1])
    end
end
