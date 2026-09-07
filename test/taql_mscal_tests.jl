# Phase 77: mscal.* derived-MS TaQL functions (the astronomy-value
# subset). Runs against SAMPLE_MS; needs SOFA.
import SOFA
import Statistics
import Dates
using MeasurementSets: measure, measconvert, MeasFrame, MDirection, MuvW, J2000,
    AZEL, HADEC, ITRF

@testset "TaQL-lite parser — mscal unit" begin
    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.el1() > 0").lhs isa MSv2.TQLMScal
    @test p("mscal.el1() > 0").lhs.fn == "el1"
    @test p("MSCAL.Hadec2() > 0").lhs.fn == "hadec2"
    @test p("mscal.uvw_j2000()[3] > 0").lhs.base isa MSv2.TQLMScal
    @test_throws ArgumentError p("mscal.wombat() > 0")
    @test_throws ArgumentError p("mscal.el1(A) > 0")
    s = Set{String}()
    MSv2._tqlrefs!(s, p("mscal.el1() > mscal.el2()"))
    @test s == Set(["mscal.el1", "mscal.el2"])
    @test MSv2._mscal_split(["A", "mscal.el1", "B", "mscal.ha2"]) ==
          (["A", "B"], ["el1", "ha2"])
end

@testset "TaQL-lite query — mscal.* functions" begin
    main = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    fld = subtable(ms, "FIELD")
    ant = subtable(ms, "ANTENNA")

    # hand reference for a few rows
    function _hand(i, B)
        a1 = column(main, "ANTENNA1")[i]
        fi = column(main, "FIELD_ID")[i]
        ep = measure(main, "TIME", i)
        dj = measconvert(measure(fld, "PHASE_DIR", fi + 1), J2000; frame = MeasFrame(epoch = ep))
        fr = MeasFrame(epoch = ep, position = measure(ant, "POSITION", a1 + 1), direction = dj)
        measconvert(dj, B; frame = fr)
    end

    q = query(main, "rownumber() >= 1"; select = [
        "el" => "mscal.el1()", "az" => "mscal.az1()", "ha" => "mscal.ha1()",
        "hd" => "mscal.hadec1()", "ae" => "mscal.azel1()", "pa" => "mscal.pa1()",
        "last" => "mscal.last1()", "it" => "mscal.itrf()",
        "d" => "mscal.delay()", "uj" => "mscal.uvw_j2000()"])
    for i in (3, 17, 250, 599)
        ae = _hand(i, AZEL)
        @test column(q, "el")[i] ≈ ae.lat
        @test column(q, "az")[i] ≈ ae.lon
        hd = _hand(i, HADEC)
        @test column(q, "ha")[i] ≈ hd.lon
        @test column(q, "hd")[i] ≈ [hd.lon, hd.lat]
        @test column(q, "ae")[i] ≈ [ae.lon, ae.lat]
        it = _hand(i, ITRF)
        @test column(q, "it")[i] ≈ [it.lon, it.lat]
        @test 0.0 <= column(q, "last")[i] < 2pi
        @test -pi <= column(q, "pa")[i] <= pi
        # uvw_j2000 is a pure rotation of the stored UVW -> length preserved
        @test hypot(column(q, "uj")[i]...) ≈ hypot(column(main, "UVW")[i]...) rtol = 1e-9
        # ... and the (ant, field, TIME)-memo'd 3x3 matches a direct convert
        let a1 = column(main, "ANTENNA1")[i], fi = column(main, "FIELD_ID")[i],
            ep = measure(main, "TIME", i)
            dj = measconvert(measure(fld, "PHASE_DIR", fi + 1), J2000; frame = MeasFrame(epoch = ep))
            fr = MeasFrame(epoch = ep, position = measure(ant, "POSITION", a1 + 1), direction = dj)
            w = measconvert(MuvW{ITRF}(column(main, "UVW")[i]...), J2000; frame = fr)
            @test column(q, "uj")[i] ≈ [w.u, w.v, w.w] rtol = 1e-9
        end
        # delay magnitude bounded by (max baseline)/c
        @test abs(column(q, "d")[i]) < 1e-4
    end

    # filter + count
    r = query(main, "mscal.el1() > 0.3")
    @test nrow(r) > 0 && nrow(r) <= nrow(main)
    for i in 1:min(nrow(r), 20)
        @test column(r, "ANTENNA1")[i] isa Integer
    end
    @test nrow(query(main, "mscal.el1() > 100.0")) == 0     # nothing above ~57 rad

    # groupby by antenna
    g = groupby(main, "ANTENNA1"; select = [
        "a" => :ANTENNA1, "mel" => "gmean(mscal.el1())", "n" => "gcount()"])
    @test length(g.a) >= 1
    for (k, aid) in enumerate(g.a)
        rows = [i for i in 1:nrow(main) if column(main, "ANTENNA1")[i] == aid]
        want = Statistics.mean(column(q, "el")[i] for i in rows)
        @test g.mel[k] ≈ want
    end

    # taql string dispatcher
    @test nrow(taql(main, "SELECT TIME WHERE mscal.el1() > 0.3")) == nrow(r)
end

@testset "TaQL-lite — mscal.* error cases" begin
    dir = joinpath(mktempdir(), "notms")
    write_table(dir, "T", Pair{String,Any}["A" => collect(1.0:4.0)]; nrow = 4)
    @test_throws ErrorException query(readtable(dir), "mscal.el1() > 0")
end

@testset "TaQL-lite — mscal.stokes() unit" begin
    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.stokes(A, 'I') > 0").lhs isa MSv2.TQLStokes
    @test p("mscal.stokes(A) > 0").lhs.outtypes == [1, 2, 3, 4]
    @test p("mscal.stokes(A, 'CIRC') > 0").lhs.outtypes == [5, 6, 7, 8]
    @test p("mscal.stokes(A, 'XX,YY') > 0").lhs.outtypes == [9, 12]
    @test p("mscal.stokes(A, 'I', true) > 0").lhs.rescale
    @test_throws ArgumentError p("mscal.stokes(A, 'Ptotal') > 0")
    @test_throws ArgumentError p("mscal.stokes(A, 'RX') > 0")
    @test_throws ArgumentError p("mscal.stokes() > 0")
    @test_throws ArgumentError p("mscal.stokes(A, B) > 0")     # non-literal type
    @test_throws ArgumentError p("mscal.stokes(A, 'I', 1) > 0") # non-bool rescale

    # conversion matrices, directly
    s = MSv2._stokes_setup([5, 6, 7, 8], [1], false)      # circ -> I
    @test s.cmat ≈ ComplexF64[1 0 0 1]
    s2 = MSv2._stokes_setup([5, 6, 7, 8], [1, 2, 3, 4], false)
    @test s2.cmat[3, :] ≈ ComplexF64[0, -1im, 1im, 0]     # U = i(LR - RL)
    sr = MSv2._stokes_setup([5, 6, 7, 8], [1], true)      # rescale halves RR/LL
    @test sr.cmat ≈ ComplexF64[0.5 0 0 0.5]
    @test_throws Exception MSv2._stokes_setup([5, 9, 7, 8], [1], false)  # mixed frame
end

@testset "TaQL-lite query — mscal.stokes()" begin
    main = readtable(SAMPLE_MS; precision = :full)
    q = query(main, "rownumber() >= 1"; select = [
        "si" => "mscal.stokes(DATA, 'I')", "iquv" => "mscal.stokes(DATA)",
        "fi" => "mscal.stokes(FLAG, 'I')"])
    D = column(main, "DATA")
    F = column(main, "FLAG")
    nch = size(D[1], 2)
    for i in (3, 17, 250, 599)
        @test size(column(q, "si")[i]) == (1, nch)
        @test vec(column(q, "si")[i]) ≈ ComplexF64.(D[i][1, :] .+ D[i][4, :])
        @test size(column(q, "iquv")[i]) == (4, nch)
        @test size(column(q, "fi")[i]) == (1, nch)
        @test vec(column(q, "fi")[i]) == (F[i][1, :] .| F[i][4, :])
    end

    # compose with a reduction + filter
    r = query(main, "mean(abs(mscal.stokes(DATA, 'I'))) >= 0.0")
    @test nrow(r) == nrow(main)

    # groupby
    g = groupby(main, "ANTENNA1"; select = [
        "a" => :ANTENNA1, "m" => "gmean(mean(abs(mscal.stokes(DATA, 'I'))))"])
    @test length(g.a) >= 1

    # error: no POLARIZATION subtable
    dir = joinpath(mktempdir(), "nopol")
    write_table(dir, "T", Pair{String,Any}["DATA" => [rand(ComplexF32, 4, 2) for _ in 1:3]];
                nrow = 3)
    @test_throws ErrorException query(readtable(dir), "any(mscal.stokes(DATA, 'I') != 0.0)")
end

@testset "TaQL-lite — mscal.<sel>() MSSelection-lite" begin
    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.baseline('0') > 0").lhs isa MSv2.TQLMSSel
    @test p("mscal.field('3C*') > 0").lhs.fn == "field"
    @test p("mscal.spw('0~3') > 0").lhs.spec == "0~3"
    @test_throws ArgumentError p("mscal.baseline() > 0")
    @test_throws ArgumentError p("mscal.baseline(A) > 0")     # non-literal spec

    # id-set / term parsing, directly
    n2i = Dict("ea01" => [0], "ea02" => [1], "ea10" => [9])
    @test MSv2._mssel_idset("0~2", 0:9, n2i) == Set([0, 1, 2])
    @test MSv2._mssel_idset(">7", 0:9, n2i) == Set([8, 9])
    @test MSv2._mssel_idset("ea0?", 0:9, n2i) == Set([0, 1])       # glob on names
    @test MSv2._mssel_idset("!ea01", 0:9, n2i) == Set(1:9)         # all-except
    @test MSv2._mssel_idset("/ea1./", 0:9, n2i) == Set([9])        # regex

    main = readtable(SAMPLE_MS)
    a1 = column(main, "ANTENNA1")[:]
    a2 = column(main, "ANTENNA2")[:]
    fid = column(main, "FIELD_ID")[:]
    nb(pred) = count(i -> pred(Int(a1[i]), Int(a2[i])), 1:nrow(main))

    @test nrow(query(main, "mscal.baseline('0')")) ==
          nb((x, y) -> x == 0 || y == 0)
    @test nrow(query(main, "mscal.baseline('ea01')")) ==
          nb((x, y) -> x == 0 || y == 0)               # ea01 == id 0
    @test nrow(query(main, "mscal.baseline('0 & 1')")) ==
          nb((x, y) -> (x, y) in ((0, 1), (1, 0)))
    @test nrow(query(main, "mscal.baseline('!ea01')")) ==
          nb((x, y) -> !(x == 0 || y == 0))
    @test nrow(query(main, "mscal.field('0')")) == count(==(0), fid)
    @test nrow(query(main, "mscal.spw('0')")) == nrow(main)        # sample has 1 spw
    @test nrow(query(main, "mscal.field('nosuchfield')")) == 0

    # composes with the rest of the grammar + groupby
    r = query(main, "mscal.baseline('0~4') AND mscal.field('0')")
    @test 0 < nrow(r) <= nrow(main)
    g = groupby(main, "FIELD_ID"; where = "mscal.baseline('0')",
                select = ["f" => :FIELD_ID, "n" => "gcount()"])
    @test sum(g.n) == nb((x, y) -> x == 0 || y == 0)

    # error: selection on a non-MS table
    dir = joinpath(mktempdir(), "notms2")
    write_table(dir, "T", Pair{String,Any}["X" => collect(1:4)]; nrow = 4)
    @test_throws ErrorException query(readtable(dir), "mscal.field('0')")
end

@testset "TaQL-lite — mscal.* with an ephemeris FIELD" begin
    ms = MeasurementSet(SAMPLE_MS)
    main0 = readtable(SAMPLE_MS)
    tm = Float64.(column(main0, "TIME")[:]) ./ 86400          # MJD days
    lo, hi = extrema(tm)

    tmp = joinpath(mktempdir(), "eph.ms")
    copyms(SAMPLE_MS, tmp)

    # replace FIELD with a moving-target field whose ephemeris straddles
    # the MS time range (dMJD 0.01 day, RA/DEC ramp of ~3 deg over the run)
    grid = collect((lo - 0.05):0.01:(hi + 0.05))
    ng = length(grid)
    eppath = joinpath(mktempdir(), "EPHEM0_Comet_J2000.tab")
    write_table(eppath, "EPHEM", Pair{String,Any}[
        "MJD" => grid, "RA" => [80.0 + 3.0 * (g - lo) for g in grid],
        "DEC" => [33.0 + 1.0 * (g - lo) for g in grid], "Rho" => fill(1.2, ng),
        "RadVel" => fill(0.0, ng)]; nrow = ng,
        keywords = Dict("MJD0" => grid[1] - 0.01, "dMJD" => 0.01,
                        "NAME" => "Comet", "posrefsys" => "J2000"))
    rm(joinpath(tmp, "FIELD"); recursive = true)
    write_table(joinpath(tmp, "FIELD"), "FIELD", Pair{String,Any}[
        "NAME" => ["Comet"], "EPHEMERIS_ID" => Int32[0], "PHASE_DIR" => [[0.0, 0.0]]];
        nrow = 1, measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    mv(eppath, joinpath(tmp, "FIELD", "EPHEM0_Comet_J2000.tab"))

    main = readtable(tmp)
    q = query(main, "rownumber() >= 1"; select = [
        "hd" => "mscal.hadec1()", "uj" => "mscal.uvw_j2000()"])
    # the ephemeris target (RA ~80 deg) is nowhere near the sample MS's
    # own field, so the hour angle must differ a lot from the static case
    qs = query(main0, "rownumber() >= 1"; select = ["hd" => "mscal.hadec1()"])
    @test abs(column(q, "hd")[1][1] - column(qs, "hd")[1][1]) > deg2rad(5)
    # uvw_j2000 still a pure rotation -> length preserved
    for i in (10, 300, 590)
        @test hypot(column(q, "uj")[i]...) ≈ hypot(column(main, "UVW")[i]...) rtol = 1e-9
    end
end

@testset "TaQL-lite — mscal.time() / mscal.uvdist()" begin
    main = readtable(SAMPLE_MS)
    tm = Float64.(column(main, "TIME")[:])
    N = nrow(main)
    d2d = [hypot(Float64(x[1]), Float64(x[2])) for x in column(main, "UVW")[:]]
    lo, hi = extrema(tm ./ 86400)                  # MJD-day bounds
    mid = (lo + hi) / 2

    # time: MJD-day endpoints, ISO datetime, and bounds
    @test nrow(query(main, "mscal.time('$(lo - 1)~$(hi + 1)')")) == N
    @test nrow(query(main, "mscal.time('>$mid')")) == count(>(mid), tm ./ 86400)
    @test nrow(query(main, "mscal.time('<$mid')")) == count(<=(mid), tm ./ 86400)
    d = Dates.Date(Dates.DateTime(1858, 11, 17) + Dates.Day(floor(Int, lo)))
    @test nrow(query(main, "mscal.time('$(d)T00:00:00~$(d)T23:59:59')")) == N

    # uvdist: metres, km, wavelength (sample has one spw, REF_FREQUENCY 7.988 GHz)
    @test nrow(query(main, "mscal.uvdist('200~1000m')")) ==
          count(x -> 200 <= x <= 1000, d2d)
    @test nrow(query(main, "mscal.uvdist('<500')")) == count(<=(500), d2d)
    @test nrow(query(main, "mscal.uvdist('>1km')")) == count(>=(1000), d2d)
    reff = column(subtable(MeasurementSet(SAMPLE_MS), "SPECTRAL_WINDOW"), "REF_FREQUENCY")[1]
    lam(x) = x * reff / MSv2.C_LIGHT
    @test nrow(query(main, "mscal.uvdist('10~100klambda')")) ==
          count(x -> 10e3 <= lam(x) <= 100e3, d2d)

    # errors
    @test_throws ArgumentError query(main, "mscal.uvdist('100')")   # bare single
    @test_throws ArgumentError query(main, "mscal.uvdist('1~2parsec')")
    @test_throws ArgumentError query(main, "mscal.uvdist('1~2m, 3~4klambda')")  # mixed
    @test_throws ArgumentError query(main, "mscal.time('not a date')")
end

if _HAVE_TAQL
    @testset "TaQL-lite — mscal.* vs real TaQL" begin
        # derivedmscal UDFs must be registered in this casacore build
        t = try
            _taqlcmd("SELECT mscal.ha1() AS H, mscal.last1() AS L, " *
                     "mscal.pa1() AS P FROM \$1", CCT.Table(SAMPLE_MS))
        catch
            nothing
        end
        if t !== nothing
            main = readtable(SAMPLE_MS)
            q = query(main, "rownumber() >= 1"; select = [
                "h" => "mscal.ha1()", "l" => "mscal.last1()", "p" => "mscal.pa1()"])
            as = MSv2.ARCSEC
            for i in (5, 123, 400)
                @test rem2pi(column(q, "h")[i] - t[:H][i], RoundNearest) ≈ 0 atol = 5as
                # casacore's mscal.last1() is a raw MVEpoch day count; we return
                # the LAST *angle* in radians -> compare the fractional day.
                @test rem2pi(column(q, "l")[i] - mod(t[:L][i], 1.0) * 2pi, RoundNearest) ≈
                      0 atol = 30as
                @test rem2pi(column(q, "p")[i] - t[:P][i], RoundNearest) ≈ 0 atol = 30as
            end
        else
            @info "derivedmscal UDFs not registered in this casacore build; " *
                  "skipping mscal cross-check"
        end
    end

    @testset "TaQL-lite — mscal.stokes() vs real TaQL" begin
        ts = try
            _taqlcmd("SELECT mscal.stokes(DATA, 'I') AS SI, mscal.stokes(DATA) AS SA " *
                     "FROM \$1", CCT.Table(SAMPLE_MS))
        catch
            nothing
        end
        if ts !== nothing
            main = readtable(SAMPLE_MS; precision = :full)
            q = query(main, "rownumber() >= 1"; select = [
                "si" => "mscal.stokes(DATA, 'I')", "sa" => "mscal.stokes(DATA)"])
            for i in (5, 123, 400)
                @test vec(column(q, "si")[i]) ≈ vec(ComplexF64.(ts[:SI][i])) rtol = 1e-5
                @test column(q, "sa")[i] ≈ ComplexF64.(ts[:SA][i]) rtol = 1e-5
            end
        else
            @info "mscal.stokes UDF not available in this casacore build; skipping"
        end
    end

    @testset "TaQL-lite — mscal.<sel>() vs real TaQL" begin
        main = readtable(SAMPLE_MS)
        for (fn, spec) in [("baseline", "0"), ("baseline", "0 & 1"),
                           ("baseline", "!0"), ("field", "0"), ("spw", "0"),
                           ("field", "0~2"), ("uvdist", "200~1000m"),
                           ("uvdist", "10~100klambda"), ("uvdist", ">1km")]
            rdir = joinpath(mktempdir(), "sel")
            ok = try
                _taqlcmd("SELECT FROM \$1 WHERE mscal.$fn('$spec') GIVING '$rdir'",
                         CCT.Table(SAMPLE_MS))
                true
            catch
                false
            end
            ok || continue
            @test nrow(query(main, "mscal.$fn('$spec')")) == nrow(readtable(rdir))
        end
    end
end
