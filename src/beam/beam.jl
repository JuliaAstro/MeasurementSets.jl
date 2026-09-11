# Analytic primary-beam (voltage/power pattern) models — the apparent-
# flux attenuation of a source at an angular offset from the pointing
# centre. A standalone Julia feature (no casacore/CASA source is
# vendored on this machine for the real per-telescope polynomial
# coefficient tables `synthesis/TransformMachines/PBMath1DPoly` uses —
# see `PolynomialBeam`'s docstring); the Gaussian and Airy-disk models
# are textbook optics, independently verifiable.
#
# `power_response` is the one method every beam type implements; every
# other verb (`voltage_response`, `attenuate`, `correct_flux`) is
# generic over it.

import SpecialFunctions: besselj1

"""
    PrimaryBeam

Abstract supertype of the analytic primary-beam models
([`GaussianBeam`](@ref), [`AiryBeam`](@ref), [`PolynomialBeam`](@ref)).
Every subtype implements [`power_response`](@ref)`(beam, θ, freq)`.
"""
abstract type PrimaryBeam end

"""
    power_response(beam::PrimaryBeam, θ, freq=reffreq(beam)) -> Float64

The primary-beam power response (0–1) at angular offset `θ` (rad, from
the pointing centre) and frequency `freq` (Hz).
"""
function power_response end

"""
    reffreq(beam::PrimaryBeam) -> Float64

The reference frequency (Hz) a beam's parameters (FWHM, diameter) were
specified at.
"""
function reffreq end

"""
    voltage_response(beam, θ, freq=reffreq(beam)) -> Float64

`sqrt(power_response(beam, θ, freq))` — the voltage (amplitude) pattern.
"""
voltage_response(b::PrimaryBeam, θ::Real, freq::Real = reffreq(b)) =
    sqrt(power_response(b, θ, freq))

"""
    attenuate(beam, flux, θ, freq=reffreq(beam)) -> Float64

`flux * power_response(beam, θ, freq)` — the apparent flux of a source
of true flux `flux` seen through the beam at offset `θ`.
"""
attenuate(b::PrimaryBeam, flux::Real, θ::Real, freq::Real = reffreq(b)) =
    flux * power_response(b, θ, freq)

"""
    correct_flux(beam, apparent_flux, θ, freq=reffreq(beam)) -> Float64

The primary-beam correction: `apparent_flux / power_response(beam, θ, freq)`.
"""
correct_flux(b::PrimaryBeam, flux::Real, θ::Real, freq::Real = reffreq(b)) =
    flux / power_response(b, θ, freq)

"""
    angular_separation(d1::MDirection, d2::MDirection) -> Float64

The great-circle angle (rad) between two directions **in the same
reference frame** — `measconvert` one first if they differ. Use as the
`θ` argument to [`power_response`](@ref) / [`voltage_response`](@ref).
"""
angular_separation(d1::MDirection, d2::MDirection) = _tql_angdist(d1.lon, d1.lat, d2.lon, d2.lat)

# ======================================================================
# Gaussian
# ======================================================================

"""
    GaussianBeam(hpbw, reffreq)
    GaussianBeam(freq; diameter, k=1.02)

A circular Gaussian power pattern, `exp(-4ln2·(θ/HPBW)²)`, `HPBW` the
half-power beam width (rad) at `reffreq` (Hz) — scales as `1/freq` at
other frequencies. The second form derives `HPBW = k·λ/diameter`
(`k≈1.02` is the standard illuminated-aperture factor; `k=1.22` is the
diffraction-limited/Airy value).
"""
struct GaussianBeam <: PrimaryBeam
    hpbw::Float64
    reffreq::Float64
end
GaussianBeam(freq::Real; diameter::Real, k::Real = 1.02) =
    GaussianBeam(k * C_LIGHT / (freq * diameter), float(freq))

reffreq(b::GaussianBeam) = b.reffreq

function power_response(b::GaussianBeam, θ::Real, freq::Real = b.reffreq)
    hpbw = b.hpbw * b.reffreq / freq          # beam narrows with increasing freq
    exp(-4 * log(2) * (θ / hpbw)^2)
end

# ======================================================================
# Airy disk (uniformly illuminated circular aperture, optional
# central obstruction)
# ======================================================================

"""
    AiryBeam(diameter; blockage=0.0)

The diffraction pattern of a uniformly illuminated circular aperture of
`diameter` metres (an optional central obstruction of `blockage`
metres — the sub-reflector shadow — modelled as a second, negated Airy
term, the standard closed form for an annular aperture):
`voltage(x) = [2·J₁(x)/x − ε²·2·J₁(εx)/(εx)] / (1−ε²)`,
`x = π·diameter·θ/λ`, `ε = blockage/diameter`.
"""
struct AiryBeam <: PrimaryBeam
    diameter::Float64
    blockage::Float64
end
AiryBeam(diameter::Real; blockage::Real = 0.0) = AiryBeam(float(diameter), float(blockage))

reffreq(::AiryBeam) = error(
    "MeasurementSets: AiryBeam has no default frequency — pass `freq` to power_response/voltage_response")

_sinc1(x::Real) = x == 0 ? 1.0 : 2 * besselj1(x) / x

function _airy_voltage(x::Real, ε::Real)
    ε == 0 && return _sinc1(x)
    (_sinc1(x) - ε^2 * _sinc1(ε * x)) / (1 - ε^2)
end

function power_response(b::AiryBeam, θ::Real, freq::Real)
    λ = C_LIGHT / freq
    x = π * b.diameter * θ / λ
    ε = b.blockage / b.diameter
    _airy_voltage(x, ε)^2
end

# ======================================================================
# Generic polynomial (CASA `PBMath1DPoly`-style: pb = 1 + Σ cₖ·xᵏ over
# even powers of x = ν[GHz]·θ[arcmin]). No coefficients are bundled --
# no CASA/casacore source for a real telescope's fitted table is
# available to this package; supply your own (e.g. from CASA's
# `PBMath1DPoly` data, or a fit to a measured/simulated beam).
# ======================================================================

"""
    PolynomialBeam(coeffs, maxrad, reffreq)

A polynomial primary-beam fit in the CASA `PBMath1DPoly` convention:
`pb(x) = 1 + Σₖ coeffs[k]·x^(2k)`, `x = (freq/1e9)·rad2deg(θ)*60`
(GHz · arcmin), valid for `θ ≤ maxrad` (rad) — `0` beyond that radius.
No coefficients are bundled; provide a real telescope's fitted table
(e.g. from CASA's own data) or use [`GaussianBeam`](@ref) /
[`AiryBeam`](@ref) instead.
"""
struct PolynomialBeam <: PrimaryBeam
    coeffs::Vector{Float64}
    maxrad::Float64
    reffreq::Float64
end
PolynomialBeam(coeffs::AbstractVector{<:Real}, maxrad::Real, reffreq::Real) =
    PolynomialBeam(Float64.(coeffs), float(maxrad), float(reffreq))

reffreq(b::PolynomialBeam) = b.reffreq

function power_response(b::PolynomialBeam, θ::Real, freq::Real = b.reffreq)
    θ > b.maxrad && return 0.0
    x = (freq / 1e9) * rad2deg(θ) * 60
    x2 = x^2
    p = 1.0; xp = x2
    for c in b.coeffs
        p += c * xp
        xp *= x2
    end
    max(p, 0.0)
end
