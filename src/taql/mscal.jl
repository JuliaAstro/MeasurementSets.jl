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
            v = Vector{Vector{Float64}}(undef, n)
            for i in 1:n
                dj = _fielddir(fid[i], i)
                fr = MeasFrame(epoch = epochs[i], position = antpos[a1[i] + 1], direction = dj)
                w = measconvert(MuvW{ITRF}(uvw[i]...), J2000; frame = fr)
                v[i] = [w.u, w.v, w.w]
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
