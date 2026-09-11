# Phase 99: analytic primary-beam models. No CASA/casacore oracle is
# available (no vendored synthesis/imaging source with real per-
# telescope coefficients) — verification is textbook-optics sanity
# (half-power point, Airy nulls, dish-diameter scaling) + round-trips.

@testset "beam — GaussianBeam" begin
    g = GaussianBeam(1.4e9; diameter = 25.0)
    @test reffreq(g) == 1.4e9
    @test power_response(g, 0.0) == 1.0
    @test power_response(g, g.hpbw / 2) ≈ 0.5 rtol = 1e-12     # definition of HPBW
    @test voltage_response(g, 0.0) == 1.0
    @test voltage_response(g, g.hpbw / 2) ≈ sqrt(0.5) rtol = 1e-12
    @test power_response(g, g.hpbw) < power_response(g, g.hpbw / 2)   # monotonic falloff

    # HPBW ∝ 1/(freq·diameter)
    g2 = GaussianBeam(1.4e9; diameter = 50.0)
    @test g2.hpbw ≈ g.hpbw / 2 rtol = 1e-12
    @test GaussianBeam(2.8e9; diameter = 25.0).hpbw ≈ g.hpbw / 2 rtol = 1e-12

    # beam narrows with increasing frequency at a fixed offset
    @test power_response(g, g.hpbw / 2, 2 * g.reffreq) < power_response(g, g.hpbw / 2)

    # explicit (hpbw, reffreq) constructor
    g3 = GaussianBeam(deg2rad(0.5), 1.4e9)
    @test power_response(g3, deg2rad(0.25)) ≈ 0.5 rtol = 1e-12
end

@testset "beam — AiryBeam" begin
    a = AiryBeam(25.0)
    freq = 1.4e9
    λ = MSv2.C_LIGHT / freq
    @test power_response(a, 0.0, freq) == 1.0
    # first null of an unobstructed Airy pattern: x = 3.8317 (1st zero of J1)
    θnull = 3.8316546 * λ / (π * a.diameter)
    @test power_response(a, θnull, freq) < 1e-8
    # monotonic decrease out to the first null
    @test power_response(a, θnull / 2, freq) < power_response(a, 0.0, freq)
    @test power_response(a, θnull / 2, freq) > power_response(a, θnull, freq)

    # central obstruction: still normalized to 1 at θ=0, keyword ctor
    a2 = AiryBeam(25.0; blockage = 2.5)
    @test power_response(a2, 0.0, freq) ≈ 1.0 rtol = 1e-10
    @test_throws ErrorException voltage_response(a, 0.0)     # no default reffreq

    # a bigger dish is narrower at the same frequency
    a3 = AiryBeam(50.0)
    @test power_response(a3, θnull / 2, freq) < power_response(a, θnull / 2, freq)
end

@testset "beam — PolynomialBeam" begin
    p = PolynomialBeam([-1.343e-3, 6.579e-7], deg2rad(1.0), 1.4e9)
    @test reffreq(p) == 1.4e9
    @test power_response(p, 0.0) == 1.0
    @test power_response(p, deg2rad(0.5)) < 1.0
    @test power_response(p, deg2rad(1.0) + 1e-9) == 0.0    # beyond maxrad
    # AbstractVector coefficients (not just Vector{Float64})
    p2 = PolynomialBeam(Float32[-1.343e-3, 6.579e-7], deg2rad(1.0), 1.4e9)
    @test power_response(p2, deg2rad(0.5)) ≈ power_response(p, deg2rad(0.5))
end

@testset "beam — attenuate / correct_flux / angular_separation" begin
    g = GaussianBeam(1.4e9; diameter = 25.0)
    @test attenuate(g, 10.0, 0.0) == 10.0
    @test attenuate(g, 10.0, g.hpbw / 2) ≈ 5.0 rtol = 1e-12
    @test correct_flux(g, attenuate(g, 10.0, g.hpbw / 2), g.hpbw / 2) ≈ 10.0 rtol = 1e-10

    d1 = MDirection{J2000}(1.0, 0.3)
    d2 = MDirection{J2000}(1.0, 0.3)
    @test angular_separation(d1, d2) == 0.0
    d3 = MDirection{J2000}(0.0, 0.0)
    d4 = MDirection{J2000}(deg2rad(2.0), 0.0)
    @test rad2deg(angular_separation(d3, d4)) ≈ 2.0 rtol = 1e-10
    # symmetric
    @test angular_separation(d3, d4) ≈ angular_separation(d4, d3)

    # composes: attenuate a catalogue flux by the beam at the true offset
    pb = GaussianBeam(1.4e9; diameter = 25.0)
    pointing = MDirection{J2000}(0.0, 0.0)
    src = MDirection{J2000}(0.0, pb.hpbw / 2)
    @test attenuate(pb, 1.0, angular_separation(pointing, src)) ≈ 0.5 rtol = 1e-10
end

@testset "beam — PrimaryBeam dispatch" begin
    for b in (GaussianBeam(1.4e9; diameter = 25.0), PolynomialBeam([-1e-3], deg2rad(1.0), 1.4e9))
        @test b isa MSv2.PrimaryBeam
        @test power_response(b, 0.0) isa Float64
    end
    @test AiryBeam(25.0) isa MSv2.PrimaryBeam
end

# Phase 100: elliptical / squinted beams + pointing_offset + TaQL funcs.
@testset "beam — EllipticalGaussianBeam" begin
    hmaj, hmin = deg2rad(1.0), deg2rad(0.5)
    eb = EllipticalGaussianBeam(hmaj, hmin, 0.0, 1.4e9)
    @test eb isa MSv2.PrimaryBeam
    @test reffreq(eb) == 1.4e9
    @test power_response(eb, (0.0, 0.0)) == 1.0
    # pa = 0 -> major axis along dlat (north)
    @test power_response(eb, (0.0, hmaj / 2)) ≈ 0.5 rtol = 1e-12
    @test power_response(eb, (hmin / 2, 0.0)) ≈ 0.5 rtol = 1e-12
    # a 90° rotation swaps the axes
    eb90 = EllipticalGaussianBeam(hmaj, hmin, pi / 2, 1.4e9)
    @test power_response(eb90, (hmaj / 2, 0.0)) ≈ 0.5 rtol = 1e-12
    @test power_response(eb90, (0.0, hmin / 2)) ≈ 0.5 rtol = 1e-12
    # circular case (hmaj == hmin) matches GaussianBeam at any pa
    g = GaussianBeam(deg2rad(0.7), 1.4e9)
    ec = EllipticalGaussianBeam(g.hpbw, g.hpbw, 0.3, 1.4e9)
    @test power_response(ec, (0.1 * g.hpbw, -0.2 * g.hpbw)) ≈
          power_response(g, hypot(0.1 * g.hpbw, 0.2 * g.hpbw)) rtol = 1e-10
    # frequency scaling narrows both axes
    @test power_response(eb, (0.0, hmaj / 2), 2 * eb.reffreq) < 0.5
    # a scalar θ is a clear error, not silently circular
    @test_throws ArgumentError power_response(eb, 0.1)
    @test_throws ArgumentError voltage_response(eb, 0.1)
end

@testset "beam — SquintBeam" begin
    base = GaussianBeam(1.4e9; diameter = 25.0)
    squint = (deg2rad(0.05), -deg2rad(0.02))
    sq = SquintBeam(base, squint)
    @test sq isa MSv2.PrimaryBeam
    @test reffreq(sq) == reffreq(base)
    # centred on the squinted offset -> unattenuated (like the base at 0,0)
    @test power_response(sq, squint) ≈ power_response(base, 0.0) rtol = 1e-12
    # at the true boresight, the squint attenuates
    @test power_response(sq, (0.0, 0.0)) < 1.0
    @test power_response(sq, (0.0, 0.0)) ≈ power_response(base, hypot(squint...)) rtol = 1e-10
    @test_throws ArgumentError power_response(sq, 0.1)
    # squinting an elliptical beam composes
    eb = EllipticalGaussianBeam(deg2rad(1.0), deg2rad(0.5), 0.0, 1.4e9)
    sqe = SquintBeam(eb, squint)
    @test power_response(sqe, squint) ≈ power_response(eb, (0.0, 0.0)) rtol = 1e-12
end

@testset "beam — pointing_offset" begin
    p = MDirection{J2000}(1.0, 0.3)
    @test pointing_offset(p, p) == (0.0, 0.0)
    p2 = MDirection{J2000}(1.0, 0.3 + deg2rad(1.0))
    dlon, dlat = pointing_offset(p, p2)
    @test dlon ≈ 0.0 atol = 1e-12
    @test rad2deg(dlat) ≈ 1.0 rtol = 1e-10
    # composes with EllipticalGaussianBeam / attenuate
    eb = EllipticalGaussianBeam(deg2rad(1.0), deg2rad(0.5), 0.0, 1.4e9)
    off = pointing_offset(p, MDirection{J2000}(1.0, 0.3 + deg2rad(1.0) / 2))
    @test attenuate(eb, 2.0, off) ≈ 1.0 rtol = 1e-10   # half-power point along the major axis
end

@testset "beam — TaQL-lite pbgaussian/pbairy/pbellipse" begin
    d = mktempdir()
    write_table(joinpath(d, "T"), "T", Pair{String,Any}["X" => [1.0, 2.0]]; nrow = 2)
    t = readtable(joinpath(d, "T"))

    q = query(t, "X > 0"; select = [
        "g" => "pbgaussian(0.1, 0.5)",
        "a" => "pbairy(0.0, 25.0, 1.4e9)",
        "a2" => "pbairy(0.0, 25.0, 1.4e9, 2.5)",
        "e" => "pbellipse(0.0, 0.005, 0.01, 0.005, 0.0)"])
    @test collect(q.g)[1] ≈ exp(-4 * log(2) * (0.1 / 0.5)^2)
    @test collect(q.a)[1] == 1.0
    @test collect(q.a2)[1] ≈ 1.0 rtol = 1e-10
    @test collect(q.e)[1] ≈ 0.5 rtol = 1e-12

    # filter with a beam function in WHERE
    r = query(t, "pbgaussian(0.0, 0.5) > 0.99")
    @test nrow(r) == 2
    @test_throws ArgumentError MSv2._taqllite_parse("pbairy(A)", Set(["A"]))
    @test_throws ArgumentError MSv2._taqllite_parse("pbgaussian(A)", Set(["A"]))
end

# Phase 117: constructor / power_response parameter validation -- a
# nonsensical input (non-positive width/diameter/frequency, blockage
# out of range, hmaj < hmin, a NaN/Inf offset or frequency) raises a
# clear ArgumentError instead of silently producing NaN/Inf.
@testset "beam — Phase 117 parameter validation" begin
    # GaussianBeam
    @test_throws ArgumentError GaussianBeam(-1.0, 1.4e9)
    @test_throws ArgumentError GaussianBeam(0.0, 1.4e9)
    @test_throws ArgumentError GaussianBeam(deg2rad(1.0), 0.0)
    @test_throws ArgumentError GaussianBeam(deg2rad(1.0), -1.0)
    @test_throws ArgumentError GaussianBeam(NaN, 1.4e9)
    @test_throws ArgumentError GaussianBeam(Inf, 1.4e9)
    @test_throws ArgumentError GaussianBeam(0.0; diameter = 25.0)         # freq <= 0
    @test_throws ArgumentError GaussianBeam(1.4e9; diameter = -25.0)
    @test_throws ArgumentError GaussianBeam(1.4e9; diameter = 25.0, k = 0.0)
    g = GaussianBeam(deg2rad(1.0), 1.4e9)
    @test_throws ArgumentError power_response(g, deg2rad(0.1), 0.0)       # freq <= 0
    @test_throws ArgumentError power_response(g, deg2rad(0.1), -1.4e9)
    @test_throws ArgumentError power_response(g, NaN)
    @test_throws ArgumentError power_response(g, Inf)
    @test_throws ArgumentError voltage_response(g, NaN)

    # AiryBeam
    @test_throws ArgumentError AiryBeam(-25.0)
    @test_throws ArgumentError AiryBeam(0.0)
    @test_throws ArgumentError AiryBeam(NaN)
    @test_throws ArgumentError AiryBeam(25.0; blockage = -1.0)
    @test_throws ArgumentError AiryBeam(25.0; blockage = 25.0)            # ε == 1, 0/0 singularity
    @test_throws ArgumentError AiryBeam(25.0; blockage = 30.0)            # > diameter
    @test_throws ArgumentError AiryBeam(25.0; blockage = NaN)
    a = AiryBeam(25.0)
    @test_throws ArgumentError power_response(a, deg2rad(0.1), 0.0)
    @test_throws ArgumentError power_response(a, NaN, 1.4e9)

    # PolynomialBeam
    @test_throws ArgumentError PolynomialBeam([0.1], -1.0, 1.4e9)
    @test_throws ArgumentError PolynomialBeam([0.1], 0.0, 1.4e9)
    @test_throws ArgumentError PolynomialBeam([0.1], deg2rad(1.0), 0.0)
    @test_throws ArgumentError PolynomialBeam([0.1, NaN], deg2rad(1.0), 1.4e9)
    @test_throws ArgumentError PolynomialBeam([Inf], deg2rad(1.0), 1.4e9)
    p = PolynomialBeam([0.1], deg2rad(1.0), 1.4e9)
    @test_throws ArgumentError power_response(p, deg2rad(0.1), 0.0)
    @test_throws ArgumentError power_response(p, NaN)

    # EllipticalGaussianBeam
    @test_throws ArgumentError EllipticalGaussianBeam(-0.02, 0.005, 0.0, 1.4e9)
    @test_throws ArgumentError EllipticalGaussianBeam(0.02, -0.005, 0.0, 1.4e9)
    @test_throws ArgumentError EllipticalGaussianBeam(0.005, 0.02, 0.0, 1.4e9)  # hmaj < hmin
    @test_throws ArgumentError EllipticalGaussianBeam(0.02, 0.005, NaN, 1.4e9)
    @test_throws ArgumentError EllipticalGaussianBeam(0.02, 0.005, 0.0, 0.0)
    eb = EllipticalGaussianBeam(0.02, 0.005, 0.0, 1.4e9)
    @test_throws ArgumentError power_response(eb, (NaN, 0.0))
    @test_throws ArgumentError power_response(eb, (0.0, 0.0), 0.0)

    # SquintBeam
    @test_throws ArgumentError SquintBeam(g, (NaN, 0.0))
    @test_throws ArgumentError SquintBeam(g, (0.0, Inf))
    sb = SquintBeam(g, (deg2rad(0.1), 0.0))
    @test_throws ArgumentError power_response(sb, (Inf, 0.0))
    @test_throws ArgumentError power_response(sb, (0.0, 0.0), 0.0)        # delegated to GaussianBeam
end
