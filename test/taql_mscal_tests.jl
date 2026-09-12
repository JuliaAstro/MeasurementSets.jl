# Phase 77: mscal.* derived-MS TaQL functions (the astronomy-value
# subset). Runs against SAMPLE_MS; needs SOFA.
import SOFA
import Statistics
import Dates
using MeasurementSets: measure, measconvert, MeasFrame, MDirection, MuvW, J2000,
    AZEL, AZELGEO, HADEC, ITRF, observatory

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

    # Phase 85: optional direction argument
    @test p("mscal.el1('SUN') > 0").lhs.dir == "SUN"
    @test p("mscal.hadec1([2.0, 0.5]) > 0").lhs.dir == "[2.0,0.5]"
    @test p("mscal.itrf('DELAY_DIR') > 0").lhs.dir == "DELAY_DIR"
    # Phase 86: sexagesimal 'RA, DEC' string arg
    let d = p("mscal.el1('10:42:31, 45:51:16') > 0").lhs.dir
        @test startswith(d, "[") && count(==(','), d) == 1
        ra, dec = parse.(Float64, split(d[2:end-1], ','))
        @test ra ≈ deg2rad(10.70861 * 15) rtol = 1e-4
        @test dec ≈ deg2rad(45.85444) rtol = 1e-4
    end
    @test MSv2._mscal_key(p("mscal.el1('SUN') > 0").lhs) == "mscal.el1::SUN"
    s2 = Set{String}(); MSv2._tqlrefs!(s2, p("mscal.el1('SUN') > 0"))
    @test s2 == Set(["mscal.el1::SUN"])
    @test MSv2._mscal_split_dir("ha2::SUN") == ("ha2", "SUN")
    @test_throws ArgumentError p("mscal.last1('SUN') > 0")      # not a dir function
    @test_throws ArgumentError p("mscal.uvw_j2000('SUN') > 0")
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

    # Phase 85: direction argument
    qd = query(main, "rownumber() >= 1"; select = [
        "e0" => "mscal.el1()", "edd" => "mscal.el1('DELAY_DIR')",
        "esun" => "mscal.el1('SUN')", "efix" => "mscal.el1([2.0, 0.5])",
        "hdsun" => "mscal.hadec1('SUN')"])
    for i in (3, 250, 599)
        # the sample field's PHASE_DIR == DELAY_DIR
        @test column(qd, "e0")[i] ≈ column(qd, "edd")[i]
        @test -pi/2 <= column(qd, "esun")[i] <= pi/2
        # Sun's declination in late May 2024 is ~ +21 deg
        @test rad2deg(column(qd, "hdsun")[i][2]) ≈ 20.9 atol = 0.5
    end
    # a fixed [ra, dec] direction is not the field -> el differs from el1()
    @test column(qd, "efix")[3] != column(qd, "e0")[3]
    @test nrow(query(main, "mscal.el1('SUN') > -10.0")) == nrow(main)
    @test_throws ErrorException query(main, "mscal.el1('NOSUCH') > 0")

    # Phase 90: suffix-less mscal.ha() / azel() use the array centre
    # (OBSERVATION.TELESCOPE_NAME = "EVLA" -> the Observatories table),
    # close to but not identical to antenna 0
    qc = query(main, "rownumber() >= 1"; select = [
        "ha" => "mscal.ha()", "ha1" => "mscal.ha1()",
        "el" => "mscal.azel()"])
    for i in (3, 250, 599)
        @test abs(column(qc, "ha")[i] - column(qc, "ha1")[i]) < deg2rad(0.1)
        @test length(column(qc, "el")[i]) == 2
    end
end

@testset "TaQL-lite — mscal.delay1()/delay2() (Phase 136)" begin
    # Found missing entirely while re-verifying `MSCalEngine::getDelay`
    # against source: casacore has THREE delay UDFs (`delay`/`delay1`/
    # `delay2`), only the bare form existed here. `delay1`/`delay2` are
    # ONE antenna's delay relative to the array centre -- not
    # `ap1`/`ap2` alone -- and the whole delay family defaults its
    # direction to FIELD.DELAY_DIR, not PHASE_DIR (confirmed via
    # `UDFMSCal::UDFMSCal(ColType,Int)` calling `setDirColName
    # ("DELAY_DIR")`).
    main = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    fld = subtable(ms, "FIELD")
    ant = subtable(ms, "ANTENNA")

    function _hand_delay(i; ddir = nothing)
        a1 = column(main, "ANTENNA1")[i]
        a2 = column(main, "ANTENNA2")[i]
        fi = column(main, "FIELD_ID")[i]
        ep = measure(main, "TIME", i)
        pd = ddir === nothing ? measure(fld, "DELAY_DIR", fi + 1) : ddir
        dj = measconvert(pd, J2000; frame = MeasFrame(epoch = ep))
        p1 = measure(ant, "POSITION", a1 + 1)
        centre = observatory("EVLA")   # this MS's OBSERVATION.TELESCOPE_NAME (Phase 90)
        fr = MeasFrame(epoch = ep, position = p1, direction = dj)
        itrf = measconvert(dj, ITRF; frame = fr)
        p2 = measure(ant, "POSITION", a2 + 1)
        (itrf, p1, p2, centre)
    end

    q = query(main, "rownumber() >= 1"; select = [
        "d" => "mscal.delay()", "d1" => "mscal.delay1()", "d2" => "mscal.delay2()"])
    for i in (3, 17, 250, 599)
        itrf, p1, p2, centre = _hand_delay(i)
        x = (cos(itrf.lat) * cos(itrf.lon), cos(itrf.lat) * sin(itrf.lon), sin(itrf.lat))
        d1want = (x[1] * (p1.x - centre.x) + x[2] * (p1.y - centre.y) + x[3] * (p1.z - centre.z)) / MSv2.C_LIGHT
        d2want = (x[1] * (p2.x - centre.x) + x[2] * (p2.y - centre.y) + x[3] * (p2.z - centre.z)) / MSv2.C_LIGHT
        @test column(q, "d1")[i] ≈ d1want rtol = 1e-9
        @test column(q, "d2")[i] ≈ d2want rtol = 1e-9
        # bare form is the difference of the two, independent of centre
        @test column(q, "d")[i] ≈ d1want - d2want rtol = 1e-9
        @test column(q, "d")[i] ≈ column(q, "d1")[i] - column(q, "d2")[i] rtol = 1e-9
    end

    # DELAY_DIR default: patch a copy's DELAY_DIR to genuinely differ
    # from PHASE_DIR and confirm mscal.delay() tracks DELAY_DIR, not
    # PHASE_DIR (the sample fixture's own DELAY_DIR == PHASE_DIR, so
    # this needs a synthetic divergence to actually exercise the fix).
    tmp = mktempdir()
    dir = joinpath(tmp, "patched.ms")
    copyms(SAMPLE_MS, dir; rows = 1:20)
    fld2 = joinpath(dir, "FIELD")
    edit(fld2) do t
        newdir = deg2rad.([100.0, -20.0])   # far from PHASE_DIR
        for r in 1:nrow(readtable(fld2))
            t[:DELAY_DIR][r] = reshape(newdir, 2, 1)
        end
    end
    main2 = readtable(dir)
    qp = query(main2, "rownumber() >= 1"; select = ["d0" => "mscal.delay()", "dpd" => "mscal.delay('PHASE_DIR')"])
    @test any(column(qp, "d0")[i] != column(qp, "dpd")[i] for i in 1:nrow(main2))
end

@testset "TaQL-lite — mscal.* error cases" begin
    dir = joinpath(mktempdir(), "notms")
    write_table(dir, "T", Pair{String,Any}["A" => collect(1.0:4.0)]; nrow = 4)
    @test_throws ErrorException query(readtable(dir), "mscal.el1() > 0")
end

# Phase 105: mscal.riseset[1|2]([elev0][, dir]) -- the Phase 104
# meas.riseset() machinery wired into the automatic per-row mscal.*
# geometry (ANTENNA1/2's own ITRF position, FIELD.PHASE_DIR by
# default), the way Phase 101 wired mscal.pbresponse() into it.
@testset "TaQL-lite — mscal.riseset()" begin
    main = readtable(SAMPLE_MS)

    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.riseset1() > 0").lhs.fn == "riseset1:0.0"
    @test p("mscal.riseset() > 0").lhs.fn == "riseset:0.0"
    @test p("mscal.riseset2(0.2) > 0").lhs.fn == "riseset2:0.2"
    @test p("mscal.riseset1(0.0, 'SUN') > 0").lhs.dir == "SUN"
    @test_throws ArgumentError p("mscal.riseset1(A) > 0")           # A is not a literal
    @test_throws ArgumentError p("mscal.riseset1(0.1, 'SUN', 1) > 0")  # too many args

    q = query(main, "rownumber() >= 1"; select = [
        "rs" => "mscal.riseset1()", "rs2" => "mscal.riseset2()",
        "rsel" => "mscal.riseset1(0.2)"])
    for i in (3, 250, 599)
        rise, set = column(q, "rs")[i]
        @test isfinite(rise) && isfinite(set)
        @test length(column(q, "rs2")[i]) == 2
        # a tighter elevation cutoff never widens the visible window
        rise2, set2 = column(q, "rsel")[i]
        (isfinite(rise2) && isfinite(rise)) && @test rise2 >= rise
        (isfinite(set2) && isfinite(set)) && @test set2 <= set
    end

    # not an MS -- same error path as every other mscal.* function
    dir = joinpath(mktempdir(), "notms2")
    write_table(dir, "T", Pair{String,Any}["A" => collect(1.0:4.0)]; nrow = 4)
    @test_throws ErrorException query(readtable(dir), "mscal.riseset1() > 0")
end

@testset "TaQL-lite — mscal.stokes() unit" begin
    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.stokes(A, 'I') > 0").lhs isa MSv2.TQLStokes
    @test p("mscal.stokes(A) > 0").lhs.outtypes == [1, 2, 3, 4]
    @test p("mscal.stokes(A, 'CIRC') > 0").lhs.outtypes == [5, 6, 7, 8]
    @test p("mscal.stokes(A, 'XX,YY') > 0").lhs.outtypes == [9, 12]
    @test p("mscal.stokes(A, 'I', true) > 0").lhs.rescale
    @test p("mscal.stokes(A, 'Ptotal') > 0").lhs.outtypes == [-1]   # Phase 109 pseudo type
    @test_throws ArgumentError p("mscal.stokes(A, 'RX') > 0")
    @test_throws ArgumentError p("mscal.stokes(A, 'PBOGUS') > 0")
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

# Phase 109: mscal.stokes()'s pseudo (non-linear, derived-from-I,Q,U,V)
# output types -- Ptotal/Plinear/Pangle/PFtotal/PFlinear.
@testset "TaQL-lite — mscal.stokes() pseudo types" begin
    tmp = joinpath(mktempdir(), "pstokes.ms")
    copyms(SAMPLE_MS, tmp)
    testval = ComplexF32[3.0 + 1im, 0.5 - 0.2im, 0.5 + 0.2im, 2.0 - 1im]   # RR,RL,LR,LL
    edit(tmp) do t
        cell = t[:DATA][1]
        fill!(cell, 0)
        cell[:, 1] = testval
        t[:DATA][1] = cell
    end
    main = readtable(tmp; precision = :full)
    q = query(main, "rownumber() == 1"; select = [
        "iquv" => "mscal.stokes(DATA)", "pt" => "mscal.stokes(DATA, 'Ptotal')",
        "pl" => "mscal.stokes(DATA, 'Plinear')", "pa" => "mscal.stokes(DATA, 'Pangle')",
        "pft" => "mscal.stokes(DATA, 'PFtotal')", "pfl" => "mscal.stokes(DATA, 'PFlinear')",
        "mixed" => "mscal.stokes(DATA, 'I,Ptotal')"])
    iquv = column(q, "iquv")[1]
    Iq, Qq, Uq, Vq = iquv[:, 1]                    # complex I,Q,U,V (V has Im != 0 here)
    I, Q, U, V = real.((Iq, Qq, Uq, Vq))
    @test I ≈ 5.0 && Q ≈ 1.0 && U ≈ -0.4 && V ≈ 1.0
    @test imag(Vq) ≈ 2.0                           # exercises the |V|² (not real(V)²) fix
    # Phase 122: real casacore sums |Q|²+|U|²+|V|² (complex magnitude
    # squared = real(z*conj(z))), not real(z)² -- live-verified against
    # real Casacore.jl (see the _stokes_pseudo doc comment).
    ptotal_ref = sqrt(abs2(Qq) + abs2(Uq) + abs2(Vq))
    plinear_ref = sqrt(abs2(Qq) + abs2(Uq))
    @test real(column(q, "pt")[1][1, 1]) ≈ ptotal_ref
    @test real(column(q, "pl")[1][1, 1]) ≈ plinear_ref
    @test real(column(q, "pa")[1][1, 1]) ≈ 0.5 * atan(U, Q)
    @test real(column(q, "pft")[1][1, 1]) ≈ ptotal_ref / abs(Iq)
    @test real(column(q, "pfl")[1][1, 1]) ≈ plinear_ref / abs(Iq)
    # a physical + a pseudo type in the same call
    mixed = column(q, "mixed")[1]
    @test real(mixed[1, 1]) ≈ I
    @test real(mixed[2, 1]) ≈ ptotal_ref

    # unit: I == 0 -> the fractional forms return 0 (not NaN/Inf)
    zc = reshape(ComplexF32[0, 0, 0, 0], 4, 1)
    s0 = MSv2._stokes_setup([5, 6, 7, 8], [MSv2._STOKES_PSEUDO_CODES["PFTOTAL"]], false)
    @test real(MSv2._stokes_convert(s0, zc)[1, 1]) == 0.0

    # errors: pseudo type against a non-complex (Bool/Real) cell
    @test_throws ArgumentError query(main, "rownumber() == 1"; select = [
        "x" => "mscal.stokes(FLAG, 'Ptotal')"])
    @test_throws ArgumentError query(main, "rownumber() == 1"; select = [
        "x" => "mscal.stokes(WEIGHT, 'Plinear')"])
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

@testset "TaQL-lite — mscal.baseline &&& and baseline-length selection" begin
    main = readtable(SAMPLE_MS)
    a1 = Int.(column(main, "ANTENNA1")[:])
    a2 = Int.(column(main, "ANTENNA2")[:])
    nb(pred) = count(i -> pred(a1[i], a2[i]), 1:nrow(main))

    # &&& = autocorrelations only (the sample is cross-correlation-only)
    @test nrow(query(main, "mscal.baseline('0 &&&')")) == nb((x, y) -> x == y == 0)
    @test nrow(query(main, "mscal.baseline('0 &&&')")) == 0
    @test nrow(query(main, "mscal.baseline('&&&')")) == 0    # empty left antenna set

    # `_mssel_baseline_pred` unit: `&&&` truth table
    pred = MSv2._mssel_baseline_pred("0 &&&", Dict{String,Vector{Int}}(), 0:25)
    @test pred(0, 0) && !pred(0, 1) && !pred(1, 1)

    # physical baseline length (ANTENNA.POSITION); partitions the full set
    pos = column(subtable(MeasurementSet(SAMPLE_MS), "ANTENNA"), "POSITION")[:]
    blen(i, j) = hypot((Float64.(pos[i + 1]) .- Float64.(pos[j + 1]))...)
    @test nrow(query(main, "mscal.baseline('<1000m')")) == nb((x, y) -> blen(x, y) < 1000.0)
    @test nrow(query(main, "mscal.baseline('>1000m')")) == nb((x, y) -> blen(x, y) > 1000.0)
    @test nrow(query(main, "mscal.baseline('0~1000m')")) ==
          nb((x, y) -> 0.0 <= blen(x, y) <= 1000.0)
    @test nrow(query(main, "mscal.baseline('0~1km')")) ==
          nb((x, y) -> 0.0 <= blen(x, y) <= 1000.0)
    @test nrow(query(main, "mscal.baseline('!<500m')")) ==
          nb((x, y) -> !(blen(x, y) < 500.0))
    @test MSv2._mssel_is_blength("100~500m") && MSv2._mssel_is_blength("<1km")
    @test !MSv2._mssel_is_blength("0 & 1")     # a real antenna-id spec, not a length
end

# Phase 115: `;`-separated list of several `&`-baseline-pair terms
# (OR'd) sharing one `mscal.baseline` spec. A `[..]`/`{..}` bracketed
# antenna-name LIST -- the plan's original "blregexlist" characterization
# -- was investigated and found NOT to exist in real casacore (`'[0,1]&2'`
# and `'{0,1}&2'` are both flatly rejected by `tableCommand`); a plain
# comma already extends one antenna-set list across `&` with no code
# change needed (`'ea01,ea02&ea03'` == `'ea01&ea03;ea02&ea03'`, verified
# live). Phase 120 REVISITS and CORRECTS the `!`+`;` handling below --
# see `_mssel_baseline_pred`'s own comment for the accumulator formula
# read straight out of `MSAntennaParse::setTEN` and the probes that
# confirm it (a positive term unions into the running result, a
# negated term intersects with it -- not a parser bug, as Phase 115
# concluded from too little evidence).
@testset "TaQL-lite — mscal.baseline() `;`-separated multi-term specs" begin
    n2i = Dict("ea01" => [0], "ea02" => [1], "ea03" => [2], "ea04" => [3], "ea05" => [4])

    main = readtable(SAMPLE_MS)
    a1 = Int.(column(main, "ANTENNA1")[:])
    a2 = Int.(column(main, "ANTENNA2")[:])
    nb(pred) = count(i -> pred(a1[i], a2[i]), 1:nrow(main))

    # OR of two disjoint pair-terms
    r1 = nrow(query(main, "mscal.baseline('ea01&ea02;ea01&ea03')"))
    @test r1 == nb((x, y) -> (x, y) in ((0, 1), (1, 0)) || (x, y) in ((0, 2), (2, 0)))

    # a comma-extended antenna list on one side of `&`, combined with a
    # second `;`-term
    r2 = nrow(query(main, "mscal.baseline('ea01,ea02&ea03;ea04&ea05')"))
    @test r2 == nb((x, y) -> (x in (0, 1) && y == 2) || (y in (0, 1) && x == 2) ||
                            (x, y) in ((3, 4), (4, 3)))

    # duplicate terms don't double-count (a genuine OR, not a sum)
    @test nrow(query(main, "mscal.baseline('ea01&ea02;ea01&ea02')")) ==
          nrow(query(main, "mscal.baseline('ea01&ea02')"))

    # `&&&`/`&&` terms compose with `;` too
    r3 = nrow(query(main, "mscal.baseline('ea01 &&& ; ea02 &&&')"))
    @test r3 == 0   # the sample MS is cross-correlation-only

    # Phase 120: `!` combined with `;` -- correct accumulator semantics.
    # 1st-term negation seeds the accumulator negated; each later term
    # unions in (positive) or intersects (negated). `A`/`B` here are the
    # (disjoint) row sets of "ea01&ea02" / "ea01&ea03".
    isA(x, y) = (x, y) in ((0, 1), (1, 0))
    isB(x, y) = (x, y) in ((0, 2), (2, 0))
    @test nrow(query(main, "mscal.baseline('!ea01&ea02;ea01&ea03')")) ==
          nb((x, y) -> !isA(x, y) || isB(x, y))              # NOT(A) ∪ B == NOT(A), A∩B=∅
    @test nrow(query(main, "mscal.baseline('ea01&ea02;!ea01&ea03')")) ==
          nb((x, y) -> isA(x, y) && !isB(x, y))              # A ∩ NOT(B) == A, A∩B=∅
    @test nrow(query(main, "mscal.baseline('!ea01&ea02;!ea01&ea03')")) ==
          nb((x, y) -> !isA(x, y) && !isB(x, y))             # NOT(A) ∩ NOT(B) == NOT(A∪B)
    isC(x, y) = (x, y) in ((3, 4), (4, 3))
    @test nrow(query(main, "mscal.baseline('!ea01&ea02;ea01&ea03;!ea04&ea05')")) ==
          nb((x, y) -> (!isA(x, y) || isB(x, y)) && !isC(x, y))
    # a `;`-free leading `!` is unaffected (unchanged from before this phase)
    @test nrow(query(main, "mscal.baseline('!ea01&ea02')")) == nb((x, y) -> !isA(x, y))

    # `_mssel_baseline_pred` unit: both truth tables directly
    pred = MSv2._mssel_baseline_pred("ea01&ea02;ea01&ea03", n2i, 0:9)
    @test pred(0, 1) && pred(0, 2) && !pred(0, 3) && !pred(1, 2)
    predn = MSv2._mssel_baseline_pred("!ea01&ea02;ea01&ea03", n2i, 0:9)
    @test !predn(0, 1) && predn(0, 2) && predn(0, 3)         # NOT(A) everywhere except A itself

    @testset "vs real TaQL" begin
        for spec in ("ea01&ea02;ea01&ea03", "ea01,ea02&ea03;ea04&ea05",
                     "ea01&ea02;ea01&ea02", "ea01 &&& ; ea02 &&&",
                     "ea01&ea02;ea03&ea04;ea05",
                     "!ea01&ea02;ea01&ea03", "ea01&ea02;!ea01&ea03",
                     "!ea01&ea02;!ea01&ea03", "!ea01&ea02;ea01&ea03;!ea04&ea05")
            rdir = joinpath(mktempdir(), "sel")
            ok = try
                _taqlcmd("SELECT FROM \$1 WHERE mscal.baseline('$spec') GIVING '$rdir'",
                         CCT.Table(SAMPLE_MS))
                true
            catch
                false
            end
            ok || continue
            @test nrow(query(main, "mscal.baseline('$spec')")) == nrow(readtable(rdir))
        end
    end
end

# Phase 119: the REAL casacore "blregexlist" mechanism -- found by
# reading `MSAntennaGram.yy`/`.ll` + `MSAntennaParse::selectBLRegex`
# while investigating Phase 118's diameter/mount question. A `/…/`
# regex whose body contains a literal `&` (the lexer's own
# discriminator) is FULL-matched against the whole `"name_i&name_j"`
# string for every ORDERED pair of antenna indices; a leading `^`
# inside the slashes negates just that one pattern; a comma list ORs
# several patterns; the outer `!` negates the whole list's result.
# Totally different from — and NOT the — `[name1,name2]` bracket form
# Phase 115 tried and discarded (real casacore rejects that outright).
@testset "TaQL-lite — mscal.baseline() regex pair lists (BLREGEX)" begin
    n2i = Dict("ea01" => [0], "ea02" => [1], "ea03" => [2])

    # unit: the discriminator + the truth table directly
    @test MSv2._mssel_is_regex_elem("/ea01&ea02/")
    @test !MSv2._mssel_is_regex_elem("/ea01/")              # no '&' inside -> a plain per-name regex
    @test !MSv2._mssel_is_regex_elem("ea01&ea02")           # not slash-delimited
    @test MSv2._mssel_is_blregexlist("/ea01&ea02/,/ea01&ea03/")
    @test !MSv2._mssel_is_blregexlist("ea01&ea02")

    names = ["ea01", "ea02", "ea03"]
    pred = MSv2._mssel_blregex_pred("/ea01&ea02/", names)
    @test pred(0, 1) && !pred(1, 0) && !pred(0, 2)          # ordered, not symmetric
    predneg = MSv2._mssel_blregex_pred("/^ea01&ea02/", names)
    @test !predneg(0, 1) && predneg(0, 2) && predneg(1, 0)  # '^' negates just this one pattern

    main = readtable(SAMPLE_MS)
    a1 = Int.(column(main, "ANTENNA1")[:])
    a2 = Int.(column(main, "ANTENNA2")[:])
    nb(pred) = count(i -> pred(a1[i], a2[i]), 1:nrow(main))

    # ordered exact match: only the stored direction, not its reverse
    @test nrow(query(main, "mscal.baseline('/ea01&ea02/')")) ==
          nb((x, y) -> (x, y) == (0, 1))
    @test nrow(query(main, "mscal.baseline('/ea02&ea01/')")) == 0

    # glob/wildcard inside the regex
    @test nrow(query(main, "mscal.baseline('/ea0[12]&ea03/')")) ==
          nb((x, y) -> (x, y) in ((0, 2), (1, 2)))
    @test nrow(query(main, "mscal.baseline('/.*&ea03/')")) ==
          nb((x, y) -> y == 2)

    # leading '^' negates just that one pattern
    r_exact = nrow(query(main, "mscal.baseline('/ea01&ea02/')"))
    @test nrow(query(main, "mscal.baseline('/^ea01&ea02/')")) == nrow(main) - r_exact

    # comma list ORs patterns (a negated one mixed with a plain one still
    # ORs -- confirmed against real casacore, see the CHANGELOG)
    @test nrow(query(main, "mscal.baseline('/ea01&ea02/,/^ea01&ea03/')")) ==
          nb((x, y) -> (x, y) == (0, 1) || (x, y) != (0, 2))

    # the outer `!` negates the WHOLE list's OR, not the first element
    r_union = nrow(query(main, "mscal.baseline('/ea01&ea02/,/ea01&ea03/')"))
    @test nrow(query(main, "mscal.baseline('!/ea01&ea02/,/ea01&ea03/')")) == nrow(main) - r_union

    # composes with the `;`-multi-term machinery (Phase 115), either order
    @test nrow(query(main, "mscal.baseline('/ea01&ea02/;ea01&ea03')")) ==
          nb((x, y) -> (x, y) == (0, 1) || (x, y) in ((0, 2), (2, 0)))

    # mscal.feed has no antenna-name table -> a clear error, not a silent misparse
    @test_throws ArgumentError query(main, "mscal.feed('/0&1/')")

    @testset "vs real TaQL" begin
        for spec in ("/ea01&ea02/", "/ea02&ea01/", "/ea0[12]&ea03/", "/.*&ea03/",
                     "/^ea01&ea02/", "/ea01&ea02/,/ea01&ea03/",
                     "/ea01&ea02/,/^ea01&ea03/", "!/ea01&ea02/",
                     "!/ea01&ea02/,/ea01&ea03/", "/ea01&ea02/;ea01&ea03")
            rdir = joinpath(mktempdir(), "sel")
            ok = try
                _taqlcmd("SELECT FROM \$1 WHERE mscal.baseline('$spec') GIVING '$rdir'",
                         CCT.Table(SAMPLE_MS))
                true
            catch
                false
            end
            ok || continue
            @test nrow(query(main, "mscal.baseline('$spec')")) == nrow(readtable(rdir))
        end
    end
end

@testset "TaQL-lite — mscal.spw channel selection + mscal.chan" begin
    main = readtable(SAMPLE_MS)
    N = nrow(main)
    cf = column(subtable(MeasurementSet(SAMPLE_MS), "SPECTRAL_WINDOW"), "CHAN_FREQ")[1]
    nch = length(cf)                                   # 64

    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test p("mscal.chan('0:5~20') != 0").lhs.fn == "chan"
    @test MSv2._parse_chan_elem("5~20") == (:idx, 5, 20, 1)
    @test MSv2._parse_chan_elem("0~63^4") == (:idx, 0, 63, 4)
    @test MSv2._parse_chan_elem("8.0~8.05GHz")[1] === :freq
    @test_throws ArgumentError MSv2._parse_chan_elem("5~20foo")

    # mscal.spw with a :chan part -- the sample has one spw (64 chan)
    @test nrow(query(main, "mscal.spw('0:5~20')")) == N          # nonempty -> all rows
    @test nrow(query(main, "mscal.spw('0:100~200')")) == 0       # out of range
    @test nrow(query(main, "mscal.spw('1:0~10')")) == 0          # no such spw
    @test nrow(query(main, "mscal.spw('0:8.0~8.05GHz')")) == N   # freq in band
    @test nrow(query(main, "mscal.spw('0:20~30GHz')")) == 0      # freq above band

    # mscal.chan -> a per-row BitVector
    q = query(main, "any(mscal.chan('0:5~20'))"; select = ["m" => "mscal.chan('0:5~20')"])
    @test nrow(q) == N
    m = column(q, "m")[1]
    @test length(m) == nch
    @test count(m) == 16 && all(m[6:21]) && !m[5] && !m[22]      # 0-based 5..20
    q2 = query(main, "rownumber() >= 1"; select = ["m" => "mscal.chan('0:0~63^4')"])
    @test count(column(q2, "m")[1]) == 16
    q3 = query(main, "rownumber() >= 1"; select = ["m" => "mscal.chan('0:8.0~8.05GHz')"])
    @test count(column(q3, "m")[1]) == count(f -> 8.0e9 <= f <= 8.05e9, cf)
    # a spw not selected -> all-false mask
    q4 = query(main, "rownumber() >= 1"; select = ["m" => "mscal.chan('1:0~10')"])
    @test !any(column(q4, "m")[1])
end

@testset "TaQL-lite — mscal.corr() / mscal.feed()" begin
    main = readtable(SAMPLE_MS)
    N = nrow(main)
    f1 = column(main, "FEED1")[:]
    f2 = "FEED2" in Set(columnnames(main)) ? column(main, "FEED2")[:] : f1

    @test MSv2._parse_corr_types("RR,LL") == Set([5, 8])
    @test MSv2._parse_corr_types("9,I") == Set([9, 1])
    @test_throws ArgumentError MSv2._parse_corr_types("ZZ")

    # sample CORR_TYPE = [5,6,7,8] = RR/RL/LR/LL
    @test nrow(query(main, "mscal.corr('RR')")) == N
    @test nrow(query(main, "mscal.corr('6')")) == N                 # RL by code
    @test nrow(query(main, "mscal.corr('XX')")) == 0                # not in setup
    @test nrow(query(main, "mscal.corr('RR,XX')")) == N             # any match

    # feed: antenna-grammar form on FEED1/FEED2 (all feeds 0 in the sample)
    @test nrow(query(main, "mscal.feed('0')")) ==
          count(i -> f1[i] == 0 || f2[i] == 0, 1:N)
    @test nrow(query(main, "mscal.feed('1')")) == 0
    @test nrow(query(main, "mscal.feed('0 & 0')")) == 0             # & excludes autocorr
    @test nrow(query(main, "mscal.feed('0 && 0')")) == N            # && keeps it
    @test nrow(query(main, "mscal.feed('!0')")) ==
          count(i -> !(f1[i] == 0 || f2[i] == 0), 1:N)
    # Phase 98: `&&&` = self-only (every row here is feed 0 & feed 0)
    @test nrow(query(main, "mscal.feed('0 &&&')")) == N
    @test nrow(query(main, "mscal.feed('1 &&&')")) == 0
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

# Phase 101: `mscal.pbresponse()` -- primary-beam attenuation from the
# offset between ANTENNA1's *actual* POINTING.DIRECTION and the nominal
# AZEL of FIELD.PHASE_DIR. The sample MS's own POINTING rows predate its
# MAIN rows (a fixture-generation artifact -- see Phase 45 memory), so
# the response there is not physically meaningful; this test replaces
# POINTING with a controlled, time-aligned fixture instead.
@testset "TaQL-lite — mscal.pbresponse()" begin
    main = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    fld = subtable(ms, "FIELD")
    ant = subtable(ms, "ANTENNA")

    a1 = column(main, "ANTENNA1")[:]
    row0 = findfirst(==(0), a1)                    # a row observed by antenna 0
    ep0 = measure(main, "TIME", row0)
    t0sec = column(main, "TIME")[row0]
    fi0 = column(main, "FIELD_ID")[row0]

    # the nominal AZELGEO of FIELD.PHASE_DIR as seen by antenna 0 -- the
    # same computation `mscal.azel1()` / `_cache` performs internally,
    # just carried one step further to AZELGEO so it round-trips through
    # the POINTING fixture's own frame with no AZEL/AZELGEO discrepancy.
    dj = measconvert(measure(fld, "PHASE_DIR", fi0 + 1), J2000; frame = MeasFrame(epoch = ep0))
    fr0 = MeasFrame(epoch = ep0, position = measure(ant, "POSITION", 1))
    ageo0 = measconvert(dj, AZELGEO; frame = fr0)

    # `mscal.*` computes every row's value regardless of the WHERE clause,
    # so POINTING needs *some* entry for every antenna that appears as
    # ANTENNA1 (irrelevant off-antenna-0 values are fine — only antenna
    # 0's rows are checked below).
    allants = sort(unique(a1))
    _write_pointing(dir, dlon) = begin
        isdir(joinpath(dir, "POINTING")) && rm(joinpath(dir, "POINTING"); recursive = true)
        write_table(joinpath(dir, "POINTING"), "POINTING", Pair{String,Any}[
            "ANTENNA_ID" => Int32.(allants), "TIME" => fill(t0sec, length(allants)),
            "DIRECTION" => [id == 0 ? [ageo0.lon + dlon, ageo0.lat] : [0.0, 0.0]
                            for id in allants]]; nrow = length(allants),
            measures = Dict("DIRECTION" => (; kind = :direction, ref = "AZELGEO")))
    end

    tmp = mktempdir(); ms2dir = joinpath(tmp, "pb.ms")
    copyms(SAMPLE_MS, ms2dir)

    # case 1: pointing == nominal -> response ≈ 1
    _write_pointing(ms2dir, 0.0)
    q1 = query(readtable(ms2dir), "ANTENNA1 == 0 AND TIME == $t0sec";
              select = ["r" => "mscal.pbresponse('gaussian:0.008727')"])
    @test all(x -> isapprox(x, 1.0; atol = 1e-6), collect(q1.r))

    # case 2: pointing offset by a known great-circle distance Δ (a pure
    # AZELGEO longitude shift dlon = Δ/cos(lat) ≈ Δ great-circle, since
    # AZELGEO<->AZEL is a rigid rotation at this scale)
    Δ = 0.005
    _write_pointing(ms2dir, Δ / cos(ageo0.lat))
    q2 = query(readtable(ms2dir), "ANTENNA1 == 0 AND TIME == $t0sec";
              select = ["r" => "mscal.pbresponse('gaussian:0.008727')"])
    expected2 = exp(-4 * log(2) * (Δ / 0.008727)^2)
    @test all(x -> isapprox(x, expected2; atol = 1e-4), collect(q2.r))

    # airy beam: same geometry, different response function
    q3 = query(readtable(ms2dir), "ANTENNA1 == 0 AND TIME == $t0sec";
              select = ["r" => "mscal.pbresponse('airy:25.0:8.0e9')"])
    expected3 = MSv2.power_response(MSv2.AiryBeam(25.0), Δ, 8.0e9)
    @test all(x -> isapprox(x, expected3; atol = 1e-5), collect(q3.r))

    # a direction argument overrides FIELD.PHASE_DIR
    q4 = query(readtable(ms2dir), "ANTENNA1 == 0 AND TIME == $t0sec";
              select = ["r" => "mscal.pbresponse('gaussian:0.008727', 'DELAY_DIR')"])
    @test collect(q4.r)[1] ≈ collect(q2.r)[1]   # DELAY_DIR == PHASE_DIR in the sample

    # errors
    @test_throws ArgumentError query(readtable(ms2dir), "mscal.pbresponse('bogus:1.0')")
    @test_throws ArgumentError query(readtable(ms2dir), "mscal.pbresponse('gaussian:1:2')")
    @test_throws ArgumentError MSv2._taqllite_parse("mscal.pbresponse(A)", Set(["A"]))
    @test_throws ArgumentError MSv2._taqllite_parse("mscal.pbresponse()", Set{String}())

    # missing POINTING subtable -> clear error
    tmp3dir = joinpath(mktempdir(), "nopt.ms")
    copyms(SAMPLE_MS, tmp3dir;
          subtables = filter(!=("POINTING"), first.(subtables(readtable(SAMPLE_MS)))))
    @test_throws ErrorException query(readtable(tmp3dir), "mscal.pbresponse('gaussian:0.01')")
end

# Phase 102: `mscal.pbcorr(valexpr, 'spec' [, dir])` /
# `mscal.pbatten(...)` -- pure parser sugar (`valexpr / mscal.pbresponse(...)`
# / `valexpr * mscal.pbresponse(...)`), exercised here through `update!`
# to primary-beam-correct DATA in place.
@testset "TaQL-lite — mscal.pbcorr() / mscal.pbatten()" begin
    main = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    fld = subtable(ms, "FIELD")
    ant = subtable(ms, "ANTENNA")

    a1 = column(main, "ANTENNA1")[:]
    row0 = findfirst(==(0), a1)
    ep0 = measure(main, "TIME", row0)
    t0sec = column(main, "TIME")[row0]
    fi0 = column(main, "FIELD_ID")[row0]
    dj = measconvert(measure(fld, "PHASE_DIR", fi0 + 1), J2000; frame = MeasFrame(epoch = ep0))
    fr0 = MeasFrame(epoch = ep0, position = measure(ant, "POSITION", 1))
    ageo0 = measconvert(dj, AZELGEO; frame = fr0)
    allants = sort(unique(a1))
    Δ = 0.003
    where0 = "ANTENNA1 == 0 AND TIME == $t0sec"

    function _fixture()
        dir = joinpath(mktempdir(), "pbc.ms")
        copyms(SAMPLE_MS, dir)
        rm(joinpath(dir, "POINTING"); recursive = true)
        write_table(joinpath(dir, "POINTING"), "POINTING", Pair{String,Any}[
            "ANTENNA_ID" => Int32.(allants), "TIME" => fill(t0sec, length(allants)),
            "DIRECTION" => [id == 0 ? [ageo0.lon + Δ / cos(ageo0.lat), ageo0.lat] : [0.0, 0.0]
                            for id in allants]]; nrow = length(allants),
            measures = Dict("DIRECTION" => (; kind = :direction, ref = "AZELGEO")))
        testval = ComplexF32(3.0, 4.0)
        edit(dir) do t
            t[:DATA][row0] = fill(testval, size(t[:DATA][row0]))
        end
        return dir, testval
    end

    resp = exp(-4 * log(2) * (Δ / 0.008727)^2)   # matches mscal.pbresponse('gaussian:0.008727')

    dir1, testval1 = _fixture()
    n1 = update!(dir1; set = ["DATA" => "mscal.pbcorr(DATA, 'gaussian:0.008727')"], where = where0)
    @test n1 >= 1   # every ANTENNA1==0 row at t0sec, not just row0
    after1 = column(readtable(dir1; precision = :full), "DATA")[row0]
    @test after1[1, 1] ≈ testval1 / resp rtol = 1e-3   # Float32 storage precision

    dir2, testval2 = _fixture()
    n2 = update!(dir2; set = ["DATA" => "mscal.pbatten(DATA, 'gaussian:0.008727')"], where = where0)
    @test n2 >= 1
    after2 = column(readtable(dir2; precision = :full), "DATA")[row0]
    @test after2[1, 1] ≈ testval2 * resp rtol = 1e-3

    # pbcorr and pbatten are exact inverses of each other (up to storage
    # precision) -- a round trip recovers the original value
    dir3, testval3 = _fixture()
    update!(dir3; set = ["DATA" => "mscal.pbatten(DATA, 'gaussian:0.008727')"], where = where0)
    update!(dir3; set = ["DATA" => "mscal.pbcorr(DATA, 'gaussian:0.008727')"], where = where0)
    after3 = column(readtable(dir3; precision = :full), "DATA")[row0]
    @test after3[1, 1] ≈ testval3 rtol = 1e-3

    # a direction argument threads through, same as mscal.pbresponse
    dir4, testval4 = _fixture()
    update!(dir4; set = ["DATA" => "mscal.pbcorr(DATA, 'gaussian:0.008727', 'DELAY_DIR')"],
            where = where0)
    after4 = column(readtable(dir4; precision = :full), "DATA")[row0]
    @test after4[1, 1] ≈ testval4 / resp rtol = 1e-3   # DELAY_DIR == PHASE_DIR in the sample

    # errors — same validation as mscal.pbresponse, one arg earlier
    p(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test_throws ArgumentError p("mscal.pbcorr(A, 'bogus:1.0')")
    @test_throws ArgumentError p("mscal.pbcorr(A, B)")            # non-literal spec
    @test_throws ArgumentError p("mscal.pbcorr(A)")                # missing spec
    @test_throws ArgumentError p("mscal.pbatten(A, 'gaussian:1:2')")
end

# Phase 103: mscal.pbresponse per-baseline (mscal.pbresponsebl) +
# elliptical/squint beam specs in the pbresponse mini-language.
@testset "TaQL-lite — mscal.pbresponse() per-baseline + ellipse/squint" begin
    main = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    fld = subtable(ms, "FIELD")
    ant = subtable(ms, "ANTENNA")

    a1 = column(main, "ANTENNA1")[:]
    a2 = column(main, "ANTENNA2")[:]
    row0 = findfirst(i -> a1[i] == 0 && a2[i] != 0, eachindex(a1))
    @test row0 !== nothing
    ant2 = a2[row0]
    ep0 = measure(main, "TIME", row0)
    t0sec = column(main, "TIME")[row0]
    fi0 = column(main, "FIELD_ID")[row0]
    dj = measconvert(measure(fld, "PHASE_DIR", fi0 + 1), J2000; frame = MeasFrame(epoch = ep0))
    ageo = Dict(id => measconvert(dj, AZELGEO;
                    frame = MeasFrame(epoch = ep0, position = measure(ant, "POSITION", id + 1)))
                for id in (0, ant2))

    allants = sort(unique(a1) ∪ unique(a2))
    Δ1, Δ2 = 0.004, -0.006
    dirs = Dict(0 => Δ1, ant2 => Δ2)
    tmp = mktempdir(); dir = joinpath(tmp, "pbbl.ms")
    copyms(SAMPLE_MS, dir)
    rm(joinpath(dir, "POINTING"); recursive = true)
    write_table(joinpath(dir, "POINTING"), "POINTING", Pair{String,Any}[
        "ANTENNA_ID" => Int32.(allants), "TIME" => fill(t0sec, length(allants)),
        "DIRECTION" => [haskey(dirs, id) ?
                         [ageo[id].lon + dirs[id] / cos(ageo[id].lat), ageo[id].lat] :
                         [0.0, 0.0] for id in allants]]; nrow = length(allants),
        measures = Dict("DIRECTION" => (; kind = :direction, ref = "AZELGEO")))

    where0 = "ANTENNA1 == 0 AND ANTENNA2 == $ant2 AND TIME == $t0sec"
    resp1 = exp(-4 * log(2) * (Δ1 / 0.008727)^2)
    resp2 = exp(-4 * log(2) * (Δ2 / 0.008727)^2)

    qbl = query(readtable(dir), where0;
                select = ["r1" => "mscal.pbresponse('gaussian:0.008727')",
                          "rbl" => "mscal.pbresponsebl('gaussian:0.008727')"])
    @test nrow(qbl) >= 1
    @test collect(qbl.r1)[1] ≈ resp1 atol = 1e-4
    @test collect(qbl.rbl)[1] ≈ resp1 * resp2 atol = 1e-4

    # pbcorrbl / pbattenbl thread through the same product response
    testval = ComplexF32(1.5, -2.5)
    edit(dir) do t
        t[:DATA][row0] = fill(testval, size(t[:DATA][row0]))
    end
    update!(dir; set = ["DATA" => "mscal.pbattenbl(DATA, 'gaussian:0.008727')"], where = where0)
    afterbl = column(readtable(dir; precision = :full), "DATA")[row0]
    @test afterbl[1, 1] ≈ testval * resp1 * resp2 rtol = 1e-3
    n = update!(dir; set = ["DATA" => "mscal.pbcorrbl(DATA, 'gaussian:0.008727')"], where = where0)
    @test n >= 1
    afterbl2 = column(readtable(dir; precision = :full), "DATA")[row0]
    @test afterbl2[1, 1] ≈ testval rtol = 1e-3   # attenuate then correct round-trips

    # ellipse / squint specs: independently recompute the tangent-plane
    # offset the production code uses (pointing_offset of the nominal
    # target from antenna 0's actual pointing) and check the closed-form
    # formulas directly against the query result.
    dj0 = measconvert(measure(fld, "PHASE_DIR", fi0 + 1), J2000; frame = MeasFrame(epoch = ep0))
    fr0 = MeasFrame(epoch = ep0, position = measure(ant, "POSITION", 1))
    nominal_azel = measconvert(dj0, AZEL; frame = fr0)
    actual_pointing = measconvert(MDirection{AZELGEO}(ageo[0].lon + Δ1 / cos(ageo[0].lat), ageo[0].lat),
                                   AZEL; frame = fr0)
    offset = MSv2.pointing_offset(actual_pointing, nominal_azel)

    where1 = "ANTENNA1 == 0 AND TIME == $t0sec"
    qell = query(readtable(dir), where1;
                 select = ["r" => "mscal.pbresponse('ellipse:0.02:0.005:0.3')"])
    expected_ell = MSv2.power_response(MSv2.EllipticalGaussianBeam(0.02, 0.005, 0.3, 1.0), offset, 1.0)
    @test all(x -> isapprox(x, expected_ell; atol = 1e-4), collect(qell.r))

    # a scalar (gaussian/airy) beam accepts a 2-D offset transparently
    # (the generic hypot fallback), so plain pbresponse is unaffected
    # by the offset-tuple rewrite of the dispatch loop
    qgauss = query(readtable(dir), where1;
                   select = ["r" => "mscal.pbresponse('gaussian:0.008727')"])
    @test collect(qgauss.r)[1] ≈ resp1 atol = 1e-4

    # squint: a beam squinted exactly onto the source responds as if
    # perfectly pointed (peak = 1) regardless of the base beam's own
    # response at that offset
    squintspec = "gaussian:0.008727:squint:$(offset[1]):$(offset[2])"
    qsq = query(readtable(dir), where1; select = ["r" => "mscal.pbresponse('$squintspec')"])
    @test all(x -> isapprox(x, 1.0; atol = 1e-6), collect(qsq.r))

    # unit checks on the beam-spec parser itself
    fell = MSv2._pb_response_fn("ellipse:0.02:0.005:0.3")
    @test fell((0.01, 0.0)) ≈
          MSv2.power_response(MSv2.EllipticalGaussianBeam(0.02, 0.005, 0.3, 1.0), (0.01, 0.0), 1.0)
    fsq = MSv2._pb_response_fn("gaussian:0.008727:squint:0.001:-0.0005")
    @test fsq((0.001, -0.0005)) ≈ 1.0
    @test fsq((0.0, 0.0)) ≈ exp(-4 * log(2) * (hypot(0.001, -0.0005) / 0.008727)^2)
    @test_throws ArgumentError MSv2._pb_response_fn("ellipse:1:2")            # wrong arity
    @test_throws ArgumentError MSv2._pb_response_fn("gaussian:1:squint:1")    # wrong squint arity
    @test_throws ArgumentError MSv2._pb_response_fn("wombat:1:2:3")

    # parser errors: same shape as pbresponse, one arg earlier for pbcorrbl
    p2(s) = MSv2._taqllite_parse(s, Set(["A"]))
    @test_throws ArgumentError p2("mscal.pbresponsebl(A)")
    @test_throws ArgumentError p2("mscal.pbcorrbl(A, B)")
    @test p2("mscal.pbresponsebl('gaussian:0.01')").fn == "pbresponsebl:gaussian:0.01"
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

    # Phase 94: full MSSelection time grammar — single time, [t0~t1]
    # edge-inclusive, N[...] buffer, t0+dur, MS-derived field defaults
    y, mo, dd = Dates.year(d), Dates.month(d), Dates.day(d)
    dstr = "$y/$(lpad(mo,2,'0'))/$(lpad(dd,2,'0'))"
    @test nrow(query(main, "mscal.time('$dstr/00:00:00~$dstr/23:59:59')")) == N
    @test nrow(query(main, "mscal.time('[$dstr/00:00:00~$dstr/23:59:59]')")) == N
    @test nrow(query(main, "mscal.time('$dstr/00:00:00+24:00:00')")) == N   # +1 day
    # time-only (date defaults to the first row's) selects the whole run
    @test nrow(query(main, "mscal.time('00:00:00~23:59:59')")) == N
    # a single time ± (default row's own EXPOSURE)/2 picks that
    # integration's rows -- Phase 121: `dT` is the FIRST UNFLAGGED row's
    # own EXPOSURE (casacore `defaultExposure`, read out of
    # `MSTimeParse.cc:163-166`), not a mean over all rows; the sample
    # MS's EXPOSURE is uniform (3.0 everywhere) so this particular
    # assertion doesn't distinguish the two formulas -- see the
    # dedicated varied-EXPOSURE/FLAG_ROW test below for that.
    exp = Float64.(column(main, "EXPOSURE")[:])
    dTexp = exp[1] / 2
    t1s = tm[1]
    dt1 = Dates.DateTime(1858, 11, 17) + Dates.Millisecond(round(Int, t1s * 1000))
    tstr = Dates.format(dt1, "yyyy/mm/dd/HH:MM:SS")
    @test nrow(query(main, "mscal.time('$tstr')")) ==
          count(x -> abs(x - t1s) <= dTexp + 1e-6, tm)

    # uvdist: metres, km, wavelength (sample has one spw, REF_FREQUENCY 7.988 GHz)
    @test nrow(query(main, "mscal.uvdist('200~1000m')")) ==
          count(x -> 200 <= x <= 1000, d2d)
    @test nrow(query(main, "mscal.uvdist('<500')")) == count(<=(500), d2d)
    @test nrow(query(main, "mscal.uvdist('>1km')")) == count(>=(1000), d2d)
    reff = column(subtable(MeasurementSet(SAMPLE_MS), "SPECTRAL_WINDOW"), "REF_FREQUENCY")[1]
    lam(x) = x * reff / MSv2.C_LIGHT
    @test nrow(query(main, "mscal.uvdist('10~100klambda')")) ==
          count(x -> 10e3 <= lam(x) <= 100e3, d2d)

    # Phase 94: `:P%` tolerance widening
    @test nrow(query(main, "mscal.uvdist('500m:20%')")) ==
          count(x -> 400 <= x <= 600, d2d)
    @test nrow(query(main, "mscal.uvdist('200~1000m:10%')")) ==
          count(x -> 180 <= x <= 1100, d2d)

    # errors
    @test_throws ArgumentError query(main, "mscal.uvdist('foo')")   # not a range
    @test_throws ArgumentError query(main, "mscal.uvdist('1~2parsec')")
    @test_throws ArgumentError query(main, "mscal.uvdist('1~2m, 3~4klambda')")  # mixed
    @test_throws ArgumentError query(main, "mscal.time('not a date')")
end

# Phase 121: `mscal.time()` grammar/defaults investigation. Read the real
# `MSTimeGram.yy`/`.ll` + `MSTimeParse.cc` end to end (the same
# read-the-grammar-first discipline as Phases 119/120, since
# `mscal.time` is confirmed — `UDFMSCal.cc:479-491` — a direct
# pass-through to real casacore's own `msTimeGramParseCommand`, exactly
# like `mscal.baseline` is to `MSAntennaGram`): the FULL real time-value
# grammar (single time / `t0~t1` / `[t0~t1]` / `N[t0~t1]` / `t0+dur` /
# `>`/`<` bounds / `*`-wildcard fields / a comma-list OR) was ALREADY
# fully implemented in Phase 94 — no missing syntax found. Two real
# correctness bugs WERE found by reading `MSTimeParse::getDefaults`
# (`MSTimeParse.cc:114-168`) and fixed: the "default row" (both the
# calendar defaults AND the single-time/edge tolerance `dT`) is the
# FIRST UNFLAGGED row (`FLAG_ROW`), not row 1 unconditionally; `dT` is
# that row's OWN `EXPOSURE`, not a mean over every row's `EXPOSURE`
# (`defaultExposure = exposure(firstLogicalRow,"s")`, verbatim).
#
# A live oracle for these fixes was NOT reachable: `mscal.time`'s
# `UDFMSCal::getDataNode` unconditionally constructs a full
# `MeasurementSet(table)`, whose C++ constructor strictly validates the
# table against casacore's `MSMainEnums` requirements. Investigating hit
# two real, separate writer gaps: (1) `FLAG_CATEGORY` needs a `CATEGORY`
# keyword casacore's own writable-table code silently adds but a
# read-only open (every cross-check in this suite) just throws on —
# fixed here (`_flag_category_kw()`, stamped by `create_ms` and
# `addcolumn!`); (2) past that, `MeasurementSet`'s validator ALSO
# requires every `MSMainEnums`-required column's `QuantumUnits`/
# `MEASINFO` keywords to exactly match casacore's own standard values —
# `create_ms` stamps none of these today, a genuinely large follow-up
# (a full measures/units audit of the synthesised MAIN + every
# subtable), out of this phase's scope. Documented here rather than
# silently worked around; the `dT`/default-row fix is instead verified
# directly against a hand-built table with intentionally varied
# `FLAG_ROW`/`EXPOSURE`, matching the exact formula read from
# `MSTimeParse.cc`.
@testset "TaQL-lite — mscal.time() default-row / dT (Phase 121)" begin
    t0 = 4.6e9
    tm = [t0, t0 + 100.0, t0 + 200.0, t0 + 300.0]
    fr = [true, false, false, false]           # row 1 flagged -> skip it
    ex = [999.0, 10.0, 10.0, 10.0]              # row 1's huge EXPOSURE must be ignored
    dir = mktempdir()
    p = joinpath(dir, "T")
    write_table(p, "T", Pair{String,Any}["TIME" => tm, "FLAG_ROW" => fr,
                                         "EXPOSURE" => ex]; nrow = 4)
    tt = readtable(p)
    cn = Set(columnnames(tt))

    # the default row is row 2 (first unflagged), dT = 10/2 = 5 s
    mjd2 = (t0 + 100.0) / 86400
    within4 = MSv2._mssel_time(tt, string(mjd2 + 4 / 86400), cn, 4)
    within6 = MSv2._mssel_time(tt, string(mjd2 + 6 / 86400), cn, 4)
    @test within4 == Bool[0, 1, 0, 0]           # inside dT=5 -> matches row 2
    @test within6 == Bool[0, 0, 0, 0]           # outside dT=5 -> matches nothing
    # if `dT` had (wrongly) used row 1's EXPOSURE=999 or the mean
    # (~257), both offsets would match row 2 -- neither does.

    # no FLAG_ROW column at all -> falls back to row 1 (unchanged
    # pre-Phase-121 behaviour)
    # no FLAG_ROW column: dT = row 1's own EXPOSURE/2 = 499.5, a huge
    # tolerance (a single isolated row proves it's genuinely row 1's
    # EXPOSURE, not a fallback constant, driving the match)
    p2 = joinpath(dir, "T2")
    write_table(p2, "T2", Pair{String,Any}["TIME" => [t0], "EXPOSURE" => [999.0]]; nrow = 1)
    tt2 = readtable(p2)
    cn2 = Set(columnnames(tt2))
    mjd1 = t0 / 86400
    @test MSv2._mssel_time(tt2, string(mjd1 + 490 / 86400), cn2, 1) == Bool[1]  # within 499.5
    @test MSv2._mssel_time(tt2, string(mjd1 + 510 / 86400), cn2, 1) == Bool[0]  # outside 499.5

    # every row flagged (the committed sample fixture's own state) ->
    # MeasurementSets stays lenient and still falls back to row 1's own
    # EXPOSURE for dT, rather than replicating casacore's "No logical
    # row zero found" throw
    p3 = joinpath(dir, "T3")
    write_table(p3, "T3", Pair{String,Any}["TIME" => [t0], "FLAG_ROW" => [true],
                                           "EXPOSURE" => [999.0]]; nrow = 1)
    tt3 = readtable(p3)
    cn3 = Set(columnnames(tt3))
    @test MSv2._mssel_time(tt3, string(mjd1 + 490 / 86400), cn3, 1) == Bool[1]
    @test MSv2._mssel_time(tt3, string(mjd1 + 510 / 86400), cn3, 1) == Bool[0]

    # `create_ms` / `addcolumn!` now stamp FLAG_CATEGORY's required
    # CATEGORY keyword (empty String[], matching casacore's own default)
    d2 = mktempdir()
    ms = joinpath(d2, "cms.ms")
    create_ms(ms; nrow = 4, nchan = 2, ncorr = 1, nant = 2)
    kw = columndesc(readtable(ms), "FLAG_CATEGORY").keywords
    @test "CATEGORY" in kw.names
    @test kw.values[findfirst(==("CATEGORY"), kw.names)] == String[]
end

# Phase 128: `*` wildcard fields + the `N[t0~t1]` explicit edge-buffer
# form. A live oracle is blocked (see the doc comment above
# `_mssel_time` for the two independent reasons found — a real
# casacore segfault in `MSTimeParse::getDefaults()` on an all-flagged
# writable table, and the pre-existing `MSTableImpl::validate`
# measures/units gap) so these are hand-built-fixture + direct
# `_mssel_time` checks, same discipline as the Phase 121 testset above.
@testset "TaQL-lite — mscal.time() `*` wildcard / N[t0~t1] (Phase 128)" begin
    # `*` is a real grammar token (STAR), identical to an omitted field
    @test MSv2._mstime_fields("*") == MSv2._mstime_fields("")
    @test MSv2._mstime_fields("2024/05/24/*") == (:cal, (2024.0, 5.0, 24.0, -1.0, -1.0, -1.0))
    @test MSv2._mstime_fields("*/*/*") == MSv2._mstime_fields("")

    t0 = 4.6e9; gap = 10.0
    tm = [t0, t0 + gap]
    dir = mktempdir()
    p = joinpath(dir, "T")
    write_table(p, "T", Pair{String,Any}["TIME" => tm, "EXPOSURE" => [8.0, 8.0]]; nrow = 2)
    tt = readtable(p)
    cn = Set(columnnames(tt))
    d0 = MSv2.MJD_EPOCH + Dates.Millisecond(round(Int, t0 * 1000))
    dstr = Dates.format(d0, "yyyy/mm/dd")
    tstr = Dates.format(d0, "HH:MM:SS")

    # bare `*` -> the default row's own time (row 1, no FLAG_ROW column)
    # -> within dT=4.0s of t0 only (the second row is 10s away)
    @test MSv2._mssel_time(tt, "*", cn, 2) == Bool[1, 0]
    # date fixed + time wildcard, and the reverse -- both fields
    # individually wildcarded still resolve to the same default
    @test MSv2._mssel_time(tt, "$dstr/*", cn, 2) == Bool[1, 0]
    @test MSv2._mssel_time(tt, "*/*/*/$tstr", cn, 2) == Bool[1, 0]

    # N[t0~t0]: an explicit buffer, literal (no /2) -- bigger than the
    # 10s gap matches both rows, smaller matches only the first
    spec0 = "$dstr/$tstr~$dstr/$tstr"
    @test MSv2._mssel_time(tt, "12[$spec0]", cn, 2) == Bool[1, 1]
    @test MSv2._mssel_time(tt, "3[$spec0]", cn, 2) == Bool[1, 0]
    # bracket-only (no N prefix) uses dT=4.0s < the 10s gap -> row 1 only
    @test MSv2._mssel_time(tt, "[$spec0]", cn, 2) == Bool[1, 0]
    # a plain (non-bracket) t0~t0 range has NO buffer at all
    # (`selectTimeRange`'s `edgeInclusive=false` branch: plain
    # `>=lo && <=hi`, no `abs(x-edge)<buf` term) -> with lo==hi==t0,
    # only the exact value matches
    @test MSv2._mssel_time(tt, spec0, cn, 2) == Bool[1, 0]

    # the buffer literal is casacore's own FNUMBER (INT | INT. | .INT |
    # INT.INT) -- `.5`/`12.` spellings must parse, not just `12`/`12.5`
    @test MSv2._mssel_time(tt, ".00001[$spec0]", cn, 2) == Bool[1, 0]   # ~0 buffer
    @test MSv2._mssel_time(tt, "12.[$spec0]", cn, 2) == Bool[1, 1]      # trailing-dot form
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
            _taqlcmd("SELECT mscal.stokes(DATA, 'I') AS SI, mscal.stokes(DATA) AS SA, " *
                     "mscal.stokes(DATA, 'Ptotal') AS PT, mscal.stokes(DATA, 'Plinear') AS PL, " *
                     "mscal.stokes(DATA, 'Pangle') AS PA, mscal.stokes(DATA, 'PFtotal') AS PFT, " *
                     "mscal.stokes(DATA, 'PFlinear') AS PFL FROM \$1", CCT.Table(SAMPLE_MS))
        catch
            nothing
        end
        if ts !== nothing
            main = readtable(SAMPLE_MS; precision = :full)
            q = query(main, "rownumber() >= 1"; select = [
                "si" => "mscal.stokes(DATA, 'I')", "sa" => "mscal.stokes(DATA)",
                "pt" => "mscal.stokes(DATA, 'Ptotal')", "pl" => "mscal.stokes(DATA, 'Plinear')",
                "pa" => "mscal.stokes(DATA, 'Pangle')", "pft" => "mscal.stokes(DATA, 'PFtotal')",
                "pfl" => "mscal.stokes(DATA, 'PFlinear')"])
            for i in (5, 123, 400)
                @test vec(column(q, "si")[i]) ≈ vec(ComplexF64.(ts[:SI][i])) rtol = 1e-5
                @test column(q, "sa")[i] ≈ ComplexF64.(ts[:SA][i]) rtol = 1e-5
                # Phase 122: live-verified real casacore uses |Q|²+|U|²+|V|²
                # (complex magnitude squared) for Ptotal/Plinear, and abs(I)
                # (not real(I)) for the PFtotal/PFlinear divisor.
                @test real(column(q, "pt")[i][1, 1]) ≈ real(ts[:PT][i][1, 1]) rtol = 1e-4
                @test real(column(q, "pl")[i][1, 1]) ≈ real(ts[:PL][i][1, 1]) rtol = 1e-4
                @test real(column(q, "pa")[i][1, 1]) ≈ real(ts[:PA][i][1, 1]) rtol = 1e-4
                # I == 0 at this cell -> real casacore divides by 0 (NaN);
                # we deliberately return 0.0 instead (documented guard).
                if isfinite(real(ts[:PFT][i][1, 1]))
                    @test real(column(q, "pft")[i][1, 1]) ≈ real(ts[:PFT][i][1, 1]) rtol = 1e-4
                    @test real(column(q, "pfl")[i][1, 1]) ≈ real(ts[:PFL][i][1, 1]) rtol = 1e-4
                else
                    @test real(column(q, "pft")[i][1, 1]) == 0.0
                    @test real(column(q, "pfl")[i][1, 1]) == 0.0
                end
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
                           ("uvdist", "10~100klambda"), ("uvdist", ">1km"),
                           ("spw", "0:5~20"), ("corr", "RR"), ("feed", "0"),
                           ("baseline", "0 &&&"), ("baseline", "0 && 1"),
                           ("baseline", "<1000m"), ("baseline", "0~1000m")]
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
