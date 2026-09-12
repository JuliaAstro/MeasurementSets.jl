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
                      # "pa*" "last*" "itrf" "uvw_j2000"
                      # "delay"/"delay1"/"delay2" (delay* defaults to
                      # FIELD.DELAY_DIR, everything else to PHASE_DIR)
                      # "riseset[1|2]:<elev0>" (Phase 105)
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
    "pa", "pa1", "pa2", "itrf", "delay", "delay1", "delay2"])

const _MSCAL_FUNCS = Set([
    "ha", "ha1", "ha2", "hadec", "hadec1", "hadec2",
    "azel", "azel1", "azel2", "az1", "az2", "el1", "el2",
    "pa", "pa1", "pa2", "last", "last1", "last2",
    "itrf", "uvw_j2000", "delay", "delay1", "delay2"])

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

# Phase 137: `MVuvw`'s own baseline->uvw construction (casacore
# `casa/Quanta/MVuvw.cc:83-91`) -- `xyz = R*pos` with `R =
# RotMatrix(Euler(dir.lat-π/2, 1u, -dir.lon-π/2, 3u))` = `Rx(dir.lat-π/2)
# · Rz(-dir.lon-π/2)`. Pure trig, no SOFA needed. This is genuinely
# NOT the same rotation basis as `MCuvw::toPole`/`fromPole` (which use
# `Ry(-π/2+lat)·Rz(-lon)`, axes 2,3 not 1,3) -- confirmed by direct
# numeric comparison; `mscal.uvw_j2000()` (`MSCalEngine::getNewUVW`)
# always uses THIS constructor fresh from antenna positions, never
# `Muvw::Convert`/`MCuvw`.
function _mvuvw_construct(pos::NTuple{3,Float64}, dir)
    a = dir.lat - pi / 2
    b = -dir.lon - pi / 2
    ca, sa = cos(a), sin(a)
    cb, sb = cos(b), sin(b)
    # R = Rx(a) * Rz(b)
    x, y, z = pos
    (cb * x - sb * y,
     ca * sb * x + ca * cb * y - sa * z,
     sa * sb * x + sa * cb * y + ca * z)
end

# Phase 101/103: parse a `mscal.pbresponse` beam spec into an
# `offset::(dlon,dlat) -> power::Float64` closure (a scalar circular
# beam ignores the offset direction via `power_response`'s generic
# 2-D-offset fallback in beam.jl).  Forms:
#   "gaussian:HPBW"                     -- GaussianBeam
#   "airy:DIAMETER:FREQ[:BLOCKAGE]"     -- AiryBeam
#   "ellipse:HMAJ:HMIN:PA"              -- EllipticalGaussianBeam
# any of which may carry a trailing ":squint:DLON:DLAT" to wrap the base
# beam in a `SquintBeam` (feed/beam pointing offset, radians).
# Called both at parse time (early validation in `functions.jl`, closure
# discarded) and at column-build time (the closure is used).
function _pb_num(p::AbstractString, spec::AbstractString)
    v = tryparse(Float64, strip(p))
    v === nothing && throw(ArgumentError(
        "mscal.pbresponse: bad numeric parameter \"$p\" in \"$spec\""))
    v
end

function _pb_response_fn(spec::AbstractString)
    parts = split(spec, ':')
    isempty(parts) && throw(ArgumentError("mscal.pbresponse: empty beam spec"))
    kind = lowercase(strip(parts[1]))
    rest = parts[2:end]
    sqidx = findfirst(p -> lowercase(strip(p)) == "squint", rest)
    squint = nothing
    if sqidx !== nothing
        sqparams = rest[(sqidx + 1):end]
        length(sqparams) == 2 || throw(ArgumentError(
            "mscal.pbresponse: \"squint:dlon:dlat\" takes 2 parameters, got " *
            "$(length(sqparams)) in \"$spec\""))
        squint = (_pb_num(sqparams[1], spec), _pb_num(sqparams[2], spec))
        rest = rest[1:(sqidx - 1)]
    end
    nums = [_pb_num(p, spec) for p in rest]
    freq = 1.0
    base = if kind == "gaussian"
        length(nums) == 1 || throw(ArgumentError(
            "mscal.pbresponse: \"gaussian:HPBW\" takes 1 parameter, got $(length(nums))"))
        GaussianBeam(nums[1], 1.0)
    elseif kind == "airy"
        length(nums) in (2, 3) || throw(ArgumentError(
            "mscal.pbresponse: \"airy:diameter:freq[:blockage]\" takes 2 or 3 " *
            "parameters, got $(length(nums))"))
        freq = nums[2]
        AiryBeam(nums[1]; blockage = length(nums) == 3 ? nums[3] : 0.0)
    elseif kind == "ellipse"
        length(nums) == 3 || throw(ArgumentError(
            "mscal.pbresponse: \"ellipse:hmaj:hmin:pa\" takes 3 parameters, got " *
            "$(length(nums))"))
        EllipticalGaussianBeam(nums[1], nums[2], nums[3], 1.0)
    else
        throw(ArgumentError(
            "mscal.pbresponse: unknown beam kind \"$kind\" (gaussian / airy / ellipse) " *
            "in \"$spec\""))
    end
    beam = squint === nothing ? base : SquintBeam(base, squint)
    return offset -> power_response(beam, offset, freq)
end

# the 2-D tangent-plane offset (dlon,dlat) of the nominal (target)
# direction from the antenna's actual pointing (the beam centre) --
# both AZEL (lon,lat) tuples.
_pb_offset(actual_azel::NTuple{2}, nominal_azel::NTuple{2}) =
    pointing_offset(MDirection{AZEL}(actual_azel...), MDirection{AZEL}(nominal_azel...))

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
    need2 = any(f -> endswith(f, "2") || startswith(f, "delay") || f == "uvw_j2000" ||
                     startswith(f, "pbresponsebl:") || startswith(f, "riseset2:"), bases)
    (need2 && !("ANTENNA2" in cn)) && error(
        "mscal.* needs an ANTENNA2 column for a `*2` / delay function")

    n = nrow(t)
    a1 = Int.(column(t, "ANTENNA1")[:])
    a2 = need2 ? Int.(column(t, "ANTENNA2")[:]) : Int[]
    fid = Int.(column(t, "FIELD_ID")[:])
    tsec = Float64.(column(t, "TIME")[:])
    epochs = measure(t, "TIME")                       # Vector{MEpoch}

    ant = readtable(subs["ANTENNA"])
    antpos = measure(ant, "POSITION")                 # Vector{MPosition{ITRF}}
    fld = readtable(subs["FIELD"])
    fieldcols = Set(columnnames(fld))

    # Phase 138: `mscal.pa*()` -- casacore's `MSCalEngine::getPA` returns
    # a hard `0.0` unless the antenna's own `MOUNT` starts with "alt-az"
    # (case-insensitive; `setData`'s `mount` also stays 0, i.e. "not
    # alt-az", for the suffix-less array-centre form, which has no real
    # antenna at all) -- an equatorially/other-mounted antenna has no
    # well-defined parallactic angle in casacore's own model. Found
    # missing entirely while re-reading `MSCalEngine.cc` for Phase 137;
    # not observable on the sample fixture (every antenna is "ALT-AZ").
    _altaz6(m) = length(m) >= 6 && lowercase(m[1:6]) == "alt-az"
    mount_altaz = "MOUNT" in Set(columnnames(ant)) ?
                  _altaz6.(String.(column(ant, "MOUNT")[:])) : trues(nrow(ant))

    # array-centre position for a suffix-less `mscal.ha()`/`azel()`/… --
    # Phase 144 fix (found while sweeping `MSCalEngine.cc` for another
    # bug after Phase 143): `MSCalEngine::attachColumns` computes this
    # ONCE for the whole engine, from OBSERVATION *row 0*'s
    # TELESCOPE_NAME -- NOT per MAIN row via `OBSERVATION_ID` as this
    # package previously did (a real, live-verified divergence: on a
    # 2-observation synthetic MS with different telescopes, real
    # casacore's `mscal.ha()` is IDENTICAL across the OBSERVATION_ID
    # split -- ours jumped by ~0.7 rad at the boundary before this fix).
    # Fallback chain, also verified against source
    # (`MSCalEngine.cc:330-349`): OBSERVATION row 0 -> table keyword
    # `TELESCOPE_NAME` -> the MIDDLE antenna (`itsAntPos[0][nant/2]`,
    # 0-based -- NOT antenna 0, a second latent bug this fix also
    # corrects, though harder to observe live since any MS with a
    # recognised telescope never reaches it).
    telname = haskey(subs, "OBSERVATION") ?
              String.(column(readtable(subs["OBSERVATION"]), "TELESCOPE_NAME")[:]) :
              String[]
    centrepos = let p = !isempty(telname) ? observatory(telname[1]) : nothing
        if p === nothing
            kwtel = get(keywords(t), "TELESCOPE_NAME", nothing)
            p = kwtel === nothing ? nothing : observatory(String(kwtel))
        end
        if p === nothing
            nant = nrow(ant)
            if nant > 0
                @warn "mscal.*: no Observatories entry for the array's " *
                    "telescope; using the middle antenna as the array centre"
                p = antpos[nant ÷ 2 + 1]
            else
                error("mscal.*: cannot determine an array centre (no " *
                      "Observatories entry, no antennas)")
            end
        end
        p
    end
    fdir = Dict{Int,Any}()                            # static field id -> J2000 direction
    fdir_t = Dict{Tuple{Int,Float64},Any}()           # (moving field, TIME) -> J2000
    feph = Dict{Int,Any}()                            # field id -> Ephemeris | nothing
    # a FIELD with any polynomial PHASE_DIR is time-dependent like an ephemeris
    _fld_poly = "NUM_POLY" in Set(columnnames(fld)) &&
                any(>(0), Int.(column(fld, "NUM_POLY")[:]))

    # Phase 139 finding, worth stating explicitly: real casacore's
    # `MSCalEngine::fillFieldDir` does NOT interpolate a polynomial
    # `PHASE_DIR` or consult an ephemeris at all -- it caches
    # `dirCol(i).data()[0]`, the array cell's FIRST element, once per
    # field, and reuses that SAME (static) direction for every row
    # regardless of `TIME` (`NUM_POLY`/`EPHEMERIS_ID` are never even
    # read by `MSCalEngine.cc` -- confirmed by grep across the whole
    # file). This package's `mscal.*` functions deliberately do the
    # opposite (Phases 93/82): they interpolate the polynomial /
    # ephemeris direction at each row's own `TIME`, giving a physically
    # correct time-varying direction for a moving target. That is a
    # genuine, intentional improvement, not a bug -- but it means this
    # package's `mscal.*` output for a polynomial/ephemeris FIELD will
    # NOT numerically match real casacore's `derivedmscal` UDFs for such
    # a field (a real MS almost never has one -- `PHASE_DIR` is
    # overwhelmingly a fixed-position `Dims` column in practice, so this
    # only matters for genuinely moving-target observations).

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
    #
    # Phase 140: real casacore (`UDFMSCal::setupHA` et al.,
    # `derivedmscal/DerivedMC/UDFMSCal.cc:288-308`) tries a string
    # argument as a body/frame name FIRST (`MDirection::makeMDirection`)
    # and falls back to `itsEngine.setDirColName(str)` — an ARBITRARY
    # FIELD column name, not a fixed set — only if that fails. This
    # package previously checked a hard-coded whitelist of 3 column
    # names (`PHASE_DIR`/`DELAY_DIR`/`REFERENCE_DIR`) BEFORE the body/
    # frame lookup, so a real (if unusual) MS with some other custom
    # FIELD direction column would wrongly fail with "unknown
    # direction" instead of being read as a column. Fixed to match
    # casacore's actual precedence and genericity: try a body/frame
    # name first, then any real column of the FIELD subtable.
    djcache = Dict{Any,Any}()
    function _djfor(dir::AbstractString, i::Int)
        isempty(dir) && return (_fielddir(fid[i], i), fid[i])
        if startswith(dir, "[")
            m = match(r"^\[([^,]+),([^\]]+)\]$", dir)
            return (MDirection{J2000}(parse(Float64, m[1]), parse(Float64, m[2])), :fixed)
        end
        R = get(_DIRECTION_FRAMES, uppercase(dir), nothing)
        if R !== nothing
            d = get!(() -> measconvert(MDirection{R}(0.0, 0.0), J2000;
                                       frame = MeasFrame(epoch = epochs[i])),
                     djcache, (dir, tsec[i]))
            return (d, (dir,))
        elseif dir in fieldcols
            d = get!(() -> measconvert(measure(fld, dir, fid[i] + 1; epoch = epochs[i]),
                                       J2000; frame = MeasFrame(epoch = epochs[i])),
                     djcache, (dir, fid[i], tsec[i]))
            return (d, (dir, fid[i]))
        else
            error("mscal: unknown direction \"$dir\" — give a body name " *
                "('SUN'), a FIELD direction column ('DELAY_DIR'), or a " *
                "`[ra, dec]` pair")
        end
    end

    # Phase 101: `mscal.pbresponse('gaussian:HPBW' | 'airy:D:FREQ[:BLK]'
    # [, dir])` -- primary-beam response toward `dir` (default
    # FIELD.PHASE_DIR) as seen through ANTENNA1's *actual* pointing
    # (POINTING.DIRECTION) rather than its nominal position -- the
    # attenuation from a pointing/tracking error. Both directions are
    # brought to AZEL and compared with the great-circle offset.
    need_pb = any(b -> startswith(b, "pbresponse"), bases)
    pointing_lut = Dict{Int,Vector{Tuple{Float64,Int}}}()  # antenna -> sorted [(TIME, row)]
    pt = nothing
    if need_pb
        haskey(subs, "POINTING") || error("mscal.pbresponse: needs a POINTING subtable")
        pt = readtable(subs["POINTING"])
        pt_ant = Int.(column(pt, "ANTENNA_ID")[:])
        pt_time = Float64.(column(pt, "TIME")[:])
        for r in 1:nrow(pt)
            push!(get!(() -> Tuple{Float64,Int}[], pointing_lut, pt_ant[r]), (pt_time[r], r))
        end
        for v in values(pointing_lut)
            sort!(v; by = first)
        end
    end
    function _pointing_row(antid::Int, t::Float64)
        v = get(pointing_lut, antid, nothing)
        (v === nothing || isempty(v)) && error(
            "mscal.pbresponse: no POINTING rows for antenna $antid")
        k = searchsortedlast(v, (t, typemax(Int)); by = first)
        v[max(k, 1)][2]
    end
    pbmemo = Dict{Tuple{Int,Float64},NTuple{2,Float64}}()   # (antenna, TIME) -> actual azel
    function _pointing_azel(antid::Int, i::Int)
        get!(pbmemo, (antid, tsec[i])) do
            r = _pointing_row(antid, tsec[i])
            d = measure(pt, "DIRECTION", r; epoch = epochs[i])
            a = measconvert(d, AZEL;
                            frame = MeasFrame(epoch = epochs[i], position = antpos[antid + 1]))
            (a.lon, a.lat)
        end
    end

    # memo: (position key, direction key, TIME seconds) -> frame-converted values.
    # antid >= 0 is an antenna; antid < 0 means the array centre for
    # OBSERVATION_ID `-antid-1`.
    memo = Dict{Tuple{Int,Any,Float64},NamedTuple}()
    function _cache(antid::Int, dir::AbstractString, i::Int)
        dj, dkey = _djfor(dir, i)
        pkey = antid >= 0 ? antid : -1
        get!(memo, (pkey, dkey, tsec[i])) do
            pos = antid >= 0 ? antpos[antid + 1] : centrepos
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

    # Phase 105: `mscal.riseset[1|2]([elev0][, dir])` -- the rise/set MJD
    # of `dir` (default FIELD.PHASE_DIR) for the antenna's own ITRF
    # position, memoized per (antenna-or-centre, direction, UTC day) --
    # rise/set only changes once a day, unlike every other mscal.*
    # geometry function which is memoized per exact TIME.
    risememo = Dict{Tuple{Int,Any,Float64,Float64},Vector{Float64}}()
    function _riseset_for(antid::Int, dir::AbstractString, elev0::Float64, i::Int)
        dj, dkey = _djfor(dir, i)
        pkey = antid >= 0 ? antid : -1
        day = floor(tsec[i] / 86400.0)
        get!(risememo, (pkey, dkey, day, elev0)) do
            pos = antid >= 0 ? antpos[antid + 1] : centrepos
            mjd = tsec[i] / 86400.0
            collect(Float64, _riseset(dj.lon, dj.lat, mjd, _pvec(pos)..., elev0))
        end
    end

    out = Dict{String,AbstractVector}()
    for spec in fns
        f, dir = _mscal_split_dir(spec)
        if (rm = match(r"^riseset(1|2)?:(.+)$", f)) !== nothing
            suf = rm.captures[1]
            elev0 = parse(Float64, rm.captures[2])
            antidfn = suf == "2" ? (i -> a2[i]) : suf == "1" ? (i -> a1[i]) : (i -> -1)
            out[_mscal_key(spec)] = [_riseset_for(antidfn(i), dir, elev0, i) for i in 1:n]
        elseif startswith(f, "pbresponsebl:")
            respfn = _pb_response_fn(f[(length("pbresponsebl:") + 1):end])
            out[_mscal_key(spec)] = Float64[
                respfn(_pb_offset(_pointing_azel(a1[i], i), _cache(a1[i], dir, i).azel)) *
                respfn(_pb_offset(_pointing_azel(a2[i], i), _cache(a2[i], dir, i).azel))
                for i in 1:n]
        elseif startswith(f, "pbresponse:")
            respfn = _pb_response_fn(f[(length("pbresponse:") + 1):end])
            out[_mscal_key(spec)] = Float64[
                respfn(_pb_offset(_pointing_azel(a1[i], i), _cache(a1[i], dir, i).azel))
                for i in 1:n]
        elseif f == "delay"
            # bare form: (dot(itrf,ap1-centre) - dot(itrf,ap2-centre))/c
            # = dot(itrf, ap1-ap2)/c (the array centre cancels) -- matches
            # `MSCalEngine::getDelay`'s `antnr` "else" branch exactly.
            v = Vector{Float64}(undef, n)
            for i in 1:n
                x = _cache(-1, dir, i).itrf_xyz
                d = _pvec(antpos[a1[i] + 1]) .- _pvec(antpos[a2[i] + 1])
                v[i] = (x[1]*d[1] + x[2]*d[2] + x[3]*d[3]) / C_LIGHT
            end
            out[_mscal_key(spec)] = v
        elseif f == "delay1" || f == "delay2"
            # Phase 136: casacore's `mscal.delay1()`/`delay2()` (antnr 0/1
            # in `getDelay`) return ONE antenna's delay relative to the
            # array centre -- genuinely different from the bare form's
            # baseline difference, not `(ap1-ap2)` for either antenna
            # alone. Found missing from this package entirely (only the
            # bare `mscal.delay()` was implemented) while re-verifying
            # `getDelay` against source for Phase 136.
            aidx = f == "delay1" ? a1 : a2
            v = Vector{Float64}(undef, n)
            for i in 1:n
                x = _cache(-1, dir, i).itrf_xyz
                d = _pvec(antpos[aidx[i] + 1]) .- _pvec(centrepos)
                v[i] = (x[1]*d[1] + x[2]*d[2] + x[3]*d[3]) / C_LIGHT
            end
            out[_mscal_key(spec)] = v
        elseif f == "uvw_j2000"
            # Phase 137 fix (found while re-verifying `mscal.delay()` for
            # Phase 136): real casacore's `mscal.uvw_j2000()`
            # (`MSCalEngine::getNewUVW`) does NOT transform the stored
            # UVW column at all -- it recomputes uvw fresh from the
            # ANTENNA POSITIONS: rotate each antenna's ITRF baseline
            # (from an arbitrary common origin -- casacore uses antenna
            # 0) to J2000 via a pure `MBaseline` rotation, construct a
            # per-antenna uvw via `MVuvw`'s OWN convention
            # (`_mvuvw_construct`, NOT `MCuvw::toPole`/`fromPole` --
            # genuinely different rotation bases, confirmed by direct
            # numeric comparison against `casa/Quanta/{RotMatrix,
            # MVuvw}.cc`), then differences `ant2 - ant1`. Both the
            # `MBaseline` rotation and the `MVuvw` construction are
            # linear in the baseline vector, so the common origin
            # cancels in the difference and this collapses to one
            # combined linear map (memoized per (field,TIME), like the
            # old code's 3x3-matrix trick) applied directly to
            # `antpos[a2]-antpos[a1]`. **Note**: this genuinely differs
            # in SIGN from the *stored* UVW column's own convention on a
            # real MS (confirmed on the sample fixture: stored UVW's `w`
            # matches `dot(dir, ap1-ap2)`, i.e. ANTENNA1-ANTENNA2, while
            # `getNewUVW` computes ANTENNA2-ANTENNA1) -- a real,
            # longstanding casacore convention split between observed
            # data and `NewMSSimulator`'s simulated output, not a bug on
            # either side; `mscal.uvw_j2000()` matches `getNewUVW`
            # exactly, as it must to agree with real casacore.
            umemo = Dict{Tuple{Int,Float64},NTuple{3,NTuple{3,Float64}}}()
            refpos = antpos[1]
            v = Vector{Vector{Float64}}(undef, n)
            for i in 1:n
                cols3 = get!(umemo, (fid[i], tsec[i])) do
                    dj = _fielddir(fid[i], i)
                    fr = MeasFrame(epoch = epochs[i], position = refpos, direction = dj)
                    map(((x, y, z),) -> begin
                            bj = measconvert(MBaseline{ITRF}(x, y, z), J2000; frame = fr)
                            _mvuvw_construct(_pvec(bj), dj)
                        end,
                        ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)))
                end
                d = _pvec(antpos[a2[i] + 1]) .- _pvec(antpos[a1[i] + 1])
                v[i] = [cols3[1][k] * d[1] + cols3[2][k] * d[2] + cols3[3][k] * d[3]
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
            _pa1(i) = begin
                aid = _antid(f, i)
                if aid >= 0 && mount_altaz[aid + 1]
                    c = _cache(aid, dir, i)
                    _position_angle(c.azel, c.pole)
                else
                    0.0
                end
            end
            out[_mscal_key(spec)] = Float64[_pa1(i) for i in 1:n]
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

# Phase 109: the derived (non-linear) "pseudo Stokes" output types --
# encoded as negative codes internally (never real correlation codes,
# so they thread through `_stokes_key`/`_stokes_setups` unchanged and
# are trivially distinguishable from a physical 1..12 output).
const _STOKES_PSEUDO_CODES = Dict{String,Int}(
    "PTOTAL" => -1, "PLINEAR" => -2, "PANGLE" => -3,
    "PFTOTAL" => -4, "PFLINEAR" => -5)
const _STOKES_PSEUDO_SYM = Dict{Int,Symbol}(
    -1 => :total, -2 => :linear, -3 => :angle, -4 => :ftotal, -5 => :flinear)

function _parse_stokes_types(s::AbstractString)
    up = uppercase(strip(s))
    up = get(_STOKES_ALIASES, up, up)
    out = Int[]
    for tok in split(up, ',')
        t = strip(tok)
        isempty(t) && continue
        if haskey(_STOKES_NAMES, t)
            code = _STOKES_NAMES[t]
            code <= 12 || throw(ArgumentError(
                "mscal.stokes: output type \"$t\" (mixed-hand RX..YL) is not supported"))
            push!(out, code)
        elseif haskey(_STOKES_PSEUDO_CODES, t)
            push!(out, _STOKES_PSEUDO_CODES[t])
        else
            throw(ArgumentError("mscal.stokes: unknown polarization type \"$t\""))
        end
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
    cmat::Matrix{ComplexF64}   # nOut x nIn; rows for a pseudo output are all-zero (unused)
    fmat::BitMatrix            # cmat .!= 0
    wmat::Matrix{Float64}      # abs.(cmat)
    outtypes::Vector{Int}      # 1..12 physical, or a negative pseudo code (Phase 109)
    iquvmat::Matrix{ComplexF64}  # 4 x nIn: I,Q,U,V from the input frame -- built iff any pseudo output
end

function _stokes_setup(intypes::Vector{Int}, outtypes::Vector{Int}, rescale::Bool)
    inf = _stokes_frame(intypes)
    nO, nI = length(outtypes), length(intypes)
    cmat = zeros(ComplexF64, nO, nI)
    haspseudo = any(<(0), outtypes)
    iquvmat = zeros(ComplexF64, haspseudo ? 4 : 0, nI)
    if haspseudo
        basei = _STOKES_BASE[(inf, :iquv)]
        for j in 1:nI, r in 1:4
            iquvmat[r, j] = basei[r, _stokes_canon(intypes[j])]
        end
    end
    for o in 1:nO
        outtypes[o] < 0 && continue        # a pseudo output has no linear cmat row
        base = _STOKES_BASE[(inf, _stokes_frame((outtypes[o],)))]
        for j in 1:nI
            cmat[o, j] = base[_stokes_canon(outtypes[o]), _stokes_canon(intypes[j])] *
                         _stokes_factor(intypes[j], rescale) /
                         _stokes_factor(outtypes[o], rescale)
        end
    end
    return StokesSetup(cmat, cmat .!= 0, abs.(cmat), outtypes, iquvmat)
end

# derived pseudo-Stokes value from a complex I,Q,U,V tuple, per casacore's
# `StokesConverter::convert(Array<Complex>&, ...)` (StokesConverter.cc:284-352,
# live-verified against real Casacore.jl): Ptotal = sqrt(|Q|²+|U|²+|V|²),
# Plinear = sqrt(|Q|²+|U|²) -- note |·|² = real(z·conj(z)), i.e. the full
# complex magnitude squared, NOT real(z)² (an earlier version of this
# function used real(z)² throughout and was measurably wrong -- e.g. for
# Q=0.5+0.1i,U=-0.3+0.1i,V=1+1.2i real casacore gives Ptotal≈1.6733 while
# real(Q)²+real(U)²+real(V)² gives ≈1.1576). Pangle = ½·atan2(real(U),
# real(Q)) ("not well defined for complex quantities" per the source
# comment -- real parts only, confirmed correct). PFtotal/PFlinear divide
# by amplitude(I) = abs(I) (the full complex modulus), not real(I).
function _stokes_pseudo(sym::Symbol, I::Complex, Q::Complex, U::Complex, V::Complex)
    sym === :total   ? sqrt(abs2(Q) + abs2(U) + abs2(V)) :
    sym === :linear  ? sqrt(abs2(Q) + abs2(U)) :
    sym === :angle   ? 0.5 * atan(real(U), real(Q)) :
    sym === :ftotal  ? (I == 0 ? 0.0 : sqrt(abs2(Q) + abs2(U) + abs2(V)) / abs(I)) :
    sym === :flinear ? (I == 0 ? 0.0 : sqrt(abs2(Q) + abs2(U)) / abs(I)) :
    error("mscal.stokes: internal: unhandled pseudo type $sym")
end

# --- applying a setup to one array cell -----------------------------------

function _stokes_convert(s::StokesSetup, x::AbstractMatrix{<:Complex})
    nI, nch = size(x)
    nI == size(s.cmat, 2) || throw(ArgumentError(
        "mscal.stokes: cell has $nI correlations, POLARIZATION.CORR_TYPE has $(size(s.cmat, 2))"))
    nO = length(s.outtypes)
    out = zeros(ComplexF64, nO, nch)
    @inbounds for ch in 1:nch, o in 1:nO
        s.outtypes[o] < 0 && continue
        for j in 1:nI
            out[o, ch] += s.cmat[o, j] * x[j, ch]
        end
    end
    if any(<(0), s.outtypes)
        @inbounds for ch in 1:nch
            I = zero(ComplexF64); Q = zero(ComplexF64); U = zero(ComplexF64); V = zero(ComplexF64)
            for j in 1:nI
                I += s.iquvmat[1, j] * x[j, ch]; Q += s.iquvmat[2, j] * x[j, ch]
                U += s.iquvmat[3, j] * x[j, ch]; V += s.iquvmat[4, j] * x[j, ch]
            end
            for o in 1:nO
                t = s.outtypes[o]
                t < 0 || continue
                out[o, ch] = _stokes_pseudo(_STOKES_PSEUDO_SYM[t], I, Q, U, V)
            end
        end
    end
    return out
end

function _stokes_convert(s::StokesSetup, x::AbstractMatrix{Bool})
    any(<(0), s.outtypes) && throw(ArgumentError(
        "mscal.stokes: pseudo Stokes types (Ptotal/Plinear/Pangle/PFtotal/PFlinear) " *
        "need complex (DATA-like) input, not a FLAG-like Bool cell"))
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
    any(<(0), s.outtypes) && throw(ArgumentError(
        "mscal.stokes: pseudo Stokes types (Ptotal/Plinear/Pangle/PFtotal/PFlinear) " *
        "need complex (DATA-like) input, not a WEIGHT-like real cell"))
    nI, nch = size(x)
    nI == size(s.cmat, 2) || throw(ArgumentError(
        "mscal.stokes: WEIGHT cell has $nI correlations, expected $(size(s.cmat, 2))"))
    out = zeros(Float64, size(s.cmat, 1), nch)
    # Phase 142 fix: ported `StokesConverter::convert(Array<Float>&,...)`
    # (`ms/MeasurementSets/StokesConverter.cc:395-414`) exactly, not the
    # "skip a zero/non-contributing input" logic this had before. Real
    # casacore loops over EVERY input correlation regardless of whether
    # its conversion coefficient is zero (a no-op `0/x` term when it
    # is), but if ANY input weight is exactly 0 -- even one that has NO
    # coefficient for this particular output -- it zeroes the WHOLE
    # output for that (output, channel) and stops, per the source's own
    # `else { outMat(i,j)=0; break; }`. A weight of exactly 0 is the
    # ordinary convention for an invalid/flagged visibility in a real
    # MS, so this is not a rare edge case in practice.
    @inbounds for ch in 1:nch, o in axes(out, 1)
        acc = 0.0
        for j in 1:nI
            if x[j, ch] == 0
                acc = 0.0
                break
            end
            w = s.wmat[o, j]
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
# `mscal.baseline` additionally takes `L & R` / `L && R` / `L &&& `
# (baseline between two antenna sets; `&` = cross-only, `&&` = cross +
# auto, `&&&` = auto-only — casacore `MSAntennaParse::CrossOnly` /
# `AutoCorrAlso` / `AutoCorrOnly`), a physical baseline-length range
# (`'100~500m'` / `'<200m'` / `'>1km'`, from `ANTENNA.POSITION`, no `&`
# involved), a `;`-separated list of SEVERAL such `L & R` baseline-pair
# terms — each independently optionally `!`-negated, combined via a
# running accumulator (a positive term UNIONS in, a negated term
# INTERSECTS — see `_mssel_baseline_pred`'s own comment for the exact
# rule, read out of `MSAntennaParse::setTEN` and cross-checked live) —
# and casacore's real "blregexlist" — `/pattern/[,/pattern/...]` where
# each `pattern`'s body contains a literal `&`, FULL-matched against
# the whole `"name_i&name_j"` string per ordered antenna-index pair
# (see `_mssel_blregex_pred`). A plain comma instead *extends* one
# antenna-set list, even across `&` — `'DA01,DA02&DV01'` is ONE
# pair-term with a 2-antenna LHS, not two terms (verified live).
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

# Phase 146: `flagged` (0-based-id-indexed, `nothing` = no filtering)
# implements the spec-form-dependent `FLAG_ROW` exclusion found live
# against real casacore for FIELD/STATE selection (Phase 145): a bare
# id or `~`-range term is NEVER `FLAG_ROW`-filtered (real casacore
# routes it through `MSFieldParse::selectFieldIds`, a plain
# `TEN.in(ids)` with no `FLAG_ROW` check at all); a comparison
# (`<`/`>`/`<=`/`>=`) or name/regex/glob term IS (real casacore routes
# it through `MSFieldIndex`'s `matchFieldIDLT/GT/GTAndLT`/
# `matchFieldNameRegexOrPattern`, which check `!flagRow`). Only the
# `field`/`state` call sites pass a real `flagged` vector; every other
# `_mssel_idset` caller (baseline/spw/scan/array/obs) keeps the
# default `nothing` — confirmed (Phases 118-119) that antenna/spw
# selection never filters by `FLAG_ROW` in real casacore either (the
# equivalent check is commented out in `MSAntennaIndex.cc`/
# `MSSpwIndex.cc`).
_mssel_notflagged(s, ::Nothing) = s
_mssel_notflagged(s, flagged::AbstractVector{Bool}) =
    Set{Int}(i for i in s if !(1 <= i + 1 <= length(flagged) && flagged[i + 1]))

function _mssel_resolve(term::AbstractString, allids, n2i::AbstractDict;
                        flagged::Union{Nothing,AbstractVector{Bool}} = nothing)
    m = match(r"^(\d+)\s*~\s*(\d+)$", term)
    m !== nothing && return Set{Int}(parse(Int, m[1]):parse(Int, m[2]))
    m = match(r"^(>=|<=|>|<)\s*(-?\d+)$", term)
    if m !== nothing
        v = parse(Int, m[2]); op = m[1]
        s = Set{Int}(i for i in allids if op == ">" ? i > v :
                        op == ">=" ? i >= v : op == "<" ? i < v : i <= v)
        return _mssel_notflagged(s, flagged)
    end
    occursin(r"^-?\d+$", term) && return Set{Int}([parse(Int, term)])
    if length(term) >= 2 && startswith(term, "/") && endswith(term, "/")
        re = Regex(term[2:end-1])
        s = Set{Int}(reduce(vcat, (v for (k, v) in n2i if occursin(re, k)); init = Int[]))
        return _mssel_notflagged(s, flagged)
    end
    if occursin(r"[*?\[\]]", term)
        re = _glob_regex(term, false)
        s = Set{Int}(reduce(vcat, (v for (k, v) in n2i if occursin(re, k)); init = Int[]))
        return _mssel_notflagged(s, flagged)
    end
    s = haskey(n2i, term) ? Set{Int}(n2i[term]) : Set{Int}()
    return _mssel_notflagged(s, flagged)
end

function _mssel_idset(spec::AbstractString, allids, n2i::AbstractDict;
                      flagged::Union{Nothing,AbstractVector{Bool}} = nothing)
    pos = Set{Int}(); neg = Set{Int}(); anypos = false
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        isneg = startswith(term, "!")
        isneg && (term = strip(term[2:end]))
        s = _mssel_resolve(term, allids, n2i; flagged)
        isneg ? union!(neg, s) : (union!(pos, s); anypos = true)
    end
    base = anypos ? pos : Set{Int}(allids)
    return setdiff(base, neg)
end

# A regex baseline-pair LIST (casacore's real "blregexlist", Phase 119
# — the Phase 80 non-goal, misidentified as a `[name1,name2]` bracket
# form in Phase 115 and discarded there since real casacore rejects
# that; the actual mechanism, found by reading `MSAntennaGram.yy`/`.ll`
# + `MSAntennaParse::selectBLRegex`, is a `/…/`-delimited regex whose
# body contains a literal `&` — the lexer's own discriminator between a
# per-name `REGEX` and a `BLREGEX` — FULL-matched against the whole
# `"name_i&name_j"` string for every ORDERED pair (i,j) of antenna
# indices (self-pairs `i==j` included), one or more comma-separated
# such patterns OR'd together, each optionally negated by a LITERAL
# leading `^` inside the slashes (stripped before compiling — this is
# NOT the regex anchor; a real anchor isn't expressible here). VERIFIED
# live against real casacore: `/DA01&DV01/` matches only that exact
# ordered pair (the reverse `/DV01&DA01/` matches nothing on data
# stored the other way round); `/DA0[12]&DV01/` and `/.*&DV01/` both
# glob/wildcard the whole baseline string; `/^DA01&DV01/` negates just
# that one pattern; a comma list ORs multiple patterns (a negated one
# mixed with a plain one still ORs, not intersects); and the outer `!`
# this file already supports negates the WHOLE list's result — e.g.
# `!/DA01&DV01/,/DA01&DV02/` matches `NOT (A ∪ B)`, not `NOT A ∪ B` —
# confirmed by an exact row-count match to that arithmetic. Composes
# cleanly with the `;`-multi-term machinery below (no interaction with
# the Phase 115 `!`+`;` refusal, which is about a DIFFERENT ambiguity —
# `;`-joined whole `baseline` terms, not a single blregexlist's own
# internal comma list).
_mssel_is_regex_elem(p::AbstractString) =
    length(p) >= 2 && startswith(p, "/") && endswith(p, "/") && occursin('&', p[2:end-1])

function _mssel_is_blregexlist(spec::AbstractString)
    parts = _mssel_commas(spec)
    !isempty(parts) && all(p -> _mssel_is_regex_elem(strip(p)), parts)
end

function _mssel_blregex_pred(spec::AbstractString, names::Vector{String})
    n = length(names)
    match = falses(n, n)
    for raw in _mssel_commas(spec)
        inner = strip(raw)[2:end-1]              # strip the /.../ delimiters
        neg = startswith(inner, "^")
        re = Regex("^(?:" * (neg ? inner[2:end] : inner) * ")\$")
        for j in 1:n, i in 1:n
            (occursin(re, names[i] * "&" * names[j]) != neg) && (match[i, j] = true)
        end
    end
    return (a1, a2) -> (0 <= a1 < n && 0 <= a2 < n) && match[a1 + 1, a2 + 1]
end

# one `&`-joined (or bare) baseline-pair term -- no leading `!`, no `;`
# (both handled by `_mssel_baseline_pred`, below).
function _mssel_baseline_term_pred(spec::AbstractString, n2i::AbstractDict, allants;
                                   names::Union{Nothing,Vector{String}} = nothing)
    if _mssel_is_blregexlist(spec)
        names === nothing && throw(ArgumentError(
            "mscal.baseline: a regex baseline-pair list (\"$spec\") needs antenna " *
            "names, which aren't available here (no ANTENNA name table)"))
        return _mssel_blregex_pred(spec, names)
    end
    # count leading ampersands after the left antenna list to distinguish
    # `&` / `&&` / `&&&` (checked longest-first: `&&&` also contains `&&`)
    if occursin("&&&", spec)
        l = split(spec, "&&&"; limit = 2)[1]
        SL = _mssel_idset(strip(l), allants, n2i)
        return (a1, a2) -> a1 == a2 && a1 in SL
    elseif occursin("&&", spec)
        l, r = split(spec, "&&"; limit = 2)
        SL = _mssel_idset(strip(l), allants, n2i)
        SR = isempty(strip(r)) ? SL : _mssel_idset(strip(r), allants, n2i)
        return (a1, a2) -> (a1 in SL && a2 in SR) || (a1 in SR && a2 in SL)
    elseif occursin("&", spec)
        l, r = split(spec, "&"; limit = 2)
        SL = _mssel_idset(strip(l), allants, n2i)
        SR = isempty(strip(r)) ? SL : _mssel_idset(strip(r), allants, n2i)
        return (a1, a2) -> a1 != a2 && ((a1 in SL && a2 in SR) || (a1 in SR && a2 in SL))
    else
        S = _mssel_idset(spec, allants, n2i)
        return (a1, a2) -> a1 in S || a2 in S
    end
end

# the full spec: a `;`-separated list of `&`-baseline-pair terms, each
# independently optionally `!`-negated (casacore's own baseline-pair-
# list separator — NOT a comma, which instead *extends* one antenna-set
# list, even across `&`: `'DA01,DA02&DV01'` is ONE pair-term with a
# 2-antenna LHS, confirmed live to give the same row count as writing
# the union out by hand).
#
# Phase 120 (revisiting the Phase 115 refusal, now correctly): read
# `MSAntennaParse::setTEN` (`MSAntennaParse.cc:80-96`) in full — it
# maintains a running accumulator (`node_p`) across every `;`-joined
# term, evaluated left to right:
#   cond = <term's own match predicate>, negated first if the TERM
#          itself has a leading `!` (each term's `!` is entirely its
#          own — there is no separate "whole-spec" negation distinct
#          from the first term's own optional `!`, since casacore's
#          grammar only ever attaches `NOT` to ONE `baseline`
#          nonterminal, never to a `;`-chain as a whole)
#   1st term:      accumulator := cond
#   later term:    accumulator := negated ? (accumulator AND cond)
#                                          : (accumulator OR cond)
# i.e. a positive term UNIONS into the running result, a negated term
# INTERSECTS with it — genuinely well-defined, not a parser bug as
# Phase 115 concluded from too little evidence. VERIFIED against real
# casacore (`tableCommand`, this session) with 8+ combinations mixing
# negated and plain terms in every position (2 and 3 terms) — every
# predicted row count from the formula above matched exactly, including
# the two cases (`'!A&B;C&D'` → `NOT(A)`; `'A&B;!C&D'` → `A`) that
# Phase 115 mis-read as "the second term gets silently dropped" (both
# are in fact `NOT(A) ∪ C&D = NOT(A)` and `A ∩ NOT(C&D) = A`
# respectively, since the two clauses happen to be disjoint sets in
# every spec tested — the "same as the first term alone" appearance was
# coincidental algebra, not term-dropping).
function _mssel_baseline_pred(spec::AbstractString, n2i::AbstractDict, allants;
                              names::Union{Nothing,Vector{String}} = nothing)
    spec = strip(spec)
    if occursin(';', spec)
        terms = [t for t in strip.(split(spec, ';')) if !isempty(t)]
        isempty(terms) && return (a1, a2) -> false
        acc = nothing
        for t in terms
            tneg = startswith(t, "!")
            tbody = tneg ? strip(t[2:end]) : t
            raw = _mssel_baseline_term_pred(tbody, n2i, allants; names)
            cond = tneg ? ((a1, a2) -> !raw(a1, a2)) : raw
            acc = acc === nothing ? cond :
                  tneg ? _mssel_and2(acc, cond) : _mssel_or2(acc, cond)
        end
        return acc
    end
    neg = startswith(spec, "!")
    body = neg ? strip(spec[2:end]) : spec
    pred = _mssel_baseline_term_pred(body, n2i, allants; names)
    return neg ? (a1, a2) -> !pred(a1, a2) : pred
end

_mssel_and2(p, q) = (a1, a2) -> p(a1, a2) && q(a1, a2)
_mssel_or2(p, q) = (a1, a2) -> p(a1, a2) || q(a1, a2)

# a bare baseline-length range/bound, no `&` involved (casacore's
# `blengthlist` — `LT`/`GT`/`a-b`, unit `m`/`km`, default `m`).
_mssel_is_blength(spec::AbstractString) =
    !occursin('&', spec) && occursin(r"^(?:[<>]|.*[-~])\s*[\d.]+\s*k?m\s*$"i, spec)

function _mssel_blength_pred(spec::AbstractString)
    ranges = Tuple{Float64,Float64}[]
    for raw in _mssel_commas(spec)
        term = strip(raw)
        isempty(term) && continue
        um = match(r"(k?m)\s*$"i, term)
        scale = (um !== nothing && lowercase(um[1]) == "km") ? 1e3 : 1.0
        body = strip(um === nothing ? term : term[1:prevind(term, um.offset)])
        num(s) = parse(Float64, strip(s)) * scale
        if startswith(body, ">")
            push!(ranges, (num(body[2:end]), Inf))
        elseif startswith(body, "<")
            push!(ranges, (-Inf, num(body[2:end])))
        else
            m = match(r"^(.+?)\s*[-~]\s*(.+)$", body)
            m === nothing && throw(ArgumentError(
                "mscal.baseline: bad length range \"$term\""))
            push!(ranges, (num(m[1]), num(m[2])))
        end
    end
    return (bl) -> _mssel_inany(bl, ranges)
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
        neg = startswith(strip(spec), "!")
        body = neg ? strip(strip(spec)[2:end]) : strip(spec)
        if _mssel_is_blength(body)
            pos = column(readtable(subs["ANTENNA"]), "POSITION")[:]
            blen(i1, i2) = hypot((Float64.(pos[i1 + 1]) .- Float64.(pos[i2 + 1]))...)
            lpred = _mssel_blength_pred(body)
            return Bool[(neg ? !lpred(blen(a1[i], a2[i])) : lpred(blen(a1[i], a2[i])))
                        for i in 1:n]
        end
        antnames = String.(column(readtable(subs["ANTENNA"]), "NAME")[:])
        n2i = _mssel_names_to_ids(antnames)
        pred = _mssel_baseline_pred(spec, n2i, 0:(length(antnames) - 1); names = antnames)
        return Bool[pred(a1[i], a2[i]) for i in 1:n]
    elseif fn == "field"
        # Phase 145/146: `mscal.field()`/`mscal.state()` vs `FLAG_ROW`
        # is SPEC-FORM-DEPENDENT in real casacore, confirmed live
        # against real `tableCommand` on a FIELD-row-0-flagged fixture
        # (see the Phase 145 CHANGELOG entry for the full writeup): a
        # bare id (`'0'`) or `~`-range (`'0~0'`) spec does NOT exclude
        # a flagged field (routes through `MSFieldParse::
        # selectFieldIds`, `MSFieldParse.cc:68-79` -- a plain
        # `TEN.in(ids)`, no `FLAG_ROW` check); a comparison
        # (`'<N'`/`'>N'`) or name/pattern spec (`'3C286'`) DOES (routes
        # through `MSFieldIndex::matchFieldIDLT/GT/GTAndLT`/
        # `matchFieldNameRegexOrPattern`, which check `!flagRow`,
        # `MSFieldIndex.cc:103,224`). `MSStateIndex.cc` has the
        # identical structure (`.cc:104,130`) -- inferred by symmetry
        # for STATE, not independently live-tested. `_mssel_idset`'s
        # `flagged` kwarg implements exactly this per-term-form split;
        # baseline/spw/scan/array/obs pass no `flagged` (Phases 118-119
        # confirmed those never filter by `FLAG_ROW` in real casacore).
        _need("FIELD_ID")
        fid = Int.(column(t, "FIELD_ID")[:])
        fldtab = haskey(subs, "FIELD") ? readtable(subs["FIELD"]) : nothing
        nf = fldtab === nothing ? maximum(fid; init = -1) + 1 : nrow(fldtab)
        flagged = fldtab !== nothing && "FLAG_ROW" in Set(columnnames(fldtab)) ?
                  Bool.(column(fldtab, "FLAG_ROW")[:]) : nothing
        S = _mssel_idset(spec, 0:(nf - 1), _sub("FIELD", "NAME"); flagged)
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
        statetab = fn == "state" && haskey(subs, "STATE") ? readtable(subs["STATE"]) : nothing
        n2i = statetab !== nothing && "OBS_MODE" in Set(columnnames(statetab)) ?
              _mssel_names_to_ids(column(statetab, "OBS_MODE")[:]) : Dict{String,Vector{Int}}()
        # Phase 145/146: STATE has the identical FLAG_ROW structure as
        # FIELD (see the `field` branch's comment above) -- inferred by
        # source symmetry, applied here too.
        flagged = statetab !== nothing && "FLAG_ROW" in Set(columnnames(statetab)) ?
                  Bool.(column(statetab, "FLAG_ROW")[:]) : nothing
        S = _mssel_idset(spec, sort(unique(ids)), n2i; flagged)
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
#   t0            single time  -> |TIME - t0| <= dT
#   t0~t1         range, exclusive edges
#   [t0~t1]       range, edge-inclusive (|TIME-edge| < dT counts)
#   N[t0~t1]      range, edge buffer N seconds
#   t0+dur        range t0 .. t0+dur   (dur = a time string past the MJD epoch)
#   >t0  <t1      open bounds
# Each time is `[Y/[M/[D/]]][h:[m:[s]]]` with any component `*` (wildcard);
# a missing / `*` component defaults to the first UNFLAGGED (`FLAG_ROW`)
# MAIN row's own TIME (t1 of a `~` range instead inherits from t0), or
# row 1 if every row is flagged or there is no `FLAG_ROW` column (a
# deliberate MeasurementSets extension — real casacore throws in that
# case instead). Bare number = MJD days.
#
# Phase 121 (`mscal.time`, confirmed a direct pass-through to real
# casacore's own `msTimeGramParseCommand`, `UDFMSCal.cc:479-491`, the
# same discipline as Phases 119/120's `mscal.baseline`): read
# `MSTimeGram.yy`/`.ll` in full — this grammar was ALREADY fully
# implemented in Phase 94, no missing syntax found (every production —
# single/range/edge-bracket/duration/bound/wildcard/comma-list — maps
# to something above). Reading `MSTimeParse::getDefaults`
# (`MSTimeParse.cc:114-168`) DID find two real bugs, now fixed: `dT`
# (the tolerance in every form above) is `defaultExposure/2`, and
# `defaultExposure` is the DEFAULT ROW's own `EXPOSURE`
# (`exposure(firstLogicalRow,"s")`) — NOT a mean over every row's
# `EXPOSURE`, which Phase 94 originally used; and the "default row"
# itself is the FIRST UNFLAGGED row, not row 1 unconditionally.
#
# Phase 128 (wildcard + edge-buffer forms specifically): confirmed the
# `*` wildcard is a real, first-class lexer token (`MSTimeGram.ll`'s
# `"*" { return STAR; }`, `MSTimeGram.yy:131` `wildNumber: STAR {$$=-1}`,
# used per-field in `yFields`/`tFields`) — identical to an omitted
# field, exactly what `_mstime_fields`'s `_f` already did, so no bug
# there. Confirmed `N[t0~t1]`'s buffer maps to casacore's own literal
# `edgeWidth` (`MSTimeParse.cc:262`, `selectTimeRange`) with **no /2**
# — unlike the bracket-only `[t0~t1]` form, which uses
# `defaultExposure/2` — our `buf = m[1] === nothing ? dT : parse(...)`
# already matched this exactly; fixed a smaller, real gap found while
# re-deriving it from the grammar: the buffer number is casacore's
# `FNUMBER` (`INT | INT. | .INT | INT.INT`), and the regex only
# accepted the `INT` / `INT.INT` spellings, rejecting `.5[...]` /
# `5.[...]`.
#
# A LIVE oracle for these forms was investigated and found blocked by
# two independent, real issues (neither fixable here): (1) the
# committed `sample.ms` fixture predates the Phase 121 `FLAG_CATEGORY`
# `CATEGORY`-keyword fix AND is fully flagged, and opening a *writable*
# copy so casacore's own `addCat()` self-heal can fire (`Update` table
# mode) makes real casacore's `MSTimeParse::getDefaults()` **segfault**
# outright (not throw) when resolving a wildcard default against an
# all-`FLAG_ROW`-true table — a genuine crash bug in this casacore
# build, live-verified, filed here as a finding, not something this
# package can work around. (2) a `create_ms`-built synthetic MS gets
# past the `CATEGORY` keyword (Phase 121's own fix) but still fails
# `MSTableImpl::validate`'s measures/units keyword audit — the exact
# "genuinely large... deliberately out of scope" gap Phase 121 already
# identified and declined to chase. So the `*`/`N[...]` forms below are
# verified the same way Phase 121's own default-row/dT fix was: hand-
# built fixtures + direct `_mssel_time` calls, the logic itself already
# pinned unambiguously by the grammar/source citations above.

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
    # casacore's own "default row" (`MSTimeParse::getDefaults`) is the
    # FIRST UNFLAGGED row (`FLAG_ROW`) -- falling back to row 1 if every
    # row is flagged is a deliberate MeasurementSets extension: real
    # casacore *throws* in that case ("No logical row zero found"),
    # which would make `mscal.time` unusable on a fully-flagged MS (a
    # real, common state -- the committed test fixture is one).
    r0 = "FLAG_ROW" in cn ? something(findfirst(!, Bool.(column(t, "FLAG_ROW")[:])), 1) : 1
    d0 = MJD_EPOCH + Dates.Millisecond(round(Int, tm[r0] * 1000))   # default row's time
    def = (Dates.year(d0), Dates.month(d0), Dates.day(d0),
           Dates.hour(d0), Dates.minute(d0), Dates.second(d0))
    epdef = (1858, 11, 17, 0, 0, 0.0)
    # dT = half the DEFAULT ROW's OWN EXPOSURE (casacore's
    # `defaultExposure = exposure(firstLogicalRow,"s")` -- NOT a mean
    # over all rows, verified by reading `MSTimeParse.cc:163-166`); the
    # 0.1 s fallback matches casacore's own no-EXPOSURE-source case.
    dT = ("EXPOSURE" in cn ? Float64(column(t, "EXPOSURE")[r0]) : 0.1) / 2

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
        elseif (m = match(r"^(?:(\d+\.\d+|\d+\.|\.\d+|\d+)\s*)?\[\s*(.+?)\s*~\s*(.+?)\s*\]$", term)) !== nothing
            # the buffer literal is casacore's own `FNUMBER` production
            # (`MSTimeGram.ll`: `INT | INT. | .INT | INT.INT`) -- the
            # bare-`\d+(?:\.\d+)?` form this regex had before Phase 128
            # rejected the `.5[...]` / `5.[...]` spellings real TaQL
            # accepts.
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
#
# Phase 143 finding: read `ms/MSSel/MSCorrParse.cc` (the code
# `msCorrGramParseCommand`/`mscal.corr()` actually calls,
# `derivedmscal/DerivedMC/UDFMSCal.cc:470-474`) to re-verify this
# against source. `MSCorrParse::selectCorrType` builds the SAME
# selection condition this package computes (`DATA_DESC_ID IN` the set
# of data-desc ids whose `POLARIZATION.CORR_TYPE` contains the
# requested code, via `MSDataDescIndex::matchPolId`/
# `MSPolarizationIndex::matchCorrType`) -- confirming the core
# selection logic here is correct. But the real function has a genuinely
# alarming, undocumented SIDE EFFECT along the way: it reopens the very
# MS being queried in `Table::Update` (writable) mode and unconditionally
# `addColumn`s (removing any existing one first) a `"SELECTED_DATA"`
# column, then copies a slice of `DATA` into it — as a side effect of
# evaluating what should be a read-only WHERE-clause predicate. This
# means `mscal.corr()` / a native `WHERE CORR = 'RR'` selection against
# a real, writable MS in real casacore genuinely MUTATES the MS on disk.
# `MSFeedParse.cc` (the `mscal.feed()` counterpart) has no such pattern
# — this is specific to `MSCorrParse`. This package's `mscal.corr()` is
# a pure, read-only, in-memory `Bool` computation with no such side
# effect — a deliberate and CORRECT divergence; replicating casacore's
# destructive behaviour here would be a regression, not a fix.

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

