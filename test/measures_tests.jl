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

# Phase 218: `_scalar` (the epoch/frequency/radialvelocity/doppler
# scalar-cell reader in read.jl) was `length(v) == 1 ? first(v) :
# first(v)` -- a dead ternary with identical branches that silently
# discarded every element past the first instead of validating the
# cell was genuinely scalar. Live-reproduced: reading an `:epoch`
# MEASINFO column whose cell is a length-3 array used to silently
# return an `MEpoch` built from only the *first* element, with no
# warning at all. Now a clear `ArgumentError`.
@testset "measures — measure() errors on a non-scalar epoch cell (Phase 218)" begin
    dir = joinpath(mktempdir(), "badepoch.tab")
    T = [[100.0, 200.0, 300.0] .* 86400.0, [400.0, 500.0, 600.0] .* 86400.0]
    write_table(dir, "T", ["T" => T]; nrow = 2,
        measures = Dict("T" => (; kind = :epoch, ref = "UTC", units = ["s"])))
    r = readtable(dir)
    @test_throws ArgumentError measure(r, "T", 1)
    @test_throws ArgumentError measure(r, "T")

    # a genuinely scalar epoch cell (the normal case) is unaffected
    dir2 = joinpath(mktempdir(), "okepoch.tab")
    write_table(dir2, "T", ["T" => [100.0 * 86400.0, 200.0 * 86400.0]]; nrow = 2,
        measures = Dict("T" => (; kind = :epoch, ref = "UTC", units = ["s"])))
    r2 = readtable(dir2)
    @test measure(r2, "T", 1) == MEpoch{UTC}(100.0)

    # array-valued frequency/radialvelocity cells (a real, supported
    # shape) route through the Vector{MFrequency} branch, never `_scalar`
    # with length != 1 -- confirm that's still untouched
    dir3 = joinpath(mktempdir(), "arrfreq.tab")
    F = [[1.0e9, 1.1e9, 1.2e9], [2.0e9, 2.1e9, 2.2e9]]
    write_table(dir3, "T", ["F" => F]; nrow = 2,
        measures = Dict("F" => (; kind = :frequency, ref = "TOPO")))
    r3 = readtable(dir3)
    f1 = measure(r3, "F", 1)
    @test f1 isa Vector{<:MFrequency}
    @test [x.hz for x in f1] == F[1]
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
    # SUPERGAL (Phase 254): a fixed rotation of GALACTIC; its north pole is at
    # galactic (l, b) = (47.37°, 6.32°) and its origin at (137.37°, 0°)
    s = measconvert(d, SUPERGAL); g = measconvert(d, GALACTIC)
    @test measconvert(s, J2000).lon ≈ d.lon atol=1e-10
    @test measconvert(s, J2000).lat ≈ d.lat atol=1e-10
    @test measconvert(measconvert(MDirection{SUPERGAL}(0.0, pi/2), GALACTIC), GALACTIC).lon ≈ deg2rad(47.37) atol=1e-4
    @test measconvert(MDirection{SUPERGAL}(0.0, pi/2), GALACTIC).lat ≈ deg2rad(6.32) atol=1e-3
    @test measconvert(MDirection{SUPERGAL}(0.0, 0.0), GALACTIC).lon ≈ deg2rad(137.37) atol=1e-3
    @test abs(measconvert(MDirection{SUPERGAL}(0.0, 0.0), GALACTIC).lat) < 1e-3
    @test MSv2._frame_type(:direction, "SUPERGAL") === SUPERGAL
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
    # AZELSW/AZELSWGEO (Phase 160): azimuth = AZEL/AZELGEO's own azimuth
    # + 180°, elevation unchanged; round-trips, and matches the AZEL/
    # AZELGEO relationship directly (not just self-consistency)
    for (SW, PLAIN) in ((AZELSW, AZEL), (AZELSWGEO, AZELGEO))
        m = measconvert(d, SW; frame = fr)
        @test m isa MDirection{SW}
        p = measconvert(d, PLAIN; frame = fr)
        @test rem2pi(m.lon - p.lon - pi, RoundNearest) ≈ 0 atol = 1e-9
        @test m.lat ≈ p.lat atol = 1e-9
        b = measconvert(m, J2000; frame = fr)
        @test rem2pi(b.lon - d.lon, RoundNearest) ≈ 0 atol = 3e-6
        @test b.lat ≈ d.lat atol = 3e-6
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

    # Phase 224 fix: `MDoppler`'s own `measconvert` dispatches on
    # `DopplerType`, a COMPLETELY SEPARATE method from the generic
    # `Measure -> RefFrame` one in `types.jl` that validates
    # `_all_finite` before converting (Phase 195) -- so it never went
    # through that guard at all. Live-reproduced: a NaN/Inf `.d` used
    # to silently propagate through `measconvert` instead of erroring,
    # unlike every other measure type (`MEpoch`, `MDirection`, ...).
    @test_throws ArgumentError measconvert(MDoppler{RADIO}(NaN), OPTICAL)
    @test_throws ArgumentError measconvert(MDoppler{RADIO}(Inf), OPTICAL)
    @test_throws ArgumentError measconvert(MDoppler{BETA}(-Inf), RADIO)
    # the same-convention short-circuit is a genuine no-op (mirrors the
    # generic version's own identical `reftype(m) === R && return m`
    # early return) and still skips the check either way.
    dnan = MDoppler{RADIO}(NaN)
    @test measconvert(dnan, RADIO) === dnan

    # Phase 222 fix: an unphysical BETA (|D| > 1, faster than light) or
    # GAMMA (|D| < 1, below the Lorentz-factor minimum of 1 at rest)
    # value used to crash with a raw, uninformative `DomainError` from
    # deep inside `sqrt` (`sqrt` of a negative real) instead of a clear
    # message -- reachable not just via a deliberately-malformed value
    # but via ordinary floating-point noise near a physical boundary
    # (e.g. `GAMMA(0.9999)`, plausible after a chain of conversions).
    @test_throws ArgumentError measconvert(MDoppler{BETA}(1.5), GAMMA)
    @test_throws ArgumentError measconvert(MDoppler{BETA}(-1.5), RADIO)
    @test_throws ArgumentError measconvert(MDoppler{GAMMA}(0.5), BETA)
    @test_throws ArgumentError measconvert(MDoppler{GAMMA}(0.9999), BETA)   # near-boundary noise
    # the physical boundary itself (|D| == 1 for both conventions) is
    # NOT an error -- only strictly beyond it is.
    @test measconvert(MDoppler{BETA}(1.0), RATIO).d ≈ 0.0
    @test measconvert(MDoppler{BETA}(-1.0), RATIO).d == Inf
    @test measconvert(MDoppler{GAMMA}(1.0), BETA).d ≈ 0.0
    @test measconvert(MDoppler{GAMMA}(-1.0), BETA).d ≈ 0.0
    # in-domain values are completely unaffected by the guard
    @test measconvert(MDoppler{GAMMA}(2.0), BETA).d ≈ sqrt(0.75)
    @test measconvert(MDoppler{BETA}(0.5), GAMMA).d ≈ 1 / sqrt(0.75)

    # Phase 223 fix: the Phase 222 guard above only protects the
    # `_dop_ratio`/`_ratio_dop` *conversion* path -- `_beta_factor` /
    # `radialvelocity(::MDoppler)` used to extract `.d` via
    # `measconvert(d, BETA).d`, whose `C === D ? m : ...` short-circuit
    # (a legitimate no-op passthrough elsewhere) skips `_dop_ratio`'s
    # domain check entirely whenever `d` is ALREADY stored in BETA
    # convention -- so `shiftfreq`/`frequency`/`restfrequency`/
    # `radialvelocity` on an out-of-domain `MDoppler{BETA}` still
    # crashed with the identical raw `DomainError` even after the
    # Phase 222 fix. Fixed by always routing through `_dop_ratio`
    # (`_beta_value`), independent of whether `d`'s own convention
    # already happens to be the target.
    dbad = MDoppler{BETA}(1.5)
    @test_throws ArgumentError shiftfreq(dbad, 1.4e9)
    @test_throws ArgumentError frequency(dbad, 1.4e9)
    @test_throws ArgumentError restfrequency(MFrequency{LSRK}(1.4e9), dbad)
    @test_throws ArgumentError radialvelocity(dbad)
    # an in-domain BETA-native value is unaffected, and gives the same
    # answer as an equivalent value reached via a different convention
    dgood = MDoppler{BETA}(0.5)
    dgood2 = measconvert(MDoppler{GAMMA}(1 / sqrt(0.75)), BETA)   # same β, different source path
    @test shiftfreq(dgood, 1.4e9) ≈ shiftfreq(dgood2, 1.4e9)
    @test radialvelocity(dgood).mps ≈ 0.5 * MSv2.C_LIGHT

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

    # Phase 224 fix: `doppler(v::MRadialVelocity)` used to construct
    # `MDoppler{BETA}(v.mps / C_LIGHT)` directly, with NO validation at
    # all -- unlike its sibling `doppler(f::MFrequency, restfreq)`,
    # whose `t = (f/restfreq)^2 >= 0` provably keeps the result in
    # `(-1, 1]` for ANY finite input and so needs none. `v.mps` has no
    # such bound: live-reproduced, `doppler(MRadialVelocity{LSRK}(4e8))`
    # (superluminal, > c) used to succeed silently, returning an
    # `MDoppler{BETA}` with `|d.d| > 1` -- a physically-meaningless
    # value that then only crashed (with the Phase 222 message) the
    # NEXT time anyone tried to `measconvert`/`radialvelocity`/
    # `frequency`/`shiftfreq` it, not at the point the bad input was
    # actually given.
    @test_throws ArgumentError doppler(MRadialVelocity{LSRK}(4e8))
    @test_throws ArgumentError doppler(MRadialVelocity{LSRK}(-4e8))
    # the physical boundary itself (|v| == c) is NOT an error
    @test doppler(MRadialVelocity{LSRK}(MSv2.C_LIGHT)).d ≈ 1.0
    @test doppler(MRadialVelocity{LSRK}(-MSv2.C_LIGHT)).d ≈ -1.0
    # an ordinary in-domain value round-trips unaffected
    @test radialvelocity(doppler(MRadialVelocity{LSRK}(3e5))).mps ≈ 3e5

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

@testset "measures — read-path coverage gaps (Phase 219)" begin
    # A coverage-instrumented sweep found these `src/measures/{read,
    # measinfo}.jl` branches were never exercised by ANY test in this
    # suite -- every existing fixture happened to always take the
    # opposite path (a fixed `Ref`, a VarRefCol column with an explicit
    # `TabRefCodes` map, an `[lon,lat]`-pair direction cell, a
    # `:radialvelocity` value only ever constructed directly rather than
    # read through `measure()`, ...).

    # measinfo.jl: `_ref_from_code`'s fixed casacore-enum-order fallback
    # -- a `VarRefCol` column with no `TabRefCodes`/`TabRefTypes` map at
    # all (every other VarRefCol fixture in this suite supplies one
    # explicitly).
    mi_f = MSv2.MeasInfo(:frequency, nothing, "F_REF", String[], Int[], ["Hz"])
    @test MSv2._ref_from_code(mi_f, 0) == "REST"
    @test MSv2._ref_from_code(mi_f, 1) == "LSRK"
    @test MSv2._ref_from_code(mi_f, 5) == "TOPO"
    @test_throws ArgumentError MSv2._ref_from_code(mi_f, 99)

    # measinfo.jl: `_measinfo_record` needs one of `ref`/`varrefcol`.
    @test_throws ArgumentError MSv2._measinfo_record(:epoch)

    # read.jl: the whole-column `measure(t, col)` `VarRefCol` path --
    # every other whole-column `measure()` call in this suite is on a
    # fixed-`Ref` column, never a per-row-coded one.
    dir = mktempdir()
    tabv = joinpath(dir, "VRC")
    write_table(tabv, "VRC",
        Pair{String,Any}["F" => Float64.(1e9 .* (1:4)), "F_REF" => Int32[1, 5, 1, 5]];
        nrow = 4,
        measures = Dict("F" => (; kind = :frequency, varrefcol = "F_REF",
                                  tabtypes = ["LSRK", "TOPO"], tabcodes = [1, 5])))
    rv = readtable(tabv)
    whole = measure(rv, "F")
    @test reftype.(whole) == [LSRK, TOPO, LSRK, TOPO]
    @test [m.hz for m in whole] == [measure(rv, "F", i).hz for i in 1:4]

    # read.jl: `:radialvelocity` through `measure()` -- scalar form.
    # Every existing radial-velocity test constructs `MRadialVelocity`
    # directly; none reads one back through a real on-disk MEASINFO
    # column.
    tabrv = joinpath(dir, "RV")
    write_table(tabrv, "RV", Pair{String,Any}["V" => [1e4, -2e4, 3e4]]; nrow = 3,
                measures = Dict("V" => (; kind = :radialvelocity, ref = "LSRK")))
    rrv = readtable(tabrv)
    mv2 = measure(rrv, "V", 2)
    @test mv2 isa MRadialVelocity{LSRK} && mv2.mps ≈ -2e4
    @test [m.mps for m in measure(rrv, "V")] ≈ [1e4, -2e4, 3e4]

    # read.jl: the array-valued `:radialvelocity` cell form (e.g.
    # `SOURCE.SYSVEL`, one value per spectral line) -- the other half of
    # the same never-exercised ternary.
    tabrva = joinpath(dir, "RVARR")
    write_table(tabrva, "RVARR", Pair{String,Any}["V" => [[1e4, 2e4], [3e4, 4e4]]]; nrow = 2,
                measures = Dict("V" => (; kind = :radialvelocity, ref = "LSRK")))
    rrva = readtable(tabrva)
    mv3 = measure(rrva, "V", 1)
    @test mv3 isa Vector{<:MRadialVelocity} && length(mv3) == 2
    @test all(m -> m isa MRadialVelocity{LSRK}, mv3)
    @test mv3[1].mps ≈ 1e4 && mv3[2].mps ≈ 2e4

    # read.jl: `_wrap_measure`'s fallback for an unrecognised MEASINFO
    # `type` -- no write-side validation rejects an arbitrary `kind`, so
    # this only ever surfaces on read.
    tabbad = joinpath(dir, "BADKIND")
    write_table(tabbad, "BADKIND", Pair{String,Any}["X" => [1.0, 2.0]]; nrow = 2,
                measures = Dict("X" => (; kind = :nonsense, ref = "FOO")))
    @test_throws ArgumentError measure(readtable(tabbad), "X", 1)

    # read.jl: `_scalar`'s legitimate length-1-array case -- distinct
    # from Phase 218's length-3 *error* case, which is the only one this
    # suite exercised until now.
    @test MSv2._scalar([12345.0]) == 12345.0
    mi_e = MSv2.MeasInfo(:epoch, "UTC", nothing, String[], Int[], ["s"])
    @test MSv2._wrap_measure(:epoch, UTC, [86400.0 * 5], mi_e) == MEpoch{UTC}(5.0)

    # read.jl: `_lonlat`'s 3-element unit-direction-vector form --
    # distinct from the `[lon,lat]` pair and `(2,npoly)`-matrix forms
    # every other direction test in this suite uses -- and its fallback
    # error for an unsupported cell length.
    lo, la = MSv2._lonlat([0.0, 1.0, 0.0])          # unit vector along +Y
    @test lo ≈ pi / 2 && la ≈ 0.0
    lo2, la2 = MSv2._lonlat([1.0, 0.0, 0.0])        # +X
    @test lo2 ≈ 0.0 && la2 ≈ 0.0
    lo3, la3 = MSv2._lonlat([0.0, 0.0, 1.0])        # +Z (pole)
    @test lo3 == 0.0 && la3 ≈ pi / 2
    @test_throws ArgumentError MSv2._lonlat([1.0])
    @test_throws ArgumentError MSv2._lonlat([1.0, 2.0, 3.0, 4.0])
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
    # a non-dimensionless kind still gets QuantumUnits stamped
    @test columndesc(r, "PDIR").keywords["QuantumUnits"] == ["rad", "rad"]

    # Phase 221 fix: a DIMENSIONLESS kind (`MDoppler`, `units == String[]`)
    # must OMIT the `QuantumUnits` keyword entirely through `addcolumn!`
    # -- `_addcol_desc` used to stamp an empty `QuantumUnits = String[]`
    # unconditionally, diverging from `write_table`'s own
    # `_stamp_measinfo` (which already guards `!isempty(units)`) for the
    # identical data. Live-verified this divergence was real before
    # fixing it -- the package's own two Measure-typed-column
    # auto-detection paths disagreeing with each other.
    tab2 = joinpath(dir, "AC2")
    write_table(tab2, "AC2", Pair{String,Any}["A" => collect(1.0:3.0)]; nrow = 3)
    edit(tab2) do t
        addcolumn!(t, "DOP", [MDoppler{RADIO}(0.01i) for i in 1:3])
    end
    r2 = readtable(tab2)
    @test !haskey(columndesc(r2, "DOP").keywords, "QuantumUnits")
    @test measinfo(r2, "DOP").kind === :doppler && measinfo(r2, "DOP").fixedref == "RADIO"
    @test measure(r2, "DOP")[2] === MDoppler{RADIO}(0.02)

    # the `write_table` path was already correct -- confirms the two
    # entry points now agree.
    tab3 = joinpath(dir, "WT")
    write_table(tab3, "WT", Pair{String,Any}["DOP" => [MDoppler{RADIO}(0.01i) for i in 1:3]];
                nrow = 3)
    @test !haskey(columndesc(readtable(tab3), "DOP").keywords, "QuantumUnits")

    # Phase 293 fix: `addcolumn!(t, name, data; type=...)` used to skip
    # the Measure/Quantity auto-flatten ENTIRELY whenever `type` was
    # given (the whole block was guarded `if type === nothing`) -- so
    # `vals` stayed a raw `Vector{MEpoch{UTC}}`, `addcolumn!` itself
    # raised no error at all, and the failure only surfaced deep inside
    # a LATER `flush` as a bare `MethodError: no method matching
    # Float64(::MEpoch{UTC})` from `write_standardstman`, naming none of
    # the real cause. Live-reproduced before the fix. There is no
    # legitimate use for the old behaviour -- `addcolumn!` has no
    # `units=`/`measures=` kwarg, so this auto-detection is the ONLY way
    # to get MEASINFO/QuantumUnits onto an added column at all -- so
    # `type=`/`shape=` now override the RESULT of the flatten, not
    # whether it happens.
    tab4 = joinpath(dir, "TY")
    write_table(tab4, "TY", Pair{String,Any}["K" => Int32[1, 2, 3]]; nrow = 3)
    edit(tab4) do t
        addcolumn!(t, "T2", [MEpoch{UTC}(58000.0 + i) for i in 1:3]; type = MSv2.TpDouble)
    end
    r4 = readtable(tab4)
    @test measinfo(r4, "T2").kind === :epoch && measinfo(r4, "T2").fixedref == "UTC"
    @test column(r4, "T2")[:] ≈ (58000.0 .+ (1:3)) .* MSv2.SEC_PER_DAY
    @test measure(r4, "T2")[2].mjd ≈ 58002.0

    # a plain (non-Measure/Quantity) `data` + `type=` is unaffected --
    # `_measure_column_spec`/`_quantity_column_spec` both return
    # `nothing` for it, exactly as before this fix.
    edit(tab4) do t
        addcolumn!(t, "P", Int32[10, 20, 30]; type = MSv2.TpFloat)
    end
    r5 = readtable(tab4)
    @test eltype(column(r5, "P")) == Float32
    @test column(r5, "P")[:] == Float32[10, 20, 30]
    @test !haskey(columndesc(r5, "P").keywords, "QuantumUnits")

    # the same fix, exercised through the shared `_addcol_desc` path a
    # `RefEditTable` also uses (Phase 126) -- the view's own mapped rows
    # get the flattened values, the parent's other rows the default.
    tab5 = joinpath(dir, "RT")
    write_table(tab5, "RT", Pair{String,Any}["K" => collect(Int32, 1:5)]; nrow = 5)
    rt = query(readtable(tab5), "K > 2")
    edit(rt) do rv
        addcolumn!(rv, "T2", [MEpoch{UTC}(58000.0 + i) for i in 1:3]; type = MSv2.TpDouble)
    end
    r6 = readtable(tab5)
    @test measinfo(r6, "T2").kind === :epoch
    @test column(r6, "T2")[:][1:2] == [0.0, 0.0]
    @test column(r6, "T2")[:][3:5] ≈ (58000.0 .+ (1:3)) .* MSv2.SEC_PER_DAY
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
    # Phase 160: AZELSW/AZELSWGEO were previously unrecognised (fell
    # back to OtherRef) -- AZELNE/AZELNEGEO are real casacore *aliases*
    # of AZEL/AZELGEO (`MDirection.h`'s own enum), so those two stay
    # mapped to the same types; AZELSW/AZELSWGEO are genuinely distinct.
    @test MSv2._frame_type(:direction, "AZELSW") === AZELSW
    @test MSv2._frame_type(:direction, "AZELSWGEO") === AZELSWGEO
    @test MSv2._frame_type(:direction, "AZELNE") === AZEL
    @test MSv2._frame_type(:direction, "AZELNEGEO") === AZELGEO

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
        # Phase 160: AZELSW/AZELSWGEO added -- a genuinely distinct
        # casacore enum value (not an alias like AZELNE/AZELNEGEO,
        # confirmed in `MDirection.h`'s own enum), a "south through
        # west" azimuth convention = AZEL/AZELGEO's own azimuth + 180°
        # (`MeasMath::applyAZELtoAZELSW` negates the direction's
        # Cartesian x/y). Was previously entirely unsupported by this
        # package (`_frame_type` fell back to `OtherRef{:AZELSW}`).
        d = MDirection{J2000}(ref.src_ra, ref.src_dec)
        as = MSv2.ARCSEC
        for (frame, T) in (("B1950", B1950), ("GALACTIC", GALACTIC), ("SUPERGAL", SUPERGAL),
                           ("APP", APP), ("AZEL", AZEL), ("AZELGEO", AZELGEO),
                           ("AZELSW", AZELSW), ("AZELSWGEO", AZELSWGEO),
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
        # Phase 159: LGROUP/CMB added -- Phase 88 assumed no `casatools`
        # oracle existed for these two ("no casatools oracle for these
        # two"), but `me.listcodes(me.frequency())` shows both ARE valid
        # `me.measure(...)` target codes; live-verified they inherit
        # exactly the same BARY-hub residual as the other frames here
        # (their own step is a pure constant-vector addition, no new
        # ephemeris error), so the same `rtol=2e-9` applies.
        f = MFrequency{TOPO}(ref.freq_hz)
        for (frame, T) in (("GEO", GEO), ("BARY", BARY), ("LSRK", LSRK),
                           ("LSRD", LSRD), ("GALACTO", GALACTO),
                           ("LGROUP", LGROUP), ("CMB", CMB))
            got = measconvert(f, T; frame = fr)
            @test got.hz ≈ getproperty(ref.frequency, Symbol(frame)) rtol = 2e-9
        end

        # radial velocity: same physics as frequency. BARY/LSRD/GALACTO/
        # LGROUP/CMB (constant `_VEL_*` only) match to < 1 mm/s; GEO/TOPO
        # carry the SOFA `epv00` + `pvtob`-diurnal-aberration vs
        # casacore-ephemeris residual (~0.25 m/s LOS, the same as the
        # frequency test's `rtol=2e-9` == ~0.6 m/s at 100 GHz).
        v = MRadialVelocity{LSRK}(ref.rv_mps)
        for (frame, T) in (("BARY", BARY), ("LSRD", LSRD), ("GALACTO", GALACTO),
                           ("LGROUP", LGROUP), ("CMB", CMB))
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

        # Phase 155: `_geodetic_to_itrf` (the engine behind `meas.wgs()`/
        # `meas.itrfxyz()`, Phase 106) vs real casacore's own WGS84->ITRF
        # ellipsoidal transform -- previously only self-round-trip tested,
        # never against a real oracle. Sub-micrometre agreement expected
        # (both use the same WGS84 ellipsoid constants: a=6378137 m,
        # 1/f=298.257223563 -- confirmed identical to SOFA's `eform`).
        gxyz = MSv2._geodetic_to_itrf(deg2rad(ref.geodetic.lon_deg),
                                      deg2rad(ref.geodetic.lat_deg),
                                      ref.geodetic.height_m)
        @test collect(gxyz) ≈ collect(ref.geodetic.itrf_xyz) atol = 1e-6
        lon2, lat2, h2 = MSv2._itrf_to_geodetic(gxyz...)
        @test rad2deg(lon2) ≈ ref.geodetic.lon_deg atol = 1e-9
        @test rad2deg(lat2) ≈ ref.geodetic.lat_deg atol = 1e-9
        @test h2 ≈ ref.geodetic.height_m atol = 1e-6
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

    # Phase 218: the valid MJD range is HALF-OPEN -- [mjd0+dmjd,
    # mjd0+length*dmjd) -- confirmed against `MeasComet::fillMeas`'s own
    # identical `ut >= nrow-1` bound (measures/Measures/MeasComet.cc:406):
    # querying exactly the table's last sampled MJD (60004.0 here) always
    # fails, in both this port and real casacore, since interpolation
    # needs a pair of bracketing rows and the last row has none after it.
    # Not a bug to fix; the error MESSAGE used to self-contradictorily
    # claim that exact value was covered ("table covers 60000.0 ..
    # 60004.0") -- fixed to state the half-open range plainly.
    @test_throws ErrorException ephemeris_direction(e, 60004.0)     # exact last sample
    @test ephemeris_direction(e, 60003.999) isa MDirection          # just inside
    @test ephemeris_direction(e, 60000.0) isa MDirection            # exact first sample: fine

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

@testset "measures — ephemeris direction offset shift (Phase 219)" begin
    # `_ephem_shift` -- the static PHASE_DIR pointing offset applied to a
    # moving-target's ephemeris direction -- used to be a small-angle
    # tangent-plane approximation (`lon + dlon/cos(lat)`) while its own
    # comment claimed it WAS casacore's `MVDirection::shift(offset,
    # True)`.  Fixed to the real 3-rotation-composition formula
    # (`ms/MeasurementSets/MSFieldColumns.cc:480` ->
    # `casa/Quanta/MVDirection.cc:308-343`).  These expected values are
    # independently re-derived -- a separate, from-scratch Julia script
    # building `Rz`/`Ry` as literal matrices and multiplying with plain
    # `*`, not the package's own tuple-based `_rotz`/`_roty`/`_mm3`
    # helpers -- from the quoted C++ `operator*`/`operator*=`
    # definitions, not merely a self-check of the package's own code.
    lon, lat = MSv2._ephem_shift(deg2rad(123.456), deg2rad(20.0),
                                 deg2rad(5 / 3600), deg2rad(-3 / 3600))
    @test rad2deg(lon) ≈ 123.4574780168599 atol = 1e-9
    @test rad2deg(lat) ≈ 19.999166660539938 atol = 1e-9

    # a nonzero (if larger) offset at 89.9° body latitude -- the regime
    # where the old small-angle approximation and the real rotation
    # formula genuinely diverge (~0.1-1″, see the comment in
    # `src/measures/ephemeris.jl`) -- still bit-matches the independent
    # from-scratch reference.
    lon2, lat2 = MSv2._ephem_shift(deg2rad(123.456), deg2rad(89.9),
                                   deg2rad(5 / 3600), deg2rad(-3 / 3600))
    @test rad2deg(lon2) ≈ 124.24514856760143 atol = 1e-9
    @test rad2deg(lat2) ≈ 89.89915710178045 atol = 1e-9

    # zero offset is an identity via the fast path; a genuinely nonzero
    # offset that happens to cancel would still exercise the general
    # formula, which must reduce to the same point
    @test MSv2._ephem_shift(deg2rad(50.0), deg2rad(-10.0), 0.0, 0.0) ==
          (deg2rad(50.0), deg2rad(-10.0))

    # end to end through `measure()`: a moving-target FIELD with a
    # genuinely nonzero PHASE_DIR pointing offset -- every pre-existing
    # ephemeris test above uses an all-zero offset, which never touches
    # this code path at all (the `dlon == 0 && dlat == 0` fast path
    # always fired).
    tmp = mktempdir()
    ep = joinpath(tmp, "EPHEM0_X_J2000.tab")
    write_table(ep, "EPHEM", Pair{String,Any}[
        "MJD" => collect(60000.0:1.0:60004.0), "RA" => fill(123.456, 5),
        "DEC" => fill(20.0, 5), "Rho" => fill(1.5, 5), "RadVel" => fill(0.0, 5)];
        nrow = 5, keywords = Dict("MJD0" => 59999.0, "dMJD" => 1.0,
                                  "NAME" => "X", "posrefsys" => "J2000"))
    flddir = joinpath(tmp, "FIELD")
    write_table(flddir, "FIELD", Pair{String,Any}[
        "NAME" => ["X"], "EPHEMERIS_ID" => Int32[0],
        "PHASE_DIR" => [[deg2rad(5 / 3600), deg2rad(-3 / 3600)]]];
        nrow = 1, measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    mv(ep, joinpath(flddir, "EPHEM0_X_J2000.tab"))
    fld = readtable(flddir)
    md = measure(fld, "PHASE_DIR", 1; epoch = MEpoch{UTC}(60002.0))
    @test md isa MDirection{J2000}
    @test rad2deg(md.lon) ≈ 123.4574780168599 atol = 1e-9
    @test rad2deg(md.lat) ≈ 19.999166660539938 atol = 1e-9

    # the same field with the offset zeroed out reads back as exactly
    # the body's own direction (123.456°, 20°) -- confirms the nonzero
    # offset above really is what moved it off that value, not some
    # unrelated discrepancy.
    flddir2 = joinpath(tmp, "FIELD2")
    write_table(flddir2, "FIELD", Pair{String,Any}[
        "NAME" => ["X"], "EPHEMERIS_ID" => Int32[0], "PHASE_DIR" => [[0.0, 0.0]]];
        nrow = 1, measures = Dict("PHASE_DIR" => (; kind = :direction, ref = "J2000")))
    cp(joinpath(flddir, "EPHEM0_X_J2000.tab"), joinpath(flddir2, "EPHEM0_X_J2000.tab"))
    md2 = measure(readtable(flddir2), "PHASE_DIR", 1; epoch = MEpoch{UTC}(60002.0))
    @test rad2deg(md2.lon) ≈ 123.456 atol = 1e-9
    @test rad2deg(md2.lat) ≈ 20.0 atol = 1e-9
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

@testset "measures — measconvert rejects a non-finite measure/frame (Phase 195)" begin
    # Same Phase 192/193/194 root-cause SHAPE, a fourth corner: a
    # non-finite value anywhere in a measure or its frame used to crash
    # deep inside SOFA.jl's own numeric routines (`jd2cal`'s
    # `AssertionError: Day is out of range.`, many stack frames below
    # the actual `measconvert` call) instead of a clear message at the
    # real entry point. Unlike the purely presentational date/time
    # STRING functions (Phase 193/194), a `measconvert` RESULT is a real
    # number consumed by real astronomy code, so this one raises a
    # clear `ArgumentError` early rather than silently returning a
    # physically-meaningless-but-plausible sentinel value.
    good_epoch = MEpoch{UTC}(60454.42255)
    good_pos = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150)
    good_dir = MDirection{J2000}(1.0, 0.5)

    # a non-finite value in the measure being converted
    for bad in (NaN, Inf, -Inf)
        @test_throws ArgumentError measconvert(MEpoch{UTC}(bad), TAI)
        @test_throws ArgumentError measconvert(MDirection{J2000}(bad, 0.5), AZEL;
            frame = MeasFrame(epoch = good_epoch, position = good_pos))
        @test_throws ArgumentError measconvert(MFrequency{TOPO}(bad), BARY;
            frame = MeasFrame(epoch = good_epoch, position = good_pos, direction = good_dir))
    end

    # a non-finite value in the FRAME instead of the measure itself
    @test_throws ArgumentError measconvert(good_dir, AZEL;
        frame = MeasFrame(epoch = MEpoch{UTC}(NaN), position = good_pos))
    @test_throws ArgumentError measconvert(good_dir, AZEL;
        frame = MeasFrame(epoch = good_epoch, position = MPosition{ITRF}(NaN, 0.0, 0.0)))
    @test_throws ArgumentError measconvert(MFrequency{TOPO}(1.4e9), BARY;
        frame = MeasFrame(epoch = good_epoch, position = good_pos,
                          direction = MDirection{J2000}(Inf, 0.5)))

    # finite input, unaffected -- still converts normally
    @test measconvert(good_epoch, TAI) isa MEpoch{TAI}
    @test measconvert(good_dir, AZEL; frame = MeasFrame(epoch = good_epoch, position = good_pos)) isa
          MDirection{AZEL}

    # `_eop_lookup` itself (EarthOrientationExt) also no longer crashes
    # on a non-finite MJD -- falls into its existing "no coverage"
    # zero-fallback instead (defense in depth; `measconvert`'s own guard
    # above is what a normal caller actually hits first).
    eoext = Base.get_extension(MSv2, :EarthOrientationExt)
    @test eoext._eop_lookup(NaN) == (dut1 = 0.0, xp = 0.0, yp = 0.0)
end

@testset "measures — EOP out-of-range fallback (Phase 220)" begin
    # `_eop_lookup`'s own docstring promises "falls back to zeros (with
    # one warning) if the table has no coverage for the date" -- but
    # `EarthOrientation.jl`'s `outside_range=:nothing` (what this
    # function used to pass) does NOT mean "return nothing": reading
    # `interpolate` directly (`EarthOrientation.jl/src/EarthOrientation.jl`)
    # shows it means "skip the warn/error, keep going" -- i.e. silently
    # return an Akima-spline *extrapolation* past the table's covered
    # range. Live-reproduced before the fix: a date past the IERS
    # table's current forward bound (~2027-09-25 at investigation time)
    # returned a real, never-warned, silently-extrapolated value instead
    # of ever reaching the zero-fallback below. Fixed by switching to
    # `outside_range=:error`, which genuinely raises
    # `EarthOrientation.OutOfRangeError` for an out-of-coverage date
    # (confirmed against `interpolate`'s own `:error` branch) -- caught
    # by the existing `try`/`catch`, so the documented fallback now
    # actually fires.
    eoext = Base.get_extension(MSv2, :EarthOrientationExt)

    # in range (a 2024 date, well within real IERS `finals2000A`
    # coverage): real, plausible-magnitude values, NOT the zero
    # fallback -- confirms the fix has no effect on ordinary usage.
    r_ok = eoext._eop_lookup(60454.0)
    @test !(r_ok.dut1 == 0.0 && r_ok.xp == 0.0 && r_ok.yp == 0.0)
    @test abs(r_ok.dut1) < 1.0                      # ΔUT1 is IERS-bounded to ±0.9 s
    @test abs(r_ok.xp) < 2000 * MSv2.ARCSEC          # real polar motion is O(0.1-0.3″)
    @test abs(r_ok.yp) < 2000 * MSv2.ARCSEC

    # far future (~year 4500) -- always past the IERS table's forward
    # bound no matter when this test runs -- falls back to zeros.
    @test eoext._eop_lookup(1_000_000.0) == (dut1 = 0.0, xp = 0.0, yp = 0.0)

    # far past (well before the IERS series even starts, ~1962) --
    # same fallback.
    @test eoext._eop_lookup(100.0) == (dut1 = 0.0, xp = 0.0, yp = 0.0)
end

# Phase 225 finding: `_eop`'s `ext === nothing` branch (`ext/SOFAExt.jl` —
# the "SOFA loaded, EarthOrientation NOT loaded" ΔUT1=0/no-polar-motion
# fallback + its one-time warning) had NEVER been exercised by any test
# in this suite's history -- confirmed via a coverage-instrumented run
# showing zero hits on `SOFAExt.jl`'s lines 49-54, because this file's
# own test harness (`runtests.jl`) always `import`s both `SOFA` AND
# `EarthOrientation` together (asserted at the top of this file, "measures
# — extensions loaded"). Once `EarthOrientationExt` loads for a Julia
# process it stays loaded for that process's whole lifetime, so this
# genuinely cannot be tested in-process -- spawn a real child process
# with only `SOFA` imported, reusing `lock_tests.jl`'s `_JULIA`/`_PROJ`
# cross-process machinery (already in scope -- `lock_tests.jl` is
# `include`d before this file in `runtests.jl`).
@testset "measures — no-EarthOrientation fallback (SOFA-only child process, Phase 225)" begin
    child_code = """
        using MeasurementSets
        import SOFA
        @assert Base.get_extension(MeasurementSets, :SOFAExt) !== nothing
        @assert Base.get_extension(MeasurementSets, :EarthOrientationExt) === nothing
        fr = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                       position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150))
        d = MDirection{J2000}(2.0, 0.5)
        r1 = measconvert(d, AZEL; frame = fr)
        r2 = measconvert(d, AZEL; frame = fr)      # second call: no repeat warning, same result
        @assert r1 == r2
        eu = measconvert(MEpoch{UTC}(60454.5), UT1; frame = fr)
        @assert eu.mjd == 60454.5                  # ΔUT1 = 0 exactly -> UT1 == UTC, bit for bit
        println(r1.lon, " ", r1.lat)
        """
    out = read(`$_JULIA --project=$_PROJ --startup-file=no -e $child_code`, String)
    lon, lat = parse.(Float64, split(strip(out)))
    @test isfinite(lon) && isfinite(lat)

    # cross-check against the EOP-accurate result computed HERE (this
    # process already has both extensions loaded) -- confirms the
    # documented "~1 arcsecond" fallback accuracy claim, not just that
    # the fallback ran without crashing.
    fr2 = MeasFrame(epoch = MEpoch{UTC}(60454.42255),
                    position = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150))
    racc = MeasurementSets.measconvert(MDirection{J2000}(2.0, 0.5), AZEL; frame = fr2)
    @test abs(lon - racc.lon) < deg2rad(2 / 3600)
    @test abs(lat - racc.lat) < deg2rad(2 / 3600)
end

# Phase 282: a random epoch/position/direction fuzz of `measconvert` against casatools found a
# 6" (0.45 s of hour angle) error on 2012-07-01 -- the day after the 2012-06-30 leap second.  An
# `MEpoch{UTC}` is casacore's UTC MJD (every day 86400 s, MS TIME / 86400), but SOFA's UTC
# quasi-JD counts the fraction of a leap-second day out of 86401 s, so the two disagree by up to a
# second across such a day.  The MJD is now converted at the SOFA boundary.
@testset "measures — UTC on a leap-second day (Phase 282)" begin
    fr = MeasFrame()
    # TAI - UTC is a constant 34 s throughout 2012-06-30 (MJD 56108) except in the leap second itself
    for f in (0.0, 0.25, 0.5, 0.75, 0.999)
        m = 56108.0 + f
        tai = measconvert(MEpoch{UTC}(m), TAI; frame = fr)
        @test (tai.mjd - m) * 86400 ≈ 34.0 atol = 1e-4
        @test measconvert(tai, UTC; frame = fr).mjd ≈ m atol = 1e-9
    end
    @test (measconvert(MEpoch{UTC}(56109.25), TAI; frame = fr).mjd - 56109.25) * 86400 ≈ 35.0 atol = 1e-4
    # UT1 - UTC is continuous through the day (with Earth-orientation data it is the tabulated dUT1)
    if Base.get_extension(MSv2, :EarthOrientationExt) !== nothing
        d = [(measconvert(MEpoch{UTC}(56108.0 + f), UT1; frame = fr).mjd - 56108.0 - f) * 86400 for f in (0.0, 0.25, 0.5, 0.75)]
        @test maximum(d) - minimum(d) < 2e-3
    end
end

# Phase 283: random-frame fuzzes of `measconvert` against casatools -- frequency and radial-velocity
# conversions between the velocity frames (200 random epochs / positions / directions: the constant-
# velocity hops LSRK/BARY/LSRD/GALACTO/LGROUP/CMB agree to 1e-9 m/s, the hops through the Earth's
# motion (TOPO / GEO) to < 1 m/s = 3e-9 of c, the ephemeris floor), and direction conversions FROM
# every frame (150 cases, 11 source frames x J2000 / GALACTIC / AZEL / APP): all within 1.5" of
# casacore except B1950 -> AZEL / APP.  Those two differ by 5" from casacore's *own*
# B1950 -> J2000 -> APP, i.e. casacore's direct route is internally inconsistent; ours composes.
# Kept as a small fixed-seed guard.
using Random
@testset "measures — random-frame conversions vs casatools (Phase 283)" begin
    if _HAVE_MEAS_CASA
        rng = MersenneTwister(283)
        cases = map(1:8) do _
            lon = (rand(rng) - 0.5) * 2π; lat = asin(2rand(rng) - 1)
            ff = 1 / 298.257223563; e2 = ff * (2 - ff); Rn = 6378137.0 / sqrt(1 - e2 * sin(lat)^2)
            (mjd = 55000.0 + rand(rng) * 5000, pos = (Rn * cos(lat) * cos(lon), Rn * cos(lat) * sin(lon), Rn * (1 - e2) * sin(lat)),
             a = rand(rng) * 2π, b = asin(2rand(rng) - 1), f = 1e9 + rand(rng) * 2e11, v = (rand(rng) - 0.5) * 4e5)
        end
        cs = join(["($(c.mjd), $(c.pos[1]), $(c.pos[2]), $(c.pos[3]), $(c.a), $(c.b), $(c.f), $(c.v))" for c in cases], ",")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
for (mjd, x, y, z, a, b, f, v) in [$cs]:
    me.done()
    me.doframe(me.epoch('utc', qa.quantity(mjd, 'd')))
    me.doframe(me.position('itrf', qa.quantity(x, 'm'), qa.quantity(y, 'm'), qa.quantity(z, 'm')))
    me.doframe(me.direction('j2000', qa.quantity(a, 'rad'), qa.quantity(b, 'rad')))
    out = []
    for t in ('geo', 'bary', 'lsrk', 'lsrd', 'galacto'):
        out.append(repr(float(me.measure(me.frequency('topo', qa.quantity(f, 'Hz')), t)['m0']['value'])))
        out.append(repr(float(me.measure(me.radialvelocity('topo', qa.quantity(v, 'm/s')), t)['m0']['value'])))
    for s in ('galactic', 'ecliptic', 'azel', 'azelgeo', 'hadec', 'itrf', 'app'):
        r = me.measure(me.direction(s, qa.quantity(a, 'rad'), qa.quantity(b, 'rad')), 'j2000')
        out.append(repr(float(r['m0']['value']))); out.append(repr(float(r['m1']['value'])))
    print(' '.join(out))
"""
        out = split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr=devnull), String)), '\n')
        fr_(c) = MeasFrame(epoch = MEpoch{UTC}(c.mjd), position = MPosition{ITRF}(c.pos...), direction = MDirection{J2000}(c.a, c.b))
        vel = (GEO, BARY, LSRK, LSRD, GALACTO); dirs = (GALACTIC, ECLIPTIC, AZEL, AZELGEO, HADEC, ITRF, APP)
        sepd(p, q) = acos(clamp(cos(p[2])*cos(q[2])*cos(p[1] - q[1]) + sin(p[2])*sin(q[2]), -1, 1))
        for (i, c) in enumerate(cases)
            r = parse.(Float64, split(out[i]))
            for (k, T) in enumerate(vel)
                @test abs(measconvert(MFrequency{TOPO}(c.f), T; frame = fr_(c)).hz - r[2k-1]) / c.f * 299792458 < 1.5     # m/s equivalent
                @test abs(measconvert(MRadialVelocity{TOPO}(c.v), T; frame = fr_(c)).mps - r[2k]) < 1.5
            end
            for (k, S) in enumerate(dirs)
                d = measconvert(MDirection{S}(c.a, c.b), J2000; frame = fr_(c))
                @test sepd((d.lon, d.lat), (r[10 + 2k - 1], r[10 + 2k])) < 1.5 / 206264.806 * 2      # 3"
            end
        end
    end
end

# Phase 298: `ext/SOFAExt.jl` sweep.  A fresh read + a coverage-instrumented
# run (against `measures_tests.jl` + `taql_mscal_tests.jl`) found no new
# bug -- one confirmed-dead branch removed (`_dir_to_icrs`'s own
# `_is_body(A)` case: `_mconv(::MDirection,...)` already routes every
# body-frame direction through `_body_dir_icrs` directly, before
# `_dir_to_icrs` is ever called with one -- confirmed by grep, every call
# site of `_dir_to_icrs`, including its own SUPERGAL/AZELSW/AZELSWGEO
# recursion, only ever constructs a non-body `MDirection`), plus two
# genuinely-reachable, previously-uncovered-but-correct paths closed with
# permanent tests below: the 8 "$(nameof(X)) is not supported" fallback
# errors (each family's final `error(...)`, reachable via a `MEASINFO`
# frame name this package parses but doesn't convert -- `OtherRef{S}`),
# and `_pole_dir`'s `R === ITRF` branch (a `MuvW` conversion whose
# `frame.direction` -- the phase centre -- is itself stored in ITRF; rare
# in practice since a real MS phase centre is always J2000-ish, but a
# real, reachable state).  Both live-verified before being pinned: the
# fallbacks give a clean, actionable error (not a crash); `_pole_dir`'s
# ITRF branch was checked against an independent from-scratch computation
# (0.0" separation) and a round trip through it.
@testset "measures — SOFAExt unsupported-frame fallbacks (Phase 298)" begin
    OR = MSv2.OtherRef{:XYZ}
    fr = MeasFrame(direction = MDirection{J2000}(1.0, 0.5))
    # epoch: unrecognised source / target scale
    @test_throws ErrorException measconvert(MEpoch{OR}(58000.0), UTC)
    @test_throws ErrorException measconvert(MEpoch{UTC}(58000.0), OR)
    # direction: unrecognised source / target frame (a non-body `OtherRef`,
    # so it falls all the way through `_dir_to_icrs`/`_icrs_to_dir` to the
    # final `error(...)`, not the earlier body-direction branch)
    @test_throws ErrorException measconvert(MDirection{OR}(0.1, 0.2), J2000)
    @test_throws ErrorException measconvert(MDirection{J2000}(0.1, 0.2), OR)
    # frequency / radial velocity: unrecognised source / target frame
    # (needs `frame.direction` set, else the earlier `_n_hat` check fires first)
    @test_throws ErrorException measconvert(MFrequency{OR}(1.4e9), LSRK; frame = fr)
    @test_throws ErrorException measconvert(MFrequency{LSRK}(1.4e9), OR; frame = fr)
    @test_throws ErrorException measconvert(MRadialVelocity{OR}(1e3), LSRK; frame = fr)
    @test_throws ErrorException measconvert(MRadialVelocity{LSRK}(1e3), OR; frame = fr)
    # each message names the real cause, not a bare MethodError/StackOverflow
    try
        measconvert(MDirection{OR}(0.1, 0.2), J2000)
        @test false
    catch err
        @test occursin("direction frame", sprint(showerror, err))
        @test occursin("OtherRef", sprint(showerror, err))
    end
end

@testset "measures — uvw conversion with an ITRF phase centre (Phase 298)" begin
    pos = MPosition{ITRF}(2225061.164, -5440057.370, -2481681.150)
    ep = MEpoch{UTC}(60454.42255)
    dir_itrf = MDirection{ITRF}(1.0, 0.4)
    fr = MeasFrame(epoch = ep, position = pos, direction = dir_itrf)

    u0 = MuvW{ITRF}(100.0, 200.0, 300.0)
    # forward: ITRF -> GALACTIC needs `_pole_dir`'s `R === ITRF` branch to
    # resolve the (ITRF-stored) phase centre into GALACTIC
    u1 = measconvert(u0, GALACTIC; frame = fr)
    @test u1 isa MuvW{GALACTIC}
    # length-preserving (a pure rotation)
    @test hypot(u1.u, u1.v, u1.w) ≈ hypot(u0.u, u0.v, u0.w) rtol = 1e-9
    # backward: GALACTIC -> ITRF exercises the same branch from the other
    # side (`_pole_dir(dir_itrf, GALACTIC, fr)` is now the "other" frame)
    u2 = measconvert(u1, ITRF; frame = fr)
    @test u2.u ≈ u0.u atol = 1e-6
    @test u2.v ≈ u0.v atol = 1e-6
    @test u2.w ≈ u0.w atol = 1e-6

    # a third frame (AZEL, needs both epoch+position AND the ITRF-phase-
    # centre resolution) round-trips too
    u3 = measconvert(u0, AZEL; frame = fr)
    u4 = measconvert(u3, ITRF; frame = fr)
    @test u4.u ≈ u0.u atol = 1e-6
    @test u4.v ≈ u0.v atol = 1e-6
    @test u4.w ≈ u0.w atol = 1e-6
end

# Phase 299: the IGRF earthfield synthesis (`_earthfield_itrf`, a verbatim
# port of casacore `EarthField::calcField`) and `EarthMagneticMachine` had
# only ever been cross-checked against real `casatools` at ONE fixed site
# / epoch (Phase 91's ALMA point + Phase 66's fixture point) -- following
# the Phases 269-287 pattern where a *single* deterministic cross-check
# repeatedly missed bugs a broader random fuzz caught, this spreads the
# same oracle across many random global sites and epochs in one CASA
# process (CASA startup dominates; looping inside one script call keeps
# this affordable). No new bug found -- the port holds up across the
# globe, not just at the one previously-tested location.
@testset "measures — IGRF earthfield random fuzz vs casatools (Phase 299)" begin
    if _HAVE_MEAS_CASA
        rng = MersenneTwister(299)
        n = 14
        cases = map(1:n) do _
            lon = (rand(rng) - 0.5) * 2π
            lat = asin(2rand(rng) - 1)
            height = rand(rng) * 3000.0
            mjd = 51544.0 + rand(rng) * 11000.0     # 2000-01-01 .. ~2030-01-24
            (; lon, lat, height, mjd)
        end
        cs = join(["($(c.lon), $(c.lat), $(c.height), $(c.mjd))" for c in cases], ",")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
for (lon, lat, height, mjd) in [$cs]:
    me.done()
    p_wgs = me.position('WGS84', qa.quantity(lon, 'rad'), qa.quantity(lat, 'rad'), qa.quantity(height, 'm'))
    p_itrf = me.measure(p_wgs, 'ITRF')
    r, plo, pla = p_itrf['m2']['value'], p_itrf['m0']['value'], p_itrf['m1']['value']
    import math
    x = r * math.cos(pla) * math.cos(plo)
    y = r * math.cos(pla) * math.sin(plo)
    z = r * math.sin(pla)
    me.doframe(me.epoch('utc', qa.quantity(mjd, 'd')))
    me.doframe(me.position('itrf', qa.quantity(x, 'm'), qa.quantity(y, 'm'), qa.quantity(z, 'm')))
    b = me.earthmagnetic('IGRF')
    bi = me.measure(b, 'ITRF')
    bj = me.measure(b, 'J2000')
    print(repr(x), repr(y), repr(z), repr(bi['m0']['value']), repr(bi['m1']['value']),
          repr(bi['m2']['value']), repr(bj['m0']['value']), repr(bj['m1']['value']), repr(bj['m2']['value']))
"""
        out = split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr = devnull), String)), '\n')
        @test length(out) == n
        for (i, c) in enumerate(cases)
            x, y, z, bix, biy, biz, bjx, bjy, bjz = parse.(Float64, split(out[i]))
            pos = MPosition{ITRF}(x, y, z)
            ep = MEpoch{UTC}(c.mjd)
            bf = earthfield(pos, ep)
            magw = hypot(bix, biy, biz)
            @test hypot(bf.x, bf.y, bf.z) ≈ magw rtol = 0.05
            @test abs(bf.x - bix) < 0.05 * magw + 250
            @test abs(bf.y - biy) < 0.05 * magw + 250
            @test abs(bf.z - biz) < 0.05 * magw + 250
            # frame rotation (ITRF -> J2000): our own conversion, magnitude
            # preserved, and matches casacore's own rotated components
            # within the same tolerance (proves the rotation, not just the
            # field magnitude, is right at each of these sites/epochs)
            fr = MeasFrame(epoch = ep, position = pos)
            bj_ours = measconvert(MEarthMagnetic{IGRF}(0.0, 0.0, 1e-6), J2000; frame = fr)
            @test hypot(bj_ours.x, bj_ours.y, bj_ours.z) ≈ hypot(bf.x, bf.y, bf.z) rtol = 1e-9
            magwj = hypot(bjx, bjy, bjz)
            @test abs(bj_ours.x - bjx) < 0.05 * magwj + 250
            @test abs(bj_ours.y - bjy) < 0.05 * magwj + 250
            @test abs(bj_ours.z - bjz) < 0.05 * magwj + 250
        end
    end
end

# Phase 300: the solar-system-body direction cross-check (Phase 76) had
# only ever been checked at ONE fixed epoch/observer position (the
# fixture's own `EPOCHS_MJD[0]`/`OBS_XYZ[0]`) across 6 bodies -- exactly
# the shape the Phases 269-287/299 fuzzes have repeatedly found real bugs
# in. Spreading the oracle across 10 random epochs (1970-2050) and random
# observer positions in one `casatools` process found a REAL bug: the SUN
# came out a nearly *constant* ~20.2-20.8" off at every single random
# case (Mercury/Venus/Moon/Mars/Jupiter did not) -- exactly the classical
# constant of aberration (Earth's own orbital speed x the ~499s Sun-Earth
# light time / 1 AU), not `plan94`/`moon98` ephemeris noise. Root cause:
# `_body_geovec(::Type{SUN},...)` retarded EARTH's own position by the
# light time (`_earth_helio(tdb - lighttime)`) instead of holding it
# fixed at the observation time like the general planet method does
# (`eb = _earth_helio(tdb)`, never retarded -- only the *target*'s
# position is) -- the Sun's own heliocentric position is trivially the
# origin at every instant (that's the definition of "heliocentric"), so
# there is nothing of the Sun's own to retard at all; the "light-time
# iteration" was retarding the wrong vector's argument, injecting Earth's
# own orbital displacement over 499s as a spurious systematic offset.
# Fixed to `_body_geovec(::Type{SUN}, tdb, ::Any) = .-_earth_helio(tdb)`
# (no iteration). The single fixed-epoch cross-check in this same file
# happened to pass throughout, purely by luck: the aberration constant
# varies ~20.1-20.9" across the year (Earth's orbital eccentricity),
# straddling the existing `20"` SUN tolerance almost exactly, and that
# one fixture date happened to land just under it.
@testset "measures — solar-system body direction random fuzz vs casatools (Phase 300)" begin
    if _HAVE_MEAS_CASA
        as = MSv2.ARCSEC
        rng = MersenneTwister(300)
        ff = 1 / 298.257223563; e2 = ff * (2 - ff)
        n = 10
        cases = map(1:n) do _
            lon = (rand(rng) - 0.5) * 2π
            lat = asin(2rand(rng) - 1)
            Rn = 6378137.0 / sqrt(1 - e2 * sin(lat)^2)
            pos = (Rn * cos(lat) * cos(lon), Rn * cos(lat) * sin(lon), Rn * (1 - e2) * sin(lat))
            mjd = 40587.0 + rand(rng) * 29200.0     # 1970-01-01 .. ~2050-01-06
            (; mjd, pos)
        end
        cs = join(["($(c.mjd), $(c.pos[1]), $(c.pos[2]), $(c.pos[3]))" for c in cases], ",")
        bodies = ("SUN", "MOON", "MERCURY", "VENUS", "MARS", "JUPITER")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
for (mjd, x, y, z) in [$cs]:
    me.done()
    e0 = me.epoch('utc', qa.quantity(mjd, 'd'))
    pos = me.position('itrf', qa.quantity(x, 'm'), qa.quantity(y, 'm'), qa.quantity(z, 'm'))
    out = []
    for body in $(bodies):
        b = me.direction(body)
        me.doframe(e0); me.doframe(pos)
        j = me.measure(b, 'J2000')
        a = me.measure(b, 'AZEL')
        out += [repr(j['m0']['value']), repr(j['m1']['value']), repr(a['m1']['value'])]
    print(' '.join(out))
"""
        out = split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr = devnull), String)), '\n')
        @test length(out) == n
        bodytol = Dict("SUN" => 20as, "MOON" => 30as, "MERCURY" => 20as,
                       "VENUS" => 20as, "MARS" => 40as, "JUPITER" => 120as)
        Ts = Dict("SUN" => SUN, "MOON" => MOON, "MERCURY" => MERCURY,
                  "VENUS" => VENUS, "MARS" => MARS, "JUPITER" => JUPITER)
        for (i, c) in enumerate(cases)
            r = parse.(Float64, split(out[i]))
            fr = MeasFrame(epoch = MEpoch{UTC}(c.mjd), position = MPosition{ITRF}(c.pos...))
            for (k, name) in enumerate(bodies)
                j2000_lon, j2000_lat, azel_lat = r[3k-2], r[3k-1], r[3k]
                T = Ts[name]
                tol = bodytol[name]
                gj = measconvert(MDirection{T}(0.0, 0.0), J2000; frame = fr)
                @test rem2pi(gj.lon - j2000_lon, RoundNearest) * cos(gj.lat) ≈ 0 atol = tol
                @test gj.lat ≈ j2000_lat atol = tol
                ga = measconvert(MDirection{T}(0.0, 0.0), AZEL; frame = fr)
                atol_azel = name == "MOON" ? 120as : tol + 60as
                @test ga.lat ≈ azel_lat atol = atol_azel
            end
        end
    end
end

# Phase 302: the CASA-oracle epoch cross-check (`measures_fixture.py`) only ever checks 3 fixed
# epochs, and -- notably -- calls `me.doframe(e)` but never `me.doframe(pos)` before converting, so
# TDB's *position-dependent* term (`_dtdb_loc`'s longitude/height-derived `SOFA.dtdb` arguments)
# has never actually been exercised against a real oracle at all; every existing TDB check used
# casacore's own position-less default. This phase spreads the oracle across 15 random epochs
# (1975-2030, safely inside the UTC leap-second table) *and* random global observer positions, with
# the position genuinely set via `me.doframe(pos)` before every conversion.
@testset "measures — epoch conversion random fuzz vs casatools, incl. TDB position term (Phase 302)" begin
    if _HAVE_MEAS_CASA
        rng = MersenneTwister(302)
        ff = 1 / 298.257223563; e2 = ff * (2 - ff)
        n = 15
        cases = map(1:n) do _
            lon = (rand(rng) - 0.5) * 2π
            lat = asin(2rand(rng) - 1)
            Rn = 6378137.0 / sqrt(1 - e2 * sin(lat)^2)
            pos = (Rn * cos(lat) * cos(lon), Rn * cos(lat) * sin(lon), Rn * (1 - e2) * sin(lat))
            mjd = 42413.0 + rand(rng) * 21360.0     # 1975-01-01 .. ~2033-06-14
            (; mjd, pos)
        end
        cs = join(["($(c.mjd), $(c.pos[1]), $(c.pos[2]), $(c.pos[3]))" for c in cases], ",")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
for (mjd, x, y, z) in [$cs]:
    me.done()
    e0 = me.epoch('utc', qa.quantity(mjd, 'd'))
    pos = me.position('itrf', qa.quantity(x, 'm'), qa.quantity(y, 'm'), qa.quantity(z, 'm'))
    me.doframe(e0); me.doframe(pos)
    out = [repr(me.measure(e0, s)['m0']['value']) for s in ('TAI', 'TT', 'TDB', 'UT1')]
    print(' '.join(out))
"""
        out = split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr = devnull), String)), '\n')
        @test length(out) == n
        for (i, c) in enumerate(cases)
            tai, tt, tdb, ut1 = parse.(Float64, split(out[i]))
            fr = MeasFrame(epoch = MEpoch{UTC}(c.mjd), position = MPosition{ITRF}(c.pos...))
            e = MEpoch{UTC}(c.mjd)
            @test measconvert(e, TAI; frame = fr).mjd ≈ tai atol = 1e-9
            @test measconvert(e, TT; frame = fr).mjd  ≈ tt  atol = 1e-9
            @test measconvert(e, TDB; frame = fr).mjd ≈ tdb atol = 1e-7   # ~ms, dtdb's own accuracy
            @test measconvert(e, UT1; frame = fr).mjd ≈ ut1 atol = 1e-7  # no EarthOrientation here
        end
    end
end

# Phase 303: `MBaseline`/`MuvW` frame conversion (Phase 75) had NO confirmed real-CASA oracle at
# all beyond `uvw_j2000`'s narrow TaQL-level scope (Phase 75's own risk note: "no CASA oracle
# confirmed available for uvw/baseline"). Found live that `casatools.measures()` genuinely has
# `me.baseline(rf, x, y, z)` / `me.uvw(rf, x, y, z)`, each returned as a *spherical* (lon, lat,
# length) triple (like `MPosition`'s own spherical ITRF representation, Phase 155) rather than
# Cartesian -- converted to Cartesian here (`sph2xyz`) for a direct comparison with this package's
# own `MBaseline`/`MuvW` (always Cartesian). Fuzzed across 12 random epochs/positions/directions and
# random synthetic baselines (not real antenna positions -- the conversion math doesn't care) against
# 6 target frames for `MBaseline` (`J2000`/`GALACTIC`/`B1950`/`ECLIPTIC`/`AZEL`/`HADEC`) and 3 for
# `MuvW` (`J2000`/`GALACTIC`/`AZEL`, `AZEL` needing the same `frame.direction` `MuvW` conversion
# already requires).
#
# No new bug found: every conversion matches to a *relative* error of at most ~1.1e-4 (`MBaseline`)
# / ~2.6e-4 (`MuvW`) of the baseline length -- squarely the same SOFA-vs-casacore ephemeris/EOP
# residual class already established and accepted for `uvw_j2000`/`itrf`/`delay` elsewhere (Phase
# 137/196/280/300 all cite ~1e-4-ish relative as the expected floor), not a new divergence. This
# closes the "no CASA oracle confirmed" gap Phase 75 flagged, for the general (non-uvw_j2000-specific)
# conversion machinery `MBaseline`/`MuvW` share with the direction-conversion code that Phases
# 280/300 both found real bugs in.
@testset "measures — MBaseline / MuvW random fuzz vs casatools (Phase 303)" begin
    if _HAVE_MEAS_CASA
        rng = MersenneTwister(303)
        ff = 1 / 298.257223563; e2 = ff * (2 - ff)
        n = 12
        cases = map(1:n) do _
            lon = (rand(rng) - 0.5) * 2π
            lat = asin(2rand(rng) - 1)
            Rn = 6378137.0 / sqrt(1 - e2 * sin(lat)^2)
            pos = (Rn * cos(lat) * cos(lon), Rn * cos(lat) * sin(lon), Rn * (1 - e2) * sin(lat))
            mjd = 55000.0 + rand(rng) * 5000
            a = rand(rng) * 2π; b = asin(2rand(rng) - 1)
            bx, by, bz = (rand(rng, 3) .- 0.5) .* 2000.0
            (; mjd, pos, a, b, bx, by, bz)
        end
        cs = join(["($(c.mjd), $(c.pos[1]), $(c.pos[2]), $(c.pos[3]), $(c.a), $(c.b), $(c.bx), $(c.by), $(c.bz))"
                   for c in cases], ",")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
for (mjd, x, y, z, a, b, bx, by, bz) in [$cs]:
    me.done()
    e0 = me.epoch('utc', qa.quantity(mjd, 'd'))
    pos = me.position('itrf', qa.quantity(x,'m'), qa.quantity(y,'m'), qa.quantity(z,'m'))
    d = me.direction('j2000', qa.quantity(a,'rad'), qa.quantity(b,'rad'))
    me.doframe(e0); me.doframe(pos); me.doframe(d)
    bl = me.baseline('itrf', qa.quantity(bx,'m'), qa.quantity(by,'m'), qa.quantity(bz,'m'))
    out = []
    for fr in ('j2000','galactic','b1950','ecliptic','azel','hadec'):
        r = me.measure(bl, fr)
        out += [repr(r['m0']['value']), repr(r['m1']['value']), repr(r['m2']['value'])]
    u = me.uvw('itrf', qa.quantity(bx,'m'), qa.quantity(by,'m'), qa.quantity(bz,'m'))
    for fr in ('j2000','galactic','azel'):
        r = me.measure(u, fr)
        out += [repr(r['m0']['value']), repr(r['m1']['value']), repr(r['m2']['value'])]
    print(' '.join(out))
"""
        out = split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr = devnull), String)), '\n')
        @test length(out) == n
        sph2xyz(lon, lat, r) = (r * cos(lat) * cos(lon), r * cos(lat) * sin(lon), r * sin(lat))
        bframes = (J2000, GALACTIC, B1950, ECLIPTIC, AZEL, HADEC)
        uframes = (J2000, GALACTIC, AZEL)
        for (i, c) in enumerate(cases)
            r = parse.(Float64, split(out[i]))
            fr = MeasFrame(epoch = MEpoch{UTC}(c.mjd), position = MPosition{ITRF}(c.pos...),
                          direction = MDirection{J2000}(c.a, c.b))
            L = hypot(c.bx, c.by, c.bz)
            b0 = MBaseline{ITRF}(c.bx, c.by, c.bz)
            for (k, T) in enumerate(bframes)
                ours = measconvert(b0, T; frame = fr)
                rx, ry, rz = sph2xyz(r[3k-2], r[3k-1], r[3k])
                @test hypot(ours.x - rx, ours.y - ry, ours.z - rz) / L < 5e-4
            end
            u0 = MuvW{ITRF}(c.bx, c.by, c.bz)
            for (k, T) in enumerate(uframes)
                ours = measconvert(u0, T; frame = fr)
                rx, ry, rz = sph2xyz(r[18 + 3k - 2], r[18 + 3k - 1], r[18 + 3k])
                @test hypot(ours.u - rx, ours.v - ry, ours.w - rz) / L < 5e-4
            end
        end
    end
end

# Phase 321: the Doppler convention conversions and the frequency <-> velocity (rest-frequency)
# bridge (Phase 72) were only cross-checked against casatools at ONE value (RADIO 0.01, one fixed
# observed/rest frequency pair, in `measures_fixture.py`).  Spreads the same oracle over 25 random
# physically-valid shifts (|beta| < 0.9, rest frequency 1e8-5e11 Hz): every convention (RADIO /
# OPTICAL / RATIO / BETA / GAMMA) from a BETA value, `doppler(f, rest)`, `radialvelocity`,
# `frequency(d, rest)` and `restfrequency(f, d)`.  Pure algebra, so the agreement is ~1e-12 relative
# (checked to 1e-9); casatools reports a Doppler as <value>*c in "m/s", divided back out here.
@testset "measures — MDoppler conventions + rest-frequency bridge random fuzz vs casatools (Phase 321)" begin
    if _HAVE_MEAS_CASA
        rng = MersenneTwister(321)
        n = 25
        cases = map(1:n) do _
            b = (rand(rng) - 0.5) * 1.8
            rest = exp10(8 + 3.7rand(rng))
            (b, rest, rest * sqrt((1 - b) / (1 + b)))
        end
        cs = join(["($(c[1]), $(c[2]), $(c[3]))" for c in cases], ",")
        py = """
from casatools import measures, quanta
me = measures(); qa = quanta()
C = 2.99792458e8
for (b, rest, obs) in [$cs]:
    out = []
    d = me.doppler('TRUE', qa.quantity(b, ''))
    for c in ('RADIO','OPTICAL','RATIO','TRUE','GAMMA'):
        out.append(repr(me.measure(d, c)['m0']['value'] / C))
    f = me.frequency('LSRK', qa.quantity(obs, 'Hz'))
    dd = me.todoppler('TRUE', f, qa.quantity(rest, 'Hz'))
    out.append(repr(dd['m0']['value'] / C))
    out.append(repr(me.toradialvelocity('LSRK', dd)['m0']['value']))
    out.append(repr(me.tofrequency('LSRK', dd, qa.quantity(rest, 'Hz'))['m0']['value']))
    out.append(repr(me.torestfrequency(f, dd)['m0']['value']))
    print(' '.join(out))
"""
        out = filter(l -> length(split(l)) == 9,
                     split(strip(read(pipeline(`$_MEAS_CASA -c $py`; stderr = devnull), String)), '\n'))
        @test length(out) == n
        for (c, l) in zip(cases, out)
            v = parse.(Float64, split(l))
            b, rest, obs = c
            mine = Float64[measconvert(MDoppler{BETA}(b), T).d for T in (RADIO, OPTICAL, RATIO, BETA, GAMMA)]
            f = MFrequency{LSRK}(obs)
            dd = doppler(f, rest)
            push!(mine, dd.d, radialvelocity(dd).mps, frequency(dd, rest).hz, restfrequency(f, dd).hz)
            for i in 1:9
                @test abs(mine[i] - v[i]) <= 1e-9 * max(abs(v[i]), i <= 6 ? 1e-3 : 0.0)
            end
        end
    end
end
