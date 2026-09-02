# AipsIO --- reader for the "canonical" (big-endian) object-framed byte
# stream used by casacore for `table.dat` and the data-manager headers.
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
#   * All scalars are big-endian; Bool is one byte.

const AIPS_MAGIC = 0xbebebebe

mutable struct AipsIO
    io::IO
    level::Int
    # remembered end position (byte offset just past the object body) for
    # each open nesting level, used by `getend` to validate / resync.
    ends::Vector{Int}
end

AipsIO(io::IO) = AipsIO(io, 0, Int[])
AipsIO(data::Vector{UInt8}) = AipsIO(IOBuffer(data))

Base.position(a::AipsIO) = position(a.io)
Base.seek(a::AipsIO, n::Integer) = seek(a.io, n)
Base.eof(a::AipsIO) = eof(a.io)

# --- primitive scalar reads (big-endian) --------------------------------

read_scalar(a::AipsIO, ::Type{T}) where {T} = ntoh(read(a.io, T))
read_scalar(a::AipsIO, ::Type{Bool}) = read(a.io, UInt8) != 0x00

function read_scalar(a::AipsIO, ::Type{Complex{T}}) where {T}
    re = ntoh(read(a.io, T))
    im = ntoh(read(a.io, T))
    Complex{T}(re, im)
end

Base.read(a::AipsIO, ::Type{T}) where {T} = read_scalar(a, T)

function read_string(a::AipsIO)
    n = ntoh(read(a.io, UInt32))
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
        magic = ntoh(read(a.io, UInt32))
        magic == AIPS_MAGIC || error("AipsIO: no magic value (got $(repr(magic)))")
    end
    lenpos = position(a.io)
    len = ntoh(read(a.io, UInt32))
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
    return ntoh(read(a.io, UInt32))
end

"""
    getstart_any(a) -> (type::String, version::UInt32)
"""
function getstart_any(a::AipsIO)
    tp = getnexttype(a)
    return tp, ntoh(read(a.io, UInt32))
end

"""
    getend(a)

Finish the current object. Seeks to the recorded end position so that a
partially decoded object does not desynchronise the stream.
"""
function getend(a::AipsIO)
    a.level > 0 || error("AipsIO.getend: no matching getstart")
    endpos = pop!(a.ends)
    a.level -= 1
    if endpos != AIPS_MAGIC   # length slot unknown on non-seekable writes
        seek(a.io, endpos)
    end
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
    nel = Int(ntoh(read(a.io, UInt32)))
    T = v == 1 ? Int32 : Int64
    shape = Int[Int(ntoh(read(a.io, T))) for _ in 1:nel]
    getend(a)
    return shape
end

"""
    read_block(a, ::Type{T}) -> Vector{T}

A casacore `Block<T>` : `getstart("Block")`, count, then the elements.
"""
function read_block(a::AipsIO, ::Type{T}) where {T}
    getstart(a, "Block")
    n = Int(ntoh(read(a.io, UInt32)))
    out = T[read_element(a, T) for _ in 1:n]
    getend(a)
    return out
end

read_element(a::AipsIO, ::Type{String}) = read_string(a)
read_element(a::AipsIO, ::Type{T}) where {T} = read_scalar(a, T)

"""
    read_array(a) -> (shape::Vector{Int}, data::Vector)

A casacore `Array<T>` written via AipsIO (used for array-valued keywords).
"""
function read_array(a::AipsIO, ::Type{T}) where {T}
    tp = getnexttype(a)
    (tp == "Array" || startswith(tp, "Array<")) ||
        error("AipsIO.read_array: found \"$tp\"")
    version = ntoh(read(a.io, UInt32))
    ndim = Int(ntoh(read(a.io, Int32)))
    if version < 3          # discard the obsolete origin
        for _ in 1:ndim; ntoh(read(a.io, Int32)); end
    end
    shape = Int[Int(ntoh(read(a.io, UInt32))) for _ in 1:ndim]
    nwritten = Int(ntoh(read(a.io, UInt32)))
    data = T[read_element(a, T) for _ in 1:nwritten]
    getend(a)
    return shape, data
end
