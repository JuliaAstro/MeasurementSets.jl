# Doppler shifts (Phase 72): the RADIO / OPTICAL / RATIO / BETA / GAMMA
# conventions, and the frequency <-> velocity bridge (which needs a rest
# frequency).  Pure algebra -- `c` is the only physical constant, and it
# is an exact SI definition -- so this lives in core, no `import SOFA`.
#
# Mirrors casacore `MDoppler` / `MCDoppler` / `MFrequency::to{Doppler,
# Rest}` / `MFrequency::fromDoppler` / `MRadialVelocity::{to,from}Doppler`.

# `C_LIGHT` (m/s) is the one shared constant -- see `src/constants.jl`.

# --- convention <-> convention (casacore hub = RATIO, the ratio F = ν/ν₀)

_dop_ratio(::Type{RADIO},   D) = 1 - D
_dop_ratio(::Type{OPTICAL}, D) = 1 / (D + 1)
_dop_ratio(::Type{RATIO},   D) = D
# Phase 222 fix: `sqrt((1-D)/(1+D))` / `sqrt(1 - 1/(D*D))` go negative
# under the radical for an unphysical BETA (`|D| > 1` -- faster than
# light) or GAMMA (`|D| < 1` -- a Lorentz factor below its minimum,
# 1, at rest) value -- live-reproduced: `measconvert(MDoppler{BETA}
# (1.5), GAMMA)` and even a merely NOISY near-rest `MDoppler{GAMMA}
# (0.9999)` (plausible after a chain of floating-point conversions,
# not just a deliberately-malformed input) both crashed with a raw,
# unhelpful `DomainError` from deep inside `sqrt` instead of a clear
# message naming the actual problem. Real casacore's C++ `std::sqrt`
# of a negative double quietly returns NaN instead of throwing, but
# this package's whole `measures/` subsystem already has an
# established, stronger convention for exactly this shape of problem
# (`measconvert`'s own `_all_finite` guard, `src/measures/types.jl`):
# a physically-meaningless result is worse than a clear early error,
# so a raw crash (worse still -- no explanation at all) gets the same
# treatment here, not silently downgraded to a NaN. The physical
# boundary itself (`|D| == 1` for BETA -- an infinite/zero Doppler
# shift at exactly the speed of light; `|D| == 1` for GAMMA -- exactly
# at rest) is NOT an error, only strictly beyond it is.
_dop_ratio(::Type{BETA}, D) = (-1 <= D <= 1 || throw(ArgumentError(
        "MeasurementSets: a BETA (v/c) Doppler value must satisfy |D| ≤ 1, got $D")
    ); sqrt((1 - D) / (1 + D)))
_dop_ratio(::Type{GAMMA}, D) = (abs(D) >= 1 || throw(ArgumentError(
        "MeasurementSets: a GAMMA (Lorentz factor) Doppler value must satisfy " *
        "|D| ≥ 1, got $D")
    ); D * (1 - sqrt(1 - 1 / (D * D))))
_dop_ratio(::Type{C}, D) where {C} =
    error("MeasurementSets: `$(nameof(C))` is not a Doppler convention")

_ratio_dop(::Type{RADIO},   F) = 1 - F
_ratio_dop(::Type{OPTICAL}, F) = 1 / F - 1
_ratio_dop(::Type{RATIO},   F) = F
_ratio_dop(::Type{BETA},    F) = (1 - F^2) / (1 + F^2)
_ratio_dop(::Type{GAMMA},   F) = (1 + F^2) / (2F)
_ratio_dop(::Type{C}, F) where {C} =
    error("MeasurementSets: `$(nameof(C))` is not a Doppler convention")

"""
    measconvert(d::MDoppler{C}, C2::Type{<:DopplerType}) -> MDoppler{C2}

Re-express a Doppler shift in another convention.
"""
measconvert(m::MDoppler{C}, ::Type{D}) where {C<:DopplerType,D<:DopplerType} =
    C === D ? m : MDoppler{D}(_ratio_dop(D, _dop_ratio(C, m.d)))

_hz(x::Real) = float(x)
_hz(f::MFrequency) = f.hz

# Phase 223 fix: `β = v/c` in the BETA convention, ALWAYS routed through
# `_dop_ratio` -- deliberately does NOT use `measconvert(d, BETA).d`.
# `measconvert(m::MDoppler{C}, ::Type{D})`'s own `C === D ? m : ...`
# short-circuit (just above) is a legitimate no-op passthrough for a
# genuine "already there" conversion, but it means `d`'s OWN value never
# passes through `_dop_ratio`'s Phase 222 domain check when `d` already
# happens to be stored in BETA convention -- so `_beta_factor` computing
# `sqrt((1-β)/(1+β))` straight from `measconvert(d, BETA).d` could still
# crash with the exact same raw `DomainError` Phase 222 was meant to
# close. Live-reproduced: `shiftfreq(MDoppler{BETA}(1.5), 1.4e9)` still
# crashed after that fix, because `1.5` never reached `_dop_ratio` in
# that call. `_beta_value` always calls `_dop_ratio(C, d.d)` regardless
# of `C`, so the validation fires unconditionally; `_ratio_dop(BETA, F)`
# is then mathematically bounded to `(-1, 1]` for ANY real `F` (its
# denominator `1+F²` is never zero), so the subsequent
# `sqrt((1-β)/(1+β))` in `_beta_factor` is always safe once
# `_beta_value` itself hasn't thrown.
_beta_value(d::MDoppler{C}) where {C} = _ratio_dop(BETA, _dop_ratio(C, d.d))

# the Doppler frequency-shift factor √((1−β)/(1+β)); β from the BETA form
_beta_factor(d::MDoppler) = (β = _beta_value(d); sqrt((1 - β) / (1 + β)))

"""
    doppler(f::MFrequency, restfreq) -> MDoppler{BETA}
    doppler(v::MRadialVelocity)      -> MDoppler{BETA}

The Doppler shift of `f` relative to `restfreq` (a frequency in Hz or an
[`MFrequency`](@ref)), or of a radial velocity (`β = v/c`).  Result in
the `BETA` (true `v/c`) convention -- `measconvert` it to `RADIO` /
`OPTICAL` / etc. as needed.
"""
function doppler(f::MFrequency, restfreq)
    t = (f.hz / _hz(restfreq))^2
    MDoppler{BETA}((1 - t) / (1 + t))
end
doppler(v::MRadialVelocity) = MDoppler{BETA}(v.mps / C_LIGHT)

"""
    radialvelocity(d::MDoppler)              -> MRadialVelocity{LSRK}
    radialvelocity(f::MFrequency, restfreq)  -> MRadialVelocity{LSRK}

The true radial velocity of a Doppler shift (`c·β`, casacore
`fromDoppler`), or of a frequency `f` relative to `restfreq`
(`= radialvelocity(doppler(f, restfreq))`).  The two-argument form
broadcasts — `radialvelocity.(measure(spw, "CHAN_FREQ"), ν₀)` is a
velocity axis.  The result frame defaults to `LSRK`.
"""
radialvelocity(d::MDoppler) = MRadialVelocity{LSRK}(C_LIGHT * _beta_value(d))
radialvelocity(f::MFrequency, restfreq) = radialvelocity(doppler(f, restfreq))

"""
    frequency(d::MDoppler, restfreq)         -> MFrequency{LSRK}
    frequency(v::MRadialVelocity, restfreq)  -> MFrequency{LSRK}

The frequency `√((1−β)/(1+β)) · ν₀` implied by a Doppler shift (casacore
`fromDoppler`) or a radial velocity `v` and a line rest frequency
`restfreq`.  The result frame defaults to `LSRK`.
"""
frequency(d::MDoppler, restfreq) = MFrequency{LSRK}(_beta_factor(d) * _hz(restfreq))
frequency(v::MRadialVelocity, restfreq) = frequency(doppler(v), restfreq)

"""
    restfrequency(f::MFrequency, d::MDoppler) -> MFrequency{REST}

The rest frequency `ν / √((1−β)/(1+β))` given an observed frequency and
its Doppler shift (casacore `toRest`).
"""
restfrequency(f::MFrequency, d::MDoppler) = MFrequency{REST}(f.hz / _beta_factor(d))

"""
    shiftfreq(d::MDoppler, ν) -> same shape as ν

Multiply frequency(ies) `ν` by the Doppler factor `√((1−β)/(1+β))` (β
from `d` in the `BETA` convention) — the vectorised form of casacore
`MDoppler::shiftFrequency`.  `ν` is a frequency in Hz, an
[`MFrequency`](@ref) (the frame label is kept), or a vector of either
(the factor is computed once).

Unlike casacore, a non-`BETA` `d` is converted to `BETA` first.
"""
shiftfreq(d::MDoppler, hz::Real) = hz * _beta_factor(d)
shiftfreq(d::MDoppler, f::MFrequency{R}) where {R} = MFrequency{R}(f.hz * _beta_factor(d))
function shiftfreq(d::MDoppler, νs::AbstractVector)
    k = _beta_factor(d)
    map(x -> x isa MFrequency ? typeof(x)(x.hz * k) : x * k, νs)
end
