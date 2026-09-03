# StandardStMan (SSM) reader.
#
# Mirrors casacore/tables/DataMan/SSMBase.cc, SSMIndex.cc, SSMColumn.cc,
# SSMDirColumn.cc, SSMStringHandler.cc.
#
# On-disk layout of `table.f<seqnr>`:
#   * bytes [0, 512)          : AipsIO "StandardStMan" header
#   * bytes [512, 512+k*len)  : k equally-sized buckets
# Bucket kinds: data buckets (fixed-length cells laid out column by column),
# string buckets (variable-length strings), index buckets (the row->bucket
# maps).  Which bucket is which is recorded in the header / index.
#
# Rows and SSM column numbers are 1-based in this file's API; the on-disk
# 0-based values are converted at parse time.  Bucket numbers and byte
# offsets stay as raw file-layout quantities.

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
end

bucketptr(ssm::StandardStMan, n::Integer) = 512 + Int(n) * ssm.length

# Int32 in the table's endianness (data-bucket contents, string refs).
_i32(ssm, off) = (ssm.endian === :big ? ntoh : ltoh)(reinterpret(Int32, view(ssm.data, off+1:off+4))[1])

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

function open_standardstman(t::CTDSTable, dm::DataManagerInfo)
    bytes = read(joinpath(t.path, "table.f$(dm.sequ)"))
    endian = t.endian

    # header lives in the first 512 bytes
    h = read_ssm_header!(AipsIO(IOBuffer(bytes); endian))

    # the SSM record embedded in table.dat (always big-endian there)
    blk = AipsIO(copy(dm.header); endian=:big)
    getstart(blk, "SSM")
    read_string(blk)                                       # data-manager name
    offset = Int.(read_block(blk, UInt32))
    index  = Int[Int(x) + 1 for x in read_block(blk, UInt32)]   # -> 1-based
    getend(blk)

    ssm = StandardStMan(bytes, endian, h.size, h.buckets, h.last,
                        offset, index, SSMIndex[])

    # assemble and parse the index buckets
    idxbytes = _read_index_bytes(ssm, h)
    ia = AipsIO(IOBuffer(idxbytes); endian)
    ssm.indices = SSMIndex[read_ssmindex(ia) for _ in 1:h.nrinx]
    return ssm
end

function _read_index_bytes(ssm::StandardStMan, h)
    h.length == 0 && return UInt8[]
    aclen = 8                                       # 2 * canonical size of Int32
    idxbucketsize = ssm.length - aclen
    out = UInt8[]
    bkt = h.first
    remaining = h.length
    for _ in 1:h.indices
        base = bucketptr(ssm, bkt)
        nextbkt = _be_i32(ssm, base + 4)
        if h.offset > 0
            s = base + h.offset
            append!(out, @view ssm.data[s+1:s+h.length])
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

# The fixed cell shape as a `Dims`; SSM cannot read variable-shape columns
# (those are stored as indirect arrays in a separate file).
_dims(c::ColumnDesc{<:Dims}) = c.shape
_dims(c::ColumnDesc) =
    error("column \"$(c.name)\": SSM reads of variable-shape arrays " *
          "(indirect arrays) are not supported yet")

_nrelem(c::ColumnDesc) = (s = _dims(c); isempty(s) ? 1 : prod(s))

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
    dims = _dims(c)                         # errors for variable-shape columns
    ext = cell_extsize(c)
    off, firstrow = locate(ssm, ssmcol, row)
    inbucket = Int(row) - firstrow          # 0-based position within the bucket
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
        usedlen = Int(_be_i32(ssm, base + intsz))
        nextbkt = Int(_be_i32(ssm, base + 3 * intsz))
        n = min(remaining, usedlen - off)
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
    dims = _dims(c)                         # errors for variable-shape columns
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
    exts   = [cell_extsize(c) for c in cols]
    nelems = [_nrelem(c) for c in cols]
    isbool = [c.type == TpBool for c in cols]

    rpb = clamp(nrow, 1, 1024)
    blocksz(i) = isbool[i] ? cld(rpb * nelems[i], 8) : exts[i] * rpb
    bs = [blocksz(i) for i in 1:ncol]
    coloffset = Int[sum(bs[1:i-1]) for i in 1:ncol]
    datasize = sum(bs)
    ndata = cld(nrow, rpb)

    # --- variable strings: build the string stream + per-cell refs -----
    strstream = UInt8[]
    strref = [Vector{NTuple{3,Int}}(undef, 0) for _ in 1:ncol]   # (bkt,off,len) or inline
    inlinechars = [Dict{Int,Vector{UInt8}}() for _ in 1:ncol]

    # index bytes: SSMIndex `itsLastRow` (0-based last row of each bucket)
    idxrows = UInt32[min((k + 1) * rpb, nrow) - 1 for k in 0:ndata-1]
    iw = AipsWriter(; endian)
    putstart(iw, "SSMIndex", 1)
    wr_u32(iw, ndata); wr_u32(iw, rpb); wr_i32(iw, ncol)
    putstart(iw, "SimpleOrderedMap", 1); wr_i32(iw, 0); wr_u32(iw, 0); wr_u32(iw, 1); putend(iw)
    wr_block(iw, idxrows)
    wr_block(iw, UInt32.(0:ndata-1))
    putend(iw)
    idxbytes = bytes(iw)

    size = max(datasize, length(idxbytes) + 8, 512)
    strchar = size - 16

    for i in 1:ncol
        cols[i].type == TpString || continue
        for r in 1:nrow
            s = codeunits(String(coldata[i][r]))
            if length(s) <= 8
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
    file = zeros(UInt8, 512 + (ndata + nstr + 1) * size)
    _bp(n) = 512 + n * size
    for k in 0:ndata-1
        base = _bp(k)
        r0 = k * rpb
        nr = min(rpb, nrow - r0)
        for i in 1:ncol
            c = cols[i]; co = base + coloffset[i]; ext = exts[i]; nel = nelems[i]
            if c.type == TpBool
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
                    o = co + lr * 12
                    bkt, soff, len = strref[i][r]
                    if haskey(inlinechars[i], r)
                        cs = inlinechars[i][r]
                        copyto!(file, o + 1, cs, 1, length(cs))
                    else
                        _wrbytes!(file, o,     Int32(strbase + bkt), endian)
                        _wrbytes!(file, o + 4, Int32(soff), endian)
                    end
                    _wrbytes!(file, o + 8, Int32(len), endian)
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
    for k in 0:nstr-1
        base = _bp(strbase + k)
        s0 = k * strchar
        used = min(strchar, length(strstream) - s0)
        _wrbytes!(file, base,      Int32(0), :big)          # free list
        _wrbytes!(file, base + 4,  Int32(used), :big)       # usedLength
        _wrbytes!(file, base + 8,  Int32(strchar - used), :big)  # nDeleted
        _wrbytes!(file, base + 12, Int32(-1), :big)         # nextBucket
        copyto!(file, base + 16 + 1, strstream, s0 + 1, used)
    end

    # --- index bucket ------------------------------------------------
    ibase = _bp(idxbase)
    _wrbytes!(file, ibase,     Int32(idxbase), :big)        # check number
    _wrbytes!(file, ibase + 4, Int32(-1), :big)             # next index bucket
    copyto!(file, ibase + 8 + 1, idxbytes, 1, length(idxbytes))

    # --- 512-byte header ------------------------------------------
    hw = AipsWriter(; endian)
    putstart(hw, "StandardStMan", 3)
    wr_scalar(hw, endian === :big)
    wr_u32(hw, size)
    wr_u32(hw, ndata + nstr + 1)          # nrBuckets
    wr_u32(hw, 2)                         # persCacheSize
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
    @assert length(hdr) <= 512
    copyto!(file, 1, hdr, 1, length(hdr))

    write(joinpath(dir, "table.f$sequ"), file)

    # --- the "SSM" record for table.dat --------------------------
    bw = AipsWriter(; endian=:big)
    putstart(bw, "SSM", 2)
    wr_string(bw, "SSM")
    wr_block(bw, UInt32.(coloffset))
    wr_block(bw, fill(UInt32(0), ncol))   # colIndexMap: all in index 0
    putend(bw)
    return bytes(bw)
end
