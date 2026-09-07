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
    radialvelocity(d::MDoppler) -> MRadialVelocity{LSRK}

The true radial velocity `c·β` of a Doppler shift (casacore
`fromDoppler`; the result frame defaults to `LSRK`).
"""
radialvelocity(d::MDoppler) = MRadialVelocity{LSRK}(C_LIGHT * measconvert(d, BETA).d)

"""
    frequency(d::MDoppler, restfreq) -> MFrequency{LSRK}

The frequency `√((1−β)/(1+β)) · ν₀` implied by a Doppler shift and a
rest frequency (casacore `fromDoppler`; the result frame defaults to
`LSRK`).
"""
function frequency(d::MDoppler, restfreq)
    β = measconvert(d, BETA).d
    MFrequency{LSRK}(sqrt((1 - β) / (1 + β)) * _hz(restfreq))
end

"""
    restfrequency(f::MFrequency, d::MDoppler) -> MFrequency{REST}

The rest frequency `ν / √((1−β)/(1+β))` given an observed frequency and
its Doppler shift (casacore `toRest`).
"""
function restfrequency(f::MFrequency, d::MDoppler)
    β = measconvert(d, BETA).d
    MFrequency{REST}(f.hz / sqrt((1 - β) / (1 + β)))
end
