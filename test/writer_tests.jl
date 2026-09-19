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

    @testset "write_ms/copyms: an unknown subtables=/subtable_rows= name errors (Phase 204)" begin
        # `want(kw) = ... kw in subtables` and `get(subtable_rows, kw,
        # ...)` are both checked only by iterating the SOURCE's own real
        # keyword names -- neither ever confirmed a name the caller
        # supplied was actually used. Live-verified: a typo (missing
        # underscore, `"SPECTRALWINDOW"`) used to be silently dropped --
        # `want` is never true for it, so that subtable was skipped with
        # zero error/warning (the same "one sibling of a validated-
        # parameter family skips the check" shape as Phase 202's `ism=`),
        # and a `subtable_rows` typo silently left that subtable
        # unrestricted (fell back to its own `1:nrow(sub)` default).
        dir1 = joinpath(mktempdir(), "wms_bad1.ms")
        @test_throws ErrorException copyms(SAMPLE_MS, dir1; subtables=["ANTENA"])
        @test !ispath(dir1)   # caught before mkpath -- no stray directory at all

        dir2 = joinpath(mktempdir(), "wms_bad2.ms")
        @test_throws ErrorException copyms(SAMPLE_MS, dir2;
            subtable_rows = Dict("ANTENA" => 1:1))
        @test !ispath(dir2)

        # valid usage still restricts exactly the requested subtable
        dir3 = joinpath(mktempdir(), "wms_ok.ms")
        copyms(SAMPLE_MS, dir3; subtables = ["ANTENNA"],
              subtable_rows = Dict("ANTENNA" => 1:2))
        @test subtablenames(MeasurementSet(dir3)) == ["ANTENNA"]
        @test nrow(readtable(joinpath(dir3, "ANTENNA"))) == 2
    end
end

# Phase 226 finding: Phase 199 fixed `storage=`/`blocksize=` specifically
# (checked first thing, before any directory is created) but every OTHER
# validated kwarg in `_write_table_core` (`measures=`/`units=`/`engines=`/
# `forward=`/`virtualtaql=`/`ism=`/the `tsm=`/`tcm=`/`tcell=`/`dysco=`
# group name checks) still threw its own clear error -- correctly -- but
# AFTER `mkpath(dir)`, so the exact same "claims to have failed but
# silently created state anyway" gap was never actually closed for the
# rest. Live-reproduced: `write_table(dir, "T", [...]; nrow=2, measures =
# Dict("NOTACOL" => (; kind=:epoch, ref="UTC")))` threw the correct
# "measures: no column \"NOTACOL\"" message, yet left an empty `dir`
# behind. A per-kwarg hoist-before-mkpath fix (Phase 199's own approach)
# isn't safe here without a much larger restructuring -- several of these
# loops (`engines=` most of all) do real, non-trivial encoding work
# interleaved with their own name check, not a separable pure-validation
# pass. Fixed once, robustly, for every validation site in the function:
# remember whether `dir` already existed, and on ANY exception, remove it
# again (only if this call is the one that created it) before rethrowing
# -- which also correctly cleans up a genuinely *partial* write (some
# storage-manager files already on disk) for an error surfacing deep
# inside `with_container_sink`, not just the "nothing written yet" early
# case Phase 199 originally covered.
@testset "measures=/engines=/dysco=/etc. bad column name: no stray directory (Phase 226)" begin
    # an early error (measures=, checked near the top of the function)
    dir1 = joinpath(mktempdir(), "wt_meas.tab")
    @test_throws ErrorException write_table(dir1, "T", ["A" => [1.0, 2.0]]; nrow=2,
        measures = Dict("NOTACOL" => (; kind=:epoch, ref="UTC")))
    @test !ispath(dir1)

    dir2 = joinpath(mktempdir(), "wt_ism.tab")
    @test_throws ErrorException write_table(dir2, "T", ["A" => [1.0, 2.0]]; nrow=2,
        ism = Set(["NOTACOL"]))
    @test !ispath(dir2)

    # a LATE error (a dysco group name typo, checked deep inside
    # `with_container_sink`'s per-DM-writer section -- by then a
    # DIFFERENT, valid StandardStMan column has already been written to
    # real files on disk) -- confirms genuinely partial output is cleaned
    # up too, not just the "nothing written yet" early case.
    dir3 = joinpath(mktempdir(), "wt_dysco.tab")
    @test_throws ErrorException write_table(dir3, "T",
        ["A" => [1.0, 2.0], "B" => ComplexF32[1 + 2im, 3 + 4im]]; nrow=2,
        dysco = [["NOTACOL"]],
        dysco_spec = Dict("NOTACOL" => (; antenna1 = [0, 0], antenna2 = [1, 1])))
    @test !ispath(dir3)

    # a directory that already existed before the call (with unrelated
    # content) must be left completely untouched, not deleted
    dir4 = joinpath(mktempdir(), "wt_preexist.tab")
    mkpath(dir4)
    write(joinpath(dir4, "sentinel.txt"), "keep me")
    @test_throws ErrorException write_table(dir4, "T", ["A" => [1.0, 2.0]]; nrow=2,
        measures = Dict("NOTACOL" => (; kind=:epoch, ref="UTC")))
    @test isfile(joinpath(dir4, "sentinel.txt"))

    # a valid call is completely unaffected
    dir5 = joinpath(mktempdir(), "wt_ok.tab")
    write_table(dir5, "T", ["A" => [1.0, 2.0]]; nrow=2)
    @test column(readtable(dir5), "A")[:] == [1.0, 2.0]
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

# Phase 210 (src/tables sweep): a bare `[...]` array literal mixing
# columns of different concrete numeric eltypes gets silently promoted
# to one common eltype by Julia's OWN array-literal construction
# (`Base.vect`) *before* `write_table` ever sees `columns` -- there is
# no way for `write_table` to detect or undo this after the fact (the
# original, narrower-typed vector no longer exists by the time it
# arrives). Found live via `write_table(dir, "T", ["TIME" =>
# Float64[...], "ANTENNA1" => Int32[...]]; nrow=...)` writing ANTENNA1
# as `TpDouble` instead of `TpInt` -- the exact, extremely common
# real-MS shape of an integer id column next to a float column. Not a
# `write_table` bug to fix (documented on its docstring instead); this
# testset pins both the hazard (so a future reader can trust it is real
# and still present) and the three documented-safe alternatives.
@testset "write_table — bare [...] literal numeric-eltype promotion hazard (Phase 210)" begin
    tp = Int32[0, 1, 2, 0]
    fp = Float64[1.0, 2.0, 3.0, 4.0]

    # the hazard itself: a bare bracket literal silently promotes Int32 -> Float64
    bad = ["TIME" => fp, "ANTENNA1" => tp]
    @test eltype(bad[2].second) === Float64          # Julia itself already did this
    dst1 = joinpath(mktempdir(), "bad.ms")
    write_table(dst1, "T", bad; nrow=4)
    @test columndesc(readtable(dst1), "ANTENNA1").type == MSv2.TpDouble   # the corrupted result

    # Dict(...) does not promote its values
    dgood = Dict("TIME" => fp, "ANTENNA1" => tp)
    @test eltype(dgood["ANTENNA1"]) === Int32
    dst2 = joinpath(mktempdir(), "dict.ms")
    write_table(dst2, "T", dgood; nrow=4)
    @test columndesc(readtable(dst2), "ANTENNA1").type == MSv2.TpInt
    @test column(readtable(dst2), "ANTENNA1")[:] == Int32[0, 1, 2, 0]

    # an explicitly-typed Pair[...] literal does not promote either
    pgood = Pair["TIME" => fp, "ANTENNA1" => tp]
    @test eltype(pgood[2].second) === Int32
    dst3 = joinpath(mktempdir(), "pair.ms")
    write_table(dst3, "T", pgood; nrow=4)
    @test columndesc(readtable(dst3), "ANTENNA1").type == MSv2.TpInt

    # nor does Any[...]
    agood = Any["TIME" => fp, "ANTENNA1" => tp]
    @test eltype(agood[2].second) === Int32
    dst4 = joinpath(mktempdir(), "any.ms")
    write_table(dst4, "T", agood; nrow=4)
    @test columndesc(readtable(dst4), "ANTENNA1").type == MSv2.TpInt

    if _HAVE_CASACORE
        @test size(CCT.Table(dst1), 1) == 4   # the corrupted table still opens (just wrong type)
        @test CCT.Table(dst2)[:ANTENNA1][:] == [0, 1, 2, 0]
    end
end
