# Phase 77: mscal.* derived-MS TaQL functions (the astronomy-value
# subset). Runs against SAMPLE_MS; needs SOFA.
import SOFA
import Statistics
using MeasurementSets: measure, measconvert, MeasFrame, MDirection, J2000,
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
end
