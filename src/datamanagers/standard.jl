# StandardStMan (SSM) reader.
#
# Mirrors casacore/tables/DataMan/SSMBase.cc, SSMIndex.cc, SSMColumn.cc,
# SSMDirColumn.cc, SSMStringHandler.cc.
#
# On-disk layout of `table.f<seqnr>`:
#   * bytes [0, 512)          : AipsIO "StandardStMan" header
#   * bytes [512, 512+k*bsz)  : k equally-sized buckets
# Bucket kinds: data buckets (fixed-length cells laid out column by column),
# string buckets (variable-length strings), index buckets (the row->bucket
# maps).  Which bucket is which is recorded in the header / index.
#
# Rows and SSM column numbers are 1-based in this file's API; the on-disk
# 0-based values are converted at parse time.  Bucket numbers and byte
# offsets stay as raw file-layout quantities.

struct SSMIndex
    nused::Int
    rowsperbucket::Int
    lastrow::Vector{Int}        # lastrow[i] = last (1-based) row in bucket i
    bucketnumber::Vector{Int}   # physical bucket number (0-based block in file)
end

function read_ssmindex(a::AipsIO)
    version = getstart(a, "SSMIndex")
    nused = Int(read_u32(a))
    rpb = Int(read_u32(a))
    read_i32(a)                                   # nrColumns
    read_map(a, Int32, Int32)                     # free-space map (unused here)
    ondisk = version == 1 ? read_block(a, UInt32) : read_block(a, UInt64)
    lastrow = Int[Int(x) + 1 for x in ondisk]     # on-disk last row is 0-based
    bucketnr = Int.(read_block(a, UInt32))
    getend(a)
    return SSMIndex(nused, rpb, lastrow, bucketnr)
end

# position i within this index whose bucket holds `row` (1-based):
# the first i with lastrow[i] >= row.
function index_of(ix::SSMIndex, row::Integer)
    for i in 1:ix.nused
        ix.lastrow[i] >= row && return i
    end
    error("SSMIndex: row $row out of range")
end

# (bucket number, first row in that bucket, last row in that bucket) — 1-based rows
function bucket_of(ix::SSMIndex, row::Integer)
    i = index_of(ix, row)
    firstrow = i == 1 ? 1 : ix.lastrow[i-1] + 1
    return ix.bucketnumber[i], firstrow, ix.lastrow[i]
end

# ---------------------------------------------------------------------

mutable struct StandardStMan
    data::Vector{UInt8}
    bigendian::Bool
    bucketsize::Int
    nrbuckets::Int
    laststringbucket::Int
    columnoffset::Vector{Int}   # per SSM column (1-based): byte offset in bucket
    colindexmap::Vector{Int}    # per SSM column (1-based): which SSMIndex (1-based)
    indices::Vector{SSMIndex}
end

bucketptr(ssm::StandardStMan, n::Integer) = 512 + Int(n) * ssm.bucketsize

# Int32 in the table's endianness (data-bucket contents, string refs).
_i32(ssm, off) = (ssm.bigendian ? ntoh : ltoh)(reinterpret(Int32, view(ssm.data, off+1:off+4))[1])

# Int32 in big-endian: casacore always uses CanonicalConversion (never the
# little-endian variant) for the string-bucket and index-bucket headers.
_be_i32(ssm, off) = ntoh(reinterpret(Int32, view(ssm.data, off+1:off+4))[1])

function read_ssm_header!(hdr::AipsIO)
    version = getstart(hdr, "StandardStMan")
    version >= 3 && read_scalar(hdr, Bool)                 # bigEndian flag
    bucketsize   = Int(read_u32(hdr))
    nrbuckets    = Int(read_u32(hdr))
    read_u32(hdr)                                          # persCacheSize
    read_u32(hdr)                                          # freeBucketsNr
    read_i32(hdr)                                          # firstFreeBucket
    nridxbuckets = Int(read_u32(hdr))
    firstidx     = Int(read_i32(hdr))
    idxoffset    = version >= 2 ? Int(read_u32(hdr)) : 0
    laststr      = Int(read_i32(hdr))
    indexlength  = Int(read_u32(hdr))
    nrinx        = Int(read_u32(hdr))
    getend(hdr)
    return (; version, bucketsize, nrbuckets, nridxbuckets, firstidx,
            idxoffset, laststr, indexlength, nrinx)
end

function open_standardstman(t::CTDSTable, dm::DataManagerInfo)
    bytes = read(joinpath(t.path, "table.f$(dm.seqnr)"))
    be = t.bigendian

    # header lives in the first 512 bytes
    h = read_ssm_header!(AipsIO(IOBuffer(bytes); bigendian=be))

    # the SSM record embedded in table.dat (always big-endian there)
    blk = AipsIO(copy(dm.header); bigendian=true)
    getstart(blk, "SSM")
    read_string(blk)                                       # data-manager name
    columnoffset = Int.(read_block(blk, UInt32))
    colindexmap  = Int[Int(x) + 1 for x in read_block(blk, UInt32)]   # -> 1-based
    getend(blk)

    ssm = StandardStMan(bytes, be, h.bucketsize, h.nrbuckets, h.laststr,
                        columnoffset, colindexmap, SSMIndex[])

    # assemble and parse the index buckets
    idxbytes = _read_index_bytes(ssm, h)
    ia = AipsIO(IOBuffer(idxbytes); bigendian=be)
    ssm.indices = SSMIndex[read_ssmindex(ia) for _ in 1:h.nrinx]
    return ssm
end

function _read_index_bytes(ssm::StandardStMan, h)
    h.indexlength == 0 && return UInt8[]
    aclen = 8                                       # 2 * canonical size of Int32
    idxbucketsize = ssm.bucketsize - aclen
    out = UInt8[]
    bkt = h.firstidx
    remaining = h.indexlength
    for _ in 1:h.nridxbuckets
        base = bucketptr(ssm, bkt)
        nextbkt = _be_i32(ssm, base + 4)
        if h.idxoffset > 0
            s = base + h.idxoffset
            append!(out, @view ssm.data[s+1:s+h.indexlength])
        else
            take = min(remaining, idxbucketsize)
            s = base + aclen
            append!(out, @view ssm.data[s+1:s+take])
        end
        remaining -= idxbucketsize
        bkt = nextbkt
    end
    return out
end

# --- per-column geometry ---------------------------------------------

"Canonical byte width of one stored cell for column `c`."
function cell_extsize(c::ColumnDesc)
    nrelem = _nrelem(c)
    if c.type == TpString
        return c.maxlength > 0 ? Int(c.maxlength) : 12       # 3 Int32 refs
    elseif c.type == TpBool
        return cld(nrelem, 8)
    else
        return sizeof(juliatype(c.type)) * nrelem
    end
end

_nrelem(c::ColumnDesc) = isempty(c.fixedshape) ? 1 : prod(c.fixedshape)

# --- value access ---------------------------------------------------

"Byte offset into `ssm.data` of column `ssmcol`'s block in the bucket
holding `row`, plus that bucket's first row (1-based)."
function locate(ssm::StandardStMan, ssmcol::Int, row::Integer)
    ix = ssm.indices[ssm.colindexmap[ssmcol]]
    bkt, firstrow, _ = bucket_of(ix, row)
    return bucketptr(ssm, bkt) + ssm.columnoffset[ssmcol], firstrow
end

_swap(ssm::StandardStMan, x) = ssm.bigendian ? ntoh(x) : ltoh(x)

function _read_elems(ssm::StandardStMan, ::Type{T}, off::Int, n::Int) where {T}
    raw = reinterpret(T, ssm.data[off+1:off+n*sizeof(T)])
    return T[_swap(ssm, x) for x in raw]
end

function _read_bits(ssm::StandardStMan, off::Int, bitstart::Int, n::Int)
    out = Vector{Bool}(undef, n)
    for k in 0:n-1
        b = bitstart + k
        out[k+1] = (ssm.data[off + (b >> 3) + 1] >> (b & 7)) & 0x01 == 0x01
    end
    return out
end

"""
    ssm_getcell(ssm, ssmcol, coldesc, row) -> value

`ssmcol` and `row` are 1-based.
"""
function ssm_getcell(ssm::StandardStMan, ssmcol::Int, c::ColumnDesc, row::Integer)
    ext = cell_extsize(c)
    off, firstrow = locate(ssm, ssmcol, row)
    inbucket = Int(row) - firstrow          # 0-based position within the bucket
    nrelem = _nrelem(c)

    if c.type == TpBool
        bits = _read_bits(ssm, off, inbucket * nrelem, nrelem)
        return isempty(c.fixedshape) ? bits[1] : reshape(bits, c.fixedshape...)
    elseif c.type == TpString
        c.maxlength > 0 && error("fixed-length strings not yet supported")
        !isempty(c.fixedshape) && error("string arrays not yet supported (Phase 2)")
        return _read_string_ref(ssm, off + inbucket * ext)
    elseif isempty(c.fixedshape)
        return _read_elems(ssm, juliatype(c.type), off + inbucket * ext, 1)[1]
    else
        vals = _read_elems(ssm, juliatype(c.type), off + inbucket * ext, nrelem)
        return reshape(vals, c.fixedshape...)
    end
end

# variable-length scalar string: 3 Int32s (bucketnr, offset, length); if
# length <= 8 the characters sit inline in the first 8 bytes.
function _read_string_ref(ssm::StandardStMan, off::Int)
    len = Int(_i32(ssm, off + 8))
    len <= 0 && return ""
    if len <= 8
        return String(ssm.data[off+1:off+len])
    end
    bkt = Int(_i32(ssm, off))
    soff = Int(_i32(ssm, off + 4))
    return _read_string_bucket(ssm, bkt, soff, len)
end

# string bucket: 4 leading Int32 (free-list, usedLength, nDeleted, nextBucket)
# then the character area; a value may span buckets via nextBucket.
function _read_string_bucket(ssm::StandardStMan, bkt::Int, offset::Int, len::Int)
    intsz = 4
    start = 4 * intsz
    out = IOBuffer()
    remaining = len
    off = offset
    while remaining > 0
        base = bucketptr(ssm, bkt)
        used = Int(_be_i32(ssm, base + intsz))
        nextbkt = Int(_be_i32(ssm, base + 3 * intsz))
        n = min(remaining, used - off)
        s = base + start + off
        write(out, @view ssm.data[s+1:s+n])
        remaining -= n
        off = 0
        remaining > 0 && (bkt = nextbkt)
    end
    return String(take!(out))
end

# iterate (bucketnr, firstrow, lastrow) over every bucket of a column's index
function _foreach_bucket(f, ssm::StandardStMan, ssmcol::Int)
    ix = ssm.indices[ssm.colindexmap[ssmcol]]
    for i in 1:ix.nused
        firstrow = i == 1 ? 1 : ix.lastrow[i-1] + 1
        f(ix.bucketnumber[i], firstrow, ix.lastrow[i])
    end
end

"""
    ssm_getcolumn(ssm, ssmcol, coldesc, nrow) -> Vector / Array

Read all `nrow` cells of column `ssmcol` (1-based).  Returns a `Vector`
for scalars and a `Vector{Array}` for direct-array columns.
"""
function ssm_getcolumn(ssm::StandardStMan, ssmcol::Int, c::ColumnDesc, nrow::Integer)
    coloff = ssm.columnoffset[ssmcol]
    nrelem = _nrelem(c)

    if c.type == TpBool
        out = Vector{Bool}(undef, nrow * nrelem)
        _foreach_bucket(ssm, ssmcol) do bkt, first, last
            n = (last - first + 1) * nrelem
            bits = _read_bits(ssm, bucketptr(ssm, bkt) + coloff, 0, n)
            copyto!(out, (first - 1) * nrelem + 1, bits, 1, n)
        end
        return isempty(c.fixedshape) ? out :
               [reshape(out[(r-1)*nrelem+1 : r*nrelem], c.fixedshape...) for r in 1:nrow]

    elseif c.type == TpString
        return [ssm_getcell(ssm, ssmcol, c, r) for r in 1:nrow]

    else
        T = juliatype(c.type)
        flat = Vector{T}(undef, nrow * nrelem)
        _foreach_bucket(ssm, ssmcol) do bkt, first, last
            n = (last - first + 1) * nrelem
            off = bucketptr(ssm, bkt) + coloff
            raw = reinterpret(T, @view ssm.data[off+1 : off + n*sizeof(T)])
            base = (first - 1) * nrelem
            @inbounds for k in 1:n
                flat[base + k] = _swap(ssm, raw[k])
            end
        end
        isempty(c.fixedshape) && return flat
        return [reshape(flat[(r-1)*nrelem+1 : r*nrelem], c.fixedshape...) for r in 1:nrow]
    end
end
