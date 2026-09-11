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
