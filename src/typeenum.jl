# casacore DataType enum  <->  Julia types
# (casacore/casa/Utilities/DataType.h)

"""
    CasaType

Enum mirroring casacore's `DataType` — the element type of a column or
keyword value (`TpBool`, `TpInt`, `TpFloat`, `TpComplex`, `TpString`, the
`TpArray*` variants, `TpInt64`, …). It is the `type` field of a
[`ColumnDesc`](@ref); `juliatype(t)` gives the corresponding Julia type.
"""
@enum CasaType::Int32 begin
    TpBool          = 0
    TpChar          = 1
    TpUChar         = 2
    TpShort         = 3
    TpUShort        = 4
    TpInt           = 5
    TpUInt          = 6
    TpFloat         = 7
    TpDouble        = 8
    TpComplex       = 9
    TpDComplex      = 10
    TpString        = 11
    TpTable         = 12
    TpArrayBool     = 13
    TpArrayChar     = 14
    TpArrayUChar    = 15
    TpArrayShort    = 16
    TpArrayUShort   = 17
    TpArrayInt      = 18
    TpArrayUInt     = 19
    TpArrayFloat    = 20
    TpArrayDouble   = 21
    TpArrayComplex  = 22
    TpArrayDComplex = 23
    TpArrayString   = 24
    TpRecord        = 25
    TpOther         = 26
    TpQuantity      = 27
    TpArrayQuantity = 28
    TpInt64         = 29
    TpArrayInt64    = 30
end

const SCALARTYPE = Dict{CasaType,DataType}(
    TpBool => Bool, TpChar => Int8, TpUChar => UInt8,
    TpShort => Int16, TpUShort => UInt16, TpInt => Int32, TpUInt => UInt32,
    TpFloat => Float32, TpDouble => Float64,
    TpComplex => ComplexF32, TpDComplex => ComplexF64,
    TpString => String, TpInt64 => Int64,
)

const ARRAYTYPE = Dict{CasaType,CasaType}(
    TpArrayBool => TpBool, TpArrayChar => TpChar, TpArrayUChar => TpUChar,
    TpArrayShort => TpShort, TpArrayUShort => TpUShort, TpArrayInt => TpInt,
    TpArrayUInt => TpUInt, TpArrayFloat => TpFloat, TpArrayDouble => TpDouble,
    TpArrayComplex => TpComplex, TpArrayDComplex => TpDComplex,
    TpArrayString => TpString, TpArrayInt64 => TpInt64,
)

isarraytype(t::CasaType) = haskey(ARRAYTYPE, t)
isscalartype(t::CasaType) = haskey(SCALARTYPE, t)

"""
    juliatype(t::CasaType)

The Julia element type for a scalar `CasaType`, or the element type of an
array `CasaType`. `TpRecord`/`TpTable`/`TpOther`/`TpQuantity` return
`Nothing`.
"""
function juliatype(t::CasaType)
    haskey(SCALARTYPE, t) && return SCALARTYPE[t]
    haskey(ARRAYTYPE, t)    && return SCALARTYPE[ARRAYTYPE[t]]
    return Nothing
end

casatype(i::Integer) = CasaType(Int32(i))
