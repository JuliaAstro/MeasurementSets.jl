# StandardStMan (SSM) reader + writer.
#
# Mirrors casacore/tables/DataMan/SSMBase.cc, SSMIndex.cc, SSMColumn.cc,
# SSMDirColumn.cc, SSMIndColumn.cc, SSMIndStringColumn.cc, SSMStringHandler.cc.
#
# On-disk layout of `table.f<seqnr>`:
#   * bytes [0, SSM_LEADER)                : AipsIO "StandardStMan" header
#   * bytes [SSM_LEADER, +nbucket*len)     : equal-size buckets
# Bucket kinds (data / string / index) are assigned by the header + SSMIndex,
# not tagged in the bucket.  Every stored integer is in the table's byte
# order EXCEPT the string-bucket and index-bucket headers, which casacore
# always writes big-endian (CanonicalConversion):
#   data bucket   : fixed-length cells laid out column by column
#   string bucket : [SSM_STRBUCKET_HEADER = 4 big-endian Int32
#                    (freeList, usedLength, nDeleted, nextBucket)][chars...]
#   index bucket  : [SSM_IDXBUCKET_HEADER = 2 big-endian Int32
#                    (checkNr, nextBucket)][serialized SSMIndex bytes...]
#
# A variable-length string cell is SSM_STRING_REF bytes = 3 Int32 (bucketNr,
# offset, length); a string of <= SSM_STRING_INLINE_MAX chars is stored
# inline in the first 8 bytes of the cell instead.  An indirect
# (variable-shape) non-string array cell is an SSM_INDARR_REF-byte Int64
# offset into `table.f<seqnr>i`.
#
# Rows and SSM column numbers are 1-based in this file's API; the on-disk
# 0-based values are converted at parse time.  Bucket numbers and byte
# offsets stay as raw file-layout quantities.

const SSM_LEADER            = 512   # header-leader size; bucket 0 starts here
const SSM_INT               = 4     # canonical Int32 / uInt size
const SSM_STRING_REF        = 3 * SSM_INT   # var-string cell: (bucket, offset, length)
const SSM_STRING_INLINE_MAX = 8     # strings this short are stored inline in the cell
const SSM_INDARR_REF        = 8     # indirect-array cell: one Int64 file offset
const SSM_STRBUCKET_HEADER  = 4 * SSM_INT   # string bucket: 4 leading Int32
const SSM_IDXBUCKET_HEADER  = 2 * SSM_INT   # index bucket: 2 leading Int32
const SSM_WRITE_ROWS_PER_BUCKET = 1024      # writer: max data rows packed per bucket

# AipsIO object versions we write
const SSM_HDR_VERSION  = 3   # "StandardStMan" header
const SSMINDEX_VERSION = 1   # "SSMIndex"
const SSM_DM_VERSION   = 2   # the "SSM" record in table.dat

struct SSMIndex
    used::Int                   # number of intervals in use
    rows::Int                   # rows per bucket
    last::Vector{Int}           # last[i] = last (1-based) row in bucket i
    bucket::Vector{Int}         # physical bucket number (0-based block in file)
end

function read_ssmindex(a::AipsIO)
    version = getstart(a, "SSMIndex")
    used = Int(read_u32(a))
    rows = Int(read_u32(a))
    read_i32(a)                                   # nrColumns
    read_map(a, Int32, Int32)                     # free-space map (unused here)
    ondisk = version == 1 ? read_block(a, UInt32) : read_block(a, UInt64)
    last = Int[Int(x) + 1 for x in ondisk]        # on-disk last row is 0-based
    bucket = Int.(read_block(a, UInt32))
    getend(a)
    return SSMIndex(used, rows, last, bucket)
end

# position i within this index whose bucket holds `row` (1-based):
# the first i with last[i] >= row.
function index_of(ix::SSMIndex, row::Integer)
    for i in 1:ix.used
        ix.last[i] >= row && return i
    end
    error("SSMIndex: row $row out of range")
end

# (bucket number, first row in that bucket, last row in that bucket) — 1-based rows
function bucket_of(ix::SSMIndex, row::Integer)
    i = index_of(ix, row)
    firstrow = i == 1 ? 1 : ix.last[i-1] + 1
    return ix.bucket[i], firstrow, ix.last[i]
end

# ---------------------------------------------------------------------

mutable struct StandardStMan
    data::Vector{UInt8}
    endian::Symbol             # :big or :little
    length::Int                # bucket size in bytes
    buckets::Int               # number of buckets
    last::Int                  # last string bucket in use
    offset::Vector{Int}        # per SSM column (1-based): byte offset in bucket
    index::Vector{Int}         # per SSM column (1-based): which SSMIndex (1-based)
    indices::Vector{SSMIndex}
    path::String               # the `table.f<seq>` path (for the `...i` array file)
    arrayfile::Union{ArrayFile,Nothing}   # lazily opened `table.f<seq>i`
end

bucketptr(ssm::StandardStMan, n::Integer) = SSM_LEADER + Int(n) * ssm.length

# `table.f<seq>i` --- opened on first indirect-array access, then memoized.
function _arrayfile!(ssm::StandardStMan)
    ssm.arrayfile === nothing &&
        (ssm.arrayfile = open_arrayfile(ssm.path * "i", ssm.endian))
    return ssm.arrayfile
end

# Int32 in the table's endianness (data-bucket contents, string refs).
_i32(ssm, off) = (ssm.endian === :big ? ntoh : ltoh)(reinterpret(Int32, view(ssm.data, off+1:off+4))[1])

# Int64 in the table's endianness (indirect-array file offset in a bucket cell).
_i64(ssm, off) = (ssm.endian === :big ? ntoh : ltoh)(reinterpret(Int64, view(ssm.data, off+1:off+8))[1])

# Int32 in big-endian: casacore always uses CanonicalConversion (never the
# little-endian variant) for the string-bucket and index-bucket headers.
_be_i32(ssm, off) = ntoh(reinterpret(Int32, view(ssm.data, off+1:off+4))[1])

function read_ssm_header!(hdr::AipsIO)
    version = getstart(hdr, "StandardStMan")
    version >= 3 && read_scalar(hdr, Bool)                 # bigEndian flag
    size     = Int(read_u32(hdr))
    buckets  = Int(read_u32(hdr))
    read_u32(hdr)                                          # persCacheSize
    read_u32(hdr)                                          # freeBucketsNr
    read_i32(hdr)                                          # firstFreeBucket
    indices  = Int(read_u32(hdr))
    first    = Int(read_i32(hdr))
    offset   = version >= 2 ? Int(read_u32(hdr)) : 0
    last     = Int(read_i32(hdr))
    length   = Int(read_u32(hdr))
    nrinx    = Int(read_u32(hdr))
    getend(hdr)
    return (; version, size, buckets, indices, first, offset, last, length, nrinx)
end

function open_standardstman(t::Table, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.sequ)")
    bytes = read(path)
    endian = t.endian

    # header lives in the first SSM_LEADER bytes
    h = read_ssm_header!(AipsIO(IOBuffer(bytes); endian))

    # the SSM record embedded in table.dat (always big-endian there)
    blk = AipsIO(copy(dm.header); endian=:big)
    getstart(blk, "SSM")
    read_string(blk)                                       # data-manager name
    offset = Int.(read_block(blk, UInt32))
    index  = Int[Int(x) + 1 for x in read_block(blk, UInt32)]   # -> 1-based
    getend(blk)

    ssm = StandardStMan(bytes, endian, h.size, h.buckets, h.last,
                        offset, index, SSMIndex[], path, nothing)

    # assemble and parse the index buckets
    idxbytes = _read_index_bytes(ssm, h)
    ia = AipsIO(IOBuffer(idxbytes); endian)
    ssm.indices = SSMIndex[read_ssmindex(ia) for _ in 1:h.nrinx]
    return ssm
end

function _read_index_bytes(ssm::StandardStMan, h)
    h.length == 0 && return UInt8[]
    idxbucketsize = ssm.length - SSM_IDXBUCKET_HEADER
    out = UInt8[]
    bkt = h.first
    remaining = h.length
    for _ in 1:h.indices
        base = bucketptr(ssm, bkt)
        nextbkt = _be_i32(ssm, base + SSM_INT)           # checkNr, then nextBucket
        if h.offset > 0
            s = base + h.offset
            append!(out, @view ssm.data[s+1:s+h.length])
        else
            take = min(remaining, idxbucketsize)
            s = base + SSM_IDXBUCKET_HEADER
            append!(out, @view ssm.data[s+1:s+take])
        end
        remaining -= idxbucketsize
        bkt = nextbkt
    end
    return out
end

# --- per-column geometry ---------------------------------------------

# The fixed cell shape as a `Dims` (scalar -> `()`).
_dims(c::ColumnDesc{<:Dims}) = c.shape
_dims(c::ColumnDesc) = error("column \"$(c.name)\": not a fixed-shape column")

# How column `c` is stored in an SSM data bucket:
#   :scalar  fixed-width scalar (incl. variable-length scalar string)
#   :direct  fixed-shape array laid out inline
#   :indarr  variable-shape non-string array -> Int64 offset into `table.f<seq>i`
#   :indstr  variable-shape string array     -> 12-byte string-bucket ref
_ssmkind(c::ColumnDesc{<:Dims}) = isempty(c.shape) ? :scalar : :direct
_ssmkind(c::ColumnDesc) = c.type == TpString ? :indstr : :indarr

_nrelem(c::ColumnDesc) = (s = _dims(c); isempty(s) ? 1 : prod(s))

"Canonical byte width of one stored cell for column `c`."
function cell_extsize(c::ColumnDesc)
    k = _ssmkind(c)
    k === :indarr && return SSM_INDARR_REF
    k === :indstr && return SSM_STRING_REF
    nrelem = _nrelem(c)
    if c.type == TpString
        return c.maxlength > 0 ? Int(c.maxlength) : SSM_STRING_REF
    elseif c.type == TpBool
        return cld(nrelem, 8)                                # bit-packed
    else
        return sizeof(juliatype(c.type)) * nrelem
    end
end

# --- value access ---------------------------------------------------

"Byte offset into `ssm.data` of column `ssmcol`'s block in the bucket
holding `row`, plus that bucket's first row (1-based)."
function locate(ssm::StandardStMan, ssmcol::Int, row::Integer)
    ix = ssm.indices[ssm.index[ssmcol]]
    bkt, firstrow, _ = bucket_of(ix, row)
    return bucketptr(ssm, bkt) + ssm.offset[ssmcol], firstrow
end

_swap(ssm::StandardStMan, x) = ssm.endian === :big ? ntoh(x) : ltoh(x)

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
    kind = _ssmkind(c)
    ext = cell_extsize(c)
    off, firstrow = locate(ssm, ssmcol, row)
    inbucket = Int(row) - firstrow          # 0-based position within the bucket

    if kind === :indarr
        foff = Int(_i64(ssm, off + inbucket * SSM_INDARR_REF))
        foff == 0 && return juliatype(c.type)[]      # shape not defined for this row
        return af_read(_arrayfile!(ssm), c.type, foff)
    elseif kind === :indstr
        return _read_string_array(ssm, off + inbucket * SSM_STRING_REF)
    end

    dims = _dims(c)
    nrelem = isempty(dims) ? 1 : prod(dims)

    if c.type == TpBool
        bits = _read_bits(ssm, off, inbucket * nrelem, nrelem)
        return isempty(dims) ? bits[1] : reshape(bits, dims...)
    elseif c.type == TpString
        c.maxlength > 0 && error("fixed-length strings not yet supported")
        isempty(dims) || error("string arrays not yet supported (Phase 2)")
        return _read_string_ref(ssm, off + inbucket * ext)
    elseif isempty(dims)
        return _read_elems(ssm, juliatype(c.type), off + inbucket * ext, 1)[1]
    else
        vals = _read_elems(ssm, juliatype(c.type), off + inbucket * ext, nrelem)
        return reshape(vals, dims...)
    end
end

# variable-length scalar string cell: 3 Int32 (bucketNr, offset, length); a
# string of <= SSM_STRING_INLINE_MAX chars sits inline in the first 8 bytes.
function _read_string_ref(ssm::StandardStMan, off::Int)
    len = Int(_i32(ssm, off + 2 * SSM_INT))               # 3rd Int32 = length
    len <= 0 && return ""
    if len <= SSM_STRING_INLINE_MAX
        return String(ssm.data[off+1:off+len])
    end
    bkt = Int(_i32(ssm, off))
    soff = Int(_i32(ssm, off + SSM_INT))
    return _read_string_bucket(ssm, bkt, soff, len)
end

# string bucket: SSM_STRBUCKET_HEADER = 4 leading big-endian Int32 (free
# list, usedLength, nDeleted, nextBucket) then the character area; a value
# may span buckets via nextBucket.
function _read_string_bytes(ssm::StandardStMan, bkt::Int, offset::Int, len::Int)
    out = IOBuffer()
    remaining = len
    off = offset
    while remaining > 0
        base = bucketptr(ssm, bkt)
        usedlen = Int(_be_i32(ssm, base + SSM_INT))       # header field 2
        nextbkt = Int(_be_i32(ssm, base + 3 * SSM_INT))   # header field 4
        n = min(remaining, usedlen - off)
        s = base + SSM_STRBUCKET_HEADER + off
        write(out, @view ssm.data[s+1:s+n])
        remaining -= n
        off = 0
        remaining > 0 && (bkt = nextbkt)
    end
    return take!(out)
end

_read_string_bucket(ssm::StandardStMan, bkt::Int, offset::Int, len::Int) =
    String(_read_string_bytes(ssm, bkt, offset, len))

# indirect string array (SSMIndStringColumn): the 12-byte cell is the same
# (bucketNr, offset, totalLength) triple as a scalar string; the blob in the
# string bucket is  [ndim:uInt][dim:Int x ndim][filled:uInt]  then, per
# element (column-major),  [len:uInt][len bytes].  All ints big-endian.
function _read_string_array(ssm::StandardStMan, cell::Int)
    total = Int(_i32(ssm, cell + 2 * SSM_INT))        # 3rd Int32 = blob length
    total <= 0 && return String[]                     # shape not defined for this row
    bkt = Int(_i32(ssm, cell))
    off = Int(_i32(ssm, cell + SSM_INT))
    blob = _read_string_bytes(ssm, bkt, off, total)
    be32(p) = ntoh(reinterpret(Int32, @view blob[p+1:p+SSM_INT])[1])
    ndim = Int(be32(0))
    dims = ntuple(k -> Int(be32(SSM_INT * k)), ndim)  # dims right after ndim
    filled = Int(be32(SSM_INT * (ndim + 1)))          # then the "filled" flag
    p = SSM_INT * (ndim + 2)                          # elements start here
    n = prod(dims; init=1)
    out = Vector{String}(undef, n)
    for k in 1:n
        if filled == 0
            out[k] = ""
        else
            len = Int(be32(p)); p += SSM_INT
            out[k] = String(@view blob[p+1:p+len]); p += len
        end
    end
    return reshape(out, dims)
end

# Build the string-bucket blob for one indirect string-array cell (inverse
# of `_read_string_array`).  All header ints big-endian.
function _string_array_blob(arr)
    out = IOBuffer()
    be(x) = write(out, hton(x))
    shp = size(arr)
    be(UInt32(length(shp)))
    for d in shp; be(Int32(d)); end
    be(UInt32(1))                                     # "filled" flag
    for s in vec(arr)
        b = codeunits(String(s))
        be(UInt32(length(b)))
        write(out, b)
    end
    return take!(out)
end

# iterate (bucketnr, firstrow, lastrow) over every bucket of a column's index
function _foreach_bucket(f, ssm::StandardStMan, ssmcol::Int)
    ix = ssm.indices[ssm.index[ssmcol]]
    for i in 1:ix.used
        firstrow = i == 1 ? 1 : ix.last[i-1] + 1
        f(ix.bucket[i], firstrow, ix.last[i])
    end
end

"""
    ssm_getcolumn(ssm, ssmcol, coldesc, nrow) -> Vector / Array

Read all `nrow` cells of column `ssmcol` (1-based).  Returns a `Vector`
for scalars and a `Vector{Array}` for direct-array columns.
"""
function ssm_getcolumn(ssm::StandardStMan, ssmcol::Int, c::ColumnDesc, nrow::Integer)
    kind = _ssmkind(c)
    if kind === :indarr || kind === :indstr
        return [ssm_getcell(ssm, ssmcol, c, r) for r in 1:nrow]   # small side tables
    end

    dims = _dims(c)
    coloff = ssm.offset[ssmcol]
    nrelem = isempty(dims) ? 1 : prod(dims)

    if c.type == TpBool
        out = Vector{Bool}(undef, nrow * nrelem)
        _foreach_bucket(ssm, ssmcol) do bkt, firstrow, lastrow
            n = (lastrow - firstrow + 1) * nrelem
            bits = _read_bits(ssm, bucketptr(ssm, bkt) + coloff, 0, n)
            copyto!(out, (firstrow - 1) * nrelem + 1, bits, 1, n)
        end
        return isempty(dims) ? out :
               [reshape(out[(r-1)*nrelem+1 : r*nrelem], dims...) for r in 1:nrow]

    elseif c.type == TpString
        return [ssm_getcell(ssm, ssmcol, c, r) for r in 1:nrow]

    else
        T = juliatype(c.type)
        flat = Vector{T}(undef, nrow * nrelem)
        _foreach_bucket(ssm, ssmcol) do bkt, firstrow, lastrow
            n = (lastrow - firstrow + 1) * nrelem
            off = bucketptr(ssm, bkt) + coloff
            raw = reinterpret(T, @view ssm.data[off+1 : off + n*sizeof(T)])
            base = (firstrow - 1) * nrelem
            @inbounds for k in 1:n
                flat[base + k] = _swap(ssm, raw[k])
            end
        end
        isempty(dims) && return flat
        return [reshape(flat[(r-1)*nrelem+1 : r*nrelem], dims...) for r in 1:nrow]
    end
end

# =====================  writer  =====================================
# Fresh, sequential fill: one bucket stream, no free list, no bucket
# splitting.  Layout: [data buckets][string buckets][index bucket].

_wrbytes!(buf, off, x, endian) = begin
    v = _toendian(endian, x)
    copyto!(buf, off + 1, reinterpret(UInt8, [v]), 1, sizeof(x))
end

"""
    write_standardstman(dir, sequ, cols, coldata, nrow, endian) -> Vector{UInt8}

Write `table.f<sequ>` for a StandardStMan holding `cols` (in order), and
return the `"SSM"` record for the table.dat column-set section.  `coldata[i]`
is a length-`nrow` vector of cell values for `cols[i]`.
"""
function write_standardstman(dir::AbstractString, sequ::Int,
                             cols::Vector{<:ColumnDesc}, coldata::Vector,
                             nrow::Int, endian::Symbol)
    ncol = length(cols)
    swap(x) = _toendian(endian, x)
    kinds  = [_ssmkind(c) for c in cols]
    exts   = [cell_extsize(c) for c in cols]
    nelems = [kinds[i] in (:indarr, :indstr) ? 0 : _nrelem(cols[i]) for i in 1:ncol]
    isbool = [cols[i].type == TpBool && kinds[i] !== :indarr for i in 1:ncol]

    rpb = clamp(nrow, 1, SSM_WRITE_ROWS_PER_BUCKET)
    blocksz(i) = isbool[i] ? cld(rpb * nelems[i], 8) : exts[i] * rpb   # 8 = bits/byte
    bs = [blocksz(i) for i in 1:ncol]
    coloffset = Int[sum(bs[1:i-1]) for i in 1:ncol]
    datasize = sum(bs)
    ndata = cld(nrow, rpb)

    # --- indirect non-string arrays -> the `table.f<sequ>i` array file ---
    afw = ArrayFileWriter(; endian, version=0)
    have_indarr = any(k -> k === :indarr, kinds)
    indoffsets = [Int64[] for _ in 1:ncol]           # per :indarr column, per row
    for i in 1:ncol
        kinds[i] === :indarr || continue
        for r in 1:nrow
            v = coldata[i][r]
            push!(indoffsets[i],
                  isempty(v) ? Int64(0) : af_put!(afw, cols[i].type, v))
        end
    end

    # --- variable strings: build the string stream + per-cell refs -----
    strstream = UInt8[]
    strref = [Vector{NTuple{3,Int}}(undef, 0) for _ in 1:ncol]   # (bkt,off,len) or inline
    inlinechars = [Dict{Int,Vector{UInt8}}() for _ in 1:ncol]

    # index bytes: SSMIndex `itsLastRow` (0-based last row of each bucket)
    idxrows = UInt32[min((k + 1) * rpb, nrow) - 1 for k in 0:ndata-1]
    iw = AipsWriter(; endian)
    putstart(iw, "SSMIndex", SSMINDEX_VERSION)
    wr_u32(iw, ndata); wr_u32(iw, rpb); wr_i32(iw, ncol)
    putstart(iw, "SimpleOrderedMap", 1)                  # empty free-space map
    wr_i32(iw, 0); wr_u32(iw, 0); wr_u32(iw, 1); putend(iw)
    wr_block(iw, idxrows)
    wr_block(iw, UInt32.(0:ndata-1))
    putend(iw)
    idxbytes = bytes(iw)

    size = max(datasize, length(idxbytes) + SSM_IDXBUCKET_HEADER, SSM_LEADER)
    strchar = size - SSM_STRBUCKET_HEADER

    for i in 1:ncol
        (kinds[i] === :scalar && cols[i].type == TpString) || kinds[i] === :indstr || continue
        for r in 1:nrow
            s = kinds[i] === :indstr ? _string_array_blob(coldata[i][r]) :
                                       codeunits(String(coldata[i][r]))
            if length(s) <= SSM_STRING_INLINE_MAX && kinds[i] !== :indstr
                push!(strref[i], (0, 0, length(s)))
                inlinechars[i][r] = collect(s)
            else
                bkt = length(strstream) ÷ strchar
                off = length(strstream) % strchar
                append!(strstream, s)
                push!(strref[i], (bkt, off, length(s)))   # bkt is string-bucket-relative
            end
        end
    end
    nstr = isempty(strstream) ? 0 : cld(length(strstream), strchar)
    strbase = ndata                       # first string bucket number
    idxbase = ndata + nstr                # index bucket number

    # --- data buckets -----------------------------------------------
    file = zeros(UInt8, SSM_LEADER + (ndata + nstr + 1) * size)
    _bp(n) = SSM_LEADER + n * size
    for k in 0:ndata-1
        base = _bp(k)
        r0 = k * rpb
        nr = min(rpb, nrow - r0)
        for i in 1:ncol
            c = cols[i]; co = base + coloffset[i]; ext = exts[i]; nel = nelems[i]
            if kinds[i] === :indarr
                for lr in 0:nr-1
                    _wrbytes!(file, co + lr * SSM_INDARR_REF,
                              Int64(indoffsets[i][r0 + lr + 1]), endian)
                end
            elseif isbool[i]
                for lr in 0:nr-1, e in 0:nel-1
                    v = coldata[i][r0 + lr + 1]
                    bit = (v isa AbstractArray ? v[e+1] : v)::Bool
                    if bit
                        b = lr * nel + e
                        file[co + (b >> 3) + 1] |= (0x01 << (b & 7))
                    end
                end
            elseif c.type == TpString
                for lr in 0:nr-1
                    r = r0 + lr + 1
                    o = co + lr * SSM_STRING_REF
                    bkt, soff, len = strref[i][r]
                    if haskey(inlinechars[i], r)
                        cs = inlinechars[i][r]
                        copyto!(file, o + 1, cs, 1, length(cs))
                    else
                        _wrbytes!(file, o,               Int32(strbase + bkt), endian)
                        _wrbytes!(file, o + SSM_INT,     Int32(soff), endian)
                    end
                    _wrbytes!(file, o + 2 * SSM_INT, Int32(len), endian)
                end
            else
                J = juliatype(c.type)
                for lr in 0:nr-1
                    v = coldata[i][r0 + lr + 1]
                    o = co + lr * ext
                    if nel == 1
                        _wrbytes!(file, o, J(v), endian)
                    else
                        vv = vec(v)
                        for e in 1:nel
                            _wrbytes!(file, o + (e-1)*sizeof(J), J(vv[e]), endian)
                        end
                    end
                end
            end
        end
    end

    # --- string buckets (headers are big-endian) -------------------
    # Buckets are chained k -> k+1 so a value straddling a `strchar`
    # boundary is followed via `nextBucket` on read.
    for k in 0:nstr-1
        base = _bp(strbase + k)
        s0 = k * strchar
        used = min(strchar, length(strstream) - s0)
        _wrbytes!(file, base,               Int32(0), :big)              # free list
        _wrbytes!(file, base + SSM_INT,     Int32(used), :big)           # usedLength
        _wrbytes!(file, base + 2 * SSM_INT, Int32(strchar - used), :big) # nDeleted
        _wrbytes!(file, base + 3 * SSM_INT,                              # nextBucket
                  Int32(k < nstr - 1 ? strbase + k + 1 : -1), :big)
        copyto!(file, base + SSM_STRBUCKET_HEADER + 1, strstream, s0 + 1, used)
    end

    # --- index bucket ------------------------------------------------
    ibase = _bp(idxbase)
    _wrbytes!(file, ibase,           Int32(idxbase), :big)  # check number
    _wrbytes!(file, ibase + SSM_INT, Int32(-1), :big)       # next index bucket
    copyto!(file, ibase + SSM_IDXBUCKET_HEADER + 1, idxbytes, 1, length(idxbytes))

    # --- header (zero-padded to SSM_LEADER) -----------------------
    hw = AipsWriter(; endian)
    putstart(hw, "StandardStMan", SSM_HDR_VERSION)
    wr_scalar(hw, endian === :big)
    wr_u32(hw, size)
    wr_u32(hw, ndata + nstr + 1)          # nrBuckets
    wr_u32(hw, 2)                         # persCacheSize (casacore default)
    wr_u32(hw, 0)                         # nFreeBucket
    wr_i32(hw, -1)                        # firstFreeBucket
    wr_u32(hw, 1)                         # nrIdxBuckets
    wr_i32(hw, idxbase)                   # firstIdxBucket
    wr_u32(hw, 0)                         # idxBucketOffset
    wr_i32(hw, nstr > 0 ? strbase + nstr - 1 : -1)   # lastStringBucket
    wr_u32(hw, length(idxbytes))
    wr_u32(hw, 1)                         # nrinx
    putend(hw)
    hdr = bytes(hw)
    @assert length(hdr) <= SSM_LEADER
    copyto!(file, 1, hdr, 1, length(hdr))

    _atomic_write(joinpath(dir, "table.f$sequ"), file)
    have_indarr && _atomic_write(joinpath(dir, "table.f$(sequ)i"), arrayfile_bytes(afw))

    # --- the "SSM" record for table.dat --------------------------
    bw = AipsWriter(; endian=:big)
    putstart(bw, "SSM", SSM_DM_VERSION)
    wr_string(bw, "SSM")
    wr_block(bw, UInt32.(coloffset))
    wr_block(bw, fill(UInt32(0), ncol))   # colIndexMap: all in index 0
    putend(bw)
    return bytes(bw)
end
