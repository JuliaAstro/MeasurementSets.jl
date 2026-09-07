# `mscal.*` derived-MS functions (Phase 77) -- the astronomy-value subset
# of casacore's `derivedmscal` UDF library, in the TaQL-lite grammar.
#
# A `mscal.<fn>()` call takes no arguments; its per-MAIN-row value is
# computed from `TIME` + the `ANTENNA` / `FIELD` subtables via the
# Measures engine (`measure` / `measconvert` -- needs `import SOFA`).
# The tokenizer already lexes `mscal.ha1` as one identifier (Phase 63).
#
# Threading: `_tqlrefs!(::TQLMScal)` puts `"mscal.<fn>"` into the
# `needed` set; `_tql_cols` (query.jl) and `_vtq_prepare!`
# (datamanagers/virtualtaql.jl) split those out and call
# `_mscal_columns(t, fns)`, which returns a `Dict` of precomputed
# per-row vectors keyed `"mscal.<fn>"`.  `_tqleval` / `_geval` then just
# index that vector.

struct TQLMScal <: TQLExpr
    fn::String        # "ha"/"ha1"/"ha2" "hadec*" "azel*" "az*"/"el*"
                      # "pa*" "last*" "itrf" "uvw_j2000" "delay"
end

_mscal_key(fn::AbstractString) = "mscal." * fn

const _MSCAL_FUNCS = Set([
    "ha", "ha1", "ha2", "hadec", "hadec1", "hadec2",
    "azel", "azel1", "azel2", "az1", "az2", "el1", "el2",
    "pa", "pa1", "pa2", "last", "last1", "last2",
    "itrf", "uvw_j2000", "delay"])

_tqleval(e::TQLMScal, cols, i) = cols[_mscal_key(e.fn)][i]
_geval(e::TQLMScal, cols, g)   = cols[_mscal_key(e.fn)][g[1]]
_tqlrefs!(seen, e::TQLMScal)   = push!(seen, _mscal_key(e.fn))
_has_aggr(::TQLMScal)          = false

# split a name set into plain column names and mscal function names
# (the "mscal." prefix stripped off the latter).
function _mscal_split(names)
    plain = String[]
    mscal = String[]
    for n in names
        s = String(n)
        startswith(s, "mscal.") ? push!(mscal, s[7:end]) : push!(plain, s)
    end
    return plain, mscal
end

# casacore MVDirection::positionAngle(other): the parallactic angle is
# the position angle of the source (az/el) relative to the celestial
# pole (az/el).
function _position_angle(azel::NTuple{2}, pole::NTuple{2})
    longDiff = azel[1] - pole[1]
    slat1 = sin(azel[2])
    slat2 = sin(pole[2])
    clat2 = sqrt(abs(1.0 - slat2 * slat2))
    s1 = -clat2 * sin(longDiff)
    c1 = sqrt(abs(1.0 - slat1 * slat1)) * slat2 - slat1 * clat2 * cos(longDiff)
    (s1 == 0.0 && c1 == 0.0) ? 0.0 : atan(s1, c1)
end

_pvec(p) = (p.x, p.y, p.z)

"""
    _mscal_columns(t, fns) -> Dict{String,AbstractVector}

Compute the per-row vectors for the requested `mscal.<fn>` functions
(names without the `mscal.` prefix) over MAIN table `t`.
"""
function _mscal_columns(t::AbstractTable, fns::AbstractVector{<:AbstractString})
    isempty(fns) && return Dict{String,AbstractVector}()
    Base.get_extension(@__MODULE__, :SOFAExt) === nothing && error(
        "mscal.* functions need SOFA.jl — run `import SOFA`")

    subs = Dict(subtables(t))
    (haskey(subs, "ANTENNA") && haskey(subs, "FIELD")) || error(
        "mscal.* needs an MS MAIN table with ANTENNA and FIELD subtables")
    cn = Set(columnnames(t))
    all(c -> c in cn, ("ANTENNA1", "FIELD_ID", "TIME")) || error(
        "mscal.* needs a MAIN table with ANTENNA1, FIELD_ID and TIME columns")
    need2 = any(f -> endswith(f, "2") || f == "delay", fns)
    (need2 && !("ANTENNA2" in cn)) && error(
        "mscal.* needs an ANTENNA2 column for a `*2` / delay function")

    n = nrow(t)
    a1 = Int.(column(t, "ANTENNA1")[:])
    a2 = need2 ? Int.(column(t, "ANTENNA2")[:]) : Int[]
    fid = Int.(column(t, "FIELD_ID")[:])
    tsec = Float64.(column(t, "TIME")[:])
    epochs = measure(t, "TIME")                       # Vector{MEpoch}
    need_uvw = "uvw_j2000" in fns
    uvw = need_uvw ? column(t, "UVW")[:] : nothing

    ant = readtable(subs["ANTENNA"])
    antpos = measure(ant, "POSITION")                 # Vector{MPosition{ITRF}}
    fld = readtable(subs["FIELD"])
    fdir = Dict{Int,Any}()                            # field id -> J2000 direction

    _antid(f, i) = endswith(f, "2") ? a2[i] : endswith(f, "1") ? a1[i] : 0

    _fielddir(fi, i) = get!(fdir, fi) do
        measconvert(measure(fld, "PHASE_DIR", fi + 1), J2000;
                    frame = MeasFrame(epoch = epochs[i]))
    end

    # memo: (antenna id, field id, TIME seconds) -> frame-converted values
    memo = Dict{Tuple{Int,Int,Float64},NamedTuple}()
    function _cache(antid::Int, fi::Int, i::Int)
        get!(memo, (antid, fi, tsec[i])) do
            dj = _fielddir(fi, i)
            fr = MeasFrame(epoch = epochs[i], position = antpos[antid + 1], direction = dj)
            hd = measconvert(dj, HADEC; frame = fr)
            ae = measconvert(dj, AZEL; frame = fr)
            it = measconvert(dj, ITRF; frame = fr)
            # casacore MSCalEngine: the pole is HADEC(0, π/2) -> AZEL
            pl = measconvert(MDirection{HADEC}(0.0, pi / 2), AZEL; frame = fr)
            (; hadec = (hd.lon, hd.lat), azel = (ae.lon, ae.lat),
               pole = (pl.lon, pl.lat), last = _lst(fr),
               itrf_ll = (it.lon, it.lat), itrf_xyz = _dir_xyz(it))
        end
    end

    out = Dict{String,AbstractVector}()
    for f in fns
        if f == "delay"
            v = Vector{Float64}(undef, n)
            for i in 1:n
                x = _cache(0, fid[i], i).itrf_xyz
                d = _pvec(antpos[a1[i] + 1]) .- _pvec(antpos[a2[i] + 1])
                v[i] = (x[1]*d[1] + x[2]*d[2] + x[3]*d[3]) / C_LIGHT
            end
            out[_mscal_key(f)] = v
        elseif f == "uvw_j2000"
            # The ITRF->J2000 uvw transform is a linear map (pole rotation
            # + baseline rotation, all rotations) that depends only on the
            # frame -- i.e. on (antenna, field, TIME). Memo the 3x3 as its
            # three result columns (one measconvert per basis vector per
            # key) and apply it to each row's stored UVW.
            umemo = Dict{Tuple{Int,Int,Float64},NTuple{3,NTuple{3,Float64}}}()
            v = Vector{Vector{Float64}}(undef, n)
            for i in 1:n
                cols3 = get!(umemo, (a1[i], fid[i], tsec[i])) do
                    dj = _fielddir(fid[i], i)
                    fr = MeasFrame(epoch = epochs[i],
                                   position = antpos[a1[i] + 1], direction = dj)
                    map(((x, y, z),) -> begin
                            w = measconvert(MuvW{ITRF}(x, y, z), J2000; frame = fr)
                            (w.u, w.v, w.w)
                        end,
                        ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)))
                end
                u = uvw[i]
                v[i] = [cols3[1][k] * u[1] + cols3[2][k] * u[2] + cols3[3][k] * u[3]
                        for k in 1:3]
            end
            out[_mscal_key(f)] = v
        elseif startswith(f, "hadec")
            out[_mscal_key(f)] = [collect(_cache(_antid(f, i), fid[i], i).hadec) for i in 1:n]
        elseif startswith(f, "azel")
            out[_mscal_key(f)] = [collect(_cache(_antid(f, i), fid[i], i).azel) for i in 1:n]
        elseif f == "itrf"
            out[_mscal_key(f)] = [collect(_cache(0, fid[i], i).itrf_ll) for i in 1:n]
        elseif startswith(f, "ha")
            out[_mscal_key(f)] = Float64[_cache(_antid(f, i), fid[i], i).hadec[1] for i in 1:n]
        elseif startswith(f, "az")
            out[_mscal_key(f)] = Float64[_cache(_antid(f, i), fid[i], i).azel[1] for i in 1:n]
        elseif startswith(f, "el")
            out[_mscal_key(f)] = Float64[_cache(_antid(f, i), fid[i], i).azel[2] for i in 1:n]
        elseif startswith(f, "last")
            out[_mscal_key(f)] = Float64[mod2pi(_cache(_antid(f, i), fid[i], i).last) for i in 1:n]
        elseif startswith(f, "pa")
            out[_mscal_key(f)] = Float64[
                (c = _cache(_antid(f, i), fid[i], i); _position_angle(c.azel, c.pole))
                for i in 1:n]
        else
            error("mscal.* internal: unhandled function \"$f\"")
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Phase 78: `mscal.stokes(col [, 'types'] [, rescale])` -- polarization /
# correlation-basis conversion of a DATA / FLAG / WEIGHT array cell.
#
# A port of casacore's `StokesConverter`: the per-cell result is a matrix
# multiply `out[o,ch] = Sum_j conv[o,j] * in[j,ch]` (Complex data), an
# any-of-contributing test (Bool flags), or the weight-propagation formula
# (Float weights).  The conversion matrix is keyed by the input basis
# (from `POLARIZATION.CORR_TYPE` row 1) and the requested output types.
#
# Threading mirrors `mscal.*`: `_tqlrefs!(::TQLStokes)` pushes a sentinel
# name `"::stokes::<types>[:r]"` into the `needed` set; `_tql_cols` /
# `_vtq_prepare!` split those with `_stokes_split` and merge the result of
# `_stokes_setups(t, keys)` (a `Dict` of length-1 vectors holding the
# `StokesSetup`).  `_tqleval` / `_geval` then apply it to the arg's value.

struct TQLStokes <: TQLExpr
    arg::TQLExpr
    outtypes::Vector{Int}      # 1..12 (I,Q,U,V / RR,RL,LR,LL / XX,XY,YX,YY)
    rescale::Bool
end

_stokes_key(e::TQLStokes) =
    "::stokes::" * join(e.outtypes, ",") * (e.rescale ? ":r" : "")

_tqleval(e::TQLStokes, cols, i) =
    _stokes_convert(cols[_stokes_key(e)][1], _tqleval(e.arg, cols, i))
_geval(e::TQLStokes, cols, g) =
    _stokes_convert(cols[_stokes_key(e)][1], _geval(e.arg, cols, g))
_tqlrefs!(seen, e::TQLStokes) = (_tqlrefs!(seen, e.arg); push!(seen, _stokes_key(e)))
_has_aggr(e::TQLStokes) = _has_aggr(e.arg)
_has_qty(e::TQLStokes) = _has_qty(e.arg)

const _STOKES_NAMES = Dict{String,Int}(
    "I" => 1, "Q" => 2, "U" => 3, "V" => 4,
    "RR" => 5, "RL" => 6, "LR" => 7, "LL" => 8,
    "XX" => 9, "XY" => 10, "YX" => 11, "YY" => 12,
    "RX" => 13, "RY" => 14, "LX" => 15, "LY" => 16,
    "XR" => 17, "XL" => 18, "YR" => 19, "YL" => 20)

const _STOKES_ALIASES = Dict{String,String}(
    "IQUV" => "I,Q,U,V", "STOKES" => "I,Q,U,V",
    "CIRC" => "RR,RL,LR,LL", "CIRCULAR" => "RR,RL,LR,LL",
    "LIN" => "XX,XY,YX,YY", "LINEAR" => "XX,XY,YX,YY")

function _parse_stokes_types(s::AbstractString)
    up = uppercase(strip(s))
    up = get(_STOKES_ALIASES, up, up)
    out = Int[]
    for tok in split(up, ',')
        t = strip(tok)
        isempty(t) && continue
        haskey(_STOKES_NAMES, t) || throw(ArgumentError(
            "mscal.stokes: unknown polarization type \"$t\""))
        code = _STOKES_NAMES[t]
        code <= 12 || throw(ArgumentError(
            "mscal.stokes: output type \"$t\" (mixed-hand RX..YL) is not supported"))
        push!(out, code)
    end
    isempty(out) && throw(ArgumentError("mscal.stokes: empty polarization type list"))
    return out
end

function _stokes_str_arg(a::TQLExpr, src::AbstractString)
    (a isa TQLLit && a.value isa AbstractString) || throw(ArgumentError(
        "TaQL-lite: mscal.stokes type argument must be a string literal in \"$src\""))
    return a.value
end

function _stokes_bool_arg(a::TQLExpr, src::AbstractString)
    (a isa TQLLit && a.value isa Bool) || throw(ArgumentError(
        "TaQL-lite: mscal.stokes rescale argument must be a boolean literal in \"$src\""))
    return a.value
end

# --- the conversion matrices (hardcoded 4x4, ComplexF64) -------------------
# `_STOKES_BASE[(from, to)]` is M with `to_vec = M * from_vec`, indexed
# `M[canon(to_code), canon(from_code)]` where canon = (code-1) % 4 + 1.

function _m4mul(A, B)
    C = zeros(ComplexF64, 4, 4)
    for i in 1:4, j in 1:4
        s = zero(ComplexF64)
        for k in 1:4
            s += A[i, k] * B[k, j]
        end
        C[i, j] = s
    end
    return C
end

const _M_LIN_FROM_IQUV = ComplexF64[.5 .5 0 0; 0 0 .5 .5im; 0 0 .5 -.5im; .5 -.5 0 0]
const _M_IQUV_FROM_LIN = ComplexF64[1 0 0 1; 1 0 0 -1; 0 1 1 0; 0 -1im 1im 0]
const _M_CIRC_FROM_IQUV = ComplexF64[.5 0 0 .5; 0 .5 .5im 0; 0 .5 -.5im 0; .5 0 0 -.5]
const _M_IQUV_FROM_CIRC = ComplexF64[1 0 0 1; 0 1 1 0; 0 -1im 1im 0; 1 0 0 -1]
const _M_I4 = ComplexF64[1 0 0 0; 0 1 0 0; 0 0 1 0; 0 0 0 1]

const _STOKES_BASE = Dict{Tuple{Symbol,Symbol},Matrix{ComplexF64}}(
    (:iquv, :iquv) => _M_I4, (:circ, :circ) => _M_I4, (:lin, :lin) => _M_I4,
    (:iquv, :lin) => _M_LIN_FROM_IQUV, (:lin, :iquv) => _M_IQUV_FROM_LIN,
    (:iquv, :circ) => _M_CIRC_FROM_IQUV, (:circ, :iquv) => _M_IQUV_FROM_CIRC,
    (:lin, :circ) => _m4mul(_M_CIRC_FROM_IQUV, _M_IQUV_FROM_LIN),
    (:circ, :lin) => _m4mul(_M_LIN_FROM_IQUV, _M_IQUV_FROM_CIRC))

_stokes_canon(t::Int) = (t - 1) % 4 + 1

function _stokes_frame(codes)
    fr = nothing
    for c in codes
        f = 1 <= c <= 4 ? :iquv : 5 <= c <= 8 ? :circ : 9 <= c <= 12 ? :lin :
            error("mscal.stokes: correlation code $c (mixed-hand RX..YL / >20) is not supported")
        fr === nothing ? (fr = f) : (fr === f ||
            error("mscal.stokes: input correlations span more than one polarization frame"))
    end
    fr === nothing && error("mscal.stokes: empty correlation list")
    return fr
end

_stokes_factor(t::Int, rescale::Bool) =
    !rescale ? 1.0 : (5 <= t <= 12 ? 0.5 : 13 <= t <= 20 ? sqrt(2) / 4 : 1.0)

struct StokesSetup
    cmat::Matrix{ComplexF64}   # nOut x nIn
    fmat::BitMatrix            # cmat .!= 0
    wmat::Matrix{Float64}      # abs.(cmat)
end

function _stokes_setup(intypes::Vector{Int}, outtypes::Vector{Int}, rescale::Bool)
    inf = _stokes_frame(intypes)
    nO, nI = length(outtypes), length(intypes)
    cmat = zeros(ComplexF64, nO, nI)
    for o in 1:nO
        base = _STOKES_BASE[(inf, _stokes_frame((outtypes[o],)))]
        for j in 1:nI
            cmat[o, j] = base[_stokes_canon(outtypes[o]), _stokes_canon(intypes[j])] *
                         _stokes_factor(intypes[j], rescale) /
                         _stokes_factor(outtypes[o], rescale)
        end
    end
    return StokesSetup(cmat, cmat .!= 0, abs.(cmat))
end

# --- applying a setup to one array cell -----------------------------------

function _stokes_convert(s::StokesSetup, x::AbstractMatrix{<:Complex})
    nI, nch = size(x)
    nI == size(s.cmat, 2) || throw(ArgumentError(
        "mscal.stokes: cell has $nI correlations, POLARIZATION.CORR_TYPE has $(size(s.cmat, 2))"))
    out = zeros(ComplexF64, size(s.cmat, 1), nch)
    @inbounds for ch in 1:nch, o in axes(out, 1), j in 1:nI
        out[o, ch] += s.cmat[o, j] * x[j, ch]
    end
    return out
end

function _stokes_convert(s::StokesSetup, x::AbstractMatrix{Bool})
    nI, nch = size(x)
    nI == size(s.cmat, 2) || throw(ArgumentError(
        "mscal.stokes: FLAG cell has $nI correlations, expected $(size(s.cmat, 2))"))
    out = falses(size(s.cmat, 1), nch)
    @inbounds for ch in 1:nch, o in axes(out, 1)
        out[o, ch] = any(j -> s.fmat[o, j] && x[j, ch], 1:nI)
    end
    return out
end

function _stokes_convert(s::StokesSetup, x::AbstractMatrix{<:Real})
    nI, nch = size(x)
    nI == size(s.cmat, 2) || throw(ArgumentError(
        "mscal.stokes: WEIGHT cell has $nI correlations, expected $(size(s.cmat, 2))"))
    out = zeros(Float64, size(s.cmat, 1), nch)
    @inbounds for ch in 1:nch, o in axes(out, 1)
        acc = 0.0
        for j in 1:nI
            w = s.wmat[o, j]
            (w == 0 || x[j, ch] == 0) && continue
            acc += w * w / x[j, ch]
        end
        out[o, ch] = acc == 0 ? 0.0 : 1.0 / acc
    end
    return out
end

# WEIGHT / SIGMA cell is a bare `(ncorr,)` vector -> one channel, drop it.
_stokes_convert(s::StokesSetup, x::AbstractVector) =
    vec(_stokes_convert(s, reshape(x, :, 1)))

# --- name-set threading ---------------------------------------------------

function _stokes_split(names)
    rest = String[]
    keys = String[]
    for n in names
        s = String(n)
        startswith(s, "::stokes::") ? push!(keys, s) : push!(rest, s)
    end
    return rest, keys
end

function _stokes_setups(t::AbstractTable, keys::AbstractVector{<:AbstractString})
    isempty(keys) && return Dict{String,AbstractVector}()
    subs = Dict(subtables(t))
    haskey(subs, "POLARIZATION") || error(
        "mscal.stokes: needs an MS with a POLARIZATION subtable")
    pol = readtable(subs["POLARIZATION"])
    nrow(pol) >= 1 || error("mscal.stokes: POLARIZATION subtable is empty")
    intypes = Int.(collect(column(pol, "CORR_TYPE")[1]))
    d = Dict{String,AbstractVector}()
    for k in keys
        body = k[length("::stokes::")+1:end]
        rescale = endswith(body, ":r")
        rescale && (body = body[1:end-2])
        outtypes = parse.(Int, split(body, ','))
        d[k] = Any[_stokes_setup(intypes, outtypes, rescale)]
    end
    return d
end

# ---------------------------------------------------------------------------
# Phase 80: `mscal.<sel>('spec')` MSSelection-lite row-selection functions
# -- casacore's `derivedmscal` selection UDFs (BASELINE / FIELD / SPW /
# SCAN / STATE / ARRAY / OBS), each returning a per-MAIN-row `Bool`.
#
# `spec` is a comma-separated list of terms (a row passes if it matches
# ANY term); a `!`-prefixed term is subtracted. Terms:
#   N            integer id
#   N~M          inclusive id range
#   >N <N >=N <=N open id range
#   name         exact match against the type's NAME column
#   name*        glob (`* ? [...]`) against NAME
#   /regex/      regex against NAME
# `mscal.baseline` additionally takes `L & R` / `L && R` (baseline
# between two antenna sets; `&` excludes autocorrelations, `&&` keeps
# them) and a whole-spec `!` negation.
#
# Threading mirrors `mscal.*`: a `TQLMSSel` node, a `"::mssel::<fn>::<spec>"`
# sentinel split by `_mssel_split` in `_tql_cols` / `_vtq_prepare!`.

struct TQLMSSel <: TQLExpr
    fn::String        # "baseline"/"field"/"spw"/"scan"/"state"/"array"/"obs"
    spec::String
end

_mssel_key(e::TQLMSSel) = "::mssel::" * e.fn * "::" * e.spec

_tqleval(e::TQLMSSel, cols, i) = cols[_mssel_key(e)][i]
_geval(e::TQLMSSel, cols, g)   = cols[_mssel_key(e)][g[1]]
_tqlrefs!(seen, e::TQLMSSel)   = push!(seen, _mssel_key(e))
_has_aggr(::TQLMSSel)          = false
_has_qty(::TQLMSSel)           = false

const _MSSEL_FUNCS = Set(["baseline", "field", "spw", "scan", "state", "array", "obs"])

function _mssel_str_arg(a::TQLExpr, src::AbstractString)
    (a isa TQLLit && a.value isa AbstractString) || throw(ArgumentError(
        "TaQL-lite: mscal selection spec must be a string literal in \"$src\""))
    return a.value
end

function _mssel_split(names)
    rest = String[]
    keys = String[]
    for n in names
        s = String(n)
        startswith(s, "::mssel::") ? push!(keys, s) : push!(rest, s)
    end
    return rest, keys
end

# top-level comma split, not breaking inside `/.../` or `[...]`
function _mssel_commas(spec::AbstractString)
    out = String[]
    buf = IOBuffer()
    inre = false
    depth = 0
    for c in spec
        if c == '/' && depth == 0
            inre = !inre; print(buf, c)
        elseif c == '[' && !inre
            depth += 1; print(buf, c)
        elseif c == ']' && !inre
            depth = max(0, depth - 1); print(buf, c)
        elseif c == ',' && !inre && depth == 0
            push!(out, String(take!(buf)))
        else
            print(buf, c)
        end
    end
    push!(out, String(take!(buf)))
    return out
end

_mssel_names_to_ids(namevec) = begin
    d = Dict{String,Vector{Int}}()
    for (i, nm) in enumerate(namevec)
        push!(get!(d, String(nm), Int[]), i - 1)   # 0-based ids
    end
    d
end

function _mssel_resolve(term::AbstractString, allids, n2i::AbstractDict)
    m = match(r"^(\d+)\s*~\s*(\d+)$", term)
    m !== nothing && return Set{Int}(parse(Int, m[1]):parse(Int, m[2]))
    m = match(r"^(>=|<=|>|<)\s*(-?\d+)$", term)
    if m !== nothing
        v = parse(Int, m[2]); op = m[1]
        return Set{Int}(i for i in allids if op == ">" ? i > v :
                        op == ">=" ? i >= v : op == "<" ? i < v : i <= v)
    end
    occursin(r"^-?\d+$", term) && return Set{Int}([parse(Int, term)])
    if length(term) >= 2 && startswith(term, "/") && endswith(term, "/")
        re = Regex(term[2:end-1])
        return Set{Int}(reduce(vcat, (v for (k, v) in n2i if occursin(re, k)); init = Int[]))
    end
    if occursin(r"[*?\[\]]", term)
        re = _glob_regex(term, false)
        return Set{Int}(reduce(vcat, (v for (k, v) in n2i if occursin(re, k)); init = Int[]))
    end
    return haskey(n2i, term) ? Set{Int}(n2i[term]) : Set{Int}()
end

function _mssel_idset(spec::AbstractString, allids, n2i::AbstractDict)
    pos = Set{Int}(); neg = Set{Int}(); anypos = false
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        isneg = startswith(term, "!")
        isneg && (term = strip(term[2:end]))
        s = _mssel_resolve(term, allids, n2i)
        isneg ? union!(neg, s) : (union!(pos, s); anypos = true)
    end
    base = anypos ? pos : Set{Int}(allids)
    return setdiff(base, neg)
end

function _mssel_baseline_pred(spec::AbstractString, n2i::AbstractDict, allants)
    spec = strip(spec)
    neg = startswith(spec, "!")
    neg && (spec = strip(spec[2:end]))
    pred = if occursin("&&", spec)
        l, r = split(spec, "&&"; limit = 2)
        SL = _mssel_idset(strip(l), allants, n2i)
        SR = isempty(strip(r)) ? SL : _mssel_idset(strip(r), allants, n2i)
        (a1, a2) -> (a1 in SL && a2 in SR) || (a1 in SR && a2 in SL)
    elseif occursin("&", spec)
        l, r = split(spec, "&"; limit = 2)
        SL = _mssel_idset(strip(l), allants, n2i)
        SR = isempty(strip(r)) ? SL : _mssel_idset(strip(r), allants, n2i)
        (a1, a2) -> a1 != a2 && ((a1 in SL && a2 in SR) || (a1 in SR && a2 in SL))
    else
        S = _mssel_idset(spec, allants, n2i)
        (a1, a2) -> a1 in S || a2 in S
    end
    return neg ? (a1, a2) -> !pred(a1, a2) : pred
end

# resolve one `mscal.<fn>('spec')` to a per-row Bool vector
function _mssel_one(t::AbstractTable, fn::AbstractString, spec::AbstractString,
                    cn::AbstractSet, subs::AbstractDict, n::Integer)
    _need(c) = c in cn || error("mscal.$fn: MAIN table has no $c column")
    _sub(name, col) = haskey(subs, name) ?
        _mssel_names_to_ids(column(readtable(subs[name]), col)[:]) :
        Dict{String,Vector{Int}}()

    if fn == "baseline"
        _need("ANTENNA1")
        haskey(subs, "ANTENNA") || error("mscal.baseline: no ANTENNA subtable")
        a1 = Int.(column(t, "ANTENNA1")[:])
        a2 = "ANTENNA2" in cn ? Int.(column(t, "ANTENNA2")[:]) : a1
        n2i = _mssel_names_to_ids(column(readtable(subs["ANTENNA"]), "NAME")[:])
        pred = _mssel_baseline_pred(spec, n2i, 0:(length(column(readtable(subs["ANTENNA"]), "NAME")) - 1))
        return Bool[pred(a1[i], a2[i]) for i in 1:n]
    elseif fn == "field"
        _need("FIELD_ID")
        fid = Int.(column(t, "FIELD_ID")[:])
        nf = haskey(subs, "FIELD") ? nrow(readtable(subs["FIELD"])) : maximum(fid; init = -1) + 1
        S = _mssel_idset(spec, 0:(nf - 1), _sub("FIELD", "NAME"))
        return Bool[f in S for f in fid]
    elseif fn == "spw"
        _need("DATA_DESC_ID")
        haskey(subs, "DATA_DESCRIPTION") || error("mscal.spw: no DATA_DESCRIPTION subtable")
        ddid = Int.(column(t, "DATA_DESC_ID")[:])
        dd2spw = Int.(column(readtable(subs["DATA_DESCRIPTION"]), "SPECTRAL_WINDOW_ID")[:])
        rowspw = Int[dd2spw[d + 1] for d in ddid]
        nspw = haskey(subs, "SPECTRAL_WINDOW") ? nrow(readtable(subs["SPECTRAL_WINDOW"])) :
               maximum(rowspw; init = -1) + 1
        n2i = (haskey(subs, "SPECTRAL_WINDOW") &&
               "NAME" in Set(columnnames(readtable(subs["SPECTRAL_WINDOW"])))) ?
              _mssel_names_to_ids(column(readtable(subs["SPECTRAL_WINDOW"]), "NAME")[:]) :
              Dict{String,Vector{Int}}()
        S = _mssel_idset(spec, 0:(nspw - 1), n2i)
        return Bool[s in S for s in rowspw]
    else
        col = fn == "scan" ? "SCAN_NUMBER" : fn == "state" ? "STATE_ID" :
              fn == "array" ? "ARRAY_ID" : "OBSERVATION_ID"
        _need(col)
        ids = Int.(column(t, col)[:])
        n2i = fn == "state" ?
              (haskey(subs, "STATE") &&
               "OBS_MODE" in Set(columnnames(readtable(subs["STATE"]))) ?
               _mssel_names_to_ids(column(readtable(subs["STATE"]), "OBS_MODE")[:]) :
               Dict{String,Vector{Int}}()) :
              Dict{String,Vector{Int}}()
        S = _mssel_idset(spec, sort(unique(ids)), n2i)
        return Bool[x in S for x in ids]
    end
end

function _mssel_columns(t::AbstractTable, keys::AbstractVector{<:AbstractString})
    isempty(keys) && return Dict{String,AbstractVector}()
    cn = Set(columnnames(t))
    subs = Dict(subtables(t))
    n = nrow(t)
    d = Dict{String,AbstractVector}()
    for k in keys
        parts = split(k, "::"; limit = 4)          # "", "mssel", fn, spec
        fn, spec = parts[3], parts[4]
        d[k] = _mssel_one(t, fn, spec, cn, subs, n)
    end
    return d
end
