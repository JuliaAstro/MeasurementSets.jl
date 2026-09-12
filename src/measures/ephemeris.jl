# Solar-system ephemeris tables (casacore `MeasComet`) -- the polynomial
# position tables a moving-target `FIELD` row points at via its
# `EPHEMERIS_ID` column.  Used to give `mscal.*` / `measure()` the
# time-dependent direction of a comet / planet field, closing the
# Phase-76 `plan94` accuracy gap.
#
# Table format (casacore `MeasComet::initMeas`): table keywords `MJD0`
# (= first MJD - dMJD), `dMJD` (day step), `NAME`, optional
# `GeoDist`/`GeoLong`/`GeoLat` (observatory, km/deg/deg) and `posrefsys`
# (`J2000` / `B1950` / `APP` / `ICRS` / `TOPO`); columns `MJD` (day),
# `RA` / `DEC` (deg), `Rho` (AU), `RadVel` (AU/d).  The position at an
# arbitrary epoch is a linear interpolation of the (ρ, RA, Dec)
# Cartesian vector between the two bracketing rows (`MeasComet::get`).

"""
    Ephemeris

An opened solar-system ephemeris table (casacore `MeasComet` format).
Construct with [`open_ephemeris`](@ref) or get one for a moving-target
field with [`field_ephemeris`](@ref); evaluate with
[`ephemeris_direction`](@ref) / [`ephemeris_radvel`](@ref) /
[`ephemeris_distance`](@ref).
"""
struct Ephemeris
    path::String
    name::String
    frame::DataType          # a `RefFrame` singleton type (from `posrefsys`)
    mjd0::Float64            # keyword MJD0 = first sampled MJD - dMJD
    dmjd::Float64
    mjd::Vector{Float64}     # the MJD column (day)
    ra::Vector{Float64}      # deg
    dec::Vector{Float64}     # deg
    rho::Vector{Float64}     # AU
    radvel::Vector{Float64}  # AU/d
    disklon::Union{Nothing,Vector{Float64}}   # sub-observer longitude, deg (optional)
    disklat::Union{Nothing,Vector{Float64}}   # sub-observer latitude,  deg (optional)
end

const _EPHEM_POSREFSYS = Dict("J2000" => J2000, "B1950" => B1950,
    "APP" => APP, "ICRS" => ICRS, "TOPO" => TOPO)

"""
    open_ephemeris(path) -> Ephemeris

Open a casacore ephemeris (`MeasComet`) table at `path`.
"""
function open_ephemeris(path::AbstractString)
    t = readtable(String(path))
    kw = keywords(t)
    _kwd(n) = (v = get(kw, n, nothing); v === nothing ? nothing :
               v isa Real ? float(v) : nothing)
    mjd0 = _kwd("MJD0")
    dmjd = _kwd("dMJD")
    (mjd0 === nothing || dmjd === nothing || dmjd <= 0) && error(
        "open_ephemeris: $path is missing the MJD0 / dMJD keywords")
    name = (v = get(kw, "NAME", nothing); v isa AbstractString ? String(v) : "")
    prs = get(kw, "posrefsys", nothing)
    frame = if prs isa AbstractString
        u = uppercase(prs)
        hit = nothing
        for (k, v) in _EPHEM_POSREFSYS
            occursin(k, u) && (hit = v)
        end
        hit === nothing ? APP : hit
    else
        gd = _kwd("GeoDist")
        (gd !== nothing && gd != 0) ? TOPO : APP     # casacore's default
    end
    cn = Set(columnnames(t))
    all(c -> c in cn, ("MJD", "RA", "DEC", "Rho", "RadVel")) || error(
        "open_ephemeris: $path is missing an MJD/RA/DEC/Rho/RadVel column")
    _diskcol(n) = n in cn ? Float64.(column(t, n)[:]) : nothing
    dlon = _diskcol("DiskLong"); dlat = _diskcol("DiskLat")
    (dlon === nothing) != (dlat === nothing) && (dlon = dlat = nothing)  # need both
    return Ephemeris(String(path), name, frame, mjd0, dmjd,
                     Float64.(column(t, "MJD")[:]), Float64.(column(t, "RA")[:]),
                     Float64.(column(t, "DEC")[:]), Float64.(column(t, "Rho")[:]),
                     Float64.(column(t, "RadVel")[:]), dlon, dlat)
end

# bracketing row + fractional offset (casacore `MeasComet::fillMeas`)
function _ephem_bracket(e::Ephemeris, mjd::Real)
    ut = floor(Int, (mjd - e.mjd0) / e.dmjd) - 1          # 0-based row
    (ut < 0 || ut >= length(e.mjd) - 1) && error(
        "ephemeris \"$(e.name)\": no entry for MJD $mjd (table covers " *
        "$(e.mjd0 + e.dmjd) .. $(e.mjd0 + length(e.mjd) * e.dmjd))")
    i0 = ut + 1                                           # Julia index of row `ut`
    return i0, (mjd - e.mjd[i0]) / e.dmjd
end

_radec_au_xyz(rho, ra_deg, dec_deg) = begin
    ra = deg2rad(ra_deg); dec = deg2rad(dec_deg); cd = cos(dec)
    (rho * cd * cos(ra), rho * cd * sin(ra), rho * sin(dec))
end

"""
    ephemeris_direction(e::Ephemeris, mjd) -> MDirection

The target direction at `mjd` (MJD, ideally TDB — a coarsely sampled
table makes the UTC↔TDB difference negligible), in the table's own
`posrefsys` frame.  Linearly interpolates the Cartesian
(ρ, RA, Dec) vector between the two bracketing rows.
"""
function ephemeris_direction(e::Ephemeris, mjd::Real)
    i0, f = _ephem_bracket(e, mjd)
    p0 = _radec_au_xyz(e.rho[i0], e.ra[i0], e.dec[i0])
    p1 = _radec_au_xyz(e.rho[i0 + 1], e.ra[i0 + 1], e.dec[i0 + 1])
    p = p0 .+ f .* (p1 .- p0)
    r = hypot(p...)
    return MDirection{e.frame}(atan(p[2], p[1]), asin(clamp(p[3] / r, -1.0, 1.0)))
end

"""
    ephemeris_radvel(e::Ephemeris, mjd) -> Float64

The target radial velocity at `mjd`, m/s (linear interpolation of the
`RadVel` column, AU/d → m/s).
"""
function ephemeris_radvel(e::Ephemeris, mjd::Real)
    i0, f = _ephem_bracket(e, mjd)
    (e.radvel[i0] + f * (e.radvel[i0 + 1] - e.radvel[i0])) * AU_METRES / SEC_PER_DAY
end

"""
    ephemeris_distance(e::Ephemeris, mjd) -> Float64

The geocentric distance to the target at `mjd`, metres.
"""
function ephemeris_distance(e::Ephemeris, mjd::Real)
    i0, f = _ephem_bracket(e, mjd)
    p0 = _radec_au_xyz(e.rho[i0], e.ra[i0], e.dec[i0])
    p1 = _radec_au_xyz(e.rho[i0 + 1], e.ra[i0 + 1], e.dec[i0 + 1])
    hypot((p0 .+ f .* (p1 .- p0))...) * AU_METRES
end

"""
    field_ephemeris(fld::Table, field_id) -> Ephemeris | nothing

If FIELD row `field_id` (0-based) is a moving target — a non-negative
`EPHEMERIS_ID` with a matching `EPHEM<id>_*.tab` in the FIELD subtable
directory — return its opened [`Ephemeris`](@ref), else `nothing`.
"""
function field_ephemeris(fld::Table, field_id::Integer)
    "EPHEMERIS_ID" in Set(columnnames(fld)) || return nothing
    eid = Int(column(fld, "EPHEMERIS_ID")[field_id + 1])
    eid < 0 && return nothing
    re = Regex("^EPHEM$(eid)_.*\\.tab\$")
    cands = sort(filter(n -> occursin(re, n), readdir(fld.path)))
    isempty(cands) && error(
        "field_ephemeris: FIELD row $field_id has EPHEMERIS_ID $eid but no " *
        "EPHEM$(eid)_*.tab in $(fld.path)")
    return open_ephemeris(joinpath(fld.path, first(cands)))
end

# shift a direction by a (usually zero) offset -- casacore's
# `MVDirection::shift(offset, True)` (longitude scaled by 1/cos(lat)).
_ephem_shift(lon, lat, dlon, dlat) =
    (dlon == 0 && dlat == 0) ? (lon, lat) : (lon + dlon / cos(lat + dlat), lat + dlat)

# great-circle (SLERP) interpolation between two (lon, lat) points --
# geometrically the same *path* casacore's own `separation` +
# `positionAngle` + `shiftAngle` walks (`MeasComet::getDisk`, verified
# directly against `casa/Quanta/MVDirection.cc`), and correct near the
# pole where a plain linear interp of lon/lat is not.
#
# Phase 135 finding: this is NOT a bit-exact port of `shiftAngle` for a
# large angular separation. `MVDirection::shiftAngle`'s own longitude
# update is `nlng = asin(sin(off)*sin(pa) / cos(nlat))` -- an `asin`,
# not the `atan2` the exact spherical "direct problem" formula needs --
# so it is only correct while the shift stays within about a quarter
# circle of the start point; beyond that it silently returns the wrong
# (aliased) longitude, independently confirmed by a direct numeric
# comparison against this SLERP for a 172°-separated pair (off by >1
# radian at f=0.75, not float noise). This function instead computes the
# true great-circle interpolation, which agrees with casacore's own
# formula for any *typical* ephemeris row-to-row separation (RA/Dec
# between two nearby dates is always small) but is deliberately more
# correct than a literal port for `DiskLong`/`DiskLat` on a fast-
# rotating body sampled at low cadence, where the sub-observer
# longitude can genuinely shift by more than 90° between two adjacent
# table rows.
function _slerp_lonlat(lon0, lat0, lon1, lat1, f)
    u0 = (cos(lat0) * cos(lon0), cos(lat0) * sin(lon0), sin(lat0))
    u1 = (cos(lat1) * cos(lon1), cos(lat1) * sin(lon1), sin(lat1))
    d = clamp(u0[1] * u1[1] + u0[2] * u1[2] + u0[3] * u1[3], -1.0, 1.0)
    Ω = acos(d)
    u = Ω < 1e-9 ? u0 :
        (sin((1 - f) * Ω) .* u0 .+ sin(f * Ω) .* u1) ./ sin(Ω)
    r = hypot(u...)
    (atan(u[2], u[1]), asin(clamp(u[3] / r, -1.0, 1.0)))
end

"""
    ephemeris_diskpos(e::Ephemeris, mjd) -> (lon, lat)

The sub-observer point on the target body's surface at `mjd` — the
`DiskLong` / `DiskLat` ephemeris columns (rad), great-circle
interpolated between the bracketing rows (casacore `MeasComet::getDisk`).
Errors if the table has no `DiskLong` / `DiskLat` columns.
"""
function ephemeris_diskpos(e::Ephemeris, mjd::Real)
    e.disklon === nothing && error(
        "ephemeris \"$(e.name)\": no DiskLong / DiskLat columns")
    i0, f = _ephem_bracket(e, mjd)
    _slerp_lonlat(deg2rad(e.disklon[i0]), deg2rad(e.disklat[i0]),
                  deg2rad(e.disklon[i0 + 1]), deg2rad(e.disklat[i0 + 1]), f)
end
