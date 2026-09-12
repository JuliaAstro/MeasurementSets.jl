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

@testset "measures — Observatories table" begin
    @test observatory("VLA") isa MPosition{ITRF}
    @test observatory("alma") isa MPosition{ITRF}      # case-insensitive
    @test observatory("  ATCA ") isa MPosition{ITRF}   # trimmed
    @test observatory("no-such-scope") === nothing
    # VLA geocentric position magnitude ≈ Earth radius + ~2 km
    p = observatory("VLA")
    @test 6.37e6 < hypot(p.x, p.y, p.z) < 6.38e6
    # ITRF longitude ≈ -107.6° (VLA site)
    @test rad2deg(atan(p.y, p.x)) ≈ -107.6 atol = 0.2
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
    for R in (GEO, BARY, LSRK, LSRD, GALACTO, LGROUP, CMB)
        g = measconvert(f, R; frame = fr)
        @test g isa MFrequency{R}
        # shift is small (< ~400 km/s / c)
        @test abs(g.hz - f.hz) / f.hz < 2e-3
        # round-trip
        back = measconvert(g, TOPO; frame = fr)
        @test back.hz ≈ f.hz rtol=1e-9
    end
end

@testset "measures — radial-velocity conversions (SOFA)" begin
    fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                   position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150),
                   direction = MDirection{J2000}(2.0, 0.5))
    v = MRadialVelocity{LSRK}(20_000.0)
    for R in (BARY, LSRD, GEO, TOPO, GALACTO, LGROUP, CMB)
        g = measconvert(v, R; frame = fr)
        @test g isa MRadialVelocity{R}
        @test abs(g.mps - v.mps) < 400_000.0             # bounded by the frame speed
        back = measconvert(g, LSRK; frame = fr)
        @test back.mps ≈ v.mps atol = 1e-3
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

    # Phase 134: `_uvw_pole_R` independently re-derived here from
    # casacore's own `RotMatrix::RotMatrix(const Euler&)` +
    # `RotMatrix::applySingle` (casa/Quanta/RotMatrix.cc) -- NOT copied
    # from ext/SOFAExt.jl's own construction, so this is a genuine check
    # against source, not a tautology. `applySingle(angle, which)` with
    # which=2 builds the standard R_y(angle) = [[c,0,s],[0,1,0],[-s,0,c]]
    # and which=3 builds R_z(angle) = [[c,-s,0],[s,c,0],[0,0,1]]; the two-
    # angle ctor `RotMatrix(Euler(a,2u,b,3u))` starts from the identity
    # and does `this *= R_y(a)` then `this *= R_z(b)`, i.e. `R = Ry(a)*Rz(b)`
    # (`operator*=` is `this = this * other`, confirmed by reading the
    # `for j; a[j]=rotat[i][j]; for j; rotat[i][j] = sum_k a[k]*other[k][j]`
    # loop directly). `MCuvw::toPole/fromPole` use `a = -π/2+lat, b = -lon`.
    Ry(a) = [cos(a) 0 sin(a); 0 1 0; -sin(a) 0 cos(a)]
    Rz(b) = [cos(b) -sin(b) 0; sin(b) cos(b) 0; 0 0 1]
    for lon in (0.3, -1.1, 2.7), lat in (-0.6, 0.0, 0.9)
        d = MDirection{J2000}(lon, lat)
        Rref = Ry(-pi/2 + lat) * Rz(-lon)
        @test collect(ext._uvw_pole_R(d)) ≈ Rref atol = 1e-12
    end
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

# Phase 91: MEarthMagnetic + the IGRF-14 model.
@testset "measures — MEarthMagnetic / IGRF" begin
    alma = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150)
    ep = MEpoch{UTC}(60454.42255)

    bf = earthfield(alma, ep)
    @test bf isa MEarthMagnetic{ITRF}
    mag = hypot(bf.x, bf.y, bf.z)
    @test 10_000 < mag < 60_000                       # plausible field strength (nT)

    # a polar site has a near-vertical, ~stronger field
    npole = MPosition{ITRF}(0.0, 0.0, 6.35e6)
    bp = earthfield(npole, ep)
    @test hypot(bp.x, bp.y, bp.z) > mag
    @test abs(bp.z) / hypot(bp.x, bp.y, bp.z) > 0.9   # mostly vertical

    # epoch interpolation: 2024 field differs from 2000 by a real amount
    b2000 = earthfield(alma, MEpoch{UTC}(51544.0))
    @test hypot((bf.x, bf.y, bf.z) .- (b2000.x, b2000.y, b2000.z)...) > 100

    ext = Base.get_extension(MSv2, :SOFAExt)
    if ext !== nothing
        fr = MeasFrame(epoch = ep, position = alma)

        # IGRF model -> ITRF is exactly `earthfield`
        bi = measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6), ITRF; frame = fr)
        @test (bi.x, bi.y, bi.z) == (bf.x, bf.y, bf.z)

        # rotation to a celestial frame preserves the magnitude; round-trips
        bj = measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6), J2000; frame = fr)
        @test bj isa MEarthMagnetic{J2000}
        @test hypot(bj.x, bj.y, bj.z) ≈ mag rtol = 1e-9
        back = measconvert(bj, ITRF; frame = fr)
        @test all(abs.((back.x, back.y, back.z) .- (bf.x, bf.y, bf.z)) .< 1e-6)

        @test_throws ErrorException measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6),
                                                ITRF; frame = MeasFrame())
    end

    # write / read round-trip of an MEarthMagnetic column
    d = mktempdir()
    tab = joinpath(d, "T")
    write_table(tab, "T",
        ["B" => [MEarthMagnetic{ITRF}(100.0i, -200.0i, 300.0i) for i in 1:3]];
        nrow = 3)
    t = readtable(tab)
    @test measinfo(t, "B").kind === :earthmagnetic
    @test measinfo(t, "B").fixedref == "ITRF"
    @test columndesc(t, "B").keywords["QuantumUnits"] == ["nT", "nT", "nT"]
    mb = measure(t, "B", 2)
    @test mb isa MEarthMagnetic{ITRF}
    @test (mb.x, mb.y, mb.z) == (200.0, -400.0, 600.0)
end

# Phase 92: EarthMagneticMachine — line-of-sight field toward a source.
@testset "measures — EarthMagneticMachine" begin
    ext = Base.get_extension(MSv2, :SOFAExt)
    ext === nothing && return

    vla = MPosition{ITRF}(-1601185.365, -5041977.547, 3554875.870)
    ep = MEpoch{UTC}(60454.4225)
    posl = hypot(vla.x, vla.y, vla.z)
    lon = atan(vla.y, vla.x); lat = asin(vla.z / posl)
    up = MDirection{ITRF}(lon, lat)                 # local vertical

    m = EarthMagneticMachine(350e3, vla, ep)
    r = m(up)
    @test r.field isa MEarthMagnetic{ITRF}
    @test r.subpoint isa MPosition{ITRF}
    # pierce point sits exactly on the shell
    @test hypot(r.subpoint.x, r.subpoint.y, r.subpoint.z) ≈ posl + 350e3 rtol = 1e-12
    # ... and on the line of sight
    for (s, p, u) in ((r.subpoint.x, vla.x, cos(lat) * cos(lon)),
                      (r.subpoint.y, vla.y, cos(lat) * sin(lon)),
                      (r.subpoint.z, vla.z, sin(lat)))
        @test (s - p) / u ≈ 350e3 rtol = 1e-9
    end
    # sub-point longitude matches
    @test rem2pi(r.sublon - atan(r.subpoint.y, r.subpoint.x), RoundNearest) ≈ 0 atol = 1e-12

    # height 0 -> pierce point is the observer, losfield == vertical component
    r0 = EarthMagneticMachine(0.0, vla, ep)(up)
    @test hypot(r0.subpoint.x - vla.x, r0.subpoint.y - vla.y, r0.subpoint.z - vla.z) < 1e-6
    bf = earthfield(vla, ep)
    @test r0.losfield ≈ bf.x * cos(lat) * cos(lon) + bf.y * cos(lat) * sin(lon) +
                        bf.z * sin(lat) rtol = 1e-12

    # a direction given in a celestial frame is rotated to ITRF first
    rj = m(MDirection{J2000}(2.0, 0.5))
    @test rj.field isa MEarthMagnetic{ITRF}
    @test abs(rj.losfield) < hypot(rj.field.x, rj.field.y, rj.field.z)
end

# Phase 96: ionospheric Faraday rotation / rotation measure.
@testset "measures — ionospheric Faraday rotation" begin
    # pure helpers (no SOFA)
    @test faraday_rotation(1.0, 1.4e9) ≈ (MSv2.C_LIGHT / 1.4e9)^2
    @test faraday_rotation(2.0, MFrequency{TOPO}(1.0e9)) ≈ 2 * (MSv2.C_LIGHT / 1.0e9)^2
    @test derotate_angle(0.7, 3.0, 1.0e9) ≈ 0.7 - faraday_rotation(3.0, 1.0e9)
    @test RM_IONOSPHERE ≈ 2.631e-6

    ext = Base.get_extension(MSv2, :SOFAExt)
    ext === nothing && return
    vla = MPosition{ITRF}(-1601185.365, -5041977.547, 3554875.870)
    ep = MEpoch{UTC}(60454.4225)
    posl = hypot(vla.x, vla.y, vla.z)
    up = MDirection{ITRF}(atan(vla.y, vla.x), asin(vla.z / posl))

    m = EarthMagneticMachine(350e3, vla, ep)
    rm = rotation_measure(m, up; stec = 10.0)
    @test rm ≈ -RM_IONOSPHERE * 10.0 * m(up).losfield
    @test abs(rm) < 5.0                         # a plausible ionospheric RM (rad/m²)
    # scales linearly with STEC; the free-function form agrees
    @test rotation_measure(m, up; stec = 20.0) ≈ 2 * rm
    @test rotation_measure(up, ep, vla; stec = 10.0) ≈ rm
    # Δχ at 150 MHz is ~ (10 / 1.5)² larger than at 1.5 GHz
    @test faraday_rotation(rm, 150e6) ≈ 100 * faraday_rotation(rm, 1.5e9) rtol = 1e-12
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
        # earth magnetic field: casacore ships IGRF-12, MeasurementSets
        # bundles IGRF-14 -> a model-generation difference of ~100-200 nT
        # is expected. Check the frame rotation is right (magnitude equal
        # ITRF vs J2000) and the field agrees to ~2%.
        em_itrf = measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6), ITRF; frame = fr)
        em_j2000 = measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6), J2000; frame = fr)
        wi = ref.earthmagnetic.ITRF
        wj = ref.earthmagnetic.J2000
        magw = hypot(wi...)
        @test hypot(em_itrf.x, em_itrf.y, em_itrf.z) ≈ magw rtol = 0.03
        @test hypot(em_j2000.x, em_j2000.y, em_j2000.z) ≈
              hypot(em_itrf.x, em_itrf.y, em_itrf.z) rtol = 1e-9
        @test all(abs.((em_itrf.x, em_itrf.y, em_itrf.z) .- wi) .< 0.03 * magw + 200)
        @test all(abs.((em_j2000.x, em_j2000.y, em_j2000.z) .- wj) .< 0.03 * magw + 200)

        # EarthMagneticMachine: the pierce-point geometry matches the
        # fixture's numpy re-derivation to a few metres (the residual is
        # the J2000->ITRF direction transform's EOP / aberration model
        # differences, ~1" ~ a metre at 350 km); the field is loose
        # (IGRF-12 vs -14).
        em = ref.emm
        mm = EarthMagneticMachine(em.height,
                                  MPosition{ITRF}(ref.obs_xyz...),
                                  MEpoch{UTC}(ref.epochs_mjd[1]))
        gr = mm(MDirection{J2000}(ref.src_ra, ref.src_dec))
        @test all(abs.((gr.subpoint.x, gr.subpoint.y, gr.subpoint.z) .-
                       em.subpoint) .< 50.0)
        emmag = hypot(em.field...)
        @test hypot(gr.field.x, gr.field.y, gr.field.z) ≈ emmag rtol = 0.03
        @test gr.losfield ≈ em.losfield atol = 0.03 * emmag + 200

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

# Phase 93: polynomial PHASE_DIR + the ephemeris sub-Earth point.
@testset "measures — polynomial PHASE_DIR" begin
    tmp = mktempdir()
    c = reshape([0.5, 0.2,  1.0e-3, 2.0e-3,  1.0e-6, 3.0e-6], 2, 3)  # (2, npoly+1)
    write_table(joinpath(tmp, "FIELD"), "FIELD", Pair{String,Any}[
        "NAME" => ["Poly"], "NUM_POLY" => Int32[2], "TIME" => [1000.0],
        "PHASE_DIR" => [c]]; nrow = 1,
        measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    fld = readtable(joinpath(tmp, "FIELD"))

    dt = 100.0                       # seconds past FIELD.TIME
    md = measure(fld, "PHASE_DIR", 1; epoch = MEpoch{UTC}((1000.0 + dt) / MSv2.SEC_PER_DAY))
    @test md isa MDirection{J2000}
    @test md.lon ≈ 0.5 + 1.0e-3 * dt + 1.0e-6 * dt^2
    @test md.lat ≈ 0.2 + 2.0e-3 * dt + 3.0e-6 * dt^2
    # no epoch, or dt ≈ 0 -> the 0-order term
    @test measure(fld, "PHASE_DIR", 1) == MDirection{J2000}(0.5, 0.2)
    @test measure(fld, "PHASE_DIR", 1;
                  epoch = MEpoch{UTC}(1000.0 / MSv2.SEC_PER_DAY)) ==
          MDirection{J2000}(0.5, 0.2)

    # NUM_POLY inferred from cell shape when the column is absent
    write_table(joinpath(tmp, "F3"), "FIELD", Pair{String,Any}[
        "NAME" => ["P"], "TIME" => [0.0], "PHASE_DIR" => [c]]; nrow = 1,
        measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    m3 = measure(readtable(joinpath(tmp, "F3")), "PHASE_DIR", 1;
                 epoch = MEpoch{UTC}(50.0 / MSv2.SEC_PER_DAY))
    @test m3.lon ≈ 0.5 + 1.0e-3 * 50 + 1.0e-6 * 2500
end

@testset "measures — ephemeris sub-Earth point" begin
    tmp = mktempdir()
    ep = joinpath(tmp, "EPHEM0_X_J2000.tab")
    write_table(ep, "EPHEM", Pair{String,Any}[
        "MJD" => collect(60000.0:1.0:60002.0), "RA" => fill(10.0, 3),
        "DEC" => fill(5.0, 3), "Rho" => fill(1.0, 3), "RadVel" => fill(0.0, 3),
        "DiskLong" => [0.0, 20.0, 40.0], "DiskLat" => [10.0, 12.0, 14.0]]; nrow = 3,
        keywords = Dict("MJD0" => 59999.0, "dMJD" => 1.0, "NAME" => "X",
                        "posrefsys" => "J2000"))
    e = open_ephemeris(ep)
    @test e.disklon !== nothing
    # f = 0.5: the great-circle (SLERP) midpoint of (0°,10°)–(20°,12°),
    # which bulges polewards from the arithmetic mean (10°, 11°).
    lon, lat = ephemeris_diskpos(e, 60000.5)
    @test rad2deg(lon) ≈ 9.9657 atol = 1e-3
    @test rad2deg(lat) ≈ 11.1655 atol = 1e-3
    @test all(ephemeris_diskpos(e, 60000.0) .≈ (deg2rad(0.0), deg2rad(10.0)))

    # a table with no disk columns errors clearly
    p2 = joinpath(tmp, "EPHEM1_Y_J2000.tab")
    write_table(p2, "EPHEM", Pair{String,Any}[
        "MJD" => collect(60000.0:1.0:60002.0), "RA" => fill(1.0, 3),
        "DEC" => fill(1.0, 3), "Rho" => fill(1.0, 3), "RadVel" => fill(0.0, 3)];
        nrow = 3, keywords = Dict("MJD0" => 59999.0, "dMJD" => 1.0))
    @test_throws ErrorException ephemeris_diskpos(open_ephemeris(p2), 60000.5)
end

# Phase 135: `_slerp_lonlat` vs a from-scratch port of casacore's own
# `MVDirection::separation`/`positionAngle`/`shiftAngle` (the actual
# `MeasComet::getDisk` formula) -- independently written here, not
# copied from `src/measures/ephemeris.jl`, so this checks against
# source, not the implementation under test.
_casacore_shiftangle_interp(lon0, lat0, lon1, lat1, f) = begin
    x0 = (cos(lat0) * cos(lon0), cos(lat0) * sin(lon0), sin(lat0))
    x1 = (cos(lat1) * cos(lon1), cos(lat1) * sin(lon1), sin(lat1))
    d1 = sqrt(sum((x0 .- x1) .^ 2)) / 2.0
    sep = 2 * asin(min(d1, 1.0))
    longDiff = lon0 - lon1
    slat1, slat2 = x0[3], x1[3]
    clat2 = sqrt(abs(1.0 - slat2^2))
    s1 = -clat2 * sin(longDiff)
    c1 = sqrt(abs(1.0 - slat1^2)) * slat2 - slat1 * clat2 * cos(longDiff)
    pa = (s1 != 0 || c1 != 0) ? atan(s1, c1) : 0.0
    off = f * sep
    nlat = asin(cos(off) * sin(lat0) + sin(off) * cos(lat0) * cos(pa))
    nlng = cos(nlat) != 0 ? asin(sin(off) * sin(pa) / cos(nlat)) : 0.0
    (lon0 + nlng, nlat)
end
_unitvec(lon, lat) = (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))

@testset "measures — _slerp_lonlat vs casacore shiftAngle (Phase 135)" begin
    # Small, ephemeris-realistic separation (a few degrees, as RA/Dec or
    # a slowly-rotating body's DiskLong would move between adjacent
    # rows): the two formulas agree to numerical precision.
    for f in (0.0, 0.25, 0.5, 0.75, 1.0)
        a = MSv2._slerp_lonlat(deg2rad(10.0), deg2rad(5.0), deg2rad(14.0), deg2rad(7.0), f)
        b = _casacore_shiftangle_interp(deg2rad(10.0), deg2rad(5.0), deg2rad(14.0), deg2rad(7.0), f)
        @test all(abs.(_unitvec(a...) .- _unitvec(b...)) .< 1e-10)
    end

    # Large separation (172°, e.g. a fast-rotating body's DiskLong
    # between two low-cadence samples): casacore's own `shiftAngle` uses
    # an `asin` for the longitude update, which is only valid within a
    # quarter circle of the start point -- confirmed here to genuinely
    # diverge (not float noise) from the true great-circle path at
    # f=0.75, while `_slerp_lonlat` always walks the correct one.
    lon0, lat0, lon1, lat1 = 0.0, 0.0, 3.0, 0.3
    a = MSv2._slerp_lonlat(lon0, lat0, lon1, lat1, 0.75)
    b = _casacore_shiftangle_interp(lon0, lat0, lon1, lat1, 0.75)
    @test sqrt(sum((_unitvec(a...) .- _unitvec(b...)) .^ 2)) > 0.5
    # `_slerp_lonlat` still lands exactly 75% of the great-circle arc
    # from point0 toward point1, by construction.
    full = 2 * asin(min(sqrt(sum((_unitvec(lon0, lat0) .- _unitvec(lon1, lat1)) .^ 2)) / 2, 1.0))
    d0a = 2 * asin(min(sqrt(sum((_unitvec(lon0, lat0) .- _unitvec(a...)) .^ 2)) / 2, 1.0))
    @test d0a ≈ 0.75 * full atol = 1e-9
end
