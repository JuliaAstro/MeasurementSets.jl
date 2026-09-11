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

const _PBOffset = Union{Real,NTuple{2,Real}}

"""
    voltage_response(beam, θ, freq=reffreq(beam)) -> Float64

`sqrt(power_response(beam, θ, freq))` — the voltage (amplitude) pattern.
`θ` is a scalar offset (rad) or a `(dlon, dlat)` tangent-plane pair (see
[`pointing_offset`](@ref) — required for [`EllipticalGaussianBeam`](@ref)
/ [`SquintBeam`](@ref)).
"""
voltage_response(b::PrimaryBeam, θ::_PBOffset, freq::Real = reffreq(b)) =
    sqrt(power_response(b, θ, freq))

"""
    attenuate(beam, flux, θ, freq=reffreq(beam)) -> Float64

`flux * power_response(beam, θ, freq)` — the apparent flux of a source
of true flux `flux` seen through the beam at offset `θ` (scalar or
`(dlon, dlat)`, see [`voltage_response`](@ref)).
"""
attenuate(b::PrimaryBeam, flux::Real, θ::_PBOffset, freq::Real = reffreq(b)) =
    flux * power_response(b, θ, freq)

"""
    correct_flux(beam, apparent_flux, θ, freq=reffreq(beam)) -> Float64

The primary-beam correction: `apparent_flux / power_response(beam, θ, freq)`
(`θ` scalar or `(dlon, dlat)`, see [`voltage_response`](@ref)).
"""
correct_flux(b::PrimaryBeam, flux::Real, θ::_PBOffset, freq::Real = reffreq(b)) =
    flux / power_response(b, θ, freq)

"""
    angular_separation(d1::MDirection, d2::MDirection) -> Float64

The great-circle angle (rad) between two directions **in the same
reference frame** — `measconvert` one first if they differ. Use as the
`θ` argument to [`power_response`](@ref) / [`voltage_response`](@ref).
"""
angular_separation(d1::MDirection, d2::MDirection) = _tql_angdist(d1.lon, d1.lat, d2.lon, d2.lat)

"""
    pointing_offset(pointing::MDirection, target::MDirection) -> (dlon, dlat)

The 2-D tangent-plane offset (rad) of `target` from `pointing` — a
small-angle projection, `dlon = (target.lon−pointing.lon)·cos(pointing.lat)`,
`dlat = target.lat−pointing.lat`. Both directions must be in the same
reference frame. Use as the `offset` argument to
[`EllipticalGaussianBeam`](@ref) / [`SquintBeam`](@ref) — a beam that
needs the offset *direction*, not just its magnitude.
"""
function pointing_offset(pointing::MDirection, target::MDirection)
    dlon = rem2pi(target.lon - pointing.lon, RoundNearest) * cos(pointing.lat)
    (dlon, target.lat - pointing.lat)
end

# A circularly symmetric beam's `power_response` only needs the offset
# magnitude — this fallback lets ANY `PrimaryBeam` accept a 2-D
# `(dlon, dlat)` offset (e.g. from `pointing_offset`) interchangeably
# with a scalar `θ`. `EllipticalGaussianBeam` / `SquintBeam` override it
# with a direction-aware method.
power_response(b::PrimaryBeam, offset::NTuple{2,Real}, freq::Real = reffreq(b)) =
    power_response(b, hypot(offset...), freq)

# Parameter validation (Phase 117): every beam constructor's physical
# parameters (widths, diameters, frequencies, position angles) and every
# `power_response` call's `freq`/offset argument are checked here, so a
# nonsensical input (a non-positive HPBW/diameter/frequency, a
# blockage ≥ diameter, a NaN/Inf offset) raises a clear `ArgumentError`
# immediately instead of silently propagating to a NaN/Inf power
# response several calls downstream.
_pb_finite(label::AbstractString, x::Real) = isfinite(x) ||
    throw(ArgumentError("MeasurementSets: $label must be finite, got $x"))
_pb_positive(label::AbstractString, x::Real) = (isfinite(x) && x > 0) ||
    throw(ArgumentError("MeasurementSets: $label must be a finite positive value, got $x"))
_pb_check_freq(freq::Real) = _pb_positive("freq", freq)
_pb_check_offset(θ::Real) = _pb_finite("θ", θ)
_pb_check_offset(offset::NTuple{2,Real}) =
    (_pb_finite("offset[1] (dlon)", offset[1]); _pb_finite("offset[2] (dlat)", offset[2]))

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
diffraction-limited/Airy value). `hpbw`/`reffreq`/`freq`/`diameter`/`k`
must all be finite and positive.
"""
struct GaussianBeam <: PrimaryBeam
    hpbw::Float64
    reffreq::Float64
    function GaussianBeam(hpbw::Real, reffreq::Real)
        _pb_positive("hpbw", hpbw)
        _pb_positive("reffreq", reffreq)
        new(float(hpbw), float(reffreq))
    end
end
function GaussianBeam(freq::Real; diameter::Real, k::Real = 1.02)
    _pb_positive("freq", freq)
    _pb_positive("diameter", diameter)
    _pb_positive("k", k)
    GaussianBeam(k * C_LIGHT / (freq * diameter), float(freq))
end

reffreq(b::GaussianBeam) = b.reffreq

function power_response(b::GaussianBeam, θ::Real, freq::Real = b.reffreq)
    _pb_check_offset(θ)
    _pb_check_freq(freq)
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
`x = π·diameter·θ/λ`, `ε = blockage/diameter`. `diameter` must be
finite and positive; `blockage` must be finite, `0 ≤ blockage < diameter`
(`blockage == diameter` makes `ε == 1`, a `0/0` singularity in the
annular-aperture formula above; `blockage > diameter` is unphysical).
"""
struct AiryBeam <: PrimaryBeam
    diameter::Float64
    blockage::Float64
    function AiryBeam(diameter::Real, blockage::Real)
        _pb_positive("diameter", diameter)
        _pb_finite("blockage", blockage)
        0 <= blockage < diameter || throw(ArgumentError(
            "MeasurementSets: blockage must satisfy 0 <= blockage < diameter " *
            "(got blockage=$blockage, diameter=$diameter)"))
        new(float(diameter), float(blockage))
    end
end
AiryBeam(diameter::Real; blockage::Real = 0.0) = AiryBeam(diameter, blockage)

reffreq(::AiryBeam) = error(
    "MeasurementSets: AiryBeam has no default frequency — pass `freq` to power_response/voltage_response")

_sinc1(x::Real) = x == 0 ? 1.0 : 2 * besselj1(x) / x

function _airy_voltage(x::Real, ε::Real)
    ε == 0 && return _sinc1(x)
    (_sinc1(x) - ε^2 * _sinc1(ε * x)) / (1 - ε^2)
end

function power_response(b::AiryBeam, θ::Real, freq::Real)
    _pb_check_offset(θ)
    _pb_check_freq(freq)
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
[`AiryBeam`](@ref) instead. `maxrad`/`reffreq` must be finite and
positive; every entry of `coeffs` must be finite.
"""
struct PolynomialBeam <: PrimaryBeam
    coeffs::Vector{Float64}
    maxrad::Float64
    reffreq::Float64
    function PolynomialBeam(coeffs::Vector{Float64}, maxrad::Float64, reffreq::Float64)
        _pb_positive("maxrad", maxrad)
        _pb_positive("reffreq", reffreq)
        all(isfinite, coeffs) || throw(ArgumentError(
            "MeasurementSets: every PolynomialBeam coefficient must be finite, got $coeffs"))
        new(coeffs, maxrad, reffreq)
    end
end
PolynomialBeam(coeffs::AbstractVector{<:Real}, maxrad::Real, reffreq::Real) =
    PolynomialBeam(Float64.(coeffs), float(maxrad), float(reffreq))

reffreq(b::PolynomialBeam) = b.reffreq

function power_response(b::PolynomialBeam, θ::Real, freq::Real = b.reffreq)
    _pb_check_offset(θ)
    _pb_check_freq(freq)
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

# ======================================================================
# Elliptical Gaussian (position-angle-rotated) and beam squint
# ======================================================================

# `pa` measured from north (the `dlat` axis) through east (`dlon`),
# the standard astronomical convention -- the major-axis unit vector is
# `(sin(pa), cos(pa))`.
function _elliptical_gaussian_power(dlon::Real, dlat::Real, hmaj::Real, hmin::Real, pa::Real)
    sp, cp = sin(pa), cos(pa)
    u = dlon * sp + dlat * cp        # along the major axis
    v = dlon * cp - dlat * sp        # along the minor axis
    exp(-4 * log(2) * ((u / hmaj)^2 + (v / hmin)^2))
end

"""
    EllipticalGaussianBeam(hpbw_major, hpbw_minor, pa, reffreq)

A Gaussian power pattern elongated along position angle `pa` (rad, from
north through east — the [`MDirection`](@ref) convention): half-power
widths `hpbw_major` ≥ `hpbw_minor` (rad) at `reffreq` (Hz, scaling as
`1/freq`, like [`GaussianBeam`](@ref)). `power_response` needs a 2-D
`(dlon, dlat)` offset, not a scalar `θ` — see [`pointing_offset`](@ref).
`hpbw_major`/`hpbw_minor`/`reffreq` must be finite and positive, with
`hpbw_major ≥ hpbw_minor`; `pa` must be finite.
"""
struct EllipticalGaussianBeam <: PrimaryBeam
    hpbw_major::Float64
    hpbw_minor::Float64
    pa::Float64
    reffreq::Float64
    function EllipticalGaussianBeam(hmaj::Real, hmin::Real, pa::Real, reffreq::Real)
        _pb_positive("hpbw_major", hmaj)
        _pb_positive("hpbw_minor", hmin)
        hmaj >= hmin || throw(ArgumentError(
            "MeasurementSets: EllipticalGaussianBeam needs hpbw_major >= hpbw_minor " *
            "(got hpbw_major=$hmaj, hpbw_minor=$hmin)"))
        _pb_finite("pa", pa)
        _pb_positive("reffreq", reffreq)
        new(float(hmaj), float(hmin), float(pa), float(reffreq))
    end
end

reffreq(b::EllipticalGaussianBeam) = b.reffreq

power_response(b::EllipticalGaussianBeam, ::Real, ::Real = b.reffreq) = throw(ArgumentError(
    "EllipticalGaussianBeam needs a 2-D (dlon, dlat) offset, not a scalar θ — see `pointing_offset`"))

function power_response(b::EllipticalGaussianBeam, offset::NTuple{2,Real}, freq::Real = b.reffreq)
    _pb_check_offset(offset)
    _pb_check_freq(freq)
    scale = b.reffreq / freq
    _elliptical_gaussian_power(offset[1], offset[2], b.hpbw_major * scale,
                               b.hpbw_minor * scale, b.pa)
end

"""
    SquintBeam(base::PrimaryBeam, squint)

Wraps `base`, offsetting its effective centre by `squint = (dlon, dlat)`
(rad) — models feed/beam squint (e.g. a circularly-polarized feed's
polarization-dependent pointing offset). Needs a 2-D offset (a scalar
`θ` is ambiguous once the beam isn't centred on the boresight). Both
components of `squint` must be finite (no sign/magnitude restriction —
a squint offset can point anywhere).
"""
struct SquintBeam{B<:PrimaryBeam} <: PrimaryBeam
    base::B
    squint::NTuple{2,Float64}
    function SquintBeam{B}(base::B, squint::NTuple{2,Float64}) where {B<:PrimaryBeam}
        _pb_finite("squint[1] (dlon)", squint[1])
        _pb_finite("squint[2] (dlat)", squint[2])
        new{B}(base, squint)
    end
end
SquintBeam(base::B, squint::NTuple{2,Float64}) where {B<:PrimaryBeam} = SquintBeam{B}(base, squint)
SquintBeam(base::PrimaryBeam, squint::Tuple{<:Real,<:Real}) = SquintBeam(base, Float64.(squint))

reffreq(b::SquintBeam) = reffreq(b.base)

power_response(b::SquintBeam, ::Real, ::Real = reffreq(b)) = throw(ArgumentError(
    "SquintBeam needs a 2-D (dlon, dlat) offset, not a scalar θ — see `pointing_offset`"))

function power_response(b::SquintBeam, offset::NTuple{2,Real}, freq::Real = reffreq(b))
    _pb_check_offset(offset)
    power_response(b.base, offset .- b.squint, freq)
end
