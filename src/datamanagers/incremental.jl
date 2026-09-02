# IncrementalStMan (ISM) reader.
#
# Mirrors casacore/tables/DataMan/ISMBase.cc, ISMIndex.cc, ISMBucket.cc,
# ISMColumn.cc.
#
# ISM stores a value only when it differs from the previous row ("store on
# change").  `table.f<seqnr>` layout:
#   * bytes [0, 512)              : AipsIO "IncrementalStMan" header
#   * bytes [512, 512+k*len)      : k data buckets
#   * bytes [512 + k*len, ...)    : AipsIO "ISMIndex" (row -> bucket map)
#
# Bucket layout (see ISMBucket synopsis):
#   [idx offset: uInt] [data part] [index part] [free]
# The index part holds, per column: [nr: uInt][nr row numbers][nr data offsets].
# Row numbers are bucket-relative; a value is valid from its row until the
# next stored row number (or the end of the bucket).
#
# Rows and column numbers are 1-based in this file's API.

struct ISMIndex
    used::Int
    rows::Vector{Int}      # used+1 entries: first (1-based) row of each bucket,
                           # with rows[used+1] == nrow+1
    bucket::Vector{Int}    # used entries: physical bucket number
end

# bucket index i whose row range [rows[i], rows[i+1]) contains `row` (1-based)
function _ism_bucket(ix::ISMIndex, row::Integer)
    for i in 1:ix.used
        ix.rows[i+1] > row && return i
    end
    error("ISMIndex: row $row out of range")
end

mutable struct IncrementalStMan
    data::Vector{UInt8}
    endian::Symbol
    length::Int            # bucket size in bytes
    buckets::Int           # number of data buckets
    index::ISMIndex
end

_u32(ism, off) = (ism.endian === :big ? ntoh : ltoh)(reinterpret(UInt32, view(ism.data, off+1:off+4))[1])

function open_incrementalstman(t::CTDSTable, dm::DataManagerInfo)
    bytes = read(joinpath(t.path, "table.f$(dm.sequ)"))
    endian = t.endian

    h = AipsIO(IOBuffer(bytes); endian)
    version = getstart(h, "IncrementalStMan")
    version >= 5 && read_scalar(h, Bool)                  # bigEndian flag
    bucketsize = Int(read_u32(h))
    nbucket    = Int(read_u32(h))
    read_u32(h)                                           # persCacheSize
    read_u32(h)                                           # uniqnr
    if version > 1
        read_u32(h); read_i32(h)                          # nFreeBucket, firstFree
    end
    getend(h)

    idxpos = 512 + nbucket * bucketsize
    ia = AipsIO(IOBuffer(@view bytes[idxpos+1:end]); endian)
    iv = getstart(ia, "ISMIndex")
    used = Int(read_u32(ia))
    ondisk = iv > 1 ? read_block(ia, UInt64) : read_block(ia, UInt32)
    rows = Int[Int(x) + 1 for x in ondisk]       # on-disk row starts are 0-based
    bucket = Int.(read_block(ia, UInt32))
    getend(ia)

    return IncrementalStMan(bytes, endian, bucketsize, nbucket,
                            ISMIndex(used, rows, bucket))
end

# --- bucket index parsing -----------------------------------------

# Parse the per-column (rownumbers, offsets) index of one bucket, for the
# first `ncol` columns.  Returns the vectors for column `colnr` (1-based).
function _ism_colindex(ism::IncrementalStMan, bucketnr::Int, colnr::Int, ncol::Int)
    base = 512 + bucketnr * ism.length
    hdr = _u32(ism, base)
    use64 = (hdr & 0xf0000000) != 0
    p = base + Int(hdr & 0x0fffffff)          # start of the index part
    rownr_t = use64 ? UInt64 : UInt32
    local rownrs, offsets
    for i in 1:ncol
        nr = Int(_u32(ism, p)); p += 4
        rr = Vector{Int}(undef, nr)
        for j in 1:nr
            rr[j] = Int((ism.endian === :big ? ntoh : ltoh)(
                reinterpret(rownr_t, view(ism.data, p+1:p+sizeof(rownr_t)))[1]))
            p += sizeof(rownr_t)
        end
        oo = Vector{Int}(undef, nr)
        for j in 1:nr
            oo[j] = Int(_u32(ism, p)); p += 4
        end
        if i == colnr
            rownrs, offsets = rr, oo
        end
    end
    return rownrs, offsets, base + 4          # data part starts at base+4
end

# largest index i with v[i] <= x  (v ascending)
function _le_index(v::Vector{Int}, x::Integer)
    i = 1
    @inbounds while i < length(v) && v[i+1] <= x
        i += 1
    end
    return i
end

# --- value decoding ----------------------------------------------

function _ism_decode(ism::IncrementalStMan, c::ColumnDesc, dataoff::Int)
    dims = _dims(c)
    nrelem = isempty(dims) ? 1 : prod(dims)
    swap = ism.endian === :big ? ntoh : ltoh

    if c.type == TpBool
        bits = Bool[(ism.data[dataoff + (k >> 3) + 1] >> (k & 7)) & 0x01 == 0x01
                    for k in 0:nrelem-1]
        return isempty(dims) ? bits[1] : reshape(bits, dims...)
    elseif c.type == TpString
        isempty(dims) || error("ISM string arrays not supported yet")
        total = Int(_u32(ism, dataoff))
        return String(ism.data[dataoff+5 : dataoff+total])   # total = 4 + nchars
    else
        T = juliatype(c.type)
        raw = reinterpret(T, view(ism.data, dataoff+1 : dataoff + nrelem*sizeof(T)))
        vals = T[swap(x) for x in raw]
        return isempty(dims) ? vals[1] : reshape(vals, dims...)
    end
end

"""
    ism_getcell(ism, colnr, coldesc, row, ncol) -> value

`colnr` and `row` are 1-based; `ncol` is the number of columns bound to this
ISM instance.
"""
function ism_getcell(ism::IncrementalStMan, colnr::Int, c::ColumnDesc,
                     row::Integer, ncol::Int)
    bi = _ism_bucket(ism.index, Int(row))
    bucketnr = ism.index.bucket[bi]
    bstart = ism.index.rows[bi]                  # 1-based first row of the bucket
    rownrs, offsets, database = _ism_colindex(ism, bucketnr, colnr, ncol)
    inx = _le_index(rownrs, Int(row) - bstart)   # bucket-relative (0-based) row
    return _ism_decode(ism, c, database + offsets[inx])
end

"""
    ism_getcolumn(ism, colnr, coldesc, nrow, ncol) -> Vector / Vector{Array}

Whole-column read: walk buckets and run-length-fill from the stored values.
"""
function ism_getcolumn(ism::IncrementalStMan, colnr::Int, c::ColumnDesc,
                       nrow::Integer, ncol::Int)
    dims = _dims(c)
    scalar = isempty(dims) && c.type != TpString
    out = scalar ? Vector{juliatype(c.type)}(undef, nrow) :
          Vector{Any}(undef, nrow)

    ix = ism.index
    for bi in 1:ix.used
        bstart = ix.rows[bi]                 # 1-based first row of the bucket
        bend = ix.rows[bi+1]                 # 1-based, exclusive
        rownrs, offsets, database = _ism_colindex(ism, ix.bucket[bi], colnr, ncol)
        for k in 1:length(rownrs)
            r0 = bstart + rownrs[k]                                  # 1-based
            r1 = k < length(rownrs) ? bstart + rownrs[k+1] : bend    # exclusive
            v = _ism_decode(ism, c, database + offsets[k])
            @inbounds for r in r0:r1-1
                out[r] = v
            end
        end
    end
    return out
end
