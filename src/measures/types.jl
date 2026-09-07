# Physical *measures* -- a value plus a reference frame (casacore
# `MeasBase` / `MEpoch` / `MDirection` / `MFrequency` / `MPosition` /
# `MRadialVelocity`).  MS columns declare theirs in a `MEASINFO` record
# keyword (parsed in `measinfo.jl`); this file is the typed value model,
# `read.jl` reads a column cell as a `Measure`, and the actual
# reference-frame conversions live in `ext/SOFAExt.jl`
# (weak dep on `SOFA.jl`; `EarthOrientation.jl` adds IERS ΔUT1 / polar
# motion via a second extension).
#
# Design (see [[julia-dispatch-style]]): a reference frame is a
# *singleton type* (`J2000`, `UTC`, `LSRK`, …); a measure value is
# parametric on it (`MEpoch{UTC}`, `MDirection{J2000}`).  Conversion
# methods dispatch on the pair.

# ======================================================================
# reference-frame singleton types
# ======================================================================

"""
    RefFrame

Abstract supertype of every measure reference frame.  Concrete singleton
subtypes, used as the type parameter of a measure value
(`MEpoch{UTC}`, `MDirection{J2000}`) and as the target of
[`measconvert`](@ref):

| group | frames |
|---|---|
| epoch (time scale) | `UTC` `TAI` `TT` `TDB` `UT1` |
| direction | `J2000` `ICRS` `B1950` `APP` `GALACTIC` `ECLIPTIC` `HADEC` `AZEL` `AZELGEO` |
| earth-fixed | `ITRF` `WGS84` `TOPO` |
| frequency / radial velocity | `REST` `LSRK` `LSRD` `BARY` `GEO` `GALACTO` |

An unrecognised casacore frame name is carried as `OtherRef{:Name}`
(parsed, not convertible).
"""
abstract type RefFrame end

for (T, doc) in [
        (:UTC, "Coordinated Universal Time (epoch scale)."),
        (:TAI, "International Atomic Time (epoch scale)."),
        (:TT,  "Terrestrial Time (epoch scale)."),
        (:TDB, "Barycentric Dynamical Time (epoch scale)."),
        (:UT1, "Universal Time UT1 (epoch scale; needs ΔUT1)."),
        (:J2000,    "Mean equator and equinox of J2000.0 (direction; treated as `ICRS`)."),
        (:ICRS,     "International Celestial Reference System (direction)."),
        (:B1950,    "FK4 B1950.0 (direction)."),
        (:APP,      "Geocentric apparent place, equinox of date (direction)."),
        (:GALACTIC, "Galactic coordinates (direction)."),
        (:ECLIPTIC, "J2000 ecliptic coordinates (direction)."),
        (:HADEC,    "Topocentric hour angle / declination (direction)."),
        (:AZEL,     "Azimuth / elevation about the geocentric vertical, N=0 E=90 (direction)."),
        (:AZELGEO,  "Azimuth / elevation about the geodetic vertical (direction)."),
        (:ITRF,     "International Terrestrial Reference Frame (position / direction)."),
        (:WGS84,    "WGS84 geodetic datum (position)."),
        (:TOPO,     "Topocentric (frequency / direction)."),
        (:REST,     "Source rest frame (frequency)."),
        (:LSRK,     "Kinematic Local Standard of Rest (frequency / radial velocity)."),
        (:LSRD,     "Dynamical Local Standard of Rest (frequency / radial velocity)."),
        (:BARY,     "Solar-system barycentre (frequency / radial velocity)."),
        (:GEO,      "Geocentric (frequency / radial velocity)."),
        (:GALACTO,  "Galactocentric (frequency / radial velocity)."),
    ]
    @eval struct $T <: RefFrame end
    @eval @doc $doc $T
end

# solar-system-body *direction* frames (casacore `MDirection::Types`
# codes ≥ 32).  Source-only: a body-frame column's stored `(lon, lat)`
# is a placeholder and `measconvert(MDirection{SUN}(...), J2000; frame)`
# resolves the body's geocentric apparent place at `frame.epoch` via
# `SOFA.jl` (`plan94` / `moon98`).  `PLUTO` (no `plan94`) and `COMET`
# (needs an ephemeris table) are deliberately absent.
for (T, doc) in [
        (:MERCURY, "The planet Mercury as a direction (geocentric apparent place)."),
        (:VENUS,   "The planet Venus as a direction (geocentric apparent place)."),
        (:MARS,    "The planet Mars as a direction (geocentric apparent place)."),
        (:JUPITER, "The planet Jupiter as a direction (geocentric apparent place)."),
        (:SATURN,  "The planet Saturn as a direction (geocentric apparent place)."),
        (:URANUS,  "The planet Uranus as a direction (geocentric apparent place)."),
        (:NEPTUNE, "The planet Neptune as a direction (geocentric apparent place)."),
        (:SUN,     "The Sun as a direction (geocentric apparent place)."),
        (:MOON,    "The Moon as a direction (geocentric apparent place; topocentric when `frame.position` is set)."),
    ]
    @eval struct $T <: RefFrame end
    @eval @doc $doc $T
end

"A reference-frame name string casacore uses that this package parses but does not convert."
struct OtherRef{S} <: RefFrame end

"""A Doppler-shift convention (`RADIO` / `OPTICAL` / `RATIO` / `BETA` / `GAMMA`)."""
abstract type DopplerType end

for (T, doc) in [
        (:RADIO,   "Radio velocity `cΔν/ν₀` (`D = 1 − ν/ν₀`)."),
        (:OPTICAL, "Optical velocity / redshift `z = cΔλ/λ₀` (`D = ν₀/ν − 1`)."),
        (:RATIO,   "The frequency ratio `ν/ν₀` itself."),
        (:BETA,    "True relativistic velocity `v/c` (`D = (1−F²)/(1+F²)`, `F = ν/ν₀`)."),
        (:GAMMA,   "The Lorentz factor `γ` (`D = (1+F²)/(2F)`)."),
    ]
    @eval struct $T <: DopplerType end
    @eval @doc $doc $T
end

"""Alias for [`OPTICAL`](@ref) — casacore's `Z` (redshift) spelling."""
const Z = OPTICAL
"""Alias for [`BETA`](@ref) — casacore's `RELATIVISTIC` spelling."""
const RELATIVISTIC = BETA

"A Doppler-convention name string casacore uses that this package parses but does not convert."
struct OtherDoppler{S} <: DopplerType end

# ======================================================================
# measure value types  -- parametric on the reference frame
# ======================================================================

"""
    MEpoch{R}(mjd)

An instant of time as a Modified Julian Date (days) in time scale `R`
(`UTC`/`TAI`/`TT`/`TDB`/`UT1`).
"""
struct MEpoch{R<:RefFrame}
    mjd::Float64
end

"""
    MDirection{R}(lon, lat)

A direction on the sky, longitude/latitude in **radians**, in frame `R`
(`J2000`/`ICRS`/`B1950`/`APP`/`GALACTIC`/`ECLIPTIC`/`AZEL`/`AZELGEO`/`HADEC`).
"""
struct MDirection{R<:RefFrame}
    lon::Float64
    lat::Float64
end

"""
    MPosition{R}(x, y, z)

A location, geocentric Cartesian **metres**, in frame `R` (`ITRF`/`WGS84`).
"""
struct MPosition{R<:RefFrame}
    x::Float64
    y::Float64
    z::Float64
end

"""
    MFrequency{R}(hz)

A frequency in **hertz**, referenced to velocity frame `R`
(`TOPO`/`GEO`/`BARY`/`LSRK`/`LSRD`/`GALACTO`/`REST`).
"""
struct MFrequency{R<:RefFrame}
    hz::Float64
end

"""
    MRadialVelocity{R}(mps)

A radial velocity in **m/s**, referenced to velocity frame `R`
(`LSRK`/`LSRD`/`BARY`/`GEO`/`TOPO`/`GALACTO`). `measconvert` converts
between these frames (needs `import SOFA` and `frame.direction`).
"""
struct MRadialVelocity{R<:RefFrame}
    mps::Float64
end

"""
    MDoppler{C}(d)

A Doppler shift as a dimensionless value in convention `C`
(`RADIO` / `OPTICAL` / `RATIO` / `BETA` / `GAMMA`). `measconvert(d, C2)`
changes convention; [`doppler`](@ref) / [`frequency`](@ref) /
[`radialvelocity`](@ref) / [`restfrequency`](@ref) bridge to the other
spectral measures (a rest frequency is needed where one is).
"""
struct MDoppler{C<:DopplerType}
    d::Float64
end

"""
    MBaseline{R}(x, y, z)

A baseline vector (antenna → antenna) in **metres**, in direction frame
`R` (`ITRF` / `J2000` / `APP` / `AZEL` / `HADEC` / `GALACTIC` / …).
`measconvert` rotates it between frames (needs `import SOFA`), preserving
its length — equivalent to converting the unit direction and rescaling.
"""
struct MBaseline{R<:RefFrame}
    x::Float64
    y::Float64
    z::Float64
end

"""
    MuvW{R}(u, v, w)

A `uvw` baseline coordinate in **metres**, in direction frame `R` — the
`UVW` column of an MS. Differs from an [`MBaseline`](@ref) by the
rotation onto the frame whose w-axis points at the phase centre, so
`measconvert` also needs `frame.direction` (the phase centre).
"""
struct MuvW{R<:RefFrame}
    u::Float64
    v::Float64
    w::Float64
end

const Measure = Union{MEpoch,MDirection,MPosition,MFrequency,MRadialVelocity,
                      MDoppler,MBaseline,MuvW}

"""
    reftype(m::Measure) -> Type{<:RefFrame}

The reference-frame type parameter of a measure value (`reftype(MEpoch{UTC}(0)) === UTC`).
"""
reftype(::MEpoch{R}) where {R}          = R
reftype(::MDirection{R}) where {R}      = R
reftype(::MPosition{R}) where {R}       = R
reftype(::MFrequency{R}) where {R}      = R
reftype(::MRadialVelocity{R}) where {R} = R
reftype(::MDoppler{C}) where {C}        = C
reftype(::MBaseline{R}) where {R}       = R
reftype(::MuvW{R}) where {R}            = R

# --- direction <-> unit vector (radians <-> xyz) ---------------------
_dir_xyz(d::MDirection) = (cos(d.lat) * cos(d.lon), cos(d.lat) * sin(d.lon), sin(d.lat))
function _xyz_dir(::Type{R}, x, y, z) where {R}
    r = hypot(x, y, z)
    MDirection{R}(atan(y, x), asin(clamp(z / r, -1.0, 1.0)))
end

Base.show(io::IO, m::MEpoch{R}) where {R}       = print(io, "MEpoch{$(nameof(R))}(", m.mjd, " d)")
Base.show(io::IO, m::MDirection{R}) where {R}   = print(io, "MDirection{$(nameof(R))}(", rad2deg(m.lon), "°, ", rad2deg(m.lat), "°)")
Base.show(io::IO, m::MPosition{R}) where {R}    = print(io, "MPosition{$(nameof(R))}(", m.x, ", ", m.y, ", ", m.z, " m)")
Base.show(io::IO, m::MFrequency{R}) where {R}   = print(io, "MFrequency{$(nameof(R))}(", m.hz, " Hz)")
Base.show(io::IO, m::MRadialVelocity{R}) where {R} = print(io, "MRadialVelocity{$(nameof(R))}(", m.mps, " m/s)")
Base.show(io::IO, m::MDoppler{C}) where {C}     = print(io, "MDoppler{$(nameof(C))}(", m.d, ")")
Base.show(io::IO, m::MBaseline{R}) where {R}    = print(io, "MBaseline{$(nameof(R))}(", m.x, ", ", m.y, ", ", m.z, " m)")
Base.show(io::IO, m::MuvW{R}) where {R}         = print(io, "MuvW{$(nameof(R))}(", m.u, ", ", m.v, ", ", m.w, " m)")

# ======================================================================
# conversion frame  -- supplies epoch / position / direction as needed
# ======================================================================

"""
    MeasFrame(; epoch, position, direction)

The auxiliary information a reference-frame conversion needs: an
[`MEpoch`](@ref) (for `APP`, `AZEL`, any velocity frame), an
[`MPosition`](@ref) (for `AZEL`/`HADEC`, `TOPO`), and an
[`MDirection`](@ref) source direction (for every frequency /
radial-velocity conversion).  Fields are set as needed and may be left
`nothing`.
"""
mutable struct MeasFrame
    epoch::Union{Nothing,MEpoch}
    position::Union{Nothing,MPosition}
    direction::Union{Nothing,MDirection}
end
MeasFrame(; epoch=nothing, position=nothing, direction=nothing) =
    MeasFrame(epoch, position, direction)

# ======================================================================
# conversion entry point  -- real methods come from the SOFA extension
# ======================================================================

"""
    measconvert(m::Measure, R::Type{<:RefFrame}; frame=MeasFrame()) -> Measure

Convert measure `m` to reference frame `R`.  Needs `SOFA.jl` loaded
(`import SOFA`); `import EarthOrientation` as well for full ΔUT1 /
polar-motion accuracy (otherwise ~1 arcsecond, with a one-time warning).
`frame` supplies whatever auxiliary epoch / position / source direction
the target frame requires -- see [`MeasFrame`](@ref).
"""
function measconvert(m::Measure, R::Type{<:RefFrame}; frame::MeasFrame=MeasFrame())
    reftype(m) === R && return m
    _mconv(m, R, frame)
end

_mconv(m::Measure, ::Type{<:RefFrame}, ::MeasFrame) = error(
    "MeasurementSets: reference-frame conversion needs SOFA.jl — run `import SOFA` " *
    "(and `import EarthOrientation` for ΔUT1 / polar-motion accuracy)")
