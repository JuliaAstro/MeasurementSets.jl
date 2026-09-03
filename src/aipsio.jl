# AipsIO --- reader and writer for the object-framed byte stream used by
# casacore for `table.dat` and the data-manager headers.
#
# Framing (see casacore/casa/IO/AipsIO.cc):
#   * The root stream begins with the magic value 0xbebebebe (UInt32).
#   * Every object is written as
#         [len::UInt32][type::String][version::UInt32][body...]
#     where `len` counts itself, the type string, the version and the body.
#     (casacore's `putstart` reserves the slot with the magic value and
#     `putend` overwrites it with the length; nested objects carry no magic.)
#   * Strings are [n::UInt32][n bytes] with no terminator.
#
# `table.dat` is always "canonical" (big-endian).  Storage-manager files
# follow the table's endian flag, so both sides carry an `endian` field
# (`:big` or `:little`).

const AIPS_MAGIC = 0xbebebebe

# canonical (big) or LE-canonical byte order
_toendian(endian::Symbol, x) = endian === :big ? hton(x) : htol(x)

# ============================ reader ================================

mutable struct AipsIO
    io::IO
    endian::Symbol           # :big or :little
    level::Int
    ends::Vector{Int}     # recorded end offset for each open nesting level
end

AipsIO(io::IO; endian::Symbol=:big) = AipsIO(io, endian, 0, Int[])
AipsIO(data::Vector{UInt8}; kw...) = AipsIO(IOBuffer(data); kw...)

Base.position(a::AipsIO) = position(a.io)
Base.seek(a::AipsIO, n::Integer) = seek(a.io, n)
Base.eof(a::AipsIO) = eof(a.io)

_ord(a::AipsIO, x) = a.endian === :big ? ntoh(x) : ltoh(x)

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

function getstart(a::AipsIO, expected::AbstractString)
    tp = getnexttype(a)
    tp == expected || error("AipsIO.getstart: found \"$tp\", expected \"$expected\"")
    return read_u32(a)
end

function getend(a::AipsIO)
    a.level > 0 || error("AipsIO.getend: no matching getstart")
    endpos = pop!(a.ends)
    a.level -= 1
    endpos == AIPS_MAGIC || seek(a.io, endpos)
    return nothing
end

function read_iposition(a::AipsIO)::Dims
    v = getstart(a, "IPosition")
    nel = Int(read_u32(a))
    T = v == 1 ? Int32 : Int64
    shape = Tuple(Int(read_scalar(a, T)) for _ in 1:nel)
    getend(a)
    return shape
end

function read_block(a::AipsIO, ::Type{T}) where {T}
    getstart(a, "Block")
    n = Int(read_u32(a))
    out = T[read_element(a, T) for _ in 1:n]
    getend(a)
    return out
end

read_element(a::AipsIO, ::Type{String}) = read_string(a)
read_element(a::AipsIO, ::Type{T}) where {T} = read_scalar(a, T)

function read_map(a::AipsIO, ::Type{K}, ::Type{V}) where {K,V}
    getstart(a, "SimpleOrderedMap")
    read_element(a, V)                       # obsolete default value
    nr = Int(read_u32(a))
    read_u32(a)                              # obsolete increment
    out = Pair{K,V}[read_element(a, K) => read_element(a, V) for _ in 1:nr]
    getend(a)
    return out
end

function read_array(a::AipsIO, ::Type{T}) where {T}
    tp = getnexttype(a)
    (tp == "Array" || startswith(tp, "Array<")) ||
        error("AipsIO.read_array: found \"$tp\"")
    version = read_u32(a)
    ndim = Int(read_i32(a))
    if version < 3          # discard the obsolete origin
        for _ in 1:ndim; read_i32(a); end
    end
    shape = Tuple(Int(read_u32(a)) for _ in 1:ndim)::Dims
    nwritten = Int(read_u32(a))
    data = T[read_element(a, T) for _ in 1:nwritten]
    getend(a)
    return shape, data
end

# ============================ writer ================================

mutable struct AipsWriter
    io::IOBuffer
    endian::Symbol
    starts::Vector{Int}   # position of the length slot for each open object
    level::Int
end

AipsWriter(; endian::Symbol=:big) = AipsWriter(IOBuffer(), endian, Int[], 0)

"The bytes written (terminal — all framing must be closed via `putend`)."
function bytes(w::AipsWriter)
    @assert w.level == 0 "AipsWriter.bytes: $(w.level) object(s) still open"
    return take!(w.io)
end

_put(w::AipsWriter, x) = write(w.io, _toendian(w.endian, x))

wr_u32(w::AipsWriter, x) = _put(w, UInt32(x))
wr_i32(w::AipsWriter, x) = _put(w, Int32(x))
wr_u64(w::AipsWriter, x) = _put(w, UInt64(x))

wr_scalar(w::AipsWriter, x::Bool) = write(w.io, x ? 0x01 : 0x00)
wr_scalar(w::AipsWriter, x::Complex) = (_put(w, real(x)); _put(w, imag(x)))
wr_scalar(w::AipsWriter, x) = _put(w, x)

function wr_string(w::AipsWriter, s::AbstractString)
    wr_u32(w, ncodeunits(s))
    write(w.io, s)
    return nothing
end

function putstart(w::AipsWriter, type::AbstractString, version::Integer)
    w.level == 0 && wr_u32(w, AIPS_MAGIC)
    push!(w.starts, position(w.io))
    wr_u32(w, 0)                         # length placeholder
    wr_string(w, type)
    wr_u32(w, version)
    w.level += 1
    return nothing
end

function putend(w::AipsWriter)
    start = pop!(w.starts)
    stop = position(w.io)
    seek(w.io, start)
    wr_u32(w, stop - start)              # slot + type + version + body
    seek(w.io, stop)
    w.level -= 1
    return nothing
end

function wr_iposition(w::AipsWriter, shape)
    putstart(w, "IPosition", 1)
    wr_u32(w, length(shape))
    for x in shape
        wr_i32(w, x)
    end
    putend(w)
end

wr_element(w::AipsWriter, x::AbstractString) = wr_string(w, x)
wr_element(w::AipsWriter, x) = wr_scalar(w, x)

function wr_block(w::AipsWriter, xs)
    putstart(w, "Block", 1)
    wr_u32(w, length(xs))
    for x in xs
        wr_element(w, x)
    end
    putend(w)
end
