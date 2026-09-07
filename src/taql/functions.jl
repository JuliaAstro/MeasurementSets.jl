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
        fn in _MSCAL_FUNCS || throw(ArgumentError(
            "TaQL-lite: unknown mscal function \"$name\" in \"$src\""))
        n == 0 && return TQLMScal(fn)
        (n == 1 && fn in _MSCAL_DIR_FUNCS) || throw(ArgumentError(
            "TaQL-lite: $name() takes no arguments" *
            (fn in _MSCAL_DIR_FUNCS ? " or one direction argument" : "") *
            " in \"$src\""))
        return TQLMScal(fn, _mscal_dir_arg(args[1], src))
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

