# AipsIO --- reader for the object-framed byte stream used by casacore for
# `table.dat` and the data-manager headers.
#
# Framing (see casacore/casa/IO/AipsIO.cc):
#   * The root stream begins with the magic value 0xbebebebe (UInt32).
#   * Every object is written as
#         [len::UInt32][type::String][version::UInt32][body...]
#     where `len` counts itself, the type string, the version and the body.
#     (On write casacore reserves the slot with a second magic value and
#     overwrites it with the length in `putend`; nested objects carry no
#     magic of their own.)
#   * Strings are [n::UInt32][n bytes] with no terminator.
#
# `table.dat` is always "canonical" (big-endian).  Storage-manager files
# follow the table's endian flag, so `AipsIO` carries a `bigendian` field.

const AIPS_MAGIC = 0xbebebebe

mutable struct AipsIO
    io::IO
    bigendian::Bool
    level::Int
    ends::Vector{Int}     # recorded end offset for each open nesting level
end

AipsIO(io::IO; bigendian::Bool=true) = AipsIO(io, bigendian, 0, Int[])
AipsIO(data::Vector{UInt8}; kw...) = AipsIO(IOBuffer(data); kw...)

Base.position(a::AipsIO) = position(a.io)
Base.seek(a::AipsIO, n::Integer) = seek(a.io, n)
Base.eof(a::AipsIO) = eof(a.io)

# --- primitive scalar reads (honouring endianness) ---------------------

_ord(a::AipsIO, x) = a.bigendian ? ntoh(x) : ltoh(x)

read_scalar(a::AipsIO, ::Type{T}) where {T} = _ord(a, read(a.io, T))
read_scalar(a::AipsIO, ::Type{Bool}) = read(a.io, UInt8) != 0x00

function read_scalar(a::AipsIO, ::Type{Complex{T}}) where {T}
    re = _ord(a, read(a.io, T))
    im = _ord(a, read(a.io, T))
    Complex{T}(re, im)
end

Base.read(a::AipsIO, ::Type{T}) where {T} = read_scalar(a, T)

read_u32(a::AipsIO) = read_scalar(a, UInt32)
read_i32(a::AipsIO) = read_scalar(a, Int32)

function read_string(a::AipsIO)
    n = read_u32(a)
    String(read(a.io, Int(n)))
end

# --- object framing ----------------------------------------------------

"""
    getnexttype(a) -> String

Peek the type name of the next object without consuming its version.
Consumes the root magic on the first call at the outermost level.
"""
function getnexttype(a::AipsIO)
    if a.level == 0
        magic = read_u32(a)
        magic == AIPS_MAGIC || error("AipsIO: no magic value (got $(repr(magic)))")
    end
    lenpos = position(a.io)
    len = read_u32(a)
    tp = read_string(a)
    a.level += 1
    push!(a.ends, lenpos + Int(len))
    return tp
end

"""
    getstart(a, expected) -> version::UInt32

Begin reading an object, verifying its type, and return its version.
"""
function getstart(a::AipsIO, expected::AbstractString)
    tp = getnexttype(a)
    tp == expected || error("AipsIO.getstart: found \"$tp\", expected \"$expected\"")
    return read_u32(a)
end

"""
    getend(a)

Finish the current object, seeking to its recorded end so a partially
decoded object cannot desynchronise the stream.
"""
function getend(a::AipsIO)
    a.level > 0 || error("AipsIO.getend: no matching getstart")
    endpos = pop!(a.ends)
    a.level -= 1
    endpos == AIPS_MAGIC || seek(a.io, endpos)   # unknown on non-seekable writes
    return nothing
end

# --- aggregates -------------------------------------------------------

"""
    read_iposition(a) -> Vector{Int}

An `IPosition` (array shape). Version 1 stores Int32 elements, version 2
Int64.
"""
function read_iposition(a::AipsIO)
    v = getstart(a, "IPosition")
    nel = Int(read_u32(a))
    T = v == 1 ? Int32 : Int64
    shape = Int[Int(read_scalar(a, T)) for _ in 1:nel]
    getend(a)
    return shape
end

"""
    read_block(a, ::Type{T}) -> Vector{T}

A casacore `Block<T>` : `getstart("Block")`, count, then the elements.
"""
function read_block(a::AipsIO, ::Type{T}) where {T}
    getstart(a, "Block")
    n = Int(read_u32(a))
    out = T[read_element(a, T) for _ in 1:n]
    getend(a)
    return out
end

read_element(a::AipsIO, ::Type{String}) = read_string(a)
read_element(a::AipsIO, ::Type{T}) where {T} = read_scalar(a, T)

"""
    read_map(a, ::Type{K}, ::Type{V}) -> Vector{Pair{K,V}}

A casacore `std::map<K,V>` written as `SimpleOrderedMap`.
"""
function read_map(a::AipsIO, ::Type{K}, ::Type{V}) where {K,V}
    getstart(a, "SimpleOrderedMap")
    read_element(a, V)                       # obsolete default value
    nr = Int(read_u32(a))
    read_u32(a)                              # obsolete increment
    out = Pair{K,V}[read_element(a, K) => read_element(a, V) for _ in 1:nr]
    getend(a)
    return out
end

"""
    read_array(a, ::Type{T}) -> (shape::Vector{Int}, data::Vector{T})

A casacore `Array<T>` written via AipsIO (used for array-valued keywords).
"""
function read_array(a::AipsIO, ::Type{T}) where {T}
    tp = getnexttype(a)
    (tp == "Array" || startswith(tp, "Array<")) ||
        error("AipsIO.read_array: found \"$tp\"")
    version = read_u32(a)
    ndim = Int(read_i32(a))
    if version < 3          # discard the obsolete origin
        for _ in 1:ndim; read_i32(a); end
    end
    shape = Int[Int(read_u32(a)) for _ in 1:ndim]
    nwritten = Int(read_u32(a))
    data = T[read_element(a, T) for _ in 1:nwritten]
    getend(a)
    return shape, data
end
