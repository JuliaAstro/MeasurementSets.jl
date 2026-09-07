# Phase 66: measures / reference frames.
#
# MEASINFO parsing (src/measures/), typed `measure()` reads, and
# reference-frame conversions via SOFAExt (SOFA.jl) with
# ΔUT1 / polar motion from EarthOrientationExt.  The
# `casatools.measures()` oracle (test/measures_fixture.py) is used when a
# CASA python3 is present, else hand-computed / SOFA-only checks.

import SOFA
import EarthOrientation

const _MEAS_CASA = get(ENV, "MEASUREMENTSETS_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")
const _HAVE_MEAS_CASA = isfile(_MEAS_CASA)

@testset "measures — extensions loaded" begin
    @test Base.get_extension(MSv2, :SOFAExt) !== nothing
    @test Base.get_extension(MSv2, :EarthOrientationExt) !== nothing
end

@testset "measures — MEASINFO parse" begin
    ms = MeasurementSet(SAMPLE_MS)
    main = readtable(SAMPLE_MS)

    mi = measinfo(main, "TIME")
    @test mi.kind === :epoch && mi.fixedref == "UTC" && mi.units == ["s"]
    @test measinfo(main, "UVW").kind === :uvw
    @test measinfo(main, "UVW").fixedref == "ITRF"

    ant = subtable(ms, "ANTENNA")
    @test measinfo(ant, "POSITION").fixedref == "ITRF"

    fld = subtable(ms, "FIELD")
    pd = measinfo(fld, "PHASE_DIR")
    @test pd.kind === :direction && pd.fixedref === nothing
    @test pd.varrefcol == "PhaseDir_Ref"
    @test !isempty(pd.tabcodes)
    # resolve a per-row frame through the code map
    @test MSv2._ref_string(pd, fld, "PHASE_DIR", 1) in pd.tabtypes

    spw = subtable(ms, "SPECTRAL_WINDOW")
    cf = measinfo(spw, "CHAN_FREQ")
    @test cf.kind === :frequency && cf.varrefcol == "MEAS_FREQ_REF"

    @test measinfo(main, "ANTENNA1") === nothing
end

@testset "measures — typed measure() reads" begin
    ms = MeasurementSet(SAMPLE_MS)
    main = readtable(SAMPLE_MS)

    e = measure(main, "TIME", 1)
    @test e isa MEpoch{UTC}
    @test e.mjd ≈ getcell(main, "TIME", 1) / 86400 rtol=1e-12

    p = measure(subtable(ms, "ANTENNA"), "POSITION", 1)
    @test p isa MPosition{ITRF}
    @test (p.x, p.y, p.z) == Tuple(getcell(subtable(ms, "ANTENNA"), "POSITION", 1))

    d = measure(subtable(ms, "FIELD"), "PHASE_DIR", 1)
    @test d isa MDirection
    raw = getcell(subtable(ms, "FIELD"), "PHASE_DIR", 1)
    @test d.lon ≈ raw[1, 1] && d.lat ≈ raw[2, 1]

    f = measure(subtable(ms, "SPECTRAL_WINDOW"), "CHAN_FREQ", 1)
    @test f isa Vector{<:MFrequency}
    @test f[1].hz ≈ getcell(subtable(ms, "SPECTRAL_WINDOW"), "CHAN_FREQ", 1)[1]
end

@testset "measures — epoch conversions (SOFA)" begin
    # round-trips
    for R in (TAI, TT, TDB, UT1)
        e = MEpoch{UTC}(60454.42255)
        back = measconvert(measconvert(e, R), UTC)
        @test back.mjd ≈ e.mjd atol=1e-9      # < ~0.1 ms
    end
    # UTC->TAI is exactly ΔAT seconds
    e = MEpoch{UTC}(58849.0)                  # 2020-01-01, ΔAT = 37 s
    @test (measconvert(e, TAI).mjd - e.mjd) * 86400 ≈ 37.0 atol=1e-6
end

@testset "measures — direction conversions (SOFA)" begin
    d = MDirection{J2000}(2.0, 0.5)
    # GALACTIC round-trips near-exactly (pure rotation)
    b = measconvert(measconvert(d, GALACTIC), J2000)
    @test b.lon ≈ d.lon atol=1e-10
    @test b.lat ≈ d.lat atol=1e-10
    # B1950 (FK4 e-terms) / ECLIPTIC round-trip to sub-arcsecond
    for R in (B1950, ECLIPTIC)
        b = measconvert(measconvert(d, R), J2000)
        @test b.lon ≈ d.lon atol=1e-6
        @test b.lat ≈ d.lat atol=1e-6
    end
    # APP / AZEL need a frame; round-trip
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150))
    for R in (APP, AZEL, HADEC)
        m = measconvert(d, R; frame = fr)
        @test m isa MDirection{R}
        b = measconvert(m, J2000; frame = fr)
        @test rem2pi(b.lon - d.lon, RoundNearest) ≈ 0 atol=3e-6
        @test b.lat ≈ d.lat atol=3e-6
    end
end

@testset "measures — frequency conversions (SOFA)" begin
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150),
                   direction = MDirection{J2000}(2.0, 0.5))
    f = MFrequency{TOPO}(100.0e9)
    for R in (GEO, BARY, LSRK, LSRD, GALACTO)
        g = measconvert(f, R; frame = fr)
        @test g isa MFrequency{R}
        # shift is small (< ~250 km/s / c)
        @test abs(g.hz - f.hz) / f.hz < 1e-3
        # round-trip
        back = measconvert(g, TOPO; frame = fr)
        @test back.hz ≈ f.hz rtol=1e-12
    end
end

@testset "measures — radial-velocity conversions (SOFA)" begin
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150),
                   direction = MDirection{J2000}(2.0, 0.5))
    v = MRadialVelocity{LSRK}(20_000.0)
    for R in (BARY, LSRD, GEO, TOPO, GALACTO)
        g = measconvert(v, R; frame = fr)
        @test g isa MRadialVelocity{R}
        @test abs(g.mps - v.mps) < 60_000.0              # bounded by the frame speed
        back = measconvert(g, LSRK; frame = fr)
        @test back.mps ≈ v.mps atol = 1e-6
    end
    # BARY identity via the reftype short-circuit
    @test measconvert(MRadialVelocity{BARY}(1234.0), BARY; frame = fr) ===
          MRadialVelocity{BARY}(1234.0)
    # no direction in the frame -> a clear error
    @test_throws ErrorException measconvert(v, BARY; frame = MeasFrame())
end

@testset "measures — Doppler conventions + rest-frequency bridge" begin
    # convention round-trips (pure algebra, no SOFA)
    d0 = MDoppler{RADIO}(0.01)
    @test measconvert(d0, RADIO) === d0
    for C in (OPTICAL, RATIO, BETA, GAMMA)
        @test measconvert(measconvert(d0, C), RADIO).d ≈ 0.01 rtol = 1e-12
    end
    @test measconvert(d0, RATIO).d ≈ 0.99
    @test measconvert(d0, OPTICAL).d ≈ 1 / 0.99 - 1
    @test Z === OPTICAL && RELATIVISTIC === BETA
    @test_throws ErrorException measconvert(MDoppler{RADIO}(0.1), MeasurementSets.OtherDoppler{:X})

    # MFrequency <-> rest frequency
    ν0 = 1.42040575e9
    f = MFrequency{LSRK}(1.4e9)
    d = doppler(f, ν0)
    @test d isa MDoppler{BETA}
    @test frequency(d, ν0).hz ≈ 1.4e9
    @test restfrequency(f, d).hz ≈ ν0
    @test frequency(d, MFrequency{REST}(ν0)).hz ≈ 1.4e9        # accepts an MFrequency rest
    @test radialvelocity(d).mps ≈ MSv2.C_LIGHT * d.d

    # MRadialVelocity <-> MDoppler
    @test doppler(MRadialVelocity{LSRK}(3e5)).d ≈ 3e5 / MSv2.C_LIGHT
    @test radialvelocity(doppler(MRadialVelocity{BARY}(-1.2e5))).mps ≈ -1.2e5

    # Phase 74: shiftfreq + one-step bridges
    @test shiftfreq(d, ν0) ≈ frequency(d, ν0).hz                  # scalar == fromDoppler
    @test shiftfreq(measconvert(d, RADIO), ν0) ≈ shiftfreq(d, ν0) # non-BETA converted first
    sf = shiftfreq(d, MFrequency{TOPO}(ν0))
    @test sf isa MFrequency{TOPO} && sf.hz ≈ 1.4e9                # frame kept
    grid = [1.40e9, 1.42e9, 1.44e9]
    @test shiftfreq(d, grid) ≈ grid .* MSv2._beta_factor(d)
    @test eltype(shiftfreq(d, [MFrequency{LSRK}(x) for x in grid])) === MFrequency{LSRK}

    @test radialvelocity(f, ν0) === radialvelocity(doppler(f, ν0))
    @test frequency(MRadialVelocity{LSRK}(3e5), ν0).hz ≈ frequency(doppler(MRadialVelocity{LSRK}(3e5)), ν0).hz
    fs = [MFrequency{LSRK}(1.4e9 + 1e7i) for i in 0:3]
    vs = radialvelocity.(fs, ν0)                                  # broadcast -> a velocity axis
    @test vs isa Vector{MRadialVelocity{LSRK}} && issorted(getfield.(vs, :mps); rev = true)

    # one SPW's CHAN_FREQ -> a velocity axis (broadcast over the channels)
    spw = subtable(MeasurementSet(SAMPLE_MS), "SPECTRAL_WINDOW")
    cf1 = measure(spw, "CHAN_FREQ", 1)                             # Vector{MFrequency{...}}
    axis = radialvelocity.(cf1, ν0)
    @test length(axis) == length(cf1) && eltype(axis) <: MRadialVelocity
    @test shiftfreq(MDoppler{BETA}(0.001), cf1) isa Vector{eltype(cf1)}

    # MEASINFO round-trip
    dir = mktempdir()
    write_table(joinpath(dir, "T"), "T",
                Pair{String,Any}["DOP" => [MDoppler{RADIO}(0.01i) for i in 1:3]]; nrow = 3)
    t = readtable(joinpath(dir, "T"))
    @test measinfo(t, "DOP").kind === :doppler && measinfo(t, "DOP").fixedref == "RADIO"
    @test measure(t, "DOP")[2] === MDoppler{RADIO}(0.02)
end

@testset "measures — write MEASINFO round-trip" begin
    dir = mktempdir()
    tab = joinpath(dir, "T")
    dvals = [reshape([1.0 + 0.01i, 0.2 + 0.01i], 2, 1) for i in 1:4]
    fref = Int32[1, 5, 1, 5]
    write_table(tab, "T",
        ["D" => dvals, "F" => Float64.(1e9 .* (1:4)), "F_REF" => fref];
        nrow = 4,
        measures = Dict(
            "D" => (; kind = :direction, ref = "J2000", units = ["rad", "rad"]),
            "F" => (; kind = :frequency, varrefcol = "F_REF",
                      tabtypes = ["LSRK", "TOPO"], tabcodes = [1, 5], units = ["Hz"])))
    r = readtable(tab)
    md = measinfo(r, "D")
    @test md.kind === :direction && md.fixedref == "J2000" && md.units == ["rad", "rad"]
    mf = measinfo(r, "F")
    @test mf.varrefcol == "F_REF" && mf.tabcodes == [1, 5]
    @test MSv2._ref_string(mf, r, "F", 2) == "TOPO"
    @test measure(r, "D", 1) isa MDirection{J2000}
end

# Phase 70: a column whose Julia eltype is a Measure is flattened to
# plain numbers + a MEASINFO/QuantumUnits keyword automatically.
@testset "measures — write from Measure-typed columns" begin
    dir = mktempdir()
    tab = joinpath(dir, "MT")
    T = [MEpoch{UTC}(58000.0 + i) for i in 1:4]
    D = [MDirection{J2000}(0.1i, 0.2i) for i in 1:4]
    P = [MPosition{ITRF}(1e6 + i, 2e6 + i, -3e6 + i) for i in 1:4]
    F = [MFrequency{TOPO}(1.4e9 + 1e6i) for i in 1:4]
    write_table(tab, "MT", Pair{String,Any}["T" => T, "D" => D, "P" => P, "F" => F]; nrow = 4)
    r = readtable(tab)

    @test measinfo(r, "T").kind === :epoch && measinfo(r, "T").fixedref == "UTC"
    @test column(r, "T")[:] ≈ (58000.0 .+ (1:4)) .* 86400.0        # stored as seconds
    @test [m.mjd for m in measure(r, "T")] ≈ 58000.0 .+ (1:4)

    @test columndesc(r, "D").keywords["QuantumUnits"] == ["rad", "rad"]
    md3 = measure(r, "D")[3]
    @test md3 isa MDirection{J2000} && md3.lon ≈ 0.3 && md3.lat ≈ 0.6
    mp2 = measure(r, "P")[2]
    @test mp2 isa MPosition{ITRF} && mp2.x ≈ 1e6 + 2 && mp2.z ≈ -3e6 + 2
    @test measure(r, "F")[1].hz ≈ 1.4e9 + 1e6
    @test measinfo(r, "F").fixedref == "TOPO"

    # an explicit `measures=` entry for the same column wins (no error)
    tab2 = joinpath(dir, "MT2")
    write_table(tab2, "MT2", Pair{String,Any}["T" => T]; nrow = 4,
                measures = Dict("T" => (; kind = :epoch, ref = "TAI", units = ["s"])))
    @test measinfo(readtable(tab2), "T").fixedref == "TAI"

    if _HAVE_CASACORE
        ct = CCT.Table(tab)
        @test size(ct[:T][:]) == (4,)                              # opens + reads
    end
end

@testset "measures — addcolumn! from a Measure-typed column" begin
    dir = mktempdir()
    tab = joinpath(dir, "AC")
    write_table(tab, "AC", Pair{String,Any}["A" => collect(1.0:5.0)]; nrow = 5)
    edit(tab) do t
        addcolumn!(t, "PDIR", [MDirection{J2000}(0.1, 0.5) for _ in 1:5])
    end
    r = readtable(tab)
    @test measinfo(r, "PDIR").kind === :direction
    pd = measure(r, "PDIR")[2]
    @test pd isa MDirection{J2000} && pd.lon ≈ 0.1 && pd.lat ≈ 0.5
end

# Phase 75: MBaseline / MuvW vector measures.
@testset "measures — MBaseline / MuvW" begin
    main = readtable(SAMPLE_MS)

    # read: UVW is a `type = "uvw"` column
    u1 = measure(main, "UVW", 1)
    @test u1 isa MuvW{ITRF}
    @test (u1.u, u1.v, u1.w) == Tuple(column(main, "UVW")[1])
    @test measinfo(main, "UVW").kind === :uvw
    @test measure(main, "UVW") isa Vector{<:MuvW}

    # a hand-built `type = "baseline"` column round-trips
    dir = mktempdir()
    btab = joinpath(dir, "BL")
    B = [MBaseline{ITRF}(1e3 + i, 2e3 - i, 3e3 + 2i) for i in 1:3]
    W = [MuvW{J2000}(10.0i, 20.0 - i, 30.0 + i) for i in 1:3]
    write_table(btab, "BL", Pair{String,Any}["B" => B, "W" => W]; nrow = 3)
    r = readtable(btab)
    @test measinfo(r, "B").kind === :baseline && measinfo(r, "B").fixedref == "ITRF"
    @test measinfo(r, "W").kind === :uvw && measinfo(r, "W").fixedref == "J2000"
    @test columndesc(r, "B").keywords["QuantumUnits"] == ["m", "m", "m"]
    mb2 = measure(r, "B")[2]
    @test mb2 isa MBaseline{ITRF} && (mb2.x, mb2.y, mb2.z) == (1e3 + 2, 2e3 - 2, 3e3 + 4)
    mw3 = measure(r, "W")[3]
    @test mw3 isa MuvW{J2000} && (mw3.u, mw3.v, mw3.w) == (30.0, 17.0, 33.0)
    if _HAVE_CASACORE
        @test size(CCT.Table(btab)[:B][:, :]) == (3, 3)
    end

    ext = Base.get_extension(MSv2, :SOFAExt)
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150),
                   direction = MDirection{J2000}(2.0, 0.5))

    # MBaseline: pure rotation preserves length, round-trips
    b = MBaseline{ITRF}(120.0, -340.0, 55.0)
    r_in = hypot(b.x, b.y, b.z)
    for T in (J2000, GALACTIC, APP)
        c = measconvert(b, T; frame = fr)
        @test c isa MBaseline{T}
        @test hypot(c.x, c.y, c.z) ≈ r_in rtol = 1e-12
        back = measconvert(c, ITRF; frame = fr)
        @test (back.x, back.y, back.z) .- (b.x, b.y, b.z) |> v -> all(abs.(v) .< 1e-6)
    end
    @test measconvert(MBaseline{ITRF}(0.0, 0.0, 0.0), J2000; frame = fr) ===
          MBaseline{J2000}(0.0, 0.0, 0.0)

    # MuvW: round-trips; the w component (delay) is frame-invariant
    u = MuvW{ITRF}(120.0, -340.0, 55.0)
    for T in (J2000, GALACTIC)
        c = measconvert(u, T; frame = fr)
        @test c isa MuvW{T}
        @test c.w ≈ u.w rtol = 1e-9
        back = measconvert(c, ITRF; frame = fr)
        @test all(abs.((back.u, back.v, back.w) .- (u.u, u.v, u.w)) .< 1e-6)
    end
    @test_throws ErrorException measconvert(u, J2000; frame = MeasFrame())

    # _topole / _frompole are inverse; hand-derived origin case
    d0 = MDirection{J2000}(0.0, 0.0)
    v = (7.0, -3.0, 11.0)
    @test all(abs.(ext._frompole(ext._topole(v, d0), d0) .- v) .< 1e-12)
    R0 = ext._uvw_pole_R(d0)
    @test all(abs.(collect(ext._frompole((1.0, 2.0, 3.0), d0)) .- [-3.0, 2.0, 1.0]) .< 1e-9)
end

# Phase 76: solar-system-body direction reference frames.
@testset "measures — solar-system body directions" begin
    # read: a fixed `Ref` body-frame column
    dir = mktempdir()
    tab = joinpath(dir, "SD")
    D = [MDirection{SUN}(0.0, 0.0) for _ in 1:3]
    write_table(tab, "SD", Pair{String,Any}["D" => D]; nrow = 3)
    r = readtable(tab)
    @test measinfo(r, "D").fixedref == "SUN"
    @test measure(r, "D", 1) isa MDirection{SUN}

    # VarRefCol with a bare-enum code (SUN = 40, MOON = 41)
    tab2 = joinpath(dir, "SV")
    dv = [reshape([0.0, 0.0], 2, 1) for _ in 1:2]
    write_table(tab2, "SV",
        ["D" => dv, "D_REF" => Int32[40, 41]]; nrow = 2,
        measures = Dict("D" => (; kind = :direction, varrefcol = "D_REF")))
    r2 = readtable(tab2)
    @test measure(r2, "D", 1) isa MDirection{SUN}
    @test measure(r2, "D", 2) isa MDirection{MOON}

    @test MSv2._frame_type(:direction, "SUN") === SUN
    @test MSv2._frame_type(:direction, "PLUTO") <: MSv2.OtherRef   # still parses

    # convert (SOFA)
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150),
                   direction = MDirection{J2000}(2.0, 0.5))
    for B in (MERCURY, VENUS, MARS, JUPITER, SATURN, URANUS, NEPTUNE, SUN, MOON)
        j = measconvert(MDirection{B}(0.0, 0.0), J2000; frame = fr)
        @test j isa MDirection{J2000}
        @test -pi <= j.lon <= 2pi && -pi/2 <= j.lat <= pi/2
        a = measconvert(MDirection{B}(0.0, 0.0), AZEL; frame = fr)
        @test -pi/2 <= a.lat <= pi/2
    end
    # a body direction round-trips J2000 -> GALACTIC -> J2000 (pure rotation)
    dj = measconvert(MDirection{JUPITER}(0.0, 0.0), J2000; frame = fr)
    dj2 = measconvert(measconvert(dj, GALACTIC; frame = fr), J2000; frame = fr)
    @test dj.lon ≈ dj2.lon atol = 1e-9
    @test dj.lat ≈ dj2.lat atol = 1e-9

    @test_throws ErrorException measconvert(MDirection{J2000}(1.0, 0.5), SUN; frame = fr)
    @test_throws ErrorException measconvert(MDirection{SUN}(0.0, 0.0), J2000; frame = MeasFrame())
end

if _HAVE_MEAS_CASA
    @testset "measures — casatools oracle cross-check" begin
        ref_jl = joinpath(mktempdir(), "measref.jl")
        script = joinpath(@__DIR__, "measures_fixture.py")
        run(`$_MEAS_CASA $script $ref_jl`)
        ref = include(ref_jl)

        fr = MeasFrame(
            epoch = MEpoch{UTC}(ref.epochs_mjd[1]),
            position = MPosition{ITRF}(ref.obs_xyz...),
            direction = MDirection{J2000}(ref.src_ra, ref.src_dec))

        # epoch
        for (k, e_mjd) in enumerate(ref.epochs_mjd)
            e = MEpoch{UTC}(e_mjd)
            row = ref.epoch[k]
            @test measconvert(e, TAI).mjd ≈ row.TAI atol=1e-9
            @test measconvert(e, TT).mjd  ≈ row.TT  atol=1e-9
            @test measconvert(e, TDB).mjd ≈ row.TDB atol=1e-7   # ~ms w/o full frame
            @test measconvert(e, UT1).mjd ≈ row.UT1 atol=1e-7
        end

        # direction (arcsec tolerance; APP/AZEL depend on EOP)
        d = MDirection{J2000}(ref.src_ra, ref.src_dec)
        as = MSv2.ARCSEC
        for (frame, T) in (("B1950", B1950), ("GALACTIC", GALACTIC),
                           ("APP", APP), ("AZEL", AZEL), ("AZELGEO", AZELGEO),
                           ("HADEC", HADEC))
            got = measconvert(d, T; frame = fr)
            want = getproperty(ref.direction, Symbol(frame))
            @test rem2pi(got.lon - want[1], RoundNearest) ≈ 0 atol = 5as
            @test got.lat ≈ want[2] atol = 5as
        end

        # solar-system-body directions: SOFA plan94 / moon98 vs casacore's
        # own ephemeris. Per-body tolerance = the plan94 accuracy floor.
        bodytol = Dict("SUN" => 20as, "MOON" => 30as, "MERCURY" => 20as,
                       "VENUS" => 20as, "MARS" => 40as, "JUPITER" => 120as)
        for (name, T) in (("SUN", SUN), ("MOON", MOON), ("MERCURY", MERCURY),
                          ("VENUS", VENUS), ("MARS", MARS), ("JUPITER", JUPITER))
            tol = bodytol[name]
            want = getproperty(ref.planet, Symbol(name))
            gj = measconvert(MDirection{T}(0.0, 0.0), J2000; frame = fr)
            @test rem2pi(gj.lon - want.j2000[1], RoundNearest) * cos(gj.lat) ≈ 0 atol = tol
            @test gj.lat ≈ want.j2000[2] atol = tol
            ga = measconvert(MDirection{T}(0.0, 0.0), AZEL; frame = fr)
            # AZEL adds the Moon topocentric term; residual = diurnal
            # aberration + refraction differences -> loosen to ~2'
            atol_azel = name == "MOON" ? 120as : tol + 60as
            @test ga.lat ≈ want.azel[2] atol = atol_azel
        end

        # frequency: agrees to ~1e-9 relative (< 0.3 m/s line-of-sight) —
        # the residual is SOFA `epv00` vs casacore's own Earth ephemeris.
        f = MFrequency{TOPO}(ref.freq_hz)
        for (frame, T) in (("GEO", GEO), ("BARY", BARY), ("LSRK", LSRK),
                           ("LSRD", LSRD), ("GALACTO", GALACTO))
            got = measconvert(f, T; frame = fr)
            @test got.hz ≈ getproperty(ref.frequency, Symbol(frame)) rtol = 2e-9
        end

        # radial velocity: same physics as frequency. BARY/LSRD/GALACTO
        # (constant `_VEL_*` only) match to < 1 mm/s; GEO/TOPO carry the
        # SOFA `epv00` + `pvtob`-diurnal-aberration vs casacore-ephemeris
        # residual (~0.25 m/s LOS, the same as the frequency test's
        # `rtol=2e-9` == ~0.6 m/s at 100 GHz).
        v = MRadialVelocity{LSRK}(ref.rv_mps)
        for (frame, T) in (("BARY", BARY), ("LSRD", LSRD), ("GALACTO", GALACTO))
            got = measconvert(v, T; frame = fr)
            @test got.mps ≈ getproperty(ref.radialvelocity, Symbol(frame)) atol = 1e-3
        end
        for (frame, T) in (("GEO", GEO), ("TOPO", TOPO))
            got = measconvert(v, T; frame = fr)
            @test got.mps ≈ getproperty(ref.radialvelocity, Symbol(frame)) atol = 0.5
        end

        # Doppler conventions + bridge -- pure algebra, near-exact
        d0 = MDoppler{RADIO}(ref.dop_radio)
        for (conv, T) in (("OPTICAL", OPTICAL), ("RATIO", RATIO),
                          ("TRUE", BETA), ("GAMMA", GAMMA))
            @test measconvert(d0, T).d ≈ getproperty(ref.doppler, Symbol(conv)) rtol = 1e-12
        end
        obsf = MFrequency{LSRK}(ref.obs_freq_hz)
        d = doppler(obsf, ref.rest_hz)
        @test d.d ≈ ref.dop_from_freq rtol = 1e-12
        @test radialvelocity(d).mps ≈ ref.rv_from_dop rtol = 1e-10
        @test frequency(d, ref.rest_hz).hz ≈ ref.freq_from_dop rtol = 1e-12
        @test restfrequency(obsf, d).hz ≈ ref.rest_from_freq rtol = 1e-12
    end
else
    @info "CASA python3 not found; skipping measures oracle cross-check" _MEAS_CASA
end

@testset "measures — ephemeris (MeasComet) tables" begin
    tmp = mktempdir()
    epdir = joinpath(tmp, "EPHEM0_Mars_J2000.tab")
    mjds = collect(60000.0:1.0:60004.0)
    write_table(epdir, "EPHEM", Pair{String,Any}[
        "MJD" => mjds, "RA" => [100.0 + 0.5k for k in 0:4],
        "DEC" => [20.0 + 0.1k for k in 0:4], "Rho" => fill(1.5, 5),
        "RadVel" => fill(0.01, 5)]; nrow = 5,
        keywords = Dict("MJD0" => 59999.0, "dMJD" => 1.0, "NAME" => "Mars",
                        "posrefsys" => "J2000"))
    e = open_ephemeris(epdir)
    @test e.frame === J2000
    @test e.name == "Mars"
    d = ephemeris_direction(e, 60002.5)
    @test rad2deg(d.lon) ≈ 101.25 atol = 1e-3
    @test rad2deg(d.lat) ≈ 20.25 atol = 1e-3
    @test ephemeris_distance(e, 60002.5) ≈ 1.5 * MSv2.AU_METRES rtol = 1e-4
    @test ephemeris_radvel(e, 60002.5) ≈ 0.01 * MSv2.AU_METRES / MSv2.SEC_PER_DAY rtol = 1e-9
    @test_throws ErrorException ephemeris_direction(e, 59000.0)   # out of range

    # via a FIELD subtable
    flddir = joinpath(tmp, "FIELD")
    write_table(flddir, "FIELD", Pair{String,Any}[
        "NAME" => ["Mars"], "EPHEMERIS_ID" => Int32[0], "PHASE_DIR" => [[0.0, 0.0]]];
        nrow = 1, measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    mv(epdir, joinpath(flddir, "EPHEM0_Mars_J2000.tab"))
    fld = readtable(flddir)
    @test field_ephemeris(fld, 0) !== nothing
    md = measure(fld, "PHASE_DIR", 1; epoch = MEpoch{UTC}(60002.5))
    @test md isa MDirection{J2000}
    @test rad2deg(md.lon) ≈ 101.25 atol = 1e-3
    @test measure(fld, "PHASE_DIR", 1) == MDirection{J2000}(0.0, 0.0)   # no epoch -> static

    # a non-ephemeris field
    write_table(joinpath(tmp, "F2"), "FIELD", Pair{String,Any}[
        "NAME" => ["3C286"], "EPHEMERIS_ID" => Int32[-1], "PHASE_DIR" => [[1.0, 0.5]]];
        nrow = 1, measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    @test field_ephemeris(readtable(joinpath(tmp, "F2")), 0) === nothing
end
