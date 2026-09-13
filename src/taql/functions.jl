# ======================================================================
# functions -- NAME(args...).  A curated "lite" subset of TaQL's library
# (scalar math, complex parts, array-cell reductions, string ops, date/
# time, measures conversions, running*/boxed* sliding-window array
# smoothing, a few specials).  Function names are case-insensitive; many
# have aliases, matching casacore's own `TableParseFunc::findFunc`.  Not
# supported: cones, `rand`, array reshaping, `rowid()`, `substr`, type
# conversions, UDFs.
# ======================================================================

# unary / binary elementwise (map over an array cell, apply directly to
# a scalar) -- share the `_bcast` helper used by the arithmetic evaluator
_ew(f) = x -> _bcast(f, x)
_ew2(f) = (x, y) -> _bcast(f, x, y)
# reduction: a scalar arg is wrapped in a 1-tuple so `f` still applies
_red(f) = x -> f(x isa TQLMArray ? _mvalid(x) : x isa AbstractArray ? x : (x,))

# `min(x,y)`/`max(x,y)` (`minFUNC`/`maxFUNC`, `ExprFuncNode.cc:899-921`)
# compare a COMPLEX pair by magnitude (`Complex`/`DComplex`'s own
# `operator<`/`>`, `casa/BasicSL/Complex.h:174-206`, are norm-based --
# ties return the first argument, matching both overloads exactly) --
# Julia's plain `min`/`max` has no ordering for `Complex` at all and
# raises a raw `MethodError` instead. Real-valued operands are
# unaffected (falls straight through to ordinary `min`/`max`).
function _tql_min2(a, b)
    (a isa Complex || b isa Complex) && return abs2(a) > abs2(b) ? b : a
    return min(a, b)
end
function _tql_max2(a, b)
    (a isa Complex || b isa Complex) && return abs2(a) < abs2(b) ? b : a
    return max(a, b)
end

_tql_rms(x) = sqrt(_red(y -> sum(abs2, y) / length(y))(x))

# `avdev()` (`arravdevFUNC`, `casa/Arrays/ArrayMath.tcc:1022-1043`):
# the mean ABSOLUTE deviation from the mean, `mean(|xᵢ - mean(x)|)`
# (casacore uses `std::abs` in the per-element sum, which for a
# Complex array is the magnitude -- so this already generalises to
# complex with no separate branch needed, matching `real(avdev(...))`
# in `ExprFuncNode.cc:808-814`, where the `real()` is a no-op since the
# `abs`-based sum is already real-valued). A real, missing-function
# gap found the same way Phase 185's `*samplevariance*` family was:
# checking the surrounding functions in `TableParseFunc.cc`'s name
# table once one sibling turned out to be absent. Live-verified:
# `avdev(1:8) == 2.0`, matching a hand computation exactly.
_tql_avdev(x) = _red(y -> Statistics.mean(abs.(y .- Statistics.mean(y))))(x)
_tql_nelem(x) = x isa TQLMArray ? count(!, x.mask) : x isa AbstractArray ? length(x) : 1
_tql_ndim(x) = x isa TQLMArray ? ndims(x.data) : x isa AbstractArray ? ndims(x) : 0

# `shape()` (`shapeFUNC`, `ExprFuncNodeArray.cc:1041-1053`) was entirely
# missing -- returns the cell's per-axis extents as an Int array, in
# the SAME axis order this package's arrays are already stored/indexed
# in (casacore's own default, non-C-order style; the C-order-reversed
# form only applies under an explicit `USING STYLE PYTHON`-family
# TaQL style, out of scope -- TaQL-lite has no style selector at all).
# Live-verified: `shape(B)` for a `(3,4)`-shaped cell gives `[3, 4]`,
# matching Julia's own `size(B) == (3, 4)` with no reversal needed; a
# scalar's shape is the empty Int array, matching `size(scalar) == ()`.
_tql_shape(x) = x isa TQLMArray ? collect(Int, size(x.data)) :
    x isa AbstractArray ? collect(Int, size(x)) : Int[]

# casacore's `ltrim()`/`rtrim()` (`leadingWS`/`trailingWS` regexes,
# `ExprFuncNode.cc:973-974`, `"^[ \\t]*"`/`"[ \\t]*\$"`) strip ONLY
# space and tab -- NOT newline/carriage-return -- unlike `trim()`
# (`String::trim()`, `casa/BasicSL/String.cc:105-112`), which strips
# all FOUR (space/tab/`\n`/`\r`) from BOTH ends. Julia's `lstrip`/
# `rstrip` (no predicate) strip ALL Unicode whitespace by default --
# a real, confirmed divergence for `ltrim`/`rtrim` specifically.
# Live-verified: `ltrim("\n\t X \t\n")` in real casacore leaves the
# string COMPLETELY UNCHANGED (it starts with `\n`, which `[ \t]*`
# never matches), while this package's old `lstrip`-based
# implementation stripped everything down to `"X \t\n"`. `trim()`
# itself was already correct (Julia's broader Unicode-whitespace
# `strip` happens to agree with casacore's narrower 4-char set for
# every plain-ASCII case) but is narrowed here too, for exact fidelity
# rather than an accidental agreement.
_tql_trim(s::AbstractString) = strip(c -> c == ' ' || c == '\t' || c == '\n' || c == '\r', s)
_tql_ltrim(s::AbstractString) = lstrip(c -> c == ' ' || c == '\t', s)
_tql_rtrim(s::AbstractString) = rstrip(c -> c == ' ' || c == '\t', s)

# `capitalize()`/`reversestring()`/`sreverse()` (`capitalizeFUNC`/
# `sreverseFUNC`, `ExprFuncNode.cc:988-998`, via `String::capitalize()`/
# `String::reverse()`, `casa/BasicSL/String.cc:315-334`) were entirely
# missing from this package -- found by checking the surrounding string
# functions once the trim divergence above turned up. `capitalize()`
# title-cases each "word" (a maximal run of letters/digits; ANY other
# character, including `_`/`.`, is a word boundary) -- first char of
# each word uppercased, the rest of that word lowercased. Live-verified:
# `capitalize("hello world") == "Hello World"`,
# `capitalize("3d star_field.name") == "3d Star_Field.Name"` (the
# leading digit `3` starts a "word" too, per casacore's own
# `isdigit(*p)` check, but has no case to change). `sreverse`/
# `reversestring` are a plain character reversal, matching Julia's
# `reverse(::AbstractString)` exactly.
function _tql_capitalize(s::AbstractString)
    io = IOBuffer()
    at_word = false
    for c in s
        if isletter(c) || isdigit(c)
            write(io, at_word ? lowercase(c) : uppercase(c))
            at_word = true
        else
            write(io, c)
            at_word = false
        end
    end
    return String(take!(io))
end

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

# casacore `MVTime::read`'s dash-numeric date form (`casa/Quanta/
# MVTime.cc:465-497`) -- `r-mm-dd`, where `r` is read first and the
# grammar disambiguates by its *magnitude*: `r > 1000` means `r` is
# itself the year (`yyyy-mm-dd`, already covered by the ISO
# `_TQL_DT_FORMATS` above); otherwise `r` is the DAY and the trailing
# number is the year, with the same 2-digit-year expansion as the
# `dd-Mon-yyyy` sibling format (`<50` -> `+2000`, `<100` -> `+1900`).
# So `"12-02-2020"` is DD-MM-YYYY (2020-02-12), not ISO -- a valid TaQL
# literal `Dates.DateFormat` can't express (no threshold-dependent
# field-swap), live-verified against real casacore's own `datetime()`.
# The date/time separator is `/`, `-`, or a space in real casacore too
# (`in.tSkipChar('/') || in.tSkipChar('-') || in.tSkipChar(' ')`,
# `MVTime.cc:513`), not just the ISO `T` -- also live-verified.
function _tql_parse_dashnum_date(s::AbstractString)
    m = match(r"^(\d{1,4})-(\d{1,2})-(\d{1,4})(?:[ /T-](\d{1,2}):(\d{1,2}):(\d{1,2}(?:\.\d+)?))?$", s)
    m === nothing && return nothing
    r = parse(Int, m[1]); mm = parse(Int, m[2]); dd2 = parse(Int, m[3])
    if r > 1000
        yyyy, mon, day = r, mm, dd2
    else
        dd2 < 50 && (dd2 += 2000)
        dd2 < 100 && (dd2 += 1900)
        yyyy, mon, day = dd2, mm, r
    end
    (1 <= mon <= 12 && 1 <= day <= 31) || return nothing
    h  = m[4] === nothing ? 0   : parse(Int, m[4])
    mi = m[5] === nothing ? 0   : parse(Int, m[5])
    se = m[6] === nothing ? 0.0 : parse(Float64, m[6])
    ms = round(Int, 1000 * (se - floor(se)))
    dt = try
        Dates.DateTime(yyyy, mon, day, h, mi, floor(Int, se), ms)
    catch
        return nothing
    end
    return _tql_mjd_of(dt)
end

function _tql_parse_datetime(s::AbstractString)
    ss = strip(String(s))
    isempty(ss) && return _tql_mjd_of(Dates.now())
    # Tried FIRST, ahead of the `_TQL_DT_FORMATS` list below: a plain
    # `Dates.DateFormat("yyyy-mm-dd")` will happily match a short
    # numeric field it shouldn't (e.g. it reads "12-02-20" as year=12,
    # stopping at the first dash, rather than raising a mismatch) --
    # `_tql_parse_dashnum_date` applies casacore's own day/year-swap +
    # 2-digit-year-expansion rule up front so the bare `N-N-N` shape is
    # never handed to a format string that can silently mis-parse it.
    m = _tql_parse_dashnum_date(ss)
    m === nothing || return m
    for f in _TQL_DT_FORMATS
        v = tryparse(Dates.DateTime, ss, f)
        v === nothing || return _tql_mjd_of(v)
    end
    v = tryparse(Dates.DateTime, ss)
    v === nothing || return _tql_mjd_of(v)
    throw(ArgumentError(
        "TaQL-lite: cannot parse datetime \"$s\" — try ISO " *
        "(`2020-02-12`, `2020-02-12T03:04:05`) or `dd-mm-yyyy`"))
end

_tql_datetime(a...) = isempty(a) ? _tql_mjd_of(Dates.now()) :
    a[1] isa AbstractString ? _tql_parse_datetime(a[1]) : float(a[1])
_tql_now_mjd() = _tql_mjd_of(Dates.now())

_pad2(n) = lpad(n, 2, '0')
# radians -> `HHhMMmSS.sss` (of time) / `+DDDdMMmSS.sss` (of arc) --
# `TableExprFuncNode::stringHMS`/`stringDMS`
# (`tables/TaQL/ExprFuncNode.cc:1315-1339`), which format via
# `MVAngle::print` (precision 9 -> 3 fractional-second digits) then
# replace the base `HH:MM:SS`/`+DDD.MM.SS` separators with letters (the
# THIRD dms separator -- the seconds decimal point -- is left alone;
# `stringDMS`'s replace loop stops after the second hit). Live-verified
# against real casacore's own `hms()`/`dms()`: no colons/dots-only form
# exists in real TaQL, degrees are always 3 digits (zero-padded, "***"
# above 999 -- not reproduced, no MS angle gets there), hours always 2,
# and — unlike `dms` — `hms` never carries a leading sign (`MVAngle::
# print` only emits one for the ANGLE branch or the `DIG2` modifier,
# neither of which `stringHMS` sets). The angle is quantised to
# milliseconds/milliarcsec as an integer first so rounding never leaves
# a `60` in a field.
function _tql_hms(rad::Real)
    tms = mod(round(Int, mod(float(rad) * (12 / pi), 24) * 3_600_000), 24 * 3_600_000)
    h, r = divrem(tms, 3_600_000)
    m, r = divrem(r, 60_000)
    sec, ms = divrem(r, 1000)
    string(_pad2(h), "h", _pad2(m), "m", _pad2(sec), ".", lpad(ms, 3, '0'))
end
function _tql_dms(rad::Real)
    sgn = signbit(float(rad)) ? "-" : "+"
    tmas = round(Int, abs(float(rad)) * (180 / pi) * 3_600_000)
    d, r = divrem(tmas, 3_600_000)
    m, r = divrem(r, 60_000)
    sec, ms = divrem(r, 1000)
    string(sgn, lpad(d, 3, '0'), "d", _pad2(m), "m", _pad2(sec), ".", lpad(ms, 3, '0'))
end

# MJD -> `"HH:MM:SS.sss"` (of-day, colon separators, no sign) -- the
# time-of-day format `ctime()`/`ctod()` use (`TableExprFuncNode::
# stringTime`/`stringDateTime`, precision 9 -> 3 fractional-second
# digits, `casa/Quanta/MVTime.cc:366-434`'s `MVAngle::print` TIME
# branch). Distinct from `_tql_hms` (which takes a *radian angle*, not
# an MJD, and uses `h`/`m` letter separators): both quantise to
# milliseconds first so rounding never leaves a `60` in a field.
function _tql_time_of_day_str(mjd::Real)
    frac = mod(float(mjd), 1.0)
    tms = mod(round(Int, frac * 24 * 3_600_000), 24 * 3_600_000)
    h, r = divrem(tms, 3_600_000)
    m, r = divrem(r, 60_000)
    sec, ms = divrem(r, 1000)
    string(_pad2(h), ":", _pad2(m), ":", _pad2(sec), ".", lpad(ms, 3, '0'))
end

# `week()` -- casacore's `MVTime::yearweek()` (`casa/Quanta/MVTime.cc:
# 198-206`, on top of `yearday()`, `.cc:185-193`) is NOT the ISO-8601
# week Julia's `Dates.week` computes: at a year boundary where the ISO
# week wraps to week 52/53 of the *previous* year, casacore's own
# algorithm instead returns **0** for those early-January days (found
# by live-checking `Dates.week` against real casacore's `week()` --
# 2022-01-01, a Saturday, is ISO week 52 of 2021 but casacore's own
# `week()` gives 0, not 52). `yearday()`/`yearweek()` ported verbatim
# (integer division/remainder below are Julia `div`/`rem`, which -- like
# C++'s `/`/`%` on `Int` -- truncate toward zero and keep the dividend's
# sign, so this is a direct translation, not a re-derivation).
function _tql_yearday(dt::Dates.DateTime)
    yyyy, e, a = Dates.year(dt), Dates.month(dt), Dates.day(dt)
    c = (yyyy % 4 == 0 && (yyyy % 100 != 0 || yyyy % 400 == 0)) ?
        div(e + 9, 12) : 2 * div(e + 9, 12)
    return div(275 * e, 9) - c + a - 30
end
function _tql_yearweek(dt::Dates.DateTime)
    yd = _tql_yearday(dt) - 4
    yw = div(yd + 7, 7)
    yd = rem(yd, 7)
    wd = Dates.dayofweek(dt)             # casacore's weekday(): Mon=1..Sun=7, same as Dates
    if yd >= 0
        yd >= wd && return yw + 1
    elseif yd + 7 >= wd
        return yw + 1
    end
    return yw
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

# --- Phase 108: running*/boxed* sliding-window array reductions -------
#
# These are, deliberately, array-*cell* smoothing filters (one MAIN row's
# array reduced along its own axis/axes), not a multi-row window -- the
# name overlap with `gs*`'s "s"-suffixed per-element GROUP BY reductions
# is coincidental, unrelated machinery.
#
#   running<X>(arr, hwidth)  -- a centred sliding window, SAME shape as
#       `arr`. Ported from casacore's own `slidingArrayMath`
#       (`casa/Arrays/ArrayPartMath.tcc:1060-1104`, `fillEdge=true` --
#       the only mode TaQL's 2-arg `running<X>()` ever exercises, live-
#       verified against real casacore): output element i (per axis d)
#       reduces the FULL `arr[i-h[d] : i+h[d]]` window ONLY where that
#       whole window fits inside the array; every edge position within
#       `h[d]` of a boundary (where no full window fits) is `zero(T)`,
#       NOT a reduction over a truncated window -- casacore does not
#       shrink the window at the edges, it leaves them unfilled.
#   boxed<X>(arr, bwidth)    -- non-overlapping bins of size `bwidth`
#       (per axis) -- SMALLER shape, `cld(n[d], b[d])` per axis (the
#       trailing bin genuinely IS a partial-window reduction if `bwidth`
#       doesn't divide evenly -- confirmed against `boxedArrayMath`,
#       `.tcc:1021-1053` -- no edge/fill concept here, unlike `running*`).
#
# `hwidth`/`bwidth` is a scalar (same width on every axis) or an array
# literal (one width per axis, `ndims(arr)` elements). Masked-array
# (`TQLMArray`) input is not supported -- pass `arraydata(...)` first.
_require_array(x) = x isa AbstractArray ? x : throw(ArgumentError(
    "TaQL-lite: running*/boxed* need an array-valued first argument"))

function _tql_window_widths(w, nd::Int)
    ws = w isa AbstractArray ? Int.(w) : fill(Int(w), nd)
    length(ws) == nd || throw(ArgumentError(
        "TaQL-lite: running*/boxed* window width must be a scalar or a " *
        "$nd-element array (one per axis)"))
    ws
end

function _running_reduce(f, T::Type, arr::AbstractArray, hw)
    nd = ndims(arr)
    h = _tql_window_widths(hw, nd)
    sz = size(arr)
    out = zeros(T, sz)                    # edges stay `zero(T)` (fillEdge=true)
    lo = ntuple(d -> h[d] + 1, nd)
    hi = ntuple(d -> sz[d] - h[d], nd)
    any(lo[d] > hi[d] for d in 1:nd) && return out     # no position has a full window
    for idx in CartesianIndices(ntuple(d -> lo[d]:hi[d], nd))
        rng = ntuple(d -> (idx[d] - h[d]):(idx[d] + h[d]), nd)
        out[idx] = f(vec(view(arr, rng...)))
    end
    out
end

function _boxed_reduce(f, T::Type, arr::AbstractArray, bw)
    nd = ndims(arr)
    b = _tql_window_widths(bw, nd)
    sz = size(arr)
    osz = ntuple(d -> cld(sz[d], b[d]), nd)
    out = Array{T}(undef, osz)
    for oidx in CartesianIndices(osz)
        rng = ntuple(d -> ((oidx[d] - 1) * b[d] + 1):min(sz[d], oidx[d] * b[d]), nd)
        out[oidx] = f(vec(view(arr, rng...)))
    end
    out
end

# casacore's plain `median()` (`arrmedianFUNC` -> `casa/Arrays/
# ArrayMath.tcc:1066-1107`, the default overload
# `median(a) = median(a, false, a.nelements()<=100, false)`) has an
# odd, size-dependent quirk Julia's `Statistics.median` does not: for
# an EVEN-length array it averages the two middle order statistics
# ONLY when the array has <=100 elements -- above that threshold it
# returns just the LOWER of the two, no averaging at all. Live-verified
# against real casacore: `median(1.0:128.0) == 64.0`, not `64.5` --
# directly relevant to any wideband spectral-window array (128/256/
# 3840-channel bands are common and both even and >100).
function _tql_median(v)
    s = sort!(vec(collect(v)))
    n = length(s)
    n == 0 && throw(ArgumentError("TaQL-lite: median of an empty array"))
    n2 = (n - 1) ÷ 2 + 1                       # 1-based lower-middle order statistic
    (iseven(n) && n <= 100) ? (s[n2] + s[n2+1]) / 2 : s[n2]
end

# casacore's GENERIC `fractile()` (`.tcc:1138-1161`) -- what `gmedian()`
# (`TableExprGroupFractileDouble(this, 0.5)`) and `running`/`boxed`
# median (`slidingMedians`/`boxedMedians`, `MArrayMath.h:1168-1184`,
# hardcoded `takeEvenMean=False`, no TaQL argument to change it) both
# actually go through -- NEVER averages, regardless of size (a
# genuinely different convention from plain `median()` above). Live-
# verified: `gmedian` of the 4-row group `[1,2,3,4]` is `2.0` in real
# casacore, not `2.5`.
_tql_fractile(v, frac::Real) = (s = sort!(vec(collect(v))); n = length(s);
    n == 0 ? throw(ArgumentError("TaQL-lite: fractile of an empty array")) :
    s[Int(floor((n - 1) * frac + 0.01)) + 1])
_tql_median_lo(v) = _tql_fractile(v, 0.5)

# casacore's `round()` (`roundFUNC`, `ExprFuncNode.cc:737-742`) is
# round-HALF-AWAY-FROM-ZERO (`val<0 ? ceil(val-0.5) : floor(val+0.5)`),
# NOT Julia's default `round` (ties-to-even/banker's rounding) -- a
# real, silent divergence at every exact `.5` boundary with an even
# integer part. Live-verified against real casacore:
# `round(2.5) == 3.0` (Julia's `round(2.5) == 2.0`), `round(0.5) ==
# 1.0` (Julia's `round(0.5) == 0.0`); non-tie values (`2.4`, `2.6`)
# already agreed, which is why this went unnoticed until directly
# checked against the source.
_tql_round(x::Real) = x < 0 ? ceil(x - 0.5) : floor(x + 0.5)

# casacore's `pow(x,y)` (`powFUNC`, `ExprFuncNode.cc:655-657`) is a
# direct call to C's `std::pow`, which returns NaN for a negative base
# with a non-integer exponent rather than raising -- Julia's `^` for
# two reals THROWS a `DomainError` in exactly that case ("Exponentiation
# yielding a complex result requires a complex argument"). A real,
# live-verified divergence: `pow(-2.0, 0.5)` is `NaN` in real casacore,
# and would crash a query in this package before this fix (any column
# that can go negative -- e.g. `pow(UVW[1], 0.5)` -- is a realistic
# trigger). An integer-valued exponent (even as a Float, e.g. `2.0`)
# does NOT throw in Julia either (`(-1.0)^2.0 == 1.0`), matching
# casacore, so only the genuinely-fractional-exponent case needs a
# guard.
_tql_pow(x::Real, y::Real) = (xf = float(x); yf = float(y);
    xf < 0 && !isinteger(yf) ? NaN : xf^yf)

# The exact same "raw C++ std:: call, no domain guard, returns NaN"
# shape as `pow` above -- found by sweeping every other unary math
# function `ExprFuncNode.cc:sqrtFUNC/logFUNC/log10FUNC/asinFUNC/
# acosFUNC` call for the identical pattern once `pow` turned out wrong.
# `sqrtFUNC`/`logFUNC`/`log10FUNC` (`.cc:668-670,653-654`) are a bare
# `sqrt`/`log`/`log10` on a `Double` (out-of-domain -> NaN in C++, a
# `DomainError` in Julia's own `sqrt`/`log`/`log10` for a negative
# `Real`); `asinFUNC`/`acosFUNC` (`.cc:713-716`) are a bare `asin`/
# `acos` (out-of-`[-1,1]` -> NaN in C++, a `DomainError` in Julia's own
# `asin`/`acos` for a `Real`). Live-verified against real casacore:
# `sqrt(-4.0)`/`log(-1.0)`/`log10(-1.0)`/`asin(2.0)`/`acos(2.0)` are
# all `NaN`, not an error -- exactly the same real-column-can-go-
# negative crash risk `pow` had (`sqrt(WEIGHT - threshold)`,
# `asin(UVW[1] / baseline)`, …). A `Complex` argument is unaffected --
# Julia's own `Complex` `sqrt`/`log`/`log10`/`asin`/`acos` already never
# throw (they return the analytic-continuation branch, matching C++'s
# `std::complex` overloads) -- so only the `Real` method needs a guard.
_tql_sqrt(x::Real) = x < 0 ? NaN : sqrt(x)
_tql_sqrt(x) = sqrt(x)
_tql_log(x::Real) = x < 0 ? NaN : log(x)
_tql_log(x) = log(x)
_tql_log10(x::Real) = x < 0 ? NaN : log10(x)
_tql_log10(x) = log10(x)
_tql_asin(x::Real) = abs(x) > 1 ? NaN : asin(x)
_tql_asin(x) = asin(x)
_tql_acos(x::Real) = abs(x) > 1 ? NaN : acos(x)
_tql_acos(x) = acos(x)

# casacore's `sign()` (`signFUNC`, `ExprFuncNode.cc:727-735`) is a
# manual `if(val>0) 1; if(val<0) -1; else 0` -- unlike Julia's own
# `sign`, a NaN input falls through BOTH comparisons (neither is true
# for NaN) to the `else 0` branch, so casacore's `sign(NaN) == 0.0`,
# not NaN. Live-verified: `sign(sqrt(-1.0)) == 0.0` in real casacore.
# Found while sweeping the surrounding functions for the same
# out-of-domain-argument shape as `pow`/`sqrt`/`log`/`asin`/`acos`
# above -- directly relevant now that those fixes let more NaNs flow
# into a downstream `sign()` call than before.
_tql_sign(x::Real) = isnan(x) ? zero(float(x)) : sign(x)
_tql_sign(x) = sign(x)

# casacore's `int()`/`integer()` (`intFUNC`, `ExprFuncNode.cc:552-553`,
# reached via `getInt`'s `argDataType_p == NTDouble` branch) is a raw
# C++ `Int64(double)` cast -- a NaN/out-of-range argument SATURATES
# rather than raising, live-verified against real casacore:
# `int(0.0/0.0) == 0`, `int(1.0/0.0) == typemax(Int64)`,
# `int(-1.0/0.0) == typemin(Int64)`. Julia's `trunc(Int, ...)` instead
# THROWS an `InexactError` for all three -- the exact same crash-risk
# shape as the other fixes above, and specifically triggered by them:
# `int(sqrt(-1.0))` now flows a `NaN` (Phase 184's own `_tql_sqrt` fix)
# straight into `int()`, which used to be an unreachable combination
# (the old `_tql_sqrt`-less `sqrt` would have already thrown first).
const _TQL_INT64_MAXF = Float64(typemax(Int64))
const _TQL_INT64_MINF = Float64(typemin(Int64))
_tql_int(x::Real) = isnan(x) ? Int64(0) :
    x >= _TQL_INT64_MAXF ? typemax(Int64) :
    x <= _TQL_INT64_MINF ? typemin(Int64) :
    trunc(Int64, x)

# casacore's `isFinite(Complex)`/`isFinite(DComplex)`
# (`casa/BasicSL/Complex.cc:123-129`) is
# `isFinite(re) || isFinite(im)` -- an OR, not the logically-expected
# AND ("finite" should mean BOTH parts finite; this looks like a bug
# in casacore itself, but it's real, reachable via TaQL's `isfinite()`,
# and live-verified: `isfinite(complex(0.0/0.0, 5.0)) == true` in real
# casacore). Julia's own `isfinite(::Complex)` uses AND -- exactly
# backwards from casacore for a mixed finite/non-finite value. Found
# while checking `isnan`/`isinf` for the same Complex-argument shape
# once `isfinite` turned out different: `isNaN`/`isInf` on `Complex`
# (`.cc:76-105`) are BOTH already `||` in casacore, and Julia's own
# `isnan`/`isinf` on `Complex` already agree (also `||`) -- so only
# `isfinite` needed a fix, not all three.
_tql_isfinite(x::Complex) = isfinite(real(x)) || isfinite(imag(x))
_tql_isfinite(x) = isfinite(x)

_running_avg(x, w) = (a = _require_array(x); _running_reduce(Statistics.mean, Float64, a, w))
_running_med(x, w) = (a = _require_array(x); _running_reduce(_tql_median_lo, Float64, a, w))
_running_min(x, w) = (a = _require_array(x); _running_reduce(minimum, eltype(a), a, w))
_running_max(x, w) = (a = _require_array(x); _running_reduce(maximum, eltype(a), a, w))
_running_var(x, w) = (a = _require_array(x);
                      _running_reduce(y -> Statistics.var(y; corrected = false), Float64, a, w))
_running_std(x, w) = (a = _require_array(x);
                      _running_reduce(y -> Statistics.std(y; corrected = false), Float64, a, w))
_running_sum(x, w) = (a = _require_array(x); _running_reduce(sum, eltype(a), a, w))

# `runningavdev`/`runningrms` (`runavdevFUNC`/`runrmsFUNC`,
# `TableParseFunc.cc:429,437`) -- two more missing siblings found the
# same way as Phase 185's `*samplevariance*` family, this time
# alongside the ALREADY-present scalar `avdev()`/`rms()` (`_tql_avdev`/
# `_tql_rms` above already work as-is when handed a plain window
# vector, no new formula needed). `runrmsFUNC` is `dtin=NTReal` (no
# complex overload, unlike `runavdevFUNC`'s `NTNumeric`) -- an
# irrelevant distinction here since `_tql_rms` already only special-
# cases nothing for Complex (it always uses `abs2`, correct for both).
# Live-verified: `runningavdev(1:8,[2])[3] == 1.2`,
# `runningrms(1:8,[2])[3] ≈ 3.3166247903554`, both matching a hand
# computation over the same 5-element window exactly.
_running_avdev(x, w) = (a = _require_array(x); _running_reduce(_tql_avdev, Float64, a, w))
_running_rms(x, w) = (a = _require_array(x); _running_reduce(_tql_rms, Float64, a, w))

# casacore's TableParseFunc.cc has TWO ddof variants for `running`/
# `boxed` variance/stddev -- `runningvariance`/`boxedvariance` (ddof=0,
# what `_running_var`/`_boxed_var` above already compute) AND
# `runningsamplevariance`/`boxedsamplevariance` (ddof=1), mirroring the
# already-implemented `gvariance`/`gsamplevariance` group-aggregate
# split. This package had NO `*sample*` sliding-window variant at all
# -- a real, missing-function gap found while checking the surrounding
# functions for a sibling of the same shape, not a wrong-value bug.
# Live-verified against real casacore: `runningsamplevariance(1:8,[2])`
# gives `2.5` where `runningvariance` gives `2.0` (population vs
# n-1-corrected over a 5-element window), confirming both are real,
# distinct, and reachable via TaQL.
#
# A window/bin of fewer than 2 elements is mathematically undefined for
# the n-1-corrected sample variance (unlike the population variant,
# which is well-defined -- 0 -- at n=1) -- and, live-verified, real
# casacore genuinely THROWS in that case ("Need at least 2 elements")
# rather than silently returning NaN the way `Statistics.var([x])`
# would. Reachable via a half-width/box-width of `0`/`1`, or a trailing
# partial box with exactly one element. Faithfully reproduced with a
# guard rather than a silent NaN, matching the "match casacore's real
# behavior exactly" discipline this whole sweep has applied in the
# OPPOSITE direction (making several other functions return NaN
# instead of throwing) -- here casacore is the one that throws.
_tql_need2(y, name) = length(y) >= 2 ? y : throw(ArgumentError(
    "TaQL-lite: $name needs at least 2 elements in the window/bin (matches casacore's own restriction)"))
_running_svar(x, w) = (a = _require_array(x);
                       _running_reduce(y -> Statistics.var(_tql_need2(y, "samplevariance")), Float64, a, w))
_running_sstd(x, w) = (a = _require_array(x);
                       _running_reduce(y -> Statistics.std(_tql_need2(y, "samplestddev")), Float64, a, w))

_boxed_avg(x, w) = (a = _require_array(x); _boxed_reduce(Statistics.mean, Float64, a, w))
_boxed_med(x, w) = (a = _require_array(x); _boxed_reduce(_tql_median_lo, Float64, a, w))
_boxed_min(x, w) = (a = _require_array(x); _boxed_reduce(minimum, eltype(a), a, w))
_boxed_max(x, w) = (a = _require_array(x); _boxed_reduce(maximum, eltype(a), a, w))
_boxed_var(x, w) = (a = _require_array(x);
                    _boxed_reduce(y -> Statistics.var(y; corrected = false), Float64, a, w))
_boxed_std(x, w) = (a = _require_array(x);
                    _boxed_reduce(y -> Statistics.std(y; corrected = false), Float64, a, w))
_boxed_sum(x, w) = (a = _require_array(x); _boxed_reduce(sum, eltype(a), a, w))
_boxed_avdev(x, w) = (a = _require_array(x); _boxed_reduce(_tql_avdev, Float64, a, w))
_boxed_rms(x, w) = (a = _require_array(x); _boxed_reduce(_tql_rms, Float64, a, w))
_boxed_svar(x, w) = (a = _require_array(x);
                     _boxed_reduce(y -> Statistics.var(_tql_need2(y, "samplevariance")), Float64, a, w))
_boxed_sstd(x, w) = (a = _require_array(x);
                     _boxed_reduce(y -> Statistics.std(_tql_need2(y, "samplestddev")), Float64, a, w))

# name => (callable-over-arg-values, allowed arg count).  `min`/`max` and
# `angdist` are arity-overloaded and handled in `_make_func`, not here.
const _TQL_FUNCS = Dict{String,Tuple{Base.Callable,UnitRange{Int}}}(
    # --- unary elementwise numeric ---
    "abs" => (_ew(abs), 1:1), "amplitude" => (_ew(abs), 1:1), "ampl" => (_ew(abs), 1:1),
    # `square`/`sqr` (`squareFUNC`) compute `x*x` -- for a complex `x`
    # that is ordinary complex multiplication (a complex result), NOT
    # the magnitude-squared `abs2` (real result) -- confirmed via
    # `ExprFuncNode.cc:658-661,889-892` (the Double/DComplex overloads)
    # and live-verified against real casacore: `square(3+4i) ==
    # -7+24i`, not `25`. `norm()` (`normFUNC`, `.cc:678-683`) IS the
    # abs2/magnitude-squared function -- a genuinely different real
    # casacore function this package's `sqr`/`square` were wrongly
    # aliased to.
    "sqrt" => (_ew(_tql_sqrt), 1:1), "square" => (_ew(x -> x^2), 1:1), "sqr" => (_ew(x -> x^2), 1:1),
    "cube" => (_ew(x -> x^3), 1:1),
    "exp" => (_ew(exp), 1:1), "log" => (_ew(_tql_log), 1:1), "ln" => (_ew(_tql_log), 1:1),
    "log10" => (_ew(_tql_log10), 1:1),
    "sin" => (_ew(sin), 1:1), "cos" => (_ew(cos), 1:1), "tan" => (_ew(tan), 1:1),
    "asin" => (_ew(_tql_asin), 1:1), "acos" => (_ew(_tql_acos), 1:1), "atan" => (_ew(atan), 1:1),
    "sinh" => (_ew(sinh), 1:1), "cosh" => (_ew(cosh), 1:1), "tanh" => (_ew(tanh), 1:1),
    "sign" => (_ew(_tql_sign), 1:1), "floor" => (_ew(floor), 1:1), "ceil" => (_ew(ceil), 1:1),
    "round" => (_ew(_tql_round), 1:1), "int" => (_ew(_tql_int), 1:1),
    "integer" => (_ew(_tql_int), 1:1),
    "real" => (_ew(real), 1:1), "imag" => (_ew(imag), 1:1),
    "arg" => (_ew(angle), 1:1), "phase" => (_ew(angle), 1:1),
    "conj" => (_ew(conj), 1:1), "norm" => (_ew(abs2), 1:1),
    "isnan" => (_ew(isnan), 1:1), "isinf" => (_ew(isinf), 1:1),
    "isfinite" => (_ew(_tql_isfinite), 1:1),
    # `nonfinite`/`isnonfinite` are a MeasurementSets-only extension
    # (not real casacore functions -- used by the Phase 59/60 masked-
    # array default-mask sugar), deliberately left on Julia's own
    # AND-based `isfinite` rather than the casacore-matching
    # `_tql_isfinite` above: for a masking predicate, "not finite"
    # should mean EITHER part is bad, which is what `!isfinite`
    # (AND then negated -> OR) already gives.
    "nonfinite" => (_ew(!isfinite), 1:1), "isnonfinite" => (_ew(!isfinite), 1:1),
    # --- binary elementwise ---
    "pow" => (_ew2(_tql_pow), 2:2), "atan2" => (_ew2((y, x) -> atan(y, x)), 2:2),
    "fmod" => (_ew2(rem), 2:2),
    # --- array-cell reductions ---
    "sum" => (_red(sum), 1:1), "product" => (_red(prod), 1:1),
    "mean" => (_red(Statistics.mean), 1:1), "avg" => (_red(Statistics.mean), 1:1),
    "median" => (_red(_tql_median), 1:1),
    "variance" => (_red(x -> Statistics.var(x; corrected=false)), 1:1),
    "stddev" => (_red(x -> Statistics.std(x; corrected=false)), 1:1),
    "rms" => (_tql_rms, 1:1), "avdev" => (_tql_avdev, 1:1),
    "any" => (_red(any), 1:1), "all" => (_red(all), 1:1),
    "ntrue" => (_red(x -> count(identity, x)), 1:1),
    "nfalse" => (_red(x -> count(!, x)), 1:1),
    "nelements" => (_tql_nelem, 1:1), "count" => (_tql_nelem, 1:1),
    "ndim" => (_tql_ndim, 1:1), "shape" => (_tql_shape, 1:1),
    # NOTE (found during Phase 186, not implemented): casacore also has
    # a whole "s"-suffixed axis-collapse family (`sums`, `means`,
    # `mins`, `maxs`, `products`, `medians`, `variances`, `stddevs`,
    # `avdevs`, `rmss`, `fractiles`, `anys`, `alls`, `ntrues`,
    # `nfalses` -- `arrsumsFUNC` etc., `TableParseFunc.cc`) that reduce
    # a multi-dimensional array cell along SPECIFIC axes (an `axes`
    # argument), leaving the other axes intact -- distinct from this
    # package's `gs*` masked group aggregates (Phase 62) despite the
    # similar naming. A real, larger feature gap, out of scope for a
    # same-day bug-fix sweep; flagged for a dedicated future phase.
    # --- running*/boxed* sliding-window array smoothing (Phase 108) ---
    "runningaverage" => (_running_avg, 2:2), "runningmean" => (_running_avg, 2:2),
    "runningmedian" => (_running_med, 2:2),
    "runningmin" => (_running_min, 2:2), "runningmax" => (_running_max, 2:2),
    "runningvariance" => (_running_var, 2:2), "runningstddev" => (_running_std, 2:2),
    "runningsamplevariance" => (_running_svar, 2:2),
    "runningsamplestddev" => (_running_sstd, 2:2),
    "runningsum" => (_running_sum, 2:2),
    "runningavdev" => (_running_avdev, 2:2), "runningrms" => (_running_rms, 2:2),
    "boxedaverage" => (_boxed_avg, 2:2), "boxedmean" => (_boxed_avg, 2:2),
    "boxedmedian" => (_boxed_med, 2:2),
    "boxedmin" => (_boxed_min, 2:2), "boxedmax" => (_boxed_max, 2:2),
    "boxedvariance" => (_boxed_var, 2:2), "boxedstddev" => (_boxed_std, 2:2),
    "boxedsamplevariance" => (_boxed_svar, 2:2), "boxedsamplestddev" => (_boxed_sstd, 2:2),
    "boxedsum" => (_boxed_sum, 2:2),
    "boxedavdev" => (_boxed_avdev, 2:2), "boxedrms" => (_boxed_rms, 2:2),
    # --- masked arrays ---
    "marray" => ((d, m) -> TQLMArray(collect(d), m isa AbstractArray ?
                     BitArray(m) : fill(Bool(m), size(d))), 2:2),
    "arraydata" => (_unwrap_marray, 1:1),
    "arraymask" => (_tql_arraymask, 1:1),
    # --- string ---
    "strlength" => (length, 1:1), "len" => (length, 1:1),
    "upcase" => (uppercase, 1:1), "upper" => (uppercase, 1:1), "toupper" => (uppercase, 1:1),
    "to_upper" => (uppercase, 1:1),
    "downcase" => (lowercase, 1:1), "lower" => (lowercase, 1:1), "tolower" => (lowercase, 1:1),
    "to_lower" => (lowercase, 1:1),
    "capitalize" => (_tql_capitalize, 1:1),
    "reversestring" => (reverse, 1:1), "sreverse" => (reverse, 1:1),
    "trim" => (_tql_trim, 1:1), "ltrim" => (_tql_ltrim, 1:1), "rtrim" => (_tql_rtrim, 1:1),
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
    "week" => (x -> _tql_yearweek(_tql_dt_of(x)), 1:1),
    "weekday" => (x -> Dates.dayofweek(_tql_dt_of(x)), 1:1),
    "dow" => (x -> Dates.dayofweek(_tql_dt_of(x)), 1:1),
    "cdate" => (x -> Dates.format(_tql_dt_of(x), "dd-uuu-yyyy"), 1:1),
    "ctime" => (x -> _tql_time_of_day_str(float(x)), 1:1),
    "cmonth" => (x -> Dates.format(_tql_dt_of(x), "uuu"), 1:1),
    "cdow" => (x -> Dates.format(_tql_dt_of(x), "eee"), 1:1),
    # `ctod`/`cdatetime` are the SAME real casacore function
    # (`TableParseFunc.cc:571`, both map to `ctodFUNC`) -- `YYYY/MM/DD`
    # (not `dd-Mon-yyyy` -- that's `cdate`'s DMY format, a different
    # `MVTime` mode) + `/` + the `HH:MM:SS.sss` time-of-day.
    "ctod" => (x -> Dates.format(_tql_dt_of(x), "yyyy/mm/dd") * "/" * _tql_time_of_day_str(float(x)), 1:1),
    "cdatetime" => (x -> Dates.format(_tql_dt_of(x), "yyyy/mm/dd") * "/" * _tql_time_of_day_str(float(x)), 1:1),
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
    "gmedian" => (_tql_median_lo, :scalar),
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

# Phase 110: `meas.<frame>('COLNAME', mjd[, x, y, z])` -- infer the
# source reference frame from column `COLNAME`'s own `MEASINFO`
# keyword (a fixed `Ref` only -- a `VarRefCol` column varies per row and
# needs `measure(t, col, row)` directly, not this single-frame form),
# instead of requiring an explicit `'SRC'` string literal. Disambiguated
# from the existing numeric `meas.<frame>(['SRC',] lon, lat, ...)` form
# at parse time: the first string literal is a COLNAME iff it is *not*
# a recognized frame name (`_MEAS_DIR_FRAMES`).
#
# Threading mirrors `mscal.*`/`mscal.stokes`: `_tqlrefs!` pushes both
# the plain column name (so `_tql_cols` loads its raw `[lon,lat]` cell
# data) and a `"::measframe::COLNAME"` sentinel; `_measframe_split` /
# `_measframe_cols` (called from `_tql_cols` / `_vtq_prepare!`) resolve
# the sentinel to the column's fixed source-frame name, once per table.
struct TQLMeasColDir <: TQLExpr
    target::DataType
    colname::String
    mjd::TQLExpr
    xyz::Union{Nothing,NTuple{3,TQLExpr}}
end

_measframe_key(colname::AbstractString) = "::measframe::" * colname

function _tqleval(e::TQLMeasColDir, cols, i)
    lonlat = cols[e.colname][i]
    sref = cols[_measframe_key(e.colname)][1]
    mjd = _tqleval(e.mjd, cols, i)
    xyz = e.xyz === nothing ? nothing :
          (_tqleval(e.xyz[1], cols, i), _tqleval(e.xyz[2], cols, i), _tqleval(e.xyz[3], cols, i))
    _meas_dir_convert(e.target, sref, lonlat[1], lonlat[2], mjd, xyz)
end
function _geval(e::TQLMeasColDir, cols, g)
    lonlat = cols[e.colname][g[1]]
    sref = cols[_measframe_key(e.colname)][1]
    mjd = _geval(e.mjd, cols, g)
    xyz = e.xyz === nothing ? nothing :
          (_geval(e.xyz[1], cols, g), _geval(e.xyz[2], cols, g), _geval(e.xyz[3], cols, g))
    _meas_dir_convert(e.target, sref, lonlat[1], lonlat[2], mjd, xyz)
end
function _tqlrefs!(seen, e::TQLMeasColDir)
    push!(seen, e.colname)
    push!(seen, _measframe_key(e.colname))
    _tqlrefs!(seen, e.mjd)
    e.xyz === nothing || foreach(x -> _tqlrefs!(seen, x), e.xyz)
end
_has_aggr(e::TQLMeasColDir) = _has_aggr(e.mjd) || (e.xyz !== nothing && any(_has_aggr, e.xyz))
_has_qty(e::TQLMeasColDir) = _has_qty(e.mjd) || (e.xyz !== nothing && any(_has_qty, e.xyz))

function _measframe_split(names)
    rest = String[]
    keys = String[]
    for n in names
        s = String(n)
        startswith(s, "::measframe::") ? push!(keys, s) : push!(rest, s)
    end
    return rest, keys
end

function _measframe_cols(t::AbstractTable, keys::AbstractVector{<:AbstractString})
    isempty(keys) && return Dict{String,AbstractVector}()
    d = Dict{String,AbstractVector}()
    for k in keys
        colname = k[(length("::measframe::") + 1):end]
        mi = measinfo(t, colname)
        mi === nothing && error(
            "meas.<frame>: column \"$colname\" has no MEASINFO keyword")
        mi.kind === :direction || error(
            "meas.<frame>: column \"$colname\" is a \"$(mi.kind)\" measure, not a direction")
        mi.fixedref === nothing && error(
            "meas.<frame>: column \"$colname\" has a per-row VarRefCol frame, not a fixed " *
            "Ref -- use `measure(t, \"$colname\", row)` directly instead")
        d[k] = Any[mi.fixedref]
    end
    return d
end

function _make_meas_func(fn::String, args::Vector{TQLExpr}, src::AbstractString)
    R = get(_MEAS_DIR_FRAMES, fn, nothing)
    if R !== nothing
        has_str1 = !isempty(args) && args[1] isa TQLLit && args[1].value isa AbstractString
        need_ep = _meas_dir_needs_epoch(R); need_p = _meas_dir_needs_pos(R)
        is_frame1 = has_str1 &&
            haskey(_MEAS_DIR_FRAMES, lowercase(strip(String(args[1].value))))
        if has_str1 && !is_frame1
            # Phase 110: meas.<frame>('COLNAME', mjd[, x, y, z]) -- the source
            # frame comes from COLNAME's own MEASINFO, not a literal
            colname = String(args[1].value)
            rest = args[2:end]
            wantc = 1 + (need_p ? 3 : 0)
            length(rest) == wantc || throw(ArgumentError(
                "TaQL-lite: meas.$fn('COLNAME', mjd" * (need_p ? ", x, y, z" : "") *
                ") in \"$src\""))
            xyz = need_p ? (rest[2], rest[3], rest[4]) : nothing
            return TQLMeasColDir(R, colname, rest[1], xyz)
        end
        sref = is_frame1 ? String(args[1].value) : "J2000"
        rest = is_frame1 ? args[2:end] : args
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
        # Phase 163: real casacore's own function is registered as
        # `derivedmscal.UVWJ2000` (`derivedmscal/DerivedMC/Register.cc`,
        # matched case-insensitively via TaQL's `mscal` synonym for
        # `derivedmscal`, `tables/TaQL/TaQLStyle.cc`'s `defineSynonym`)
        # -- no underscore. This package spelled it `uvw_j2000`
        # (Phase 79) before this was checked against source; keep that
        # name (used throughout this codebase's tests/docs/CHANGELOG)
        # as the canonical internal one and accept the real, underscore-
        # free spelling as an alias so a query written against real
        # casacore's own `mscal.uvwj2000()` also works here.
        fn == "uvwj2000" && (fn = "uvw_j2000")
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
        # Phase 136: casacore's own `mscal.delay[1|2]()` defaults to
        # FIELD.DELAY_DIR, not PHASE_DIR (`UDFMSCal::UDFMSCal(ColType,Int)`
        # calls `itsEngine.setDirColName("DELAY_DIR")` specifically for
        # the DELAY type -- every other direction function defaults to
        # PHASE_DIR via `MSCalEngine`'s own field initializer). An
        # explicit direction argument still overrides it, as for ha/azel/…
        n == 0 && startswith(fn, "delay") && return TQLMScal(fn, "DELAY_DIR")
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
        base = name == "min" ? _tql_min2 : _tql_max2
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

