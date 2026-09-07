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
_dop_ratio(::Type{BETA},    D) = sqrt((1 - D) / (1 + D))
_dop_ratio(::Type{GAMMA},   D) = D * (1 - sqrt(1 - 1 / (D * D)))
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

# the Doppler frequency-shift factor √((1−β)/(1+β)); β from the BETA form
_beta_factor(d::MDoppler) = (β = measconvert(d, BETA).d; sqrt((1 - β) / (1 + β)))

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
radialvelocity(d::MDoppler) = MRadialVelocity{LSRK}(C_LIGHT * measconvert(d, BETA).d)
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
