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
#
# Which engine a column is bound to is a singleton type (below), not a
# `Symbol` -- `_decode`/`_encode` (one method per engine, dispatched on
# that type) do the actual array transform; there is no separately-named
# `_decode_<engine>` helper for multiple dispatch to pick between, the
# `_decode(::SomeEngine, ...)` method *is* that engine's transform.

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

# --- engine kind: singleton types, one per casacore engine -----------
#
# `ScaledKind` / `CompressKind` group the two families that share an
# initialisation / keyword-writing shape (see `_init!` / `_push_kw!`
# below); `Mapped` (a plain cast, no scale/offset at all) stands alone.
abstract type EngineKind end
abstract type ScaledKind   <: EngineKind end
abstract type CompressKind <: EngineKind end

struct Mapped            <: EngineKind end
struct ScaledArray       <: ScaledKind end
struct ScaledComplex     <: ScaledKind end
struct CompressFloat     <: CompressKind end
struct CompressComplex   <: CompressKind end
struct CompressComplexSD <: CompressKind end

_prefix(::ScaledArray)       = "_ScaledArrayEngine_"
_prefix(::ScaledComplex)     = "_ScaledComplexData_"
_prefix(::CompressFloat)     = "_CompressFloat_"
_prefix(::CompressComplex)   = "_CompressComplex_"
_prefix(::CompressComplexSD) = "_CompressComplex_"   # SD reuses the CompressComplex prefix

# --- reader -------------------------------------------------------

mutable struct VirtualEngine
    table::Table
    kind::EngineKind
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

# One constructor method per engine kind -- each builds its own fully-
# initialised instance directly from the `_<Engine>_*` keywords (no
# generic placeholder instance handed to a separate mutator).

VirtualEngine(table::Table, kind::Mapped, vdesc::ColumnDesc, storedname::String, ::Record) =
    VirtualEngine(table, kind, vdesc, storedname, false, true, true,
                 nothing, nothing, "", "", nothing, nothing, nothing)

function VirtualEngine(table::Table, kind::CompressKind, vdesc::ColumnDesc,
                       storedname::String, kw::Record)
    pfx = _prefix(kind)
    fixed = Bool(get(kw, pfx * "Fixed", true))
    autoscale = Bool(get(kw, pfx * "AutoScale", false))
    scale  = Float32(get(kw, pfx * "Scale", ENG_UNIT_SCALE))
    offset = Float32(get(kw, pfx * "Offset", ENG_ZERO_OFFSET))
    scalename  = String(get(kw, pfx * "ScaleName", ""))
    offsetname = String(get(kw, pfx * "OffsetName", ""))
    return VirtualEngine(table, kind, vdesc, storedname, autoscale, fixed, fixed,
                         scale, offset, scalename, offsetname, nothing, nothing, nothing)
end

function VirtualEngine(table::Table, kind::ScaledKind, vdesc::ColumnDesc,
                       storedname::String, kw::Record)
    fixed_scale  = Bool(get(kw, _prefix(kind) * "FixedScale", true))
    fixed_offset = Bool(get(kw, _prefix(kind) * "FixedOffset", true))
    scale  = get(kw, _prefix(kind) * "Scale", nothing)
    offset = get(kw, _prefix(kind) * "Offset", nothing)
    scalename  = String(get(kw, _prefix(kind) * "ScaleName", ""))
    offsetname = String(get(kw, _prefix(kind) * "OffsetName", ""))
    return VirtualEngine(table, kind, vdesc, storedname, false, fixed_scale, fixed_offset,
                         scale, offset, scalename, offsetname, nothing, nothing, nothing)
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

"The `EngineKind` for a bound engine's on-disk name (an exact string for
Compress*, a `ScaledArrayEngine<...>`-style prefix otherwise)."
function _engine_kind(name::AbstractString, kw::Record)::EngineKind
    startswith(name, "ScaledArrayEngine") && return ScaledArray()
    startswith(name, "ScaledComplexData") && return ScaledComplex()
    startswith(name, "MappedArrayEngine") && return Mapped()
    name == "CompressFloat" && return CompressFloat()
    get(kw, "_CompressComplex_Type", name) == "CompressComplexSD" ?
        CompressComplexSD() : CompressComplex()
end

# the engine type string as it appears in the ColumnSet DM list
_engine_typestr(::CompressFloat,     ::CasaType, ::CasaType) = "CompressFloat"
_engine_typestr(::CompressComplex,   ::CasaType, ::CasaType) = "CompressComplex"
_engine_typestr(::CompressComplexSD, ::CasaType, ::CasaType) = "CompressComplexSD"
_engine_typestr(::Mapped, vtype::CasaType, stored_type::CasaType) =
    "MappedArrayEngine<$(_TYPEID[vtype]),$(_TYPEID[stored_type])>"
_engine_typestr(::ScaledArray, vtype::CasaType, stored_type::CasaType) =
    "ScaledArrayEngine<$(_TYPEID[vtype]),$(_TYPEID[stored_type])>"
_engine_typestr(::ScaledComplex, vtype::CasaType, stored_type::CasaType) =
    "ScaledComplexData<$(_TYPEID[vtype]),$(_TYPEID[stored_type])>"

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

    return VirtualEngine(t, kind, vdesc, storedname, kw)
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

# --- decode (inverse transform): one method per engine, no separately
#     named `_decode_<engine>` helpers -- dispatch on `kind` picks the body
#     directly. ------------------------------------------------------

_decode(::Mapped, st, scale, offset, J::Type) = convert(Array{J}, st)

function _decode(::ScaledArray, st::AbstractArray, scale, offset, J::Type)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        out[i] = J(muladd(st[i], scale, offset))
    end
    return out
end

function _decode(::ScaledComplex, st::AbstractArray, scale, offset, J::Type)
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

function _decode(::CompressFloat, st::AbstractArray{<:Integer}, scale, offset, J::Type)
    sc, of = Float32(scale), Float32(offset)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        out[i] = st[i] == -ENG_C_WRAP ? J(NaN) : J(muladd(Float32(st[i]), sc, of))
    end
    return out
end

function _decode(::CompressComplex, st::AbstractArray{<:Integer}, scale, offset, J::Type)
    sc, of = Float32(scale), Float32(offset)
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
            out[i] = J(R(muladd(r, sc, of)), R(muladd(im, sc, of)))
        end
    end
    return out
end

function _decode(::CompressComplexSD, st::AbstractArray{<:Integer}, scale, offset, J::Type)
    sc, of = Float32(scale), Float32(offset)
    R = real(J)
    fullScale = sc / Float32(ENG_SD_REAL_BITS)
    imagScale = sc * Float32(ENG_SD_IMAG_MULT)
    out = Array{J}(undef, size(st))
    @inbounds for i in eachindex(st)
        v = Int(st[i])
        if iseven(v)
            out[i] = J(R(muladd(v >> 1, fullScale, of)), zero(R))
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
                out[i] = J(R(muladd(r, sc, of)), R(muladd(im, imagScale, of)))
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

_eng_stored_eltype(::CompressFloat, ::CasaType)     = Int16
_eng_stored_eltype(::CompressComplex, ::CasaType)   = Int32
_eng_stored_eltype(::CompressComplexSD, ::CasaType) = Int32
_eng_stored_eltype(::Mapped, ::CasaType)            = ComplexF64
_eng_stored_eltype(::ScaledKind, stored_type::CasaType) = juliatype(stored_type)

# --- encode (inverse of decode): one method per engine, same pattern --

function _encode(::ScaledArray, cell::AbstractArray, scale, offset, T::Type)
    out = Array{T}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        out[i] = trunc(T, (cell[i] - offset) / scale)      # C++ static_cast: toward zero
    end
    return out
end

function _encode(::ScaledComplex, cell::AbstractArray, scale, offset, T::Type)
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

function _encode(::CompressFloat, cell::AbstractArray, scale, offset, ::Type)
    sc, of = Float32(scale), Float32(offset)
    out = Array{Int16}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        v = Float32(cell[i])
        out[i] = (!isfinite(v) || sc == 0) ? ENG_NAN_F :
                 Int16(_round_clamp((v - of) / sc, -ENG_C_PART_MAX, ENG_C_PART_MAX))
    end
    return out
end

function _encode(::CompressComplex, cell::AbstractArray, scale, offset, ::Type)
    sc, of = Float32(scale), Float32(offset)
    out = Array{Int32}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        z = ComplexF32(cell[i])
        if !isfinite(real(z)) || !isfinite(imag(z)) || sc == 0
            out[i] = ENG_NAN_C
        else
            sre = _round_clamp((real(z) - of) / sc, -ENG_C_PART_MAX, ENG_C_PART_MAX)
            sim = _round_clamp((imag(z) - of) / sc, -ENG_C_PART_MAX, ENG_C_PART_MAX)
            out[i] = Int32(sre * ENG_C_HIWORD + sim)
        end
    end
    return out
end

function _encode(::CompressComplexSD, cell::AbstractArray, scale, offset, ::Type)
    sc, of = Float32(scale), Float32(offset)
    fullScale = sc / Float32(ENG_SD_REAL_BITS)
    imagScale = sc * Float32(ENG_SD_IMAG_MULT)
    out = Array{Int32}(undef, size(cell))
    @inbounds for i in eachindex(cell)
        z = ComplexF32(cell[i])
        if !isfinite(real(z)) || !isfinite(imag(z)) || sc == 0
            out[i] = ENG_NAN_C
        elseif imag(z) == 0                                  # even LSB flags imag == 0
            s = _round_clamp((real(z) - of) / fullScale, ENG_SD_EVEN_LO, ENG_SD_EVEN_HI)
            out[i] = Int32(s << 1)
        else                                                 # odd LSB flags imag != 0
            sre = _round_clamp((real(z) - of) / sc, -ENG_SD_REAL_MAX, ENG_SD_REAL_MAX)
            sim = _round_clamp((imag(z) - of) / imagScale, ENG_SD_IMAG_LO, ENG_SD_IMAG_HI)
            out[i] = Int32(sre * ENG_C_HIWORD + (sim << 1) + 1)
        end
    end
    return out
end

# --- keyword record ------------------------------------------

_kwpush!(r::Record, name, t::CasaType, v) =
    (push!(r.names, name); push!(r.types, t); push!(r.values, v); push!(r.comments, ""))

"""
    _engine_keywords(kind::EngineKind, vtype, storedname, scale, offset,
                     scalename, offsetname, autoscale) -> Record

The `_<Engine>_*` keyword record to stamp onto the virtual `ColumnDesc`.
"""
function _engine_keywords(kind::EngineKind, vtype::CasaType, storedname, scale, offset,
                          scalename, offsetname, autoscale::Bool)
    r = Record()
    _kwpush!(r, "_BaseMappedArrayEngine_Name", TpString, String(storedname))
    _push_kw!(r, kind, vtype, scale, offset, scalename, offsetname, autoscale)
    return r
end

_push_kw!(r::Record, ::Mapped, vtype, scale, offset, scalename, offsetname, autoscale) = r

function _push_kw!(r::Record, kind::CompressKind, vtype::CasaType, scale, offset,
                   scalename, offsetname, autoscale::Bool)
    pfx = _prefix(kind)
    fixed = !autoscale
    _kwpush!(r, pfx * "Scale",  TpFloat, Float32(fixed ? scale  : ENG_UNIT_SCALE))
    _kwpush!(r, pfx * "Offset", TpFloat, Float32(fixed ? offset : ENG_ZERO_OFFSET))
    _kwpush!(r, pfx * "ScaleName",  TpString, fixed ? "" : String(scalename))
    _kwpush!(r, pfx * "OffsetName", TpString, fixed ? "" : String(offsetname))
    _kwpush!(r, pfx * "Fixed",     TpBool, fixed)
    _kwpush!(r, pfx * "AutoScale", TpBool, autoscale)
    _push_compresstype!(r, kind)
    return r
end

_push_compresstype!(::Record, ::CompressFloat) = nothing
_push_compresstype!(r::Record, ::CompressComplex) =
    _kwpush!(r, "_CompressComplex_Type", TpString, "CompressComplex")
_push_compresstype!(r::Record, ::CompressComplexSD) =
    _kwpush!(r, "_CompressComplex_Type", TpString, "CompressComplexSD")

function _push_kw!(r::Record, kind::ScaledKind, vtype::CasaType, scale, offset,
                   scalename, offsetname, autoscale::Bool)
    pfx = _prefix(kind)
    S = _scaled_scaletype(kind, vtype)
    SJ = juliatype(S)
    _kwpush!(r, pfx * "Scale",  S, SJ(scale))
    _kwpush!(r, pfx * "Offset", S, SJ(offset))
    _kwpush!(r, pfx * "ScaleName",   TpString, "")
    _kwpush!(r, pfx * "OffsetName",  TpString, "")
    _kwpush!(r, pfx * "FixedScale",  TpBool, true)
    _kwpush!(r, pfx * "FixedOffset", TpBool, true)
    return r
end

_scaled_scaletype(::ScaledComplex, vtype::CasaType) = vtype == TpDComplex ? TpDComplex : TpComplex
_scaled_scaletype(::ScaledArray,   vtype::CasaType) = vtype == TpDouble   ? TpDouble   : TpFloat

"""
    encode_engine(kind::EngineKind, vdata, vtype; scale, offset, autoscale, stored_type,
                  storedname, scalename, offsetname)
        -> (storeddata, keywords, scaledata, offsetdata)

Pack the virtual column `vdata` (a vector of numeric arrays) into stored
integers.  `scaledata` / `offsetdata` are `Vector{Float32}` (one per row)
when `autoscale`, else `nothing`.  `keywords` is the `_<Engine>_*` record
to merge onto the virtual `ColumnDesc`.
"""
function encode_engine(kind::Mapped, vdata::AbstractVector, vtype::CasaType;
                       storedname::AbstractString="", kwargs...)
    n = length(vdata)
    stored = Any[convert(Array{ComplexF64}, Array(vdata[r])) for r in 1:n]
    return stored, _engine_keywords(kind, vtype, storedname, 0, 0, "", "", false), nothing, nothing
end

function encode_engine(kind::EngineKind, vdata::AbstractVector, vtype::CasaType;
                       scale=nothing, offset=nothing, autoscale::Bool=false,
                       stored_type::CasaType=TpInt,
                       storedname::AbstractString="", scalename::AbstractString="",
                       offsetname::AbstractString="")
    n = length(vdata)
    T = _eng_stored_eltype(kind, stored_type)

    (kind isa ScaledKind && autoscale) &&
        error("autoscale is only supported for CompressFloat / CompressComplex[SD]")

    if autoscale
        sc = Vector{Float32}(undef, n)
        of = Vector{Float32}(undef, n)
        stored = Vector{Any}(undef, n)
        for r in 1:n
            cell = Array(vdata[r])
            sc[r], of[r] = _auto_scale_offset(cell)
            s = sc[r] == 0 ? ENG_UNIT_SCALE : sc[r]
            stored[r] = _encode(kind, cell, s, of[r], T)
        end
        kw = _engine_keywords(kind, vtype, storedname, ENG_UNIT_SCALE, ENG_ZERO_OFFSET,
                              scalename, offsetname, true)
        return stored, kw, sc, of
    end

    scale === nothing && error("encode_engine: fixed engine needs a `scale`")
    off = offset === nothing ? zero(scale) : offset
    stored = Any[_encode(kind, Array(vdata[r]), scale, off, T) for r in 1:n]
    kw = _engine_keywords(kind, vtype, storedname, scale, off, "", "", false)
    return stored, kw, nothing, nothing
end
