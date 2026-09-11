# Reference-frame conversions for the `Measure` types, on top of the
# pure-Julia `SOFA.jl` (IAU SOFA) port.  Loaded when the caller does
# `import SOFA`; `import EarthOrientation` as well activates
# `EarthOrientationExt`, which feeds real IERS ΔUT1 / polar-motion into
# `_eop` here (otherwise ΔUT1 = 0, no polar motion, ~1 arcsecond, a
# one-time warning).
#
# Hubs: epoch -> TAI, direction -> ICRS (J2000 treated as ICRS, a ~0.02"
# frame-bias simplification -- documented), frequency -> BARY.
# Physical constants (c, AU, the LSR velocity vectors from casacore
# `MeasTable.cc:3616-3690`) live in `src/constants.jl`.

module SOFAExt

import SOFA
import MeasurementSets as MS
using StaticArrays: SVector, SMatrix
using MeasurementSets: MEpoch, MDirection, MPosition, MFrequency, MRadialVelocity,
    MBaseline, MuvW, MEarthMagnetic, IGRF,
    RefFrame, MeasFrame, reftype,
    UTC, TAI, TT, TDB, UT1, J2000, ICRS, B1950, APP, GALACTIC, ECLIPTIC,
    HADEC, AZEL, AZELGEO, ITRF, WGS84, TOPO, REST, LSRK, LSRD, BARY, GEO, GALACTO,
    LGROUP, CMB,
    MERCURY, VENUS, MARS, JUPITER, SATURN, URANUS, NEPTUNE, SUN, MOON,
    OtherRef, _dir_xyz, _xyz_dir

# All shared -- see `src/constants.jl` (each equals its `SOFA.jl` value).
const C_LIGHT     = MS.C_LIGHT           # m/s
const AU_M        = MS.AU_METRES         # m
const MJD0        = MS.MJD_JD_OFFSET     # 2400000.5
const DAYSEC      = MS.SEC_PER_DAY       # 86400.0
const _VEL_LSRK   = MS.VEL_LSRK
const _VEL_LSRD   = MS.VEL_LSRD
const _VEL_LSRGAL = MS.VEL_LSRGAL
const _VEL_LGROUP = MS.VEL_LGROUP
const _VEL_CMB    = MS.VEL_CMB

_dot(a, b) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]

# ======================================================================
# Earth orientation
# ======================================================================

const _EOP_WARNED = Ref(false)

function _eop(mjd_utc::Float64)
    ext = Base.get_extension(MS, :EarthOrientationExt)
    if ext === nothing
        if !_EOP_WARNED[]
            @warn "MeasurementSets: no Earth-orientation data — `import EarthOrientation` " *
                  "for ΔUT1 / polar motion. Assuming ΔUT1 = 0, no polar motion (~1 arcsec)."
            _EOP_WARNED[] = true
        end
        return (dut1=0.0, xp=0.0, yp=0.0)
    end
    return ext._eop_lookup(mjd_utc)
end

# ΔAT (TAI-UTC, seconds) at a UTC MJD
function _delta_at(mjd_utc::Float64)
    y, m, d, _ = SOFA.jd2cal(MJD0, mjd_utc)
    SOFA.dat(y, m, d, 0.0)
end

# ======================================================================
# epoch  (hub = TAI MJD)
# ======================================================================

_total(nt) = nt.day + nt.fraction - MJD0     # (day, fraction) -> MJD

# location args for dtdb, from a frame position (ITRF xyz, metres)
function _dtdb_loc(frame::MeasFrame)
    p = frame.position
    p === nothing && return (0.5, 0.0, 0.0, 0.0)
    (0.5, atan(p.y, p.x), hypot(p.x, p.y)/1e3, p.z/1e3)
end

function _to_tai(m::MEpoch{A}, frame::MeasFrame) where {A}
    A === TAI && return m.mjd
    if A === UTC
        return _total(SOFA.utctai(MJD0, m.mjd))
    elseif A === TT
        return _total(SOFA.tttai(MJD0, m.mjd))
    elseif A === TDB
        ut, el, u, v = _dtdb_loc(frame)
        dtr = SOFA.dtdb(MJD0, m.mjd, ut, el, u, v)          # TDB-TT, seconds
        tt = SOFA.tdbtt(MJD0, m.mjd, dtr)
        return _total(SOFA.tttai(tt.day, tt.fraction))
    elseif A === UT1
        dat = _delta_at(m.mjd)
        du = _eop(m.mjd).dut1
        return _total(SOFA.ut1tai(MJD0, m.mjd, du - dat))    # dta = UT1-TAI
    end
    error("MeasurementSets: epoch scale $(nameof(A)) is not supported")
end

function _from_tai(tai::Float64, ::Type{B}, frame::MeasFrame) where {B}
    B === TAI && return tai
    if B === UTC
        return _total(SOFA.taiutc(MJD0, tai))
    elseif B === TT
        return _total(SOFA.taitt(MJD0, tai))
    elseif B === TDB
        tt = SOFA.taitt(MJD0, tai)
        ut, el, u, v = _dtdb_loc(frame)
        ttmjd = tt.day + tt.fraction - MJD0
        dtr = SOFA.dtdb(MJD0, ttmjd, ut, el, u, v)
        return _total(SOFA.tttdb(tt.day, tt.fraction, dtr))
    elseif B === UT1
        utc = _total(SOFA.taiutc(MJD0, tai))
        du = _eop(utc).dut1
        return _total(SOFA.utcut1(MJD0, utc, du))
    end
    error("MeasurementSets: epoch scale $(nameof(B)) is not supported")
end

MS._mconv(m::MEpoch, ::Type{B}, frame::MeasFrame) where {B<:RefFrame} =
    MEpoch{B}(_from_tai(_to_tai(m, frame), B, frame))

# --- frame time helpers (two-part JD) --------------------------------
function _frame_scale_mjd(frame::MeasFrame, ::Type{S}) where {S}
    e = frame.epoch
    e === nothing && error("MeasurementSets: this conversion needs `frame.epoch`")
    _from_tai(_to_tai(e, frame), S, frame)
end
_frame_tt(frame)  = (t = _frame_scale_mjd(frame, TT);  (MJD0, t))
_frame_utc(frame) = (u = _frame_scale_mjd(frame, UTC); (MJD0, u))
_frame_ut1(frame) = (u = _frame_scale_mjd(frame, UT1); (MJD0, u))

# `geodetic = true` -> ellipsoid-normal vertical (casacore AZELGEO);
# `false` -> geocentric vertical, i.e. the local vertical points straight
# away from the geocentre (casacore AZEL).
function _frame_site(frame::MeasFrame; geodetic::Bool=true)
    p = frame.position
    p === nothing && error("MeasurementSets: this conversion needs `frame.position`")
    if geodetic
        g = SOFA.gc2gd(:WGS84, SVector(p.x, p.y, p.z))    # (ϵ=elong, ϕ=lat, r=height)
        return (g.ϵ, g.ϕ, g.r)
    end
    r = hypot(p.x, p.y, p.z)
    (atan(p.y, p.x), asin(clamp(p.z / r, -1.0, 1.0)), r - 6_378_137.0)
end

_frame_eop(frame) = _eop(_frame_scale_mjd(frame, UTC))

# local apparent sidereal time (rad) = GAST + observatory east longitude
function MS._lst(frame::MeasFrame)
    uta, utb = _frame_ut1(frame)
    tta, ttb = _frame_tt(frame)
    elong, _, _ = _frame_site(frame)
    mod2pi(SOFA.gst06a(uta, utb, tta, ttb) + elong)
end

# mean sidereal rate, rad per UT1 day (IAU 1982): LST is close enough to
# linear in UT1 over one day that a couple of Newton steps against the
# real (SOFA) sidereal-time relation converge to sub-second precision.
const _SIDEREAL_RATE = 2π * 1.00273781191135448

function _mjd_for_lst(lst_target::Real, mjd0::Real, pos::MPosition)
    fr(m) = MeasFrame(epoch = MEpoch{UTC}(m), position = pos)
    lst0 = MS._lst(fr(mjd0))
    m = mjd0 + mod(lst_target - lst0, 2π) / _SIDEREAL_RATE
    for _ in 1:3
        diff = rem2pi(lst_target - MS._lst(fr(m)), RoundNearest)
        m += diff / _SIDEREAL_RATE
    end
    m
end

# see the docstring on the core stub, `src/measures/types.jl`.
function MS._riseset(ra::Real, dec::Real, mjd::Real, x::Real, y::Real, z::Real,
                     elev0::Real = 0.0)
    pos = MPosition{ITRF}(float(x), float(y), float(z))
    d0 = floor(float(mjd))
    noon = MeasFrame(epoch = MEpoch{UTC}(d0 + 0.5), position = pos)
    dapp = MS.measconvert(MDirection{J2000}(float(ra), float(dec)), APP; frame = noon)
    _, lat, _ = _frame_site(noon)
    c = (sin(elev0) - sin(lat) * sin(dapp.lat)) / (cos(lat) * cos(dapp.lat))
    c > 1 && return (NaN, NaN)                      # never reaches elev0
    c < -1 && return (d0, d0 + 1.0)                 # circumpolar -- up all day
    h0 = acos(c)
    rise_lst = mod2pi(dapp.lon - h0)
    set_lst  = mod2pi(dapp.lon + h0)
    (_mjd_for_lst(rise_lst, d0, pos), _mjd_for_lst(set_lst, d0, pos))
end

# ======================================================================
# position  (ITRF <-> WGS84: casacore stores the SAME geocentric
# Cartesian vector under both refs -- they only differ in which
# ellipsoid a *geodetic* (lon,lat,height) view of that vector uses, so
# the position-frame "conversion" is an identity on x,y,z; the real
# conversion is Cartesian <-> geodetic, `_itrf_to_geodetic`/
# `_geodetic_to_itrf` below, exposed to TaQL-lite as `meas.wgs` /
# `meas.itrfxyz`, Phase 106).
# ======================================================================

function MS._mconv(m::MPosition{A}, ::Type{B}, ::MeasFrame) where {A<:RefFrame,B<:RefFrame}
    (A === ITRF || A === WGS84) && (B === ITRF || B === WGS84) ||
        error("MeasurementSets: position frame $(nameof(A)) -> $(nameof(B)) is not supported")
    MPosition{B}(m.x, m.y, m.z)
end

# see the docstrings on the core stubs, `src/measures/types.jl`.
function MS._geodetic_to_itrf(lon::Real, lat::Real, height::Real)
    p = SOFA.gd2gc(:WGS84, float(lon), float(lat), float(height))
    (p[1], p[2], p[3])
end
function MS._itrf_to_geodetic(x::Real, y::Real, z::Real)
    g = SOFA.gc2gd(:WGS84, SVector(float(x), float(y), float(z)))
    (g.ϵ, g.ϕ, g.r)
end

# ======================================================================
# direction  (hub = ICRS; J2000 ≈ ICRS)
# ======================================================================

_is_icrsish(::Type{T}) where {T} = T === ICRS || T === J2000

# ---- solar-system-body directions (SOFA plan94 / moon98) -------------

const _PLAN94_NP = Dict{DataType,Int}(
    MERCURY => 1, VENUS => 2, MARS => 4, JUPITER => 5,
    SATURN => 6, URANUS => 7, NEPTUNE => 8)
_is_body(::Type{T}) where {T} = T === SUN || T === MOON || haskey(_PLAN94_NP, T)

const _C_AUDAY = C_LIGHT * DAYSEC / AU_M      # speed of light, AU/day

_earth_helio(t) = SOFA.epv00(MJD0, t).helio[1]                 # AU, J2000 eq
_planet_helio(np, t) = SOFA.plan94(MJD0, t, np)[1]             # AU, J2000 eq

# geocentric vector (AU) of the body at the frame epoch
function _body_geovec(::Type{SUN}, tdb, ::Any)
    g = .-_earth_helio(tdb)
    for _ in 1:2
        g = .-_earth_helio(tdb - hypot(g...) / _C_AUDAY)
    end
    g
end
function _body_geovec(::Type{MOON}, ::Any, tt)
    Tuple(SOFA.moon98(MJD0, tt)[1])            # geocentric GCRS ≈ J2000, AU
end
function _body_geovec(::Type{P}, tdb, ::Any) where {P}
    np = _PLAN94_NP[P]
    eb = _earth_helio(tdb)
    g  = _planet_helio(np, tdb) .- eb          # heliocentric planet − heliocentric Earth
    for _ in 1:2
        τ = hypot(g...) / _C_AUDAY
        g = _planet_helio(np, tdb - τ) .- eb   # Earth fixed at tdb (casacore R_PLANET)
    end
    Tuple(g)
end

# observatory geocentric position (metres, GCRS) -- pv[1] of pvtob
function _p_obs_geo(frame::MeasFrame)
    el, phi, hm = _frame_site(frame)
    uta, utb = _frame_ut1(frame)
    tta, ttb = _frame_tt(frame)
    era = SOFA.era00(uta, utb)
    sp  = SOFA.sp00(tta, ttb)
    eop = _frame_eop(frame)
    Tuple(SOFA.pvtob(el, phi, hm, eop.xp, eop.yp, sp, era)[1])
end

# astrometric direction of a body, J2000 equatorial ≈ ICRS -> (ra, dec)
# radians.  `topo` applies the geometric geocentric→topocentric parallax
# shift (~1° for the Moon, ≲30″ planets) -- only wanted for an
# observer-frame target (casacore does this in `applyAPPtoTOPO`); a
# celestial-frame target and `_n_hat` want the geocentric direction, to
# match casacore's `me.measure(body, "J2000")`.
function _body_dir_icrs(::Type{P}, frame::MeasFrame, topo::Bool) where {P}
    frame.epoch === nothing && error(
        "MeasurementSets: a solar-system-body direction needs `frame.epoch`")
    tdb = _frame_scale_mjd(frame, TDB)
    tt  = _frame_scale_mjd(frame, TT)
    g = _body_geovec(P, tdb, tt)                     # AU, geocentric
    if topo && frame.position !== nothing
        g = g .- _p_obs_geo(frame) ./ AU_M           # observer geocentric, AU
    end
    r = hypot(g...)
    (atan(g[2], g[1]), asin(clamp(g[3] / r, -1.0, 1.0)))
end

function _dir_to_icrs(m::MDirection{A}, frame::MeasFrame) where {A}
    _is_icrsish(A) && return (m.lon, m.lat)
    _is_body(A) && return _body_dir_icrs(A, frame, false)
    if A === B1950
        r = SOFA.fk425(m.lon, m.lat, 0.0, 0.0, 0.0, 0.0)
        return (r.ra, r.dec)
    elseif A === GALACTIC
        r = SOFA.g2icrs(m.lon, m.lat);        return (r.ra, r.dec)
    elseif A === ECLIPTIC
        r = SOFA.eceq06(SOFA.JD2000, 0.0, m.lon, m.lat);  return (r.ra, r.dec)
    elseif A === APP
        tt1, tt2 = _frame_tt(frame)
        eo = SOFA.atci13(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, tt1, tt2).eo
        ri = m.lon + eo
        r = SOFA.atic13(ri, m.lat, tt1, tt2)
        return (r.ra, r.dec)
    elseif A === AZEL || A === AZELGEO || A === HADEC
        utc1, utc2 = _frame_utc(frame)
        el, phi, hm = _frame_site(frame; geodetic = A !== AZEL)
        eop = _frame_eop(frame)
        typ = A === HADEC ? 'H' : 'A'
        a = m.lon                                          # ha  /  az
        b = A === HADEC ? m.lat : (pi/2 - m.lat)           # dec /  zen
        ci = SOFA.atoi13(typ, a, b, utc1, utc2, eop.dut1,
                         el, phi, hm, eop.xp, eop.yp, 0.0, 273.15, 0.0, 0.5)
        tt1, tt2 = _frame_tt(frame)
        r = SOFA.atic13(ci.ra, ci.dec, tt1, tt2)
        return (r.ra, r.dec)
    elseif A === ITRF
        uta, utb = _frame_ut1(frame)
        tta, ttb = _frame_tt(frame)
        eop = _frame_eop(frame)
        rc2t = SOFA.c2t06a(tta, ttb, uta, utb, eop.xp, eop.yp)   # GCRS->ITRS
        g = rc2t' * SVector(_dir_xyz(m))                         # ITRS -> GCRS
        d = _xyz_dir(ICRS, g...)
        return (d.lon, d.lat)
    end
    error("MeasurementSets: direction frame $(nameof(A)) is not supported")
end

function _icrs_to_dir(lon::Float64, lat::Float64, ::Type{B}, frame::MeasFrame) where {B}
    _is_icrsish(B) && return MDirection{B}(lon, lat)
    _is_body(B) && error(
        "MeasurementSets: cannot convert a direction *to* the solar-system-body " *
        "frame $(nameof(B)) (body frames are source-only)")
    if B === B1950
        r = SOFA.fk524(lon, lat, 0.0, 0.0, 0.0, 0.0)
        return MDirection{B}(r.ra, r.dec)
    elseif B === GALACTIC
        r = SOFA.icrs2g(lon, lat);       return MDirection{B}(r.lon, r.lat)
    elseif B === ECLIPTIC
        r = SOFA.eqec06(SOFA.JD2000, 0.0, lon, lat);  return MDirection{B}(r.lon, r.lat)
    elseif B === APP
        tt1, tt2 = _frame_tt(frame)
        r = SOFA.atci13(lon, lat, 0.0, 0.0, 0.0, 0.0, tt1, tt2)
        return MDirection{B}(r.ra - r.eo, r.dec)
    elseif B === AZEL || B === AZELGEO || B === HADEC
        utc1, utc2 = _frame_utc(frame)
        el, phi, hm = _frame_site(frame; geodetic = B !== AZEL)
        eop = _frame_eop(frame)
        r = SOFA.atco13(lon, lat, 0.0, 0.0, 0.0, 0.0, utc1, utc2, eop.dut1,
                        el, phi, hm, eop.xp, eop.yp, 0.0, 273.15, 0.0, 0.5)
        return B === HADEC ? MDirection{B}(r.ha, r.dec) : MDirection{B}(r.azi, pi/2 - r.zen)
    elseif B === ITRF
        uta, utb = _frame_ut1(frame)
        tta, ttb = _frame_tt(frame)
        eop = _frame_eop(frame)
        rc2t = SOFA.c2t06a(tta, ttb, uta, utb, eop.xp, eop.yp)   # GCRS -> ITRS
        g = rc2t * SVector(cos(lat)*cos(lon), cos(lat)*sin(lon), sin(lat))
        return _xyz_dir(B, g...)
    end
    error("MeasurementSets: direction frame $(nameof(B)) is not supported")
end

const _OBS_FRAMES = (AZEL, AZELGEO, HADEC, APP, ITRF)

function MS._mconv(m::MDirection, ::Type{B}, frame::MeasFrame) where {B<:RefFrame}
    A = reftype(m)
    if _is_body(A)
        ra, dec = _body_dir_icrs(A, frame, B in _OBS_FRAMES)
        return _icrs_to_dir(ra, dec, B, frame)
    end
    _icrs_to_dir(_dir_to_icrs(m, frame)..., B, frame)
end

# ======================================================================
# frequency  (hub = BARY);  radio/relativistic Doppler, casacore MCFrequency
# ======================================================================

# Earth's barycentric velocity (m/s, J2000) at the frame epoch.
function _v_earth_bary(frame::MeasFrame)
    tdb = _frame_scale_mjd(frame, TDB)
    e = SOFA.epv00(MJD0, tdb)
    v = e.bary[2]                         # AU/day
    (v[1], v[2], v[3]) .* (AU_M / DAYSEC)
end

# Observatory velocity w.r.t. the geocentre (m/s, GCRS≈J2000).
function _v_obs_geo(frame::MeasFrame)
    el, phi, hm = _frame_site(frame)
    uta, utb = _frame_ut1(frame)
    tta, ttb = _frame_tt(frame)
    era = SOFA.era00(uta, utb)
    sp  = SOFA.sp00(tta, ttb)
    eop = _frame_eop(frame)
    pv = SOFA.pvtob(el, phi, hm, eop.xp, eop.yp, sp, era)
    v = pv[2]
    (v[1], v[2], v[3])
end

_dopp(f, beta, sign) = sign > 0 ? f * sqrt((1 + beta) / (1 - beta)) :
                                  f * sqrt((1 - beta) / (1 + beta))

function _n_hat(frame::MeasFrame)
    d = frame.direction
    d === nothing && error(
        "MeasurementSets: a frequency / radial-velocity conversion needs `frame.direction`")
    _dir_xyz(MS.measconvert(d, J2000; frame))
end

function _freq_to_bary(f::MFrequency{A}, n, frame::MeasFrame) where {A}
    A === BARY && return f.hz
    if A === LSRK
        return _dopp(f.hz, _dot(_VEL_LSRK, n) / C_LIGHT, +1)
    elseif A === LSRD
        return _dopp(f.hz, _dot(_VEL_LSRD, n) / C_LIGHT, +1)
    elseif A === GALACTO
        flsrd = _dopp(f.hz, _dot(_VEL_LSRGAL, n) / C_LIGHT, +1)   # GALACTO->LSRD
        return _dopp(flsrd, _dot(_VEL_LSRD, n) / C_LIGHT, +1)     # LSRD->BARY
    elseif A === GEO
        return _dopp(f.hz, _dot(_v_earth_bary(frame), n) / C_LIGHT, -1)
    elseif A === TOPO
        fgeo = _dopp(f.hz, _dot(_v_obs_geo(frame), n) / C_LIGHT, -1)   # TOPO->GEO
        return _dopp(fgeo, _dot(_v_earth_bary(frame), n) / C_LIGHT, -1)
    elseif A === LGROUP
        return _dopp(f.hz, _dot(_VEL_LGROUP, n) / C_LIGHT, +1)
    elseif A === CMB
        return _dopp(f.hz, _dot(_VEL_CMB, n) / C_LIGHT, +1)
    end
    error("MeasurementSets: frequency frame $(nameof(A)) is not supported")
end

function _bary_to_freq(hz::Float64, ::Type{B}, n, frame::MeasFrame) where {B}
    B === BARY && return MFrequency{B}(hz)
    if B === LSRK
        return MFrequency{B}(_dopp(hz, _dot(_VEL_LSRK, n) / C_LIGHT, -1))
    elseif B === LSRD
        return MFrequency{B}(_dopp(hz, _dot(_VEL_LSRD, n) / C_LIGHT, -1))
    elseif B === GALACTO
        flsrd = _dopp(hz, _dot(_VEL_LSRD, n) / C_LIGHT, -1)
        return MFrequency{B}(_dopp(flsrd, _dot(_VEL_LSRGAL, n) / C_LIGHT, -1))
    elseif B === GEO
        return MFrequency{B}(_dopp(hz, _dot(_v_earth_bary(frame), n) / C_LIGHT, +1))
    elseif B === TOPO
        fgeo = _dopp(hz, _dot(_v_earth_bary(frame), n) / C_LIGHT, +1)
        return MFrequency{B}(_dopp(fgeo, _dot(_v_obs_geo(frame), n) / C_LIGHT, +1))
    elseif B === LGROUP
        return MFrequency{B}(_dopp(hz, _dot(_VEL_LGROUP, n) / C_LIGHT, -1))
    elseif B === CMB
        return MFrequency{B}(_dopp(hz, _dot(_VEL_CMB, n) / C_LIGHT, -1))
    end
    error("MeasurementSets: frequency frame $(nameof(B)) is not supported")
end

function MS._mconv(f::MFrequency, ::Type{B}, frame::MeasFrame) where {B<:RefFrame}
    n = _n_hat(frame)
    _bary_to_freq(_freq_to_bary(f, n, frame), B, n, frame)
end

# --- radial velocity (m/s) --------------------------------------------
# casacore `MCRadialVelocity`: relativistic velocity addition of the
# projected frame velocity along the source direction, hub = BARY. Same
# machinery as the frequency path -- the RV `_radd` sign per hop is the
# negative of the frequency `_dopp` sign (Doppler-factor composition and
# relativistic β-addition are algebraically equivalent).

_radd(a, b) = (a + b) / (1 + a * b)          # relativistic β addition

function _rv_to_bary(m::MRadialVelocity{A}, n, frame::MeasFrame) where {A}
    A === BARY && return m.mps
    b = m.mps / C_LIGHT
    if A === LSRK
        return _radd(b, -_dot(_VEL_LSRK, n) / C_LIGHT) * C_LIGHT
    elseif A === LSRD
        return _radd(b, -_dot(_VEL_LSRD, n) / C_LIGHT) * C_LIGHT
    elseif A === GALACTO
        b = _radd(b, -_dot(_VEL_LSRGAL, n) / C_LIGHT)          # GALACTO->LSRD
        return _radd(b, -_dot(_VEL_LSRD, n) / C_LIGHT) * C_LIGHT
    elseif A === GEO
        return _radd(b, _dot(_v_earth_bary(frame), n) / C_LIGHT) * C_LIGHT
    elseif A === TOPO
        b = _radd(b, _dot(_v_obs_geo(frame), n) / C_LIGHT)     # TOPO->GEO
        return _radd(b, _dot(_v_earth_bary(frame), n) / C_LIGHT) * C_LIGHT
    elseif A === LGROUP
        return _radd(b, -_dot(_VEL_LGROUP, n) / C_LIGHT) * C_LIGHT
    elseif A === CMB
        return _radd(b, -_dot(_VEL_CMB, n) / C_LIGHT) * C_LIGHT
    end
    error("MeasurementSets: radial-velocity frame $(nameof(A)) is not supported")
end

function _bary_to_rv(mps::Float64, ::Type{B}, n, frame::MeasFrame) where {B}
    B === BARY && return MRadialVelocity{B}(mps)
    b = mps / C_LIGHT
    if B === LSRK
        return MRadialVelocity{B}(_radd(b, _dot(_VEL_LSRK, n) / C_LIGHT) * C_LIGHT)
    elseif B === LSRD
        return MRadialVelocity{B}(_radd(b, _dot(_VEL_LSRD, n) / C_LIGHT) * C_LIGHT)
    elseif B === GALACTO
        b = _radd(b, _dot(_VEL_LSRD, n) / C_LIGHT)             # BARY->LSRD
        return MRadialVelocity{B}(_radd(b, _dot(_VEL_LSRGAL, n) / C_LIGHT) * C_LIGHT)
    elseif B === GEO
        return MRadialVelocity{B}(_radd(b, -_dot(_v_earth_bary(frame), n) / C_LIGHT) * C_LIGHT)
    elseif B === TOPO
        b = _radd(b, -_dot(_v_earth_bary(frame), n) / C_LIGHT) # BARY->GEO
        return MRadialVelocity{B}(_radd(b, -_dot(_v_obs_geo(frame), n) / C_LIGHT) * C_LIGHT)
    elseif B === LGROUP
        return MRadialVelocity{B}(_radd(b, _dot(_VEL_LGROUP, n) / C_LIGHT) * C_LIGHT)
    elseif B === CMB
        return MRadialVelocity{B}(_radd(b, _dot(_VEL_CMB, n) / C_LIGHT) * C_LIGHT)
    end
    error("MeasurementSets: radial-velocity frame $(nameof(B)) is not supported")
end

function MS._mconv(m::MRadialVelocity, ::Type{B}, frame::MeasFrame) where {B<:RefFrame}
    n = _n_hat(frame)
    _bary_to_rv(_rv_to_bary(m, n, frame), B, n, frame)
end

# ======================================================================
# baseline / uvw  (3-vectors in a direction frame)
# ======================================================================

# casacore `MCBaseline`: every route applies the same rotations as
# `MCDirection` to the whole vector; a pure rotation preserves the
# length, and the aberration routes bracket the call with
# `adjust`/`readjust` (normalise to unit, restore length).  So a
# baseline conversion is: convert the unit direction with the existing
# `MDirection` code, then rescale by the original length.
function MS._mconv(b::MBaseline{A}, ::Type{B}, frame::MeasFrame) where {A<:RefFrame,B<:RefFrame}
    r = hypot(b.x, b.y, b.z)
    r == 0 && return MBaseline{B}(0.0, 0.0, 0.0)
    d2 = MS.measconvert(_xyz_dir(A, b.x, b.y, b.z), B; frame)
    ux, uy, uz = _dir_xyz(d2)
    MBaseline{B}(r * ux, r * uy, r * uz)
end

# casacore `MCuvw::toPole` / `fromPole` --
#   R = RotMatrix(Euler(-π/2 + lat, 2u, -lon, 3u))
#     = T₂(-π/2+lat) · T₃(-lon)   (RotMatrix applies Euler angles in
#       forward order with right-multiplication; the header doc's
#       reverse order is stale -- see casa/Quanta/RotMatrix.cc).
# `MVPosition::operator*=(R)` (toPole) computes  Rᵀ·v ;
# `R * MVPosition`           (fromPole) computes  R·v .
function _uvw_pole_R(d::MDirection)
    a = -pi/2 + d.lat
    b = -d.lon
    ca, sa = cos(a), sin(a)
    cb, sb = cos(b), sin(b)
    SMatrix{3,3,Float64}(
        # column-major: (row1..3 of col1), (col2), (col3)
        ca*cb,  sb,     -sa*cb,
        -ca*sb, cb,      sa*sb,
        sa,     0.0,     ca)
end
_topole(xyz, d::MDirection)   = _uvw_pole_R(d)' * SVector{3,Float64}(xyz)
_frompole(xyz, d::MDirection) = _uvw_pole_R(d)  * SVector{3,Float64}(xyz)

function MS._mconv(u::MuvW{A}, ::Type{B}, frame::MeasFrame) where {A<:RefFrame,B<:RefFrame}
    frame.direction === nothing && error(
        "MeasurementSets: a uvw conversion needs `frame.direction` (the phase centre)")
    dA = MS.measconvert(frame.direction, A; frame)
    plain = _topole((u.u, u.v, u.w), dA)                    # uvw -> plain baseline in A
    bB = MS._mconv(MBaseline{A}(plain...), B, frame)        # rotate A -> B
    dB = MS.measconvert(frame.direction, B; frame)
    w = _frompole((bB.x, bB.y, bB.z), dB)                   # plain baseline -> uvw in B
    MuvW{B}(w...)
end

# ======================================================================
# Earth magnetic field  (nano-tesla, direction-family frames + IGRF model)
# ======================================================================

# A field vector rotates like a plain vector -- same as `MCBaseline`:
# rotate the unit direction with the `MDirection` code, keep the length.
function MS._mconv(m::MEarthMagnetic{A}, ::Type{B}, frame::MeasFrame) where {A<:RefFrame,B<:RefFrame}
    r = hypot(m.x, m.y, m.z)
    r == 0 && return MEarthMagnetic{B}(0.0, 0.0, 0.0)
    d2 = MS.measconvert(_xyz_dir(A, m.x, m.y, m.z), B; frame)
    ux, uy, uz = _dir_xyz(d2)
    MEarthMagnetic{B}(r * ux, r * uy, r * uz)
end

# The IGRF model frame: evaluate the field at `frame.position` /
# `frame.epoch` (giving an ITRF vector), then rotate to `B`.
function MS._mconv(::MEarthMagnetic{IGRF}, ::Type{B}, frame::MeasFrame) where {B<:RefFrame}
    frame.position === nothing && error(
        "MeasurementSets: an IGRF earth-magnetic conversion needs `frame.position`")
    frame.epoch === nothing && error(
        "MeasurementSets: an IGRF earth-magnetic conversion needs `frame.epoch`")
    bf = MS.earthfield(frame.position, frame.epoch)
    B === ITRF ? bf : MS._mconv(bf, B, frame)
end

# casacore `EarthMagneticMachine::calculate` -- intersect the line of
# sight with a shell `height` above the observer, sample the IGRF field
# at the pierce point, project onto the line of sight.
function MS.emm_lineofsight(dir::MDirection, height::Real, pos::MPosition, epoch::MEpoch)
    fr = MeasFrame(epoch = epoch, position = pos)
    u = _dir_xyz(MS.measconvert(dir, ITRF; frame = fr))     # unit line of sight, ITRF
    px, py, pz = pos.x, pos.y, pos.z
    posl = hypot(px, py, pz)
    subl = height * (height + 2 * posl)                     # = (posl+h)^2 - posl^2
    an = px * u[1] + py * u[2] + pz * u[3]
    x = sqrt(an * an + subl)
    x = min(abs(-an + x), abs(-an - x))                     # near shell crossing
    sx, sy, sz = px + x * u[1], py + x * u[2], pz + x * u[3]
    sr = hypot(sx, sy, sz)
    slon = atan(sy, sx)
    slat = asin(clamp(sz / sr, -1.0, 1.0))
    bx, by, bz = MS._earthfield_itrf(MS._igrf_gh(epoch.mjd), sr, slon, slat)
    (; losfield = bx * u[1] + by * u[2] + bz * u[3],
       field = MEarthMagnetic{ITRF}(bx, by, bz),
       subpoint = MPosition{ITRF}(sx, sy, sz),
       sublon = slon, sublat = slat)
end

end # module
