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
    dir::String       # "" (use FIELD.PHASE_DIR) | a body name ("SUN") |
                      # a FIELD direction column ("DELAY_DIR") | "[ra,dec]"
end
TQLMScal(fn::AbstractString) = TQLMScal(String(fn), "")

_mscal_key(fn::AbstractString) = "mscal." * fn
_mscal_key(e::TQLMScal) = "mscal." * e.fn * (isempty(e.dir) ? "" : "::" * e.dir)

# direction functions that accept an optional direction argument
const _MSCAL_DIR_FUNCS = Set([
    "ha", "ha1", "ha2", "hadec", "hadec1", "hadec2",
    "azel", "azel1", "azel2", "az1", "az2", "el1", "el2",
    "pa", "pa1", "pa2", "itrf", "delay"])

const _MSCAL_FUNCS = Set([
    "ha", "ha1", "ha2", "hadec", "hadec1", "hadec2",
    "azel", "azel1", "azel2", "az1", "az2", "el1", "el2",
    "pa", "pa1", "pa2", "last", "last1", "last2",
    "itrf", "uvw_j2000", "delay"])

_tqleval(e::TQLMScal, cols, i) = cols[_mscal_key(e)][i]
_geval(e::TQLMScal, cols, g)   = cols[_mscal_key(e)][g[1]]
_tqlrefs!(seen, e::TQLMScal)   = push!(seen, _mscal_key(e))
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
    bases = [first(_mscal_split_dir(f)) for f in fns]
    need2 = any(f -> endswith(f, "2") || f == "delay", bases)
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

    # array-centre position for a suffix-less `mscal.ha()`/`azel()`/… --
    # OBSERVATION.TELESCOPE_NAME -> the bundled Observatories table, else
    # a one-time warn + antenna 0.
    obsid = "OBSERVATION_ID" in cn ? Int.(column(t, "OBSERVATION_ID")[:]) :
            zeros(Int, n)
    telname = haskey(subs, "OBSERVATION") ?
              String.(column(readtable(subs["OBSERVATION"]), "TELESCOPE_NAME")[:]) :
              String[]
    _warned_obs = Ref(false)
    _centrepos(oi) = begin
        p = (1 <= oi + 1 <= length(telname)) ? observatory(telname[oi + 1]) : nothing
        if p === nothing
            _warned_obs[] || (@warn "mscal.*: no Observatories entry for " *
                "telescope $(get(telname, oi + 1, "?")); using antenna 0 as the array centre";
                _warned_obs[] = true)
            antpos[1]
        else
            p
        end
    end
    centrepos = Dict{Int,Any}(o => _centrepos(o) for o in unique(obsid))
    fdir = Dict{Int,Any}()                            # static field id -> J2000 direction
    fdir_t = Dict{Tuple{Int,Float64},Any}()           # (moving field, TIME) -> J2000
    feph = Dict{Int,Any}()                            # field id -> Ephemeris | nothing
    # a FIELD with any polynomial PHASE_DIR is time-dependent like an ephemeris
    _fld_poly = "NUM_POLY" in Set(columnnames(fld)) &&
                any(>(0), Int.(column(fld, "NUM_POLY")[:]))

    # suffix-less -> -1 (array centre); a `*1`/`*2` -> the antenna
    _antid(f, i) = endswith(f, "2") ? a2[i] : endswith(f, "1") ? a1[i] : -1

    _fe(fi) = get!(() -> field_ephemeris(fld, fi), feph, fi)

    function _fielddir(fi, i)
        e = _fe(fi)
        if e === nothing
            _fld_poly || return get!(fdir, fi) do
                measconvert(measure(fld, "PHASE_DIR", fi + 1), J2000;
                            frame = MeasFrame(epoch = epochs[i]))
            end
            return get!(fdir_t, (fi, tsec[i])) do
                measconvert(measure(fld, "PHASE_DIR", fi + 1; epoch = epochs[i]),
                            J2000; frame = MeasFrame(epoch = epochs[i]))
            end
        end
        get!(fdir_t, (fi, tsec[i])) do
            tdb = measconvert(epochs[i], TDB; frame = MeasFrame(epoch = epochs[i])).mjd
            d = ephemeris_direction(e, tdb)
            measconvert(d, J2000;
                        frame = MeasFrame(epoch = epochs[i], position = antpos[1]))
        end
    end

    # resolve a `mscal.<fn>` direction argument to a per-row J2000
    # direction + a memo-distinguishing key.  "" -> FIELD.PHASE_DIR (or
    # its ephemeris); a body name -> geocentric apparent place; a FIELD
    # direction column; a `[ra,dec]` J2000 pair.
    djcache = Dict{Any,Any}()
    function _djfor(dir::AbstractString, i::Int)
        isempty(dir) && return (_fielddir(fid[i], i), fid[i])
        if startswith(dir, "[")
            m = match(r"^\[([^,]+),([^\]]+)\]$", dir)
            return (MDirection{J2000}(parse(Float64, m[1]), parse(Float64, m[2])), :fixed)
        elseif dir in _MSCAL_DIR_COLS
            d = get!(() -> measconvert(measure(fld, dir, fid[i] + 1; epoch = epochs[i]),
                                       J2000; frame = MeasFrame(epoch = epochs[i])),
                     djcache, (dir, fid[i], tsec[i]))
            return (d, (dir, fid[i]))
        else
            R = get(_DIRECTION_FRAMES, uppercase(dir), nothing)
            R === nothing && error("mscal: unknown direction \"$dir\" — give a " *
                "body name ('SUN'), a FIELD direction column ('DELAY_DIR'), or " *
                "a `[ra, dec]` pair")
            d = get!(() -> measconvert(MDirection{R}(0.0, 0.0), J2000;
                                       frame = MeasFrame(epoch = epochs[i])),
                     djcache, (dir, tsec[i]))
            return (d, (dir,))
        end
    end

    # memo: (position key, direction key, TIME seconds) -> frame-converted values.
    # antid >= 0 is an antenna; antid < 0 means the array centre for
    # OBSERVATION_ID `-antid-1`.
    memo = Dict{Tuple{Int,Any,Float64},NamedTuple}()
    function _cache(antid::Int, dir::AbstractString, i::Int)
        dj, dkey = _djfor(dir, i)
        pkey = antid >= 0 ? antid : -obsid[i] - 1
        get!(memo, (pkey, dkey, tsec[i])) do
            pos = antid >= 0 ? antpos[antid + 1] : centrepos[obsid[i]]
            fr = MeasFrame(epoch = epochs[i], position = pos, direction = dj)
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
    for spec in fns
        f, dir = _mscal_split_dir(spec)
        if f == "delay"
            v = Vector{Float64}(undef, n)
            for i in 1:n
                x = _cache(-1, dir, i).itrf_xyz
                d = _pvec(antpos[a1[i] + 1]) .- _pvec(antpos[a2[i] + 1])
                v[i] = (x[1]*d[1] + x[2]*d[2] + x[3]*d[3]) / C_LIGHT
            end
            out[_mscal_key(spec)] = v
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
            out[_mscal_key(spec)] = v
        elseif startswith(f, "hadec")
            out[_mscal_key(spec)] = [collect(_cache(_antid(f, i), dir, i).hadec) for i in 1:n]
        elseif startswith(f, "azel")
            out[_mscal_key(spec)] = [collect(_cache(_antid(f, i), dir, i).azel) for i in 1:n]
        elseif f == "itrf"
            out[_mscal_key(spec)] = [collect(_cache(_antid(f, i), dir, i).itrf_ll) for i in 1:n]
        elseif startswith(f, "ha")
            out[_mscal_key(spec)] = Float64[_cache(_antid(f, i), dir, i).hadec[1] for i in 1:n]
        elseif startswith(f, "az")
            out[_mscal_key(spec)] = Float64[_cache(_antid(f, i), dir, i).azel[1] for i in 1:n]
        elseif startswith(f, "el")
            out[_mscal_key(spec)] = Float64[_cache(_antid(f, i), dir, i).azel[2] for i in 1:n]
        elseif startswith(f, "last")
            out[_mscal_key(spec)] = Float64[mod2pi(_cache(_antid(f, i), dir, i).last) for i in 1:n]
        elseif startswith(f, "pa")
            out[_mscal_key(spec)] = Float64[
                (c = _cache(_antid(f, i), dir, i); _position_angle(c.azel, c.pole))
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

const _MSSEL_FUNCS = Set(["baseline", "field", "spw", "scan", "state", "array",
                          "obs", "time", "uvdist", "chan", "corr", "feed"])

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

    fn == "time" && return _mssel_time(t, spec, cn, n)
    fn == "uvdist" && return _mssel_uvdist(t, spec, cn, subs, n)

    if fn == "corr"
        _need("DATA_DESC_ID")
        (haskey(subs, "DATA_DESCRIPTION") && haskey(subs, "POLARIZATION")) || error(
            "mscal.corr: needs DATA_DESCRIPTION + POLARIZATION subtables")
        ddid = Int.(column(t, "DATA_DESC_ID")[:])
        dd2pol = Int.(column(readtable(subs["DATA_DESCRIPTION"]), "POLARIZATION_ID")[:])
        polct = column(readtable(subs["POLARIZATION"]), "CORR_TYPE")[:]   # Vector per setup
        want = _parse_corr_types(spec)
        have = [Set(Int.(c)) for c in polct]
        return Bool[!isempty(want ∩ have[dd2pol[d + 1] + 1]) for d in ddid]
    elseif fn == "feed"
        _need("FEED1")
        f1 = Int.(column(t, "FEED1")[:])
        f2 = "FEED2" in cn ? Int.(column(t, "FEED2")[:]) : f1
        maxf = max(maximum(f1; init = -1), maximum(f2; init = -1))
        pred = _mssel_baseline_pred(spec, Dict{String,Vector{Int}}(), 0:maxf)
        return Bool[pred(f1[i], f2[i]) for i in 1:n]
    elseif fn == "baseline"
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
    elseif fn == "spw" || fn == "chan"
        _need("DATA_DESC_ID")
        haskey(subs, "DATA_DESCRIPTION") || error("mscal.$fn: no DATA_DESCRIPTION subtable")
        ddid = Int.(column(t, "DATA_DESC_ID")[:])
        dd2spw = Int.(column(readtable(subs["DATA_DESCRIPTION"]), "SPECTRAL_WINDOW_ID")[:])
        rowspw = Int[dd2spw[d + 1] for d in ddid]
        spwtab = haskey(subs, "SPECTRAL_WINDOW") ? readtable(subs["SPECTRAL_WINDOW"]) : nothing
        nspw = spwtab === nothing ? maximum(rowspw; init = -1) + 1 : nrow(spwtab)
        n2i = (spwtab !== nothing && "NAME" in Set(columnnames(spwtab))) ?
              _mssel_names_to_ids(column(spwtab, "NAME")[:]) : Dict{String,Vector{Int}}()

        if fn == "spw" && !_spw_has_chan(spec)
            S = _mssel_idset(spec, 0:(nspw - 1), n2i)
            return Bool[s in S for s in rowspw]
        end

        spwtab === nothing && error("mscal.$fn: channel selection needs a SPECTRAL_WINDOW subtable")
        chanfreq = column(spwtab, "CHAN_FREQ")[:]          # Vector, per spw
        items = _parse_spw_spec(spec, nspw, n2i)
        # per-spw combined channel mask (OR of matching items)
        spwmask = Dict{Int,BitVector}()
        _mask(s) = get!(spwmask, s) do
            cf = chanfreq[s + 1]
            m = falses(length(cf))
            for it in items
                s in it.spws && (m .|= _chan_mask(it.chans, cf))
            end
            m
        end
        return fn == "chan" ? [_mask(s) for s in rowspw] :
               Bool[any(_mask(s)) for s in rowspw]
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

# ---------------------------------------------------------------------------
# Phase 81: `mscal.time('spec')` and `mscal.uvdist('spec')`.
#
# time: a comma-list of `t0~t1` ranges (or `>t0` / `<t1` bounds); each
#   endpoint is an ISO / `YYYY/MM/DD[/HH:MM:SS]` datetime (parsed by the
#   Phase-69 `_tql_parse_datetime`) or a bare number = MJD days. Compared
#   against the MAIN `TIME` column (UTC seconds).
# uvdist: a comma-list of `a~b` ranges (or `<b` / `>a` bounds) with an
#   optional unit suffix `m` (default) / `km` / `lambda` / `klambda` /
#   `mlambda`. The 2-D uv-distance `sqrt(u^2 + v^2)` (matching casacore's
#   fast path). Wavelength units scale per row by
#   `SPECTRAL_WINDOW.REF_FREQUENCY` of the row's spw.

function _mssel_ranges(spec::AbstractString, parse1)
    out = Tuple{Float64,Float64}[]
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        if startswith(term, ">")
            push!(out, (parse1(strip(term[2:end])), Inf))
        elseif startswith(term, "<")
            push!(out, (-Inf, parse1(strip(term[2:end]))))
        else
            m = match(r"^(.*?)\s*~\s*(.*)$", term)
            m === nothing && throw(ArgumentError(
                "mscal selection range \"$term\" — give `a~b`, `>a`, or `<b`"))
            push!(out, (parse1(strip(m[1])), parse1(strip(m[2]))))
        end
    end
    return out
end

_mssel_inany(x, ranges) = any(r -> r[1] <= x <= r[2], ranges)

# --- MSSelection time grammar (casacore ms/MSSel/MSTimeParse) -----------
# A comma-list of:
#   t0            single time  -> |TIME - t0| <= dT   (dT = EXPOSURE/2, or 1 s)
#   t0~t1         range, exclusive edges
#   [t0~t1]       range, edge-inclusive (|TIME-edge| < dT counts)
#   N[t0~t1]      range, edge buffer N seconds
#   t0+dur        range t0 .. t0+dur   (dur = a time string past the MJD epoch)
#   >t0  <t1      open bounds
# Each time is `[Y/[M/[D/]]][h:[m:[s]]]` with any component `*` (wildcard);
# a missing / `*` component defaults to the first MAIN-row TIME (t1 of a
# `~` range instead inherits from t0).  Bare number = MJD days.

# parse one time token -> 6 fields (y,mo,d,h,mi,s), -1 = wildcard/missing;
# or a bare Float64 (already MJD days) wrapped as `(:mjd, val)`.
function _mstime_fields(tok::AbstractString)
    s = strip(String(tok))
    v = tryparse(Float64, s)
    v !== nothing && return (:mjd, v)
    # the `Y/M/D[/h:m:s]` MSSelection form; fall back to ISO / `d U y`
    # (`_tql_parse_datetime`) for anything else (e.g. `2024-05-24T…`).
    if !occursin('/', s) && occursin('-', s)
        return (:mjd, _tql_parse_datetime(s))
    end
    datepart, timepart = if occursin(':', s)
        i = findlast('/', s)
        j = something(i, 0)
        (j > 0 ? s[1:j-1] : "", j > 0 ? s[j+1:end] : s)
    else
        (s, "")
    end
    _f(x) = (x == "*" || isempty(x)) ? -1.0 : parse(Float64, x)
    dp = isempty(datepart) ? String[] : split(datepart, '/')
    tp = isempty(timepart) ? String[] : split(timepart, ':')
    g(a, k) = k <= length(a) ? _f(a[k]) : -1.0
    try
        return (:cal, (g(dp, 1), g(dp, 2), g(dp, 3), g(tp, 1), g(tp, 2), g(tp, 3)))
    catch
        return (:mjd, _tql_parse_datetime(s))
    end
end

# fill -1 fields from `def` (a 6-tuple), then -> seconds since MJD 0.
function _mstime_secs(fields, def)
    f = ntuple(k -> fields[k] < 0 ? def[k] : fields[k], 6)
    dt = Dates.DateTime(Int(f[1]), Int(f[2]), Int(f[3]), Int(f[4]), Int(f[5]),
                        Int(floor(f[6])), Int(round((f[6] - floor(f[6])) * 1000)))
    ((dt - MJD_EPOCH) / Dates.Millisecond(1)) / 1000
end

function _mssel_time(t::AbstractTable, spec::AbstractString, cn::AbstractSet, n::Integer)
    "TIME" in cn || error("mscal.time: MAIN table has no TIME column")
    tm = Float64.(column(t, "TIME")[:])
    n == 0 && return Bool[]
    d0 = MJD_EPOCH + Dates.Millisecond(round(Int, tm[1] * 1000))   # first-row time
    def = (Dates.year(d0), Dates.month(d0), Dates.day(d0),
           Dates.hour(d0), Dates.minute(d0), Dates.second(d0))
    epdef = (1858, 11, 17, 0, 0, 0.0)
    dT = "EXPOSURE" in cn ?
         (e = Float64.(column(t, "EXPOSURE")[:]); (isempty(e) ? 2.0 : sum(e) / length(e)) / 2) :
         1.0

    _sec(tok, dfl) = begin
        k, v = _mstime_fields(tok)
        k === :mjd ? v * SEC_PER_DAY : _mstime_secs(v, dfl)
    end

    preds = Vector{Function}()
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        if startswith(term, ">")
            lo = _sec(term[2:end], def);  push!(preds, x -> x >= lo)
        elseif startswith(term, "<")
            hi = _sec(term[2:end], def);  push!(preds, x -> x <= hi)
        elseif (m = match(r"^(?:(\d+(?:\.\d+)?)\s*)?\[\s*(.+?)\s*~\s*(.+?)\s*\]$", term)) !== nothing
            buf = m[1] === nothing ? dT : parse(Float64, m[1])
            lo = _sec(m[2], def)
            hi = _mstime_incl_hi(m[3], lo)
            push!(preds, x -> (x > lo || abs(x - lo) < buf) && (x < hi || abs(x - hi) < buf))
        elseif (m = match(r"^(.+?)\s*~\s*(.+)$", term)) !== nothing
            lo = _sec(m[1], def)
            hi = _mstime_incl_hi(m[2], lo)
            push!(preds, x -> lo <= x <= hi)
        elseif (m = match(r"^(.+?)\s*\+\s*(.+)$", term)) !== nothing
            lo = _sec(m[1], def)
            dur = _sec(m[2], epdef)          # seconds since MJD 0 == the interval
            push!(preds, x -> lo <= x <= lo + dur)
        else
            c = _sec(term, def);  push!(preds, x -> abs(x - c) <= dT)
        end
    end
    isempty(preds) && return falses(n)
    return Bool[any(p -> p(tm[i]), preds) for i in 1:n]
end

# t1 of a `~` range: its wildcard/missing fields inherit from t0's
# resolved calendar (casacore `copyDefaults`), not the MS default.
function _mstime_incl_hi(tok::AbstractString, lo_secs::Float64)
    k, v = _mstime_fields(tok)
    k === :mjd && return v * SEC_PER_DAY
    d = MJD_EPOCH + Dates.Millisecond(round(Int, lo_secs * 1000))
    _mstime_secs(v, (Dates.year(d), Dates.month(d), Dates.day(d),
                     Dates.hour(d), Dates.minute(d), Dates.second(d)))
end

const _MSSEL_UV_UNIT = Dict("m" => (1.0, :dist), "km" => (1e3, :dist),
    "lambda" => (1.0, :wave), "klambda" => (1e3, :wave), "mlambda" => (1e6, :wave))

function _mssel_uvdist(t::AbstractTable, spec::AbstractString, cn::AbstractSet,
                       subs::AbstractDict, n::Integer)
    "UVW" in cn || error("mscal.uvdist: MAIN table has no UVW column")
    kinds = Set{Symbol}()
    ranges = Tuple{Float64,Float64}[]
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        # an optional trailing `:P%` widens the range by ±P percent
        # (casacore `uvwdistexpr COLON FNUMBER PERCENT`).
        pct = 0.0
        pm = match(r"^(.*?)\s*:\s*(\d+(?:\.\d+)?)\s*%\s*$", term)
        if pm !== nothing
            term = strip(pm[1]); pct = parse(Float64, pm[2]) * 0.01
        end
        # a term's unit is the trailing letters; it applies to every
        # number in the term (matching casacore's global-unit behaviour).
        um = match(r"[a-zA-Z]+\s*$", term)
        u = um === nothing ? "m" : lowercase(strip(um.match))
        haskey(_MSSEL_UV_UNIT, u) || throw(ArgumentError(
            "mscal.uvdist: unknown unit \"$u\" (m / km / lambda / klambda / mlambda)"))
        scale, k = _MSSEL_UV_UNIT[u]
        push!(kinds, k)
        body = strip(um === nothing ? term : term[1:prevind(term, um.offset)])
        num(s) = parse(Float64, strip(s)) * scale
        wide(lo, hi) = push!(ranges, (lo * (1 - pct), hi * (1 + pct)))
        if startswith(body, ">")
            wide(num(body[2:end]), Inf)
        elseif startswith(body, "<")
            push!(ranges, (-Inf, num(body[2:end]) * (1 + pct)))
        elseif (m = match(r"^(.+?)\s*(?:~|(?<![eE])-)\s*(.+)$", body)) !== nothing
            wide(num(m[1]), num(m[2]))
        elseif tryparse(Float64, strip(body)) !== nothing   # bare value (needs :P%)
            v = num(body); wide(v, v)
        else
            throw(ArgumentError("mscal.uvdist: \"$term\" — give `a~b`, `>a`, `<b`, or `V:P%`"))
        end
    end
    length(kinds) <= 1 || throw(ArgumentError(
        "mscal.uvdist: a spec mixes distance and wavelength units"))
    kind = Ref(isempty(kinds) ? :dist : first(kinds))
    uvw = column(t, "UVW")[:]
    d2d = Float64[hypot(Float64(x[1]), Float64(x[2])) for x in uvw]
    if kind[] === :dist
        return Bool[_mssel_inany(d2d[i], ranges) for i in 1:n]
    end
    # wavelength: compare d2d * refFreq / c per row's spw
    haskey(subs, "DATA_DESCRIPTION") && haskey(subs, "SPECTRAL_WINDOW") || error(
        "mscal.uvdist: wavelength units need DATA_DESCRIPTION + SPECTRAL_WINDOW subtables")
    ddid = Int.(column(t, "DATA_DESC_ID")[:])
    dd2spw = Int.(column(readtable(subs["DATA_DESCRIPTION"]), "SPECTRAL_WINDOW_ID")[:])
    reff = Float64.(column(readtable(subs["SPECTRAL_WINDOW"]), "REF_FREQUENCY")[:])
    return Bool[_mssel_inany(d2d[i] * reff[dd2spw[ddid[i] + 1] + 1] / C_LIGHT, ranges)
                for i in 1:n]
end

# ---------------------------------------------------------------------------
# Phase 83: `mscal.spw('spec')` channel sub-selection + companion
# `mscal.chan('spec')`.
#
# `spec` is a comma-list of `<spwterm>[:<chanlist>]` items.  `<spwterm>`
# is a single MSSelection-lite term (`N`, `N~M`, `>N`, `<N`, a name /
# glob / `/regex/` against `SPECTRAL_WINDOW.NAME`, `*`).  `<chanlist>`
# is a `;`-list of channel selectors:
#   a          a single 0-based channel index
#   a~b        an inclusive channel-index range
#   a~b^s      ... with a step
#   f1~f2GHz   a CHAN_FREQ range (Hz / kHz / MHz / GHz)
#   <f / >f    a CHAN_FREQ bound
#
# `mscal.spw` returns a per-row `Bool`: the row's spw matches an item
# *and*, if that item has a channel list, at least one of the row's
# channels is selected.  `mscal.chan` returns a per-row `BitVector`
# (length = the spw's channel count) -- the OR of the matching items'
# channel masks (a full mask for an item with no channel list).

struct _SpwItem
    spws::Set{Int}
    chans::Union{Nothing,Vector{Any}}     # each: (:idx, lo, hi, step) | (:freq, flo, fhi)
end

_spw_has_chan(spec::AbstractString) = occursin(':', spec)

const _CHAN_FREQ_UNIT = Dict("hz" => 1.0, "khz" => 1e3, "mhz" => 1e6, "ghz" => 1e9)

function _parse_chan_elem(s::AbstractString)
    s = strip(s)
    um = match(r"[a-zA-Z]+\s*$", s)
    if um !== nothing
        u = lowercase(strip(um.match))
        haskey(_CHAN_FREQ_UNIT, u) || throw(ArgumentError(
            "mscal channel selection: unknown frequency unit \"$u\""))
        sc = _CHAN_FREQ_UNIT[u]
        body = strip(s[1:prevind(s, um.offset)])
        num(x) = parse(Float64, strip(x)) * sc
        startswith(body, ">") && return (:freq, num(body[2:end]), Inf)
        startswith(body, "<") && return (:freq, -Inf, num(body[2:end]))
        m = match(r"^(.+?)\s*~\s*(.+)$", body)
        m === nothing && throw(ArgumentError("mscal channel freq \"$s\": give `f1~f2UNIT`"))
        return (:freq, num(m[1]), num(m[2]))
    end
    m = match(r"^(\d+)\s*~\s*(\d+)(?:\s*\^\s*(\d+))?$", s)
    m !== nothing && return (:idx, parse(Int, m[1]), parse(Int, m[2]),
                             m[3] === nothing ? 1 : parse(Int, m[3]))
    startswith(s, ">") && return (:idx, parse(Int, strip(s[2:end])) + 1, typemax(Int) ÷ 2, 1)
    startswith(s, "<") && return (:idx, 0, parse(Int, strip(s[2:end])) - 1, 1)
    occursin(r"^\d+$", s) && return (:idx, parse(Int, s), parse(Int, s), 1)
    throw(ArgumentError("mscal channel selection: bad selector \"$s\""))
end

function _parse_spw_spec(spec::AbstractString, nspw::Integer, n2i::AbstractDict)
    items = _SpwItem[]
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        ci = findfirst(':', term)
        spwpart = ci === nothing ? term : strip(term[1:prevind(term, ci)])
        chanpart = ci === nothing ? nothing : strip(term[nextind(term, ci):end])
        spws = _mssel_resolve(spwpart, 0:(nspw - 1), n2i)
        chans = chanpart === nothing ? nothing :
                Any[_parse_chan_elem(e) for e in split(chanpart, ';') if !isempty(strip(e))]
        push!(items, _SpwItem(spws, chans))
    end
    return items
end

# channel mask for one spw given its CHAN_FREQ vector
function _chan_mask(elems, chanfreq::AbstractVector)
    nc = length(chanfreq)
    m = falses(nc)
    elems === nothing && return trues(nc)
    for e in elems
        if e[1] === :idx
            lo, hi, st = e[2], min(e[3], nc - 1), e[4]
            for c in lo:st:hi
                0 <= c < nc && (m[c + 1] = true)
            end
        else
            flo, fhi = e[2], e[3]
            for c in 1:nc
                flo <= chanfreq[c] <= fhi && (m[c] = true)
            end
        end
    end
    return m
end

# ---------------------------------------------------------------------------
# Phase 84: `mscal.corr('spec')` and `mscal.feed('spec')`.
#
# corr: a comma-list of correlation names (`RR` / `XX` / `I` / … via the
#   Phase-78 `_STOKES_NAMES`) or integer Stokes codes. A per-row `Bool`:
#   true if the row's polarization setup (`POLARIZATION.CORR_TYPE` via
#   `DATA_DESCRIPTION.POLARIZATION_ID`) shares any code with the request.
# feed: the antenna-grammar form on FEED1 / FEED2 -- `L & R` feed-pair
#   selection, comma-lists of ids / `N~M` ranges, `!` negation -- exactly
#   like `mscal.baseline` but with numeric feed ids only.

function _parse_corr_types(spec::AbstractString)
    out = Set{Int}()
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        up = uppercase(term)
        if haskey(_STOKES_NAMES, up)
            push!(out, _STOKES_NAMES[up])
        elseif occursin(r"^\d+$", term)
            push!(out, parse(Int, term))
        else
            throw(ArgumentError("mscal.corr: unknown correlation \"$term\""))
        end
    end
    isempty(out) && throw(ArgumentError("mscal.corr: empty correlation list"))
    return out
end

# ---------------------------------------------------------------------------
# Phase 85: an optional direction argument for the `mscal.*` direction
# functions (`mscal.ha1('SUN')`, `mscal.azel1('DELAY_DIR')`,
# `mscal.hadec1([2.0, 0.5])`).  Mirrors casacore's help text: the arg may
# be a solar-system body name, a FIELD direction-column name, or a
# `[ra, dec]` J2000 pair (radians here).  No arg -> `FIELD.PHASE_DIR`.

_dir_pair_key(ra::Real, dec::Real) = "[" * string(Float64(ra)) * "," * string(Float64(dec)) * "]"

function _mscal_dir_arg(a::TQLExpr, src::AbstractString)
    if a isa TQLLit && a.value isa AbstractString
        s = String(a.value)
        if occursin(',', s)                       # an "RA, DEC" sexagesimal pair
            ra, dec = strip.(split(s, ','; limit = 2))
            return _dir_pair_key(_parse_sexagesimal(ra, :ra),
                                 _parse_sexagesimal(dec, :dec))
        end
        return s                                  # a body / FIELD-column name
    elseif a isa TQLArrayLit && length(a.elems) == 2 &&
           all(e -> e isa TQLLit, a.elems)
        e1, e2 = a.elems[1].value, a.elems[2].value
        ra  = e1 isa Real ? Float64(e1) : _parse_sexagesimal(String(e1), :ra)
        dec = e2 isa Real ? Float64(e2) : _parse_sexagesimal(String(e2), :dec)
        return _dir_pair_key(ra, dec)
    end
    throw(ArgumentError("TaQL-lite: mscal direction argument must be a " *
        "body name ('SUN'), a FIELD column name ('DELAY_DIR'), a " *
        "`[ra, dec]` pair (radians), or a sexagesimal `'RA, DEC'` string " *
        "in \"$src\""))
end

# `"ha1"` -> `("ha1", "")`; `"ha1::SUN"` -> `("ha1", "SUN")`
function _mscal_split_dir(spec::AbstractString)
    i = findfirst("::", spec)
    i === nothing ? (String(spec), "") :
        (String(spec[1:prevind(spec, first(i))]), String(spec[nextind(spec, last(i)):end]))
end

const _MSCAL_DIR_COLS = Set(["PHASE_DIR", "DELAY_DIR", "REFERENCE_DIR"])
