# ======================================================================
# functions -- NAME(args...).  A curated "lite" subset of TaQL's library
# (scalar math, complex parts, array-cell reductions, string ops, a few
# specials).  Function names are case-insensitive; many have aliases,
# matching casacore's own `TableParseFunc::findFunc`.  Not supported:
# date/time, measures/cones, sliding-window (`running*`/`boxed*`) ops,
# `rand`, array reshaping, `rowid()`, `substr`, type conversions, UDFs.
# ======================================================================

# unary / binary elementwise (map over an array cell, apply directly to
# a scalar) -- share the `_bcast` helper used by the arithmetic evaluator
_ew(f) = x -> _bcast(f, x)
_ew2(f) = (x, y) -> _bcast(f, x, y)
# reduction: a scalar arg is wrapped in a 1-tuple so `f` still applies
_red(f) = x -> f(x isa TQLMArray ? _mvalid(x) : x isa AbstractArray ? x : (x,))

_tql_rms(x) = sqrt(_red(y -> sum(abs2, y) / length(y))(x))
_tql_nelem(x) = x isa TQLMArray ? count(!, x.mask) : x isa AbstractArray ? length(x) : 1
_tql_ndim(x) = x isa TQLMArray ? ndims(x.data) : x isa AbstractArray ? ndims(x) : 0

_tql_arraymask(x::TQLMArray) = x.mask
_tql_arraymask(x::AbstractArray) = falses(size(x))
_tql_arraymask(_) = false

# --- date/time (Phase 69) --------------------------------------------
# Every TaQL-lite date value is an MJD `Float64` (days) -- so `_bcast`,
# `isless`, ORDER BY all keep working. casacore's `datetime`/`mjd`/... are
# built-in (`casa/Quanta` only). `Dates` (stdlib) does the parsing.
_tql_mjd_of(dt::Dates.DateTime) = (dt - MJD_EPOCH) / Dates.Millisecond(MSEC_PER_DAY)
_tql_dt_of(m::Real) = MJD_EPOCH + Dates.Millisecond(round(Int, float(m) * MSEC_PER_DAY))

const _TQL_DT_FORMATS = (
    Dates.DateFormat("yyyy-mm-ddTHH:MM:SS.s"),
    Dates.DateFormat("yyyy-mm-ddTHH:MM:SS"),
    Dates.DateFormat("yyyy-mm-dd HH:MM:SS"),
    Dates.DateFormat("yyyy-mm-dd"),
    Dates.DateFormat("yyyy/mm/dd/HH:MM:SS"),
    Dates.DateFormat("yyyy/mm/dd"),
    Dates.DateFormat("dduuuyyyy/HH:MM:SS"),
    Dates.DateFormat("dduuuyyyy"),
    Dates.DateFormat("dd-uuu-yyyy/HH:MM:SS"),
    Dates.DateFormat("dd-uuu-yyyy"),
)

# Parse a sexagesimal angle. `kind` -> `:ra` (h/m/s time, ×15 to
# degrees), `:dec` / `:angle` (d/m/s degrees). Accepts `10h42m31.3s`,
# `10:42:31.3`, `10 42 31.3`, a leading sign, or a bare decimal (degrees).
# Returns radians.
# classify a `<num><unit>` literal's unit run as a sexagesimal token:
# `h` / `h30m` / `h30m15s` -> :ra, `d` / `d51m` / `d51m16` -> :dec, else
# `nothing` (a plain quantity literal like `30deg` / `1.4GHz`).
function _sexagesimal_unit(u::AbstractString)
    m = match(r"^([hd])(?:\d+(?:\.\d+)?m(?:\d+(?:\.\d+)?s?)?|\d+(?:\.\d+)?s)?$", u)
    m === nothing ? nothing : (m[1] == "h" ? :ra : :dec)
end

function _parse_sexagesimal(s::AbstractString, kind::Symbol)
    t = strip(String(s))
    neg = startswith(t, "-")
    (neg || startswith(t, "+")) && (t = strip(t[nextind(t, 1):end]))
    fields = if occursin(r"[hdms]"i, t)
        parse.(Float64, split(t, r"[hdms]"i; keepempty = false))
    elseif occursin(':', t)
        parse.(Float64, split(t, ':'; keepempty = false))
    elseif occursin(r"\s", t)
        parse.(Float64, split(t))
    else
        return (neg ? -1.0 : 1.0) * deg2rad(parse(Float64, t))   # decimal degrees
    end
    isempty(fields) && throw(ArgumentError("TaQL-lite: bad sexagesimal value \"$s\""))
    v = fields[1] + get(fields, 2, 0.0) / 60 + get(fields, 3, 0.0) / 3600
    kind === :ra && (v *= 15.0)
    return (neg ? -1.0 : 1.0) * deg2rad(v)
end

function _tql_parse_datetime(s::AbstractString)
    ss = strip(String(s))
    isempty(ss) && return _tql_mjd_of(Dates.now())
    for f in _TQL_DT_FORMATS
        v = tryparse(Dates.DateTime, ss, f)
        v === nothing || return _tql_mjd_of(v)
    end
    v = tryparse(Dates.DateTime, ss)
    v === nothing && throw(ArgumentError(
        "TaQL-lite: cannot parse datetime \"$s\" — try ISO " *
        "(`2020-02-12`, `2020-02-12T03:04:05`)"))
    return _tql_mjd_of(v)
end

_tql_datetime(a...) = isempty(a) ? _tql_mjd_of(Dates.now()) :
    a[1] isa AbstractString ? _tql_parse_datetime(a[1]) : float(a[1])
_tql_now_mjd() = _tql_mjd_of(Dates.now())

_pad2(n) = lpad(n, 2, '0')
# radians -> `HH:MM:SS.sss` (of time) / `+DD.MM.SS.sss` (of arc); the
# angle is quantised to milliseconds/milliarcsec as an integer first so
# rounding never leaves a `60` in a field.
function _tql_hms(rad::Real)
    tms = mod(round(Int, mod(float(rad) * (12 / pi), 24) * 3_600_000), 24 * 3_600_000)
    h, r = divrem(tms, 3_600_000)
    m, r = divrem(r, 60_000)
    sec, ms = divrem(r, 1000)
    string(_pad2(h), ":", _pad2(m), ":", _pad2(sec), ".", lpad(ms, 3, '0'))
end
function _tql_dms(rad::Real)
    sgn = signbit(float(rad)) ? "-" : "+"
    tmas = round(Int, abs(float(rad)) * (180 / pi) * 3_600_000)
    d, r = divrem(tmas, 3_600_000)
    m, r = divrem(r, 60_000)
    sec, ms = divrem(r, 1000)
    string(sgn, _pad2(d), ".", _pad2(m), ".", _pad2(sec), ".", lpad(ms, 3, '0'))
end

# great-circle angular distance between two `[lon, lat]` radian points
# (SOFA `seps` -- the atan2 form, numerically stable near 0 and π).
function _tql_angdist(lon1::Real, lat1::Real, lon2::Real, lat2::Real)
    dlon = lon2 - lon1
    x = cos(lat2) * sin(dlon)
    y = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon)
    z = sin(lat1) * sin(lat2) + cos(lat1) * cos(lat2) * cos(dlon)
    return atan(hypot(x, y), z)
end

# name => (callable-over-arg-values, allowed arg count).  `min`/`max` and
# `angdist` are arity-overloaded and handled in `_make_func`, not here.
const _TQL_FUNCS = Dict{String,Tuple{Base.Callable,UnitRange{Int}}}(
    # --- unary elementwise numeric ---
    "abs" => (_ew(abs), 1:1), "amplitude" => (_ew(abs), 1:1), "ampl" => (_ew(abs), 1:1),
    "sqrt" => (_ew(sqrt), 1:1), "square" => (_ew(abs2), 1:1), "sqr" => (_ew(abs2), 1:1),
    "cube" => (_ew(x -> x^3), 1:1),
    "exp" => (_ew(exp), 1:1), "log" => (_ew(log), 1:1), "ln" => (_ew(log), 1:1),
    "log10" => (_ew(log10), 1:1),
    "sin" => (_ew(sin), 1:1), "cos" => (_ew(cos), 1:1), "tan" => (_ew(tan), 1:1),
    "asin" => (_ew(asin), 1:1), "acos" => (_ew(acos), 1:1), "atan" => (_ew(atan), 1:1),
    "sinh" => (_ew(sinh), 1:1), "cosh" => (_ew(cosh), 1:1), "tanh" => (_ew(tanh), 1:1),
    "sign" => (_ew(sign), 1:1), "floor" => (_ew(floor), 1:1), "ceil" => (_ew(ceil), 1:1),
    "round" => (_ew(round), 1:1), "int" => (_ew(x -> trunc(Int, x)), 1:1),
    "integer" => (_ew(x -> trunc(Int, x)), 1:1),
    "real" => (_ew(real), 1:1), "imag" => (_ew(imag), 1:1),
    "arg" => (_ew(angle), 1:1), "phase" => (_ew(angle), 1:1),
    "conj" => (_ew(conj), 1:1), "norm" => (_ew(abs2), 1:1),
    "isnan" => (_ew(isnan), 1:1), "isinf" => (_ew(isinf), 1:1),
    "isfinite" => (_ew(isfinite), 1:1),
    "nonfinite" => (_ew(!isfinite), 1:1), "isnonfinite" => (_ew(!isfinite), 1:1),
    # --- binary elementwise ---
    "pow" => (_ew2(^), 2:2), "atan2" => (_ew2((y, x) -> atan(y, x)), 2:2),
    "fmod" => (_ew2(rem), 2:2),
    # --- array-cell reductions ---
    "sum" => (_red(sum), 1:1), "product" => (_red(prod), 1:1),
    "mean" => (_red(Statistics.mean), 1:1), "avg" => (_red(Statistics.mean), 1:1),
    "median" => (_red(Statistics.median), 1:1),
    "variance" => (_red(x -> Statistics.var(x; corrected=false)), 1:1),
    "stddev" => (_red(x -> Statistics.std(x; corrected=false)), 1:1),
    "rms" => (_tql_rms, 1:1),
    "any" => (_red(any), 1:1), "all" => (_red(all), 1:1),
    "ntrue" => (_red(x -> count(identity, x)), 1:1),
    "nfalse" => (_red(x -> count(!, x)), 1:1),
    "nelements" => (_tql_nelem, 1:1), "count" => (_tql_nelem, 1:1),
    "ndim" => (_tql_ndim, 1:1),
    # --- masked arrays ---
    "marray" => ((d, m) -> TQLMArray(collect(d), m isa AbstractArray ?
                     BitArray(m) : fill(Bool(m), size(d))), 2:2),
    "arraydata" => (_unwrap_marray, 1:1),
    "arraymask" => (_tql_arraymask, 1:1),
    # --- string ---
    "strlength" => (length, 1:1), "len" => (length, 1:1),
    "upcase" => (uppercase, 1:1), "upper" => (uppercase, 1:1), "toupper" => (uppercase, 1:1),
    "downcase" => (lowercase, 1:1), "lower" => (lowercase, 1:1), "tolower" => (lowercase, 1:1),
    "trim" => (strip, 1:1), "ltrim" => (lstrip, 1:1), "rtrim" => (rstrip, 1:1),
    # --- misc ---
    "iif" => (ifelse, 3:3),
    # --- date/time (MJD-Float days) + angle strings (Phase 69) ---
    "datetime" => (_tql_datetime, 0:1),
    "mjd" => ((a...) -> isempty(a) ? _tql_now_mjd() : float(a[1]), 0:1),
    "mjdtodate" => (x -> float(x), 1:1),
    "date" => ((a...) -> floor(isempty(a) ? _tql_now_mjd() : float(a[1])), 0:1),
    "time" => ((a...) -> (m = isempty(a) ? _tql_now_mjd() : float(a[1]); 2pi * (m - floor(m))), 0:1),
    "year" => (x -> Dates.year(_tql_dt_of(x)), 1:1),
    "month" => (x -> Dates.month(_tql_dt_of(x)), 1:1),
    "day" => (x -> Dates.day(_tql_dt_of(x)), 1:1),
    "week" => (x -> Dates.week(_tql_dt_of(x)), 1:1),
    "weekday" => (x -> Dates.dayofweek(_tql_dt_of(x)), 1:1),
    "dow" => (x -> Dates.dayofweek(_tql_dt_of(x)), 1:1),
    "cdate" => (x -> Dates.format(_tql_dt_of(x), "dd-uuu-yyyy"), 1:1),
    "ctime" => (x -> Dates.format(_tql_dt_of(x), "HH:MM:SS"), 1:1),
    "cmonth" => (x -> Dates.format(_tql_dt_of(x), "uuu"), 1:1),
    "cdow" => (x -> Dates.format(_tql_dt_of(x), "eee"), 1:1),
    "ctod" => (x -> Dates.format(_tql_dt_of(x), "dd-uuu-yyyy/HH:MM:SS"), 1:1),
    "cdatetime" => (x -> Dates.format(_tql_dt_of(x), "dd-uuu-yyyy/HH:MM:SS"), 1:1),
    "hms" => (x -> _tql_hms(float(x)), 1:1),
    "dms" => (x -> _tql_dms(float(x)), 1:1),
    "normangle" => (x -> rem2pi(float(x), RoundNearest), 1:1),
    # sexagesimal string -> radians (`h` in the string => hour angle)
    "angle" => (s -> _parse_sexagesimal(String(s),
                     occursin(r"[hH]", String(s)) ? :ra : :dec), 1:1),
    # observatory name -> its ITRF position [x, y, z] (m), from the
    # bundled Observatories table -- e.g. distance of an antenna from the
    # array centre: `sqrt(sum((POSITION - observatory('VLA'))**2))`
    "observatory" => (s -> begin
        p = observatory(String(s))
        p === nothing && throw(ArgumentError("TaQL-lite: unknown observatory \"$s\""))
        Float64[p.x, p.y, p.z]
    end, 1:1),
    # primary-beam power response (Phase 99/100 `src/beam/beam.jl`)
    "pbgaussian" => ((θ, hpbw) -> exp(-4 * log(2) * (float(θ) / float(hpbw))^2), 2:2),
    "pbellipse" => ((dlon, dlat, hmaj, hmin, pa) ->
        _elliptical_gaussian_power(float(dlon), float(dlat), float(hmaj), float(hmin), float(pa)), 5:5),
)

# g-prefixed aggregate functions.  `_geval(::TQLAggr)` collects the
# group's per-row argument values and applies the scalar reducer here:
# `:scalar` -> over the pooled values (unmasked elements, if the arg is a
# masked array) -> one scalar; `:perelem` (the `s`-suffixed variants) ->
# per array-cell position, over the rows where that cell is unmasked ->
# one array.  `gvariance`/`gstddev` are population (÷N); `gsample*` are
# ÷(N-1), matching casacore's `gvariance0`/`gvariance1` split.
const _pop_var = v -> Statistics.var(v; corrected=false)
const _pop_std = v -> Statistics.std(v; corrected=false)
const _ntrue = v -> count(identity, v)
const _nfalse = v -> count(!, v)
const _TQL_AGGRS = Dict{String,Tuple{Base.Callable,Symbol}}(
    "gcount" => (length, :scalar),
    "gsum" => (sum, :scalar), "gproduct" => (prod, :scalar),
    "gmean" => (Statistics.mean, :scalar), "gavg" => (Statistics.mean, :scalar),
    "gmedian" => (Statistics.median, :scalar),
    "gmin" => (minimum, :scalar), "gmax" => (maximum, :scalar),
    "gvariance" => (_pop_var, :scalar), "gsamplevariance" => (Statistics.var, :scalar),
    "gstddev" => (_pop_std, :scalar), "gsamplestddev" => (Statistics.std, :scalar),
    "grms" => (v -> sqrt(sum(abs2, v) / length(v)), :scalar),
    "gany" => (any, :scalar), "gall" => (all, :scalar),
    "gntrue" => (_ntrue, :scalar), "gnfalse" => (_nfalse, :scalar),
    "gfirst" => (first, :scalar), "glast" => (last, :scalar),
    # per-element variants -- same scalar reducer, applied per cell position
    "gsums" => (sum, :perelem), "gproducts" => (prod, :perelem),
    "gmeans" => (Statistics.mean, :perelem), "gavgs" => (Statistics.mean, :perelem),
    "gvariances" => (_pop_var, :perelem), "gsamplevariances" => (Statistics.var, :perelem),
    "gstddevs" => (_pop_std, :perelem), "gsamplestddevs" => (Statistics.std, :perelem),
    "grmss" => (v -> sqrt(sum(abs2, v) / length(v)), :perelem),
    "gmins" => (minimum, :perelem), "gmaxs" => (maximum, :perelem),
    "ganys" => (any, :perelem), "galls" => (all, :perelem),
    "gntrues" => (_ntrue, :perelem), "gnfalses" => (_nfalse, :perelem),
)

# --- meas.* : measure conversions in a TaQL-lite expression (Phase 97),
#     a subset of casacore's `libmeas` UDF library.
#
#   meas.<frame>(['SRC',] lon, lat [, mjd [, x, y, z]])  -> [lon, lat] rad
#       <frame> = j2000 / b1950 / app / galactic / ecliptic / azel /
#                 hadec / itrf / icrs;  SRC (a string literal, default
#                 J2000) is the source frame;  mjd (MJD days) is needed
#                 for app/azel/hadec/itrf, x,y,z (ITRF m) also for
#                 azel/hadec/itrf.
#   meas.epoch('TAI'|'TT'|'TDB'|'UT1'|'UTC', mjd)         -> MJD days
#   meas.last(mjd, x, y, z)  /  meas.lst(...)             -> LAST rad
#   meas.freq('SSCALE', 'TSCALE', freq, mjd, x, y, z, ra, dec)     -> Hz
#       (Phase 104) SSCALE/TSCALE ∈ topo/geo/bary/lsrk/lsrd/galacto/
#       lgroup/cmb; ra/dec (J2000, rad) is the source direction the
#       frequency frame is measured toward.
#   meas.rv('SSCALE', 'TSCALE', v, mjd, x, y, z, ra, dec)          -> m/s
#       (Phase 104) same frames/args as meas.freq, for a radial velocity.
#   meas.doppler('SCONV', 'TCONV', value)                          -> value
#       (Phase 104) SCONV/TCONV ∈ radio/optical(z)/ratio/beta(true,
#       relativistic)/gamma -- pure Doppler-convention algebra, no
#       frame/epoch needed.
#   meas.riseset(ra, dec, mjd, x, y, z [, elev0])   -> [rise_mjd, set_mjd]
#       (Phase 104) rise/set UTC MJD of a J2000 direction for the day
#       containing `mjd`; NaN,NaN if it never reaches `elev0` (rad,
#       default 0), floor(mjd),floor(mjd)+1 if circumpolar.
#   meas.pos('SSCALE', 'TSCALE', x, y, z)             -> [x, y, z] m
#       (Phase 106) position frame conversion, SSCALE/TSCALE ∈ itrf/
#       wgs84 -- casacore stores the same Cartesian vector under both,
#       so this is an identity; included for API symmetry.
#   meas.itrfxyz(lon, lat, height)                    -> [x, y, z] m
#       (Phase 106) WGS84 geodetic (lon/lat rad, height m) -> geocentric
#       Cartesian ITRF.
#   meas.wgs(x, y, z)                                 -> [lon, lat, height]
#       (Phase 106) the inverse of meas.itrfxyz -- Cartesian -> WGS84
#       geodetic (rad, rad, m).

const _MEAS_DIR_FRAMES = Dict{String,DataType}(
    "j2000" => J2000, "b1950" => B1950, "app" => APP, "apparent" => APP,
    "galactic" => GALACTIC, "gal" => GALACTIC, "ecliptic" => ECLIPTIC,
    "ecl" => ECLIPTIC, "azel" => AZEL, "hadec" => HADEC, "itrf" => ITRF,
    "icrs" => ICRS)
const _MEAS_EPOCH_FRAMES = Dict{String,DataType}(
    "utc" => UTC, "tai" => TAI, "tt" => TT, "tdt" => TT, "tdb" => TDB, "ut1" => UT1)
const _MEAS_FREQ_FRAMES = Dict{String,DataType}(
    "topo" => TOPO, "geo" => GEO, "bary" => BARY, "lsrk" => LSRK,
    "lsrd" => LSRD, "galacto" => GALACTO, "lgroup" => LGROUP, "cmb" => CMB)
const _MEAS_DOPPLER_CONV = Dict{String,DataType}(
    "radio" => RADIO, "optical" => OPTICAL, "z" => OPTICAL, "ratio" => RATIO,
    "beta" => BETA, "true" => BETA, "relativistic" => BETA, "gamma" => GAMMA)
const _MEAS_POS_FRAMES = Dict{String,DataType}(
    "itrf" => ITRF, "wgs84" => WGS84, "wgs" => WGS84)

_meas_dir_needs_epoch(R) = R === APP || R === AZEL || R === HADEC || R === ITRF
_meas_dir_needs_pos(R) = R === AZEL || R === HADEC || R === ITRF

function _meas_frame(mjd, xyz)
    fr = MeasFrame()
    mjd === nothing || (fr.epoch = MEpoch{UTC}(float(mjd)))
    xyz === nothing || (fr.position = MPosition{ITRF}(float.(xyz)...))
    fr
end

function _meas_full_frame(mjd, x, y, z, ra, dec)
    MeasFrame(epoch = MEpoch{UTC}(float(mjd)), position = MPosition{ITRF}(float(x), float(y), float(z)),
              direction = MDirection{J2000}(float(ra), float(dec)))
end

_meas_freq_convert(S::DataType, T::DataType, freq, mjd, x, y, z, ra, dec) =
    measconvert(MFrequency{S}(float(freq)), T; frame = _meas_full_frame(mjd, x, y, z, ra, dec)).hz

_meas_rv_convert(S::DataType, T::DataType, v, mjd, x, y, z, ra, dec) =
    measconvert(MRadialVelocity{S}(float(v)), T; frame = _meas_full_frame(mjd, x, y, z, ra, dec)).mps

function _meas_pos_convert(S::DataType, T::DataType, x, y, z)
    m = measconvert(MPosition{S}(float(x), float(y), float(z)), T)
    Float64[m.x, m.y, m.z]
end

function _meas_two_scale_args(kind::AbstractString, dict, args::Vector{TQLExpr}, src::AbstractString)
    (length(args) >= 2 && args[1] isa TQLLit && args[1].value isa AbstractString &&
     args[2] isa TQLLit && args[2].value isa AbstractString) || throw(ArgumentError(
        "TaQL-lite: meas.$kind's first two arguments must be string literal frame names " *
        "in \"$src\""))
    S = get(dict, lowercase(String(args[1].value)), nothing)
    T = get(dict, lowercase(String(args[2].value)), nothing)
    (S === nothing || T === nothing) && throw(ArgumentError(
        "TaQL-lite: meas.$kind: unknown frame name in \"$src\""))
    (S, T)
end

function _meas_dir_convert(target::DataType, sref::AbstractString, lon, lat, mjd, xyz)
    S = get(_DIRECTION_FRAMES, uppercase(strip(String(sref))), nothing)
    S === nothing && throw(ArgumentError("meas: unknown source frame \"$sref\""))
    d = measconvert(MDirection{S}(float(lon), float(lat)), target;
                    frame = _meas_frame(mjd, xyz))
    Float64[d.lon, d.lat]
end

function _make_meas_func(fn::String, args::Vector{TQLExpr}, src::AbstractString)
    R = get(_MEAS_DIR_FRAMES, fn, nothing)
    if R !== nothing
        has_sref = !isempty(args) && args[1] isa TQLLit && args[1].value isa AbstractString
        sref = has_sref ? String(args[1].value) : "J2000"
        rest = has_sref ? args[2:end] : args
        need_ep = _meas_dir_needs_epoch(R); need_p = _meas_dir_needs_pos(R)
        want = 2 + (need_ep ? 1 : 0) + (need_p ? 3 : 0)
        length(rest) == want || throw(ArgumentError(
            "TaQL-lite: meas.$fn(['SRC', ]lon, lat" *
            (need_ep ? ", mjd" : "") * (need_p ? ", x, y, z" : "") *
            ") in \"$src\""))
        cb = if need_p
            (a, b, e, x, y, z) -> _meas_dir_convert(R, sref, a, b, e, (x, y, z))
        elseif need_ep
            (a, b, e) -> _meas_dir_convert(R, sref, a, b, e, nothing)
        else
            (a, b) -> _meas_dir_convert(R, sref, a, b, nothing, nothing)
        end
        return TQLFunc(cb, rest)
    end
    if fn == "epoch"
        (length(args) == 2 && args[1] isa TQLLit && args[1].value isa AbstractString) ||
            throw(ArgumentError("TaQL-lite: meas.epoch('TAI'|'TT'|'TDB'|'UT1'|'UTC', mjd) in \"$src\""))
        T = get(_MEAS_EPOCH_FRAMES, lowercase(String(args[1].value)), nothing)
        T === nothing && throw(ArgumentError("meas.epoch: unknown scale \"$(args[1].value)\""))
        return TQLFunc(m -> measconvert(MEpoch{UTC}(float(m)), T).mjd, args[2:end])
    end
    if fn == "last" || fn == "lst"
        length(args) == 4 || throw(ArgumentError(
            "TaQL-lite: meas.last(mjd, x, y, z) in \"$src\""))
        return TQLFunc((m, x, y, z) -> _lst(_meas_frame(m, (x, y, z))), args)
    end
    if fn == "freq" || fn == "frequency"
        (S, T) = _meas_two_scale_args("freq", _MEAS_FREQ_FRAMES, args, src)
        length(args) == 9 || throw(ArgumentError(
            "TaQL-lite: meas.freq('SSCALE', 'TSCALE', freq, mjd, x, y, z, ra, dec) in \"$src\""))
        return TQLFunc((v, m, x, y, z, ra, dec) -> _meas_freq_convert(S, T, v, m, x, y, z, ra, dec),
                       args[3:end])
    end
    if fn == "rv" || fn == "radialvelocity"
        (S, T) = _meas_two_scale_args("rv", _MEAS_FREQ_FRAMES, args, src)
        length(args) == 9 || throw(ArgumentError(
            "TaQL-lite: meas.rv('SSCALE', 'TSCALE', v, mjd, x, y, z, ra, dec) in \"$src\""))
        return TQLFunc((v, m, x, y, z, ra, dec) -> _meas_rv_convert(S, T, v, m, x, y, z, ra, dec),
                       args[3:end])
    end
    if fn == "doppler"
        (S, T) = _meas_two_scale_args("doppler", _MEAS_DOPPLER_CONV, args, src)
        length(args) == 3 || throw(ArgumentError(
            "TaQL-lite: meas.doppler('SCONV', 'TCONV', value) in \"$src\""))
        return TQLFunc(v -> measconvert(MDoppler{S}(float(v)), T).d, args[3:end])
    end
    if fn == "riseset"
        length(args) in (6, 7) || throw(ArgumentError(
            "TaQL-lite: meas.riseset(ra, dec, mjd, x, y, z[, elev0]) in \"$src\""))
        return TQLFunc((rargs...) -> collect(Float64, _riseset(rargs...)), args)
    end
    if fn == "pos" || fn == "position"
        (S, T) = _meas_two_scale_args("pos", _MEAS_POS_FRAMES, args, src)
        length(args) == 5 || throw(ArgumentError(
            "TaQL-lite: meas.pos('SSCALE', 'TSCALE', x, y, z) in \"$src\""))
        return TQLFunc((x, y, z) -> _meas_pos_convert(S, T, x, y, z), args[3:end])
    end
    if fn == "itrfxyz"
        length(args) == 3 || throw(ArgumentError(
            "TaQL-lite: meas.itrfxyz(lon, lat, height) in \"$src\""))
        return TQLFunc((lon, lat, h) -> collect(Float64, _geodetic_to_itrf(lon, lat, h)), args)
    end
    if fn == "wgs"
        length(args) == 3 || throw(ArgumentError(
            "TaQL-lite: meas.wgs(x, y, z) in \"$src\""))
        return TQLFunc((x, y, z) -> collect(Float64, _itrf_to_geodetic(x, y, z)), args)
    end
    throw(ArgumentError("TaQL-lite: meas.$fn is not supported in \"$src\""))
end

function _make_func(name::String, args::Vector{TQLExpr}, src::AbstractString)
    n = length(args)
    if startswith(name, "mscal.")
        fn = name[7:end]
        if fn == "stokes"
            1 <= n <= 3 || throw(ArgumentError(
                "TaQL-lite: mscal.stokes takes 1 to 3 arguments in \"$src\""))
            typestr = n >= 2 ? _stokes_str_arg(args[2], src) : "IQUV"
            rescale = n >= 3 ? _stokes_bool_arg(args[3], src) : false
            return TQLStokes(args[1], _parse_stokes_types(typestr), rescale)
        end
        if fn in _MSSEL_FUNCS
            n == 1 || throw(ArgumentError(
                "TaQL-lite: mscal.$fn takes one selection-string argument in \"$src\""))
            return TQLMSSel(fn, _mssel_str_arg(args[1], src))
        end
        if fn == "pbresponse" || fn == "pbresponsebl"
            1 <= n <= 2 || throw(ArgumentError(
                "TaQL-lite: mscal.$fn('beamspec' [, dir]) in \"$src\""))
            (args[1] isa TQLLit && args[1].value isa AbstractString) || throw(ArgumentError(
                "TaQL-lite: mscal.$fn's first argument must be a string " *
                "literal beam spec (\"gaussian:HPBW\" / \"airy:D:FREQ[:BLK]\" / " *
                "\"ellipse:HMAJ:HMIN:PA\", optionally \":squint:DLON:DLAT\") in \"$src\""))
            beamspec = String(args[1].value)
            _pb_response_fn(beamspec)      # validate now; the closure is rebuilt per-column
            dir = n == 2 ? _mscal_dir_arg(args[2], src) : ""
            return TQLMScal(fn * ":" * beamspec, dir)
        end
        if fn in ("pbcorr", "pbatten", "pbcorrbl", "pbattenbl")
            2 <= n <= 3 || throw(ArgumentError(
                "TaQL-lite: mscal.$fn(valexpr, 'beamspec' [, dir]) in \"$src\""))
            (args[2] isa TQLLit && args[2].value isa AbstractString) || throw(ArgumentError(
                "TaQL-lite: mscal.$fn's second argument must be a string literal " *
                "beam spec (\"gaussian:HPBW\" / \"airy:D:FREQ[:BLK]\" / " *
                "\"ellipse:HMAJ:HMIN:PA\") in \"$src\""))
            beamspec = String(args[2].value)
            _pb_response_fn(beamspec)      # validate now
            dir = n == 3 ? _mscal_dir_arg(args[3], src) : ""
            respname = endswith(fn, "bl") ? "pbresponsebl" : "pbresponse"
            resp = TQLMScal(respname * ":" * beamspec, dir)
            # pbcorr(bl): valexpr / response (true flux from an apparent one);
            # pbatten(bl): valexpr * response (simulate the beam's attenuation)
            return TQLArith(startswith(fn, "pbcorr") ? (/) : (*), args[1], resp)
        end
        if fn in ("riseset", "riseset1", "riseset2")
            0 <= n <= 2 || throw(ArgumentError(
                "TaQL-lite: mscal.$fn([elev0][, dir]) in \"$src\""))
            elev0 = 0.0
            if n >= 1
                (args[1] isa TQLLit && args[1].value isa Real) || throw(ArgumentError(
                    "TaQL-lite: mscal.$fn's elevation-cutoff argument must be a " *
                    "numeric literal (radians) in \"$src\""))
                elev0 = Float64(args[1].value)
            end
            dir = n == 2 ? _mscal_dir_arg(args[2], src) : ""
            return TQLMScal(fn * ":" * string(elev0), dir)
        end
        fn in _MSCAL_FUNCS || throw(ArgumentError(
            "TaQL-lite: unknown mscal function \"$name\" in \"$src\""))
        n == 0 && return TQLMScal(fn)
        (n == 1 && fn in _MSCAL_DIR_FUNCS) || throw(ArgumentError(
            "TaQL-lite: $name() takes no arguments" *
            (fn in _MSCAL_DIR_FUNCS ? " or one direction argument" : "") *
            " in \"$src\""))
        return TQLMScal(fn, _mscal_dir_arg(args[1], src))
    end
    if startswith(name, "meas.")
        return _make_meas_func(name[6:end], args, src)
    end
    if haskey(_TQL_AGGRS, name)
        if name == "gcount"
            n in 0:1 || throw(ArgumentError("TaQL-lite: gcount() takes 0 or 1 arguments in \"$src\""))
            return TQLAggr(length, n == 0 ? nothing : args[1], :scalar)
        end
        n == 1 || throw(ArgumentError("TaQL-lite: $name() takes 1 argument, got $n, in \"$src\""))
        fn, mode = _TQL_AGGRS[name]
        return TQLAggr(fn, args[1], mode)
    end
    if name == "grouping"
        (n == 1 && args[1] isa TQLCol) || throw(ArgumentError(
            "TaQL-lite: grouping() takes one grouping-key column name in \"$src\""))
        return TQLGrouping(args[1].name)
    end
    if name in ("rownumber", "rownr")
        n == 0 || throw(ArgumentError("TaQL-lite: $name() takes no arguments in \"$src\""))
        return TQLRowNum()
    elseif name == "pi" && n == 0
        return TQLLit(π)
    elseif name == "e" && n == 0
        return TQLLit(ℯ)
    elseif name == "min" || name == "max"
        n in 1:2 || throw(ArgumentError("TaQL-lite: $name() takes 1 or 2 arguments in \"$src\""))
        base = name == "min" ? min : max
        fn = n == 1 ? _red(x -> (name == "min" ? minimum : maximum)(x)) : _ew2(base)
        return TQLFunc(fn, args)
    elseif name in ("angdist", "angdistx", "angulardistance", "angulardistancex")
        n in (2, 4) || throw(ArgumentError(
            "TaQL-lite: $name() takes 4 scalar radians or two `[lon, lat]` arrays in \"$src\""))
        fn = n == 4 ? ((a, b, c, d) -> _tql_angdist(a, b, c, d)) :
                      ((a, b) -> _tql_angdist(a[1], a[2], b[1], b[2]))
        return TQLFunc(fn, args)
    elseif name == "pbairy"
        n in 3:4 || throw(ArgumentError(
            "TaQL-lite: pbairy(θ, diameter, freq[, blockage]) in \"$src\""))
        fn = n == 3 ? (θ, d, freq) -> power_response(AiryBeam(float(d)), float(θ), float(freq)) :
                      (θ, d, freq, blk) -> power_response(AiryBeam(float(d); blockage = float(blk)),
                                                          float(θ), float(freq))
        return TQLFunc(fn, args)
    end
    haskey(_TQL_FUNCS, name) || throw(ArgumentError(
        "TaQL-lite: unknown function \"$name\" in \"$src\""))
    fn, arity = _TQL_FUNCS[name]
    n in arity || throw(ArgumentError(
        "TaQL-lite: $name() takes $(arity == 1:1 ? "1 argument" :
         length(arity) == 1 ? "$(first(arity)) arguments" :
         "$(first(arity))–$(last(arity)) arguments"), got $n, in \"$src\""))
    return TQLFunc(fn, args)
end

