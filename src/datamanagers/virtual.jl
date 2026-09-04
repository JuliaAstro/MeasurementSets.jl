# Virtual column engines:
#   ScaledArrayEngine<S,T>, ScaledComplexData<S,T>, CompressFloat,
#   CompressComplex, CompressComplexSD, MappedArrayEngine<Complex,DComplex>.
#
# Mirrors casacore/tables/DataMan/VirtColEng.cc, BaseMappedArrayEngine.tcc,
# ScaledArrayEngine.tcc, ScaledComplexData.tcc, CompressComplex.cc,
# CompressFloat.cc, MappedArrayEngine.tcc.
#
# A virtual engine stores nothing itself: `VirtualColumnEngine::flush`
# returns False, so in `table.dat`'s ColumnSet it contributes a
# `(dmType, seqnr)` entry and an empty per-DM block (`uInt 0`), exactly
# like a TiledShapeStMan's block.  It maps a *virtual* column (what the
# user sees) onto a hidden *stored* column of scaled integers bound to a
# real storage manager, applying `virtual = stored * scale + offset` on
# read.  All configuration lives in `_`-prefixed keywords on the virtual
# column's keyword set (already parsed into `ColumnDesc.keywords`):
#
#   _BaseMappedArrayEngine_Name          stored column name
#   _<Engine>_Scale / _Offset            fixed scale/offset value
#   _<Engine>_ScaleName / _OffsetName    per-row scale/offset scalar columns
#   _<Engine>_FixedScale / _FixedOffset  (ScaledArray/ScaledComplex)
#   _<Engine>_Fixed / _AutoScale         (Compress*)
#   _CompressComplex_Type                "CompressComplex" | "CompressComplexSD"
#
# Rounding on write: ScaledArray/ScaledComplex truncate toward zero
# (C++ `T(x)`); Compress* round half away from zero
# (`floor(x+0.5)` / `ceil(x-0.5)`), clamped.  1-based rows.

# --- constants (casacore CompressComplex.cc / CompressFloat.cc) ------
const ENG_C_HIWORD       = 65536             # CompressComplex/SD: `stored = s_re*65536 + s_im`
const ENG_C_WRAP         = ENG_C_HIWORD ÷ 2  # 32768: imag-wrap threshold / |real NaN sentinel|
const ENG_ROUND_HALF     = 0.5              # round half away from zero: `floor(x+0.5)` / `ceil(x-0.5)`
const ENG_MIDPOINT       = 2                # autoScale offset = (min + max) / 2
const ENG_UNIT_SCALE     = 1.0f0            # scale written to keywords when autoScale
const ENG_ZERO_OFFSET    = 0.0f0
const ENG_AUTOSCALE_DIV  = 65534            # autoScale: scale = (max - min) / 65534

const ENG_NAN_C          = Int32(-ENG_C_WRAP) * Int32(ENG_C_HIWORD)  # CompressComplex/SD sentinel
const ENG_NAN_F          = Int16(-ENG_C_WRAP)                        # CompressFloat sentinel
const ENG_C_PART_MAX     = ENG_C_WRAP - 1                            # 32767: CompressComplex per-part clamp
const ENG_SD_REAL_MAX    = ENG_C_WRAP - 1                            # CompressComplexSD real clamp (odd)
const ENG_SD_IMAG_MULT   = 2                                         # SD odd: imag scaled by `scale*2`
const ENG_SD_IMAG_HI     = ENG_C_WRAP ÷ ENG_SD_IMAG_MULT - 1         # 16383: SD imag clamp (odd)
const ENG_SD_IMAG_LO     = -(ENG_SD_IMAG_HI + 1)                     # -16384
const ENG_SD_REAL_BITS   = ENG_C_WRAP                                # SD even: `fullScale = scale/32768`
const ENG_SD_EVEN_HI     = Float64(ENG_C_WRAP) * ENG_SD_REAL_BITS - 1  # SD real clamp (even)
const ENG_SD_EVEN_LO     = -Float64(ENG_C_WRAP) * ENG_SD_REAL_BITS

const _ENGINE_PREFIX = Dict(
    :scaledarray       => "_ScaledArrayEngine_",
    :scaledcomplex     => "_ScaledComplexData_",
    :compressfloat     => "_CompressFloat_",
    :compresscomplex   => "_CompressComplex_",
    :compresscomplexsd => "_CompressComplex_",   # SD reuses the CompressComplex prefix
)

# --- reader -------------------------------------------------------

mutable struct VirtualEngine
    table::Table
    kind::Symbol                  # :scaledarray|:scaledcomplex|:compressfloat|
                                  # :compresscomplex|:compresscomplexsd|:mapped
    vdesc::ColumnDesc             # the virtual column
    storedname::String
    autoscale::Bool
    fixed_scale::Bool
    fixed_offset::Bool
    scale::Any                    # fixed value (Float/Double/Complex/DComplex)
    offset::Any
    scalename::String
    offsetname::String
    stored::Any                   # Column, opened lazily
    scalecol::Any
    offsetcol::Any
end

# The three Compress* engines have a fixed, non-templated on-disk name.
DATAMANAGERS["CompressFloat"]     = VirtualEngine
DATAMANAGERS["CompressComplex"]   = VirtualEngine
DATAMANAGERS["CompressComplexSD"] = VirtualEngine

# The other three are casacore C++ template instantiations -- their on-disk
# name (e.g. `"ScaledArrayEngine<Float,Int>"`) depends on the scalar types
# the column was created with, so there's no fixed set of exact strings to
# enumerate; matched by prefix pattern instead.
DATAMANAGER_PATTERNS[r"^ScaledArrayEngine<"]  = VirtualEngine
DATAMANAGER_PATTERNS[r"^ScaledComplexData<"]  = VirtualEngine
DATAMANAGER_PATTERNS[r"^MappedArrayEngine<"]  = VirtualEngine

_is_engine_dm(name::AbstractString) =
    startswith(name, "ScaledArrayEngine") || startswith(name, "ScaledComplexData") ||
    startswith(name, "MappedArrayEngine") ||
    name in ("CompressFloat", "CompressComplex", "CompressComplexSD")

function _engine_kind(name::AbstractString, kw::Record)
    startswith(name, "ScaledArrayEngine") && return :scaledarray
    startswith(name, "ScaledComplexData") && return :scaledcomplex
    startswith(name, "MappedArrayEngine") && return :mapped
    name == "CompressFloat" && return :compressfloat
    get(kw, "_CompressComplex_Type", name) == "CompressComplexSD" ?
        :compresscomplexsd : :compresscomplex
end

# the engine type string as it appears in the ColumnSet DM list
function _engine_typestr(kind::Symbol, vtype::CasaType, stored_type::CasaType)
    kind === :compressfloat     && return "CompressFloat"
    kind === :compresscomplex   && return "CompressComplex"
    kind === :compresscomplexsd && return "CompressComplexSD"
    sid = _TYPEID[vtype]; tid = _TYPEID[stored_type]
    kind === :mapped        && return "MappedArrayEngine<$sid,$tid>"
    kind === :scaledarray   && return "ScaledArrayEngine<$sid,$tid>"
    kind === :scaledcomplex && return "ScaledComplexData<$sid,$tid>"
    error("unknown engine kind $kind")
end

function Base.open(::Type{VirtualEngine}, t::Table, dm::DataManagerInfo)
    vi = findfirst(c -> c.sequ == dm.sequ, t.desc.columns)
    vi === nothing &&
        error("virtual engine \"$(dm.name)\" (seq $(dm.sequ)) has no bound column")
    vdesc = t.desc.columns[vi]
    kw = vdesc.keywords
    kind = _engine_kind(dm.name, kw)
    storedname = String(get(kw, "_BaseMappedArrayEngine_Name", ""))
    isempty(storedname) &&
        error("virtual column \"$(vdesc.name)\": missing _BaseMappedArrayEngine_Name keyword")

    e = VirtualEngine(t, kind, vdesc, storedname, false, true, true,
                      nothing, nothing, "", "", nothing, nothing, nothing)
    kind === :mapped && return e

    pfx = _ENGINE_PREFIX[kind]
    if kind in (:compressfloat, :compresscomplex, :compresscomplexsd)
        fixed = Bool(get(kw, pfx * "Fixed", true))
        e.fixed_scale = e.fixed_offset = fixed
        e.autoscale = Bool(get(kw, pfx * "AutoScale", false))
        e.scale  = Float32(get(kw, pfx * "Scale", ENG_UNIT_SCALE))
        e.offset = Float32(get(kw, pfx * "Offset", ENG_ZERO_OFFSET))
        e.scalename  = String(get(kw, pfx * "ScaleName", ""))
        e.offsetname = String(get(kw, pfx * "OffsetName", ""))
    else                                                # scaledarray / scaledcomplex
        e.fixed_scale  = Bool(get(kw, pfx * "FixedScale", true))
        e.fixed_offset = Bool(get(kw, pfx * "FixedOffset", true))
        e.scale  = get(kw, pfx * "Scale", nothing)
        e.offset = get(kw, pfx * "Offset", nothing)
        e.scalename  = String(get(kw, pfx * "ScaleName", ""))
        e.offsetname = String(get(kw, pfx * "OffsetName", ""))
    end
    return e
end

_eng_stored(e::VirtualEngine)  =
    e.stored === nothing ? (e.stored = column(e.table, e.storedname)) : e.stored
_eng_scalecol(e::VirtualEngine) =
    e.scalecol === nothing ? (e.scalecol = column(e.table, e.scalename)) : e.scalecol
_eng_offsetcol(e::VirtualEngine) =
    e.offsetcol === nothing ? (e.offsetcol = column(e.table, e.offsetname)) : e.offsetcol

_row_scale(e::VirtualEngine, row) =
    (e.fixed_scale && !e.autoscale) ? e.scale : _eng_scalecol(e)[row]
_row_offset(e::VirtualEngine, row) =
    (e.fixed_offset && !e.autoscale) ? e.offset : _eng_offsetcol(e)[row]

# round half away from zero (casacore `floor(x+0.5)` / `ceil(x-0.5)`)
_rha(x) = x < 0 ? ceil(Float64(x) - ENG_ROUND_HALF) : floor(Float64(x) + ENG_ROUND_HALF)
_round_clamp(x, lo, hi) = Int(clamp(_rha(x), lo, hi))

# --- decode (inverse transform) --------------------------------

function _decode(kind::Symbol, st, scale, offset, J::Type)
    kind === :mapped        && return convert(Array{J}, st)
    kind === :scaledarray   && return _decode_scaled(st, scale, offset, J)
    kind === :scaledcomplex && return _decode_scaledcomplex(st, scale, offset, J)
    kind === :compressfloat && return _decode_cfloat(st, Float32(scale), Float32(offset), J)
    kind === :compresscomplex   && return _decode_ccomplex(st, Float32(scale), Float32(offset), J)
    kind === :compresscomplexsd && return _decode_ccomplexsd(st, Float32(scale), Float32(offset), J)
    error("unknown engine kind $kind")
end

function _decode_scaled(st::AbstractArray, scale, offset, J::Type)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        out[i] = J(muladd(st[i], scale, offset))
    end
    return out
end

function _decode_scaledcomplex(st::AbstractArray, scale, offset, J::Type)
    R = real(J)
    sre, sim = R(real(scale)), R(imag(scale))
    ore, oim = R(real(offset)), R(imag(offset))
    vsh = size(st)[2:end]
    out = Array{J}(undef, vsh)
    @inbounds for i in eachindex(out)
        out[i] = J(muladd(R(st[2i-1]), sre, ore), muladd(R(st[2i]), sim, oim))
    end
    return out
end

function _decode_cfloat(st::AbstractArray{<:Integer}, scale::Float32, offset::Float32, J::Type)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        out[i] = st[i] == -ENG_C_WRAP ? J(NaN) : J(muladd(Float32(st[i]), scale, offset))
    end
    return out
end

function _decode_ccomplex(st::AbstractArray{<:Integer}, scale::Float32, offset::Float32, J::Type)
    R = real(J)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        v = Int(st[i])
        r = div(v, ENG_C_HIWORD)                    # trunc toward zero, as C++ `/`
        if r == -ENG_C_WRAP
            out[i] = J(NaN, NaN)
        else
            im = v - r * ENG_C_HIWORD
            if im < -ENG_C_WRAP
                r -= 1; im += ENG_C_HIWORD
            elseif im >= ENG_C_WRAP
                r += 1; im -= ENG_C_HIWORD
            end
            out[i] = J(R(muladd(r, scale, offset)), R(muladd(im, scale, offset)))
        end
    end
    return out
end

function _decode_ccomplexsd(st::AbstractArray{<:Integer}, scale::Float32, offset::Float32, J::Type)
    R = real(J)
    fullScale = scale / Float32(ENG_SD_REAL_BITS)
    imagScale = scale * Float32(ENG_SD_IMAG_MULT)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        v = Int(st[i])
        if iseven(v)
            out[i] = J(R(muladd(v >> 1, fullScale, offset)), zero(R))
        else
            r = div(v, ENG_C_HIWORD)
            if r == -ENG_C_WRAP
                out[i] = J(NaN, NaN)
            else
                im = v - r * ENG_C_HIWORD
                if im < -ENG_C_WRAP
                    r -= 1; im += ENG_C_HIWORD
                elseif im >= ENG_C_WRAP
                    r += 1; im -= ENG_C_HIWORD
                end
                im >>= 1
                out[i] = J(R(muladd(r, scale, offset)), R(muladd(im, imagScale, offset)))
            end
        end
    end
    return out
end

# --- Column dispatch entry points -----------------------------
#
# A virtual engine binds exactly one (virtual) column per instance, so
# the DM-local `index`/`cols` that every other data manager's `getcell`/
# `getcolumn` method takes (for dispatch-signature uniformity -- see
# `column.jl`) are always `(1, 1)` here and unused.

function getcell(e::VirtualEngine, ::Integer, ::ColumnDesc, row::Integer, ::Integer)
    st = Array(_eng_stored(e)[row])
    return _decode(e.kind, st, _row_scale(e, row), _row_offset(e, row),
                   juliatype(e.vdesc.type))
end

getcolumn(e::VirtualEngine, index::Integer, c::ColumnDesc, nrow::Integer, cols::Integer) =
    [getcell(e, index, c, r, cols) for r in 1:nrow]

# =====================  writer  ==================================

# per-row scale/offset for autoScale (casacore findMinMax + makeScaleOffset)
function _auto_scale_offset(cell::AbstractArray)
    mn = Inf64; mx = -Inf64; seen = false
    for x in cell
        re = Float64(real(x))
        isfinite(re) || continue
        cplx = x isa Complex
        im = cplx ? Float64(imag(x)) : 0.0
        (cplx && !isfinite(im)) && continue
        seen = true
        re < mn && (mn = re); re > mx && (mx = re)
        if cplx && im != 0
            im < mn && (mn = im); im > mx && (mx = im)
        end
    end
    seen || return (ENG_ZERO_OFFSET, ENG_ZERO_OFFSET)
    mn == mx && return (ENG_UNIT_SCALE, Float32((mn + mx) / ENG_MIDPOINT))
    return (Float32((mx - mn) / ENG_AUTOSCALE_DIV), Float32((mx + mn) / ENG_MIDPOINT))
end

_eng_stored_eltype(kind::Symbol, stored_type::CasaType) =
    kind === :compressfloat ? Int16 :
    kind in (:compresscomplex, :compresscomplexsd) ? Int32 :
    kind === :mapped ? ComplexF64 : juliatype(stored_type)

# --- per-kind pack (inverse transform) ------------------------

function _enc_scaled(cell::AbstractArray, scale, offset, T::Type)
    out = Array{T}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        out[i] = trunc(T, (cell[i] - offset) / scale)      # C++ static_cast: toward zero
    end
    return out
end

function _enc_scaledcomplex(cell::AbstractArray, scale, offset, T::Type)
    sre, sim = real(scale), imag(scale)
    ore, oim = real(offset), imag(offset)
    out = Array{T}(undef, 2, size(cell)...)
    @inbounds for i in eachindex(cell)
        z = cell[i]
        out[2i-1] = trunc(T, (real(z) - ore) / sre)
        out[2i]   = trunc(T, (imag(z) - oim) / sim)
    end
    return out
end

function _enc_cfloat(cell::AbstractArray, scale::Float32, offset::Float32)
    out = Array{Int16}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        v = Float32(cell[i])
        out[i] = (!isfinite(v) || scale == 0) ? ENG_NAN_F :
                 Int16(_round_clamp((v - offset) / scale, -ENG_C_PART_MAX, ENG_C_PART_MAX))
    end
    return out
end

function _enc_ccomplex(cell::AbstractArray, scale::Float32, offset::Float32)
    out = Array{Int32}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        z = ComplexF32(cell[i])
        if !isfinite(real(z)) || !isfinite(imag(z)) || scale == 0
            out[i] = ENG_NAN_C
        else
            sre = _round_clamp((real(z) - offset) / scale, -ENG_C_PART_MAX, ENG_C_PART_MAX)
            sim = _round_clamp((imag(z) - offset) / scale, -ENG_C_PART_MAX, ENG_C_PART_MAX)
            out[i] = Int32(sre * ENG_C_HIWORD + sim)
        end
    end
    return out
end

function _enc_ccomplexsd(cell::AbstractArray, scale::Float32, offset::Float32)
    fullScale = scale / Float32(ENG_SD_REAL_BITS)
    imagScale = scale * Float32(ENG_SD_IMAG_MULT)
    out = Array{Int32}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        z = ComplexF32(cell[i])
        if !isfinite(real(z)) || !isfinite(imag(z)) || scale == 0
            out[i] = ENG_NAN_C
        elseif imag(z) == 0                                  # even LSB flags imag == 0
            s = _round_clamp((real(z) - offset) / fullScale, ENG_SD_EVEN_LO, ENG_SD_EVEN_HI)
            out[i] = Int32(s << 1)
        else                                                 # odd LSB flags imag != 0
            sre = _round_clamp((real(z) - offset) / scale, -ENG_SD_REAL_MAX, ENG_SD_REAL_MAX)
            sim = _round_clamp((imag(z) - offset) / imagScale, ENG_SD_IMAG_LO, ENG_SD_IMAG_HI)
            out[i] = Int32(sre * ENG_C_HIWORD + (sim << 1) + 1)
        end
    end
    return out
end

# --- keyword record ------------------------------------------

_kwpush!(r::Record, name, t::CasaType, v) =
    (push!(r.names, name); push!(r.types, t); push!(r.values, v); push!(r.comments, ""))

function _engine_keywords(kind::Symbol, vtype::CasaType, storedname, scale, offset,
                          scalename, offsetname, autoscale::Bool)
    r = Record()
    _kwpush!(r, "_BaseMappedArrayEngine_Name", TpString, String(storedname))
    kind === :mapped && return r
    pfx = _ENGINE_PREFIX[kind]

    if kind in (:compressfloat, :compresscomplex, :compresscomplexsd)
        fixed = !autoscale
        _kwpush!(r, pfx * "Scale",  TpFloat, Float32(fixed ? scale  : ENG_UNIT_SCALE))
        _kwpush!(r, pfx * "Offset", TpFloat, Float32(fixed ? offset : ENG_ZERO_OFFSET))
        _kwpush!(r, pfx * "ScaleName",  TpString, fixed ? "" : String(scalename))
        _kwpush!(r, pfx * "OffsetName", TpString, fixed ? "" : String(offsetname))
        _kwpush!(r, pfx * "Fixed",     TpBool, fixed)
        _kwpush!(r, pfx * "AutoScale", TpBool, autoscale)
        kind !== :compressfloat &&
            _kwpush!(r, "_CompressComplex_Type", TpString,
                     kind === :compresscomplexsd ? "CompressComplexSD" : "CompressComplex")
    else                                                # scaledarray / scaledcomplex
        S = kind === :scaledcomplex ?
            (vtype == TpDComplex ? TpDComplex : TpComplex) :
            (vtype == TpDouble ? TpDouble : TpFloat)
        SJ = juliatype(S)
        _kwpush!(r, pfx * "Scale",  S, SJ(scale))
        _kwpush!(r, pfx * "Offset", S, SJ(offset))
        _kwpush!(r, pfx * "ScaleName",   TpString, "")
        _kwpush!(r, pfx * "OffsetName",  TpString, "")
        _kwpush!(r, pfx * "FixedScale",  TpBool, true)
        _kwpush!(r, pfx * "FixedOffset", TpBool, true)
    end
    return r
end

"""
    encode_engine(kind, vdata, vtype; scale, offset, autoscale, stored_type,
                  storedname, scalename, offsetname)
        -> (storeddata, keywords, scaledata, offsetdata)

Pack the virtual column `vdata` (a vector of numeric arrays) into stored
integers.  `scaledata` / `offsetdata` are `Vector{Float32}` (one per row)
when `autoscale`, else `nothing`.  `keywords` is the `_<Engine>_*` record
to merge onto the virtual `ColumnDesc`.
"""
function encode_engine(kind::Symbol, vdata::AbstractVector, vtype::CasaType;
                       scale=nothing, offset=nothing, autoscale::Bool=false,
                       stored_type::CasaType=TpInt,
                       storedname::AbstractString="", scalename::AbstractString="",
                       offsetname::AbstractString="")
    n = length(vdata)
    T = _eng_stored_eltype(kind, stored_type)

    if kind === :mapped
        stored = Any[convert(Array{ComplexF64}, Array(vdata[r])) for r in 1:n]
        return stored, _engine_keywords(kind, vtype, storedname, 0, 0, "", "", false), nothing, nothing
    end

    (kind in (:scaledarray, :scaledcomplex) && autoscale) &&
        error("autoscale is only supported for CompressFloat / CompressComplex[SD]")

    if autoscale
        sc = Vector{Float32}(undef, n)
        of = Vector{Float32}(undef, n)
        stored = Vector{Any}(undef, n)
        for r in 1:n
            cell = Array(vdata[r])
            sc[r], of[r] = _auto_scale_offset(cell)
            s = sc[r] == 0 ? ENG_UNIT_SCALE : sc[r]
            stored[r] = _enc_dispatch(kind, cell, s, of[r], T)
        end
        kw = _engine_keywords(kind, vtype, storedname, ENG_UNIT_SCALE, ENG_ZERO_OFFSET,
                              scalename, offsetname, true)
        return stored, kw, sc, of
    end

    scale === nothing && error("encode_engine: fixed engine needs a `scale`")
    off = offset === nothing ? zero(scale) : offset
    stored = Any[_enc_dispatch(kind, Array(vdata[r]), scale, off, T) for r in 1:n]
    kw = _engine_keywords(kind, vtype, storedname, scale, off, "", "", false)
    return stored, kw, nothing, nothing
end

_enc_dispatch(kind, cell, scale, offset, T) =
    kind === :scaledarray       ? _enc_scaled(cell, scale, offset, T) :
    kind === :scaledcomplex     ? _enc_scaledcomplex(cell, scale, offset, T) :
    kind === :compressfloat     ? _enc_cfloat(cell, Float32(scale), Float32(offset)) :
    kind === :compresscomplex   ? _enc_ccomplex(cell, Float32(scale), Float32(offset)) :
    kind === :compresscomplexsd ? _enc_ccomplexsd(cell, Float32(scale), Float32(offset)) :
    error("unknown engine kind $kind")
