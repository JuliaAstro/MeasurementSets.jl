# StManArrayFile --- the `table.f<seq>i` file that holds indirect
# (variable-shape) arrays for StandardStMan / IncrementalStMan indirect
# array columns.
#
# Mirrors casacore/tables/DataMan/StArrayFile.cc + StIndArray.cc.
#
# File layout:
#   bytes [0, AF_INT)          version  (uInt32)
#   bytes [AF_INT, AF_INT+8)   leng     (Int64)  -- logical length / next-alloc ptr
#   bytes [.., AF_HEADER)      padding  (zero)
#   records from byte AF_HEADER, each starting on an AF_ALIGN-byte boundary:
#     [refCount : uInt32]     -- only when version >= 1 (SSM writes version 0)
#     [ndim     : uInt32]
#     [dim      : Int32 x ndim]
#     [element data]          -- column-major, canonical
#
# `Bool` element data is bit-packed LSB-first (ceil(prod/8) bytes);
# `Complex`/`DComplex` are stored as 2 x Float/Double.  `String` arrays store
# `prod` uInt32 offsets right after the dims, each pointing at a
# `[len : uInt32][len bytes]` block appended later in the file (0 = empty).
#
# Every integer/float is in the *table's* byte order --- the file itself
# carries no endian flag.

const AF_INT    = 4    # canonical Int32 / uInt size (version, refCount, ndim, dims)
const AF_HEADER = 16   # file header size (version @0, leng @4, pad @12)
const AF_ALIGN  = 8    # each array record starts on an 8-byte boundary

# --- reader --------------------------------------------------------

struct ArrayFile
    data::Vector{UInt8}
    endian::Symbol
    version::Int
end

_af_get(af::ArrayFile, ::Type{T}, off::Integer) where {T} =
    (af.endian === :big ? ntoh : ltoh)(reinterpret(T, @view af.data[off+1:off+sizeof(T)])[1])

function open_arrayfile(path::AbstractString, endian::Symbol)
    data = read(path)
    length(data) >= AF_HEADER ||
        error("StManArrayFile $path: truncated header ($(length(data)) bytes)")
    version = Int((endian === :big ? ntoh : ltoh)(reinterpret(UInt32, @view data[1:AF_INT])[1]))
    return ArrayFile(data, endian, version)
end

# shape record at byte `offset` -> (dims::Dims, first-data-byte offset)
function _af_shape(af::ArrayFile, offset::Integer)
    p = Int(offset)
    af.version >= 1 && (p += AF_INT)                  # skip refCount
    ndim = Int(_af_get(af, UInt32, p)); p += AF_INT
    dims = ntuple(k -> Int(_af_get(af, Int32, p + AF_INT * (k - 1))), ndim)
    return dims, p + AF_INT * ndim
end

"""
    af_read(af, t::CasaType, offset) -> Array

Read the indirect array whose shape record starts at byte `offset`.
"""
function af_read(af::ArrayFile, t::CasaType, offset::Integer)
    dims, dp = _af_shape(af, offset)
    n = prod(dims; init=1)
    J = juliatype(t)

    if t == TpBool
        out = Vector{Bool}(undef, n)
        for k in 0:n-1
            out[k+1] = (af.data[dp + (k >> 3) + 1] >> (k & 7)) & 0x01 == 0x01
        end
        return reshape(out, dims)

    elseif t == TpString
        out = Vector{String}(undef, n)
        for k in 0:n-1
            so = Int(_af_get(af, UInt32, dp + AF_INT * k))     # offset slot
            if so == 0
                out[k+1] = ""
            else
                len = Int(_af_get(af, UInt32, so))
                out[k+1] = String(af.data[so + AF_INT + 1 : so + AF_INT + len])
            end
        end
        return reshape(out, dims)

    elseif J <: Complex
        R = real(J)
        raw = reinterpret(R, @view af.data[dp+1 : dp + 2n * sizeof(R)])
        swap = af.endian === :big ? ntoh : ltoh
        out = Vector{J}(undef, n)
        for k in 1:n
            out[k] = J(swap(raw[2k-1]), swap(raw[2k]))
        end
        return reshape(out, dims)

    else
        raw = reinterpret(J, @view af.data[dp+1 : dp + n * sizeof(J)])
        swap = af.endian === :big ? ntoh : ltoh
        return reshape(J[swap(x) for x in raw], dims)
    end
end

# --- writer -------------------------------------------------------

mutable struct ArrayFileWriter
    io::IOBuffer
    endian::Symbol
    version::Int
    leng::Int64
end

function ArrayFileWriter(; endian::Symbol, version::Integer=0)
    io = IOBuffer()
    write(io, zeros(UInt8, AF_HEADER))           # reserve the header
    ArrayFileWriter(io, endian, Int(version), Int64(AF_HEADER))
end

_afw(w::ArrayFileWriter, x) = write(w.io, w.endian === :big ? hton(x) : htol(x))

function _afw_at(w::ArrayFileWriter, x, pos::Integer)
    cur = position(w.io)
    seek(w.io, pos); _afw(w, x); seek(w.io, cur)
end

function _afw_pad_to(w::ArrayFileWriter, upto::Integer)
    n = Int(upto) - position(w.io)
    n > 0 && write(w.io, zeros(UInt8, n))
    seek(w.io, upto)
end

"""
    af_put!(w, t::CasaType, arr) -> Int64

Append `arr` (element `CasaType` `t`) as a new record and return its byte
offset (to be stored in the data-manager bucket cell).
"""
function af_put!(w::ArrayFileWriter, t::CasaType, arr)
    rec = AF_ALIGN * cld(w.leng, AF_ALIGN)            # align the record start
    _afw_pad_to(w, rec)
    w.version >= 1 && _afw(w, UInt32(1))              # refCount
    shp = size(arr)
    _afw(w, UInt32(length(shp)))
    for d in shp
        _afw(w, Int32(d))
    end
    n = prod(shp; init=1)
    J = juliatype(t)
    v = vec(arr)

    if t == TpBool
        packed = zeros(UInt8, cld(n, 8))
        for k in 0:n-1
            v[k+1] && (packed[(k >> 3) + 1] |= (0x01 << (k & 7)))
        end
        write(w.io, packed)
        w.leng = position(w.io)

    elseif t == TpString
        slotbase = position(w.io)
        write(w.io, zeros(UInt8, AF_INT * n))         # offset slots, patched below
        w.leng = position(w.io)
        for k in 0:n-1
            s = codeunits(String(v[k+1]))
            if isempty(s)
                _afw_at(w, UInt32(0), slotbase + AF_INT * k)
            else
                so = Int(w.leng)
                _afw_at(w, UInt32(so), slotbase + AF_INT * k)
                seek(w.io, so)
                _afw(w, UInt32(length(s)))
                write(w.io, s)
                w.leng = position(w.io)
            end
        end

    elseif J <: Complex
        R = real(J)
        for x in v
            _afw(w, R(real(x))); _afw(w, R(imag(x)))
        end
        w.leng = position(w.io)

    else
        for x in v
            _afw(w, J(x))
        end
        w.leng = position(w.io)
    end

    return Int64(rec)
end

"Finalize: patch the header and return the file bytes."
function arrayfile_bytes(w::ArrayFileWriter)
    _afw_pad_to(w, w.leng)
    _afw_at(w, UInt32(w.version), 0)
    _afw_at(w, Int64(w.leng), AF_INT)
    seek(w.io, w.leng)
    return take!(w.io)
end

"""
    af_append!(path, endian, t::CasaType, arr) -> Int64

Append one array record to the existing `StManArrayFile` at `path` and
return its byte offset (for the data-manager bucket cell).  The old
`leng` pointer at byte `AF_INT` is advanced; existing records are never
moved, so offsets already stored in SM buckets stay valid.
"""
function af_append!(path::AbstractString, endian::Symbol, t::CasaType, arr)
    data = read(path)
    version = Int((endian === :big ? ntoh : ltoh)(reinterpret(UInt32, @view data[1:AF_INT])[1]))
    leng = Int((endian === :big ? ntoh : ltoh)(reinterpret(Int64, @view data[AF_INT+1:AF_INT+8])[1]))

    w = ArrayFileWriter(; endian, version)
    w.leng = leng
    seek(w.io, 0); write(w.io, data)              # start from the current file
    seek(w.io, leng)
    off = af_put!(w, t, arr)
    _atomic_write(path, arrayfile_bytes(w))
    return off
end
