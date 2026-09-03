# IncrementalStMan (ISM) reader + writer.
#
# Mirrors casacore/tables/DataMan/ISMBase.cc, ISMIndex.cc, ISMBucket.cc,
# ISMColumn.cc, ISMIndColumn.cc.
#
# ISM stores a value only when it differs from the previous row ("store on
# change").  `table.f<seqnr>` layout (every integer in the table's byte
# order):
#   * bytes [0, ISM_LEADER)                : AipsIO "IncrementalStMan"
#                                            header, zero-padded
#   * bytes [ISM_LEADER, +nbucket*len)     : the data buckets
#   * remainder                            : AipsIO "ISMIndex" (row->bucket)
#
# A bucket is  [uInt woffset][data part][index part][free space].  The low
# 28 bits of `woffset` (ISM_IDXOFF_MASK) give the byte offset of the index
# part; the top nibble (ISM_ROWNR64_MASK) flags 64-bit row numbers.  The
# index part holds, per bound column,
#   [uInt nr][nr * uInt(/uInt64) bucket-relative 0-based row][nr * uInt off]
# where each `off` is measured from the first data byte (`base + ISM_UINT`).
# A stored value is valid from its row until the next stored row (or the
# bucket end).  Indirect (variable-shape) array columns store an 8-byte
# Int64 offset into `table.f<seqnr>i` (a version-1 StManArrayFile).
#
# casacore auto-sizes a bucket to hold ISM_TARGET_ROWS rows, clamped to
# [ISM_MIN_BUCKET, ISM_MAX_BUCKET] (ISMBase::init).
#
# Rows and column numbers are 1-based in this file's API.

const ISM_LEADER       = 512           # fixed header-leader size; bucket 0 starts here
const ISM_UINT         = 4             # canonical uInt size (index words, offsets)
const ISM_INDEX_ENTRY  = 2 * ISM_UINT  # one (row number, data offset) index pair
const ISM_MIN_BUCKET   = 32768         # casacore auto bucket-size floor
const ISM_MAX_BUCKET   = 327680        # casacore auto bucket-size soft ceiling
const ISM_TARGET_ROWS  = 100           # casacore auto bucket-size target rows/bucket
const ISM_ROWNR64_MASK = 0xf0000000    # woffset top nibble: 64-bit row numbers
const ISM_IDXOFF_MASK  = 0x0fffffff    # woffset low 28 bits: byte offset of index part

# AipsIO object versions we write (casacore accepts these for a modern table)
const ISM_HDR_VERSION   = 5   # "IncrementalStMan" header, little-endian (4 for big-endian)
const ISMINDEX_VERSION  = 1   # "ISMIndex", 32-bit row numbers (2 would be 64-bit)
const ISM_DM_VERSION    = 3   # the "ISM" record in table.dat

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
    path::String           # the `table.f<seq>` path (for the `...i` array file)
    arrayfile::Union{ArrayFile,Nothing}   # lazily opened `table.f<seq>i`
end

_u32(ism, off) = (ism.endian === :big ? ntoh : ltoh)(reinterpret(UInt32, view(ism.data, off+1:off+4))[1])
_ism_i64(ism, off) = (ism.endian === :big ? ntoh : ltoh)(reinterpret(Int64, view(ism.data, off+1:off+8))[1])

# `table.f<seq>i` --- opened on first indirect-array access, then memoized.
function _arrayfile!(ism::IncrementalStMan)
    ism.arrayfile === nothing &&
        (ism.arrayfile = open_arrayfile(ism.path * "i", ism.endian))
    return ism.arrayfile
end

# How column `c` is stored in an ISM bucket data part:
#   :scalar  fixed-width scalar (incl. variable-length scalar string)
#   :direct  fixed-shape array laid out inline
#   :ind     variable-shape array -> Int64 offset into `table.f<seq>i`
_ismkind(c::ColumnDesc{<:Dims}) = isempty(c.shape) ? :scalar : :direct
_ismkind(c::ColumnDesc) = :ind

function open_incrementalstman(t::Table, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.sequ)")
    bytes = read(path)
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

    idxpos = ISM_LEADER + nbucket * bucketsize
    ia = AipsIO(IOBuffer(@view bytes[idxpos+1:end]); endian)
    iv = getstart(ia, "ISMIndex")
    used = Int(read_u32(ia))
    ondisk = iv > 1 ? read_block(ia, UInt64) : read_block(ia, UInt32)
    rows = Int[Int(x) + 1 for x in ondisk]       # on-disk row starts are 0-based
    bucket = Int.(read_block(ia, UInt32))
    getend(ia)

    return IncrementalStMan(bytes, endian, bucketsize, nbucket,
                            ISMIndex(used, rows, bucket), path, nothing)
end

# --- bucket index parsing -----------------------------------------

# Parse the per-column (rownumbers, offsets) index of one bucket, for the
# first `ncol` columns.  Returns the vectors for column `colnr` (1-based).
function _ism_colindex(ism::IncrementalStMan, bucketnr::Int, colnr::Int, ncol::Int)
    base = ISM_LEADER + bucketnr * ism.length
    hdr = _u32(ism, base)
    use64 = (hdr & ISM_ROWNR64_MASK) != 0
    p = base + Int(hdr & ISM_IDXOFF_MASK)     # start of the index part
    rownr_t = use64 ? UInt64 : UInt32
    local rownrs, offsets
    for i in 1:ncol
        nr = Int(_u32(ism, p)); p += ISM_UINT
        rr = Vector{Int}(undef, nr)
        for j in 1:nr
            rr[j] = Int((ism.endian === :big ? ntoh : ltoh)(
                reinterpret(rownr_t, view(ism.data, p+1:p+sizeof(rownr_t)))[1]))
            p += sizeof(rownr_t)
        end
        oo = Vector{Int}(undef, nr)
        for j in 1:nr
            oo[j] = Int(_u32(ism, p)); p += ISM_UINT
        end
        if i == colnr
            rownrs, offsets = rr, oo
        end
    end
    return rownrs, offsets, base + ISM_UINT   # data part starts after `woffset`
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
    if _ismkind(c) === :ind
        foff = Int(_ism_i64(ism, dataoff))
        foff == 0 && return juliatype(c.type)[]      # shape not defined for this row
        return af_read(_arrayfile!(ism), c.type, foff)
    end

    dims = _dims(c)
    nrelem = isempty(dims) ? 1 : prod(dims)
    swap = ism.endian === :big ? ntoh : ltoh

    if c.type == TpBool
        bits = Bool[(ism.data[dataoff + (k >> 3) + 1] >> (k & 7)) & 0x01 == 0x01
                    for k in 0:nrelem-1]
        return isempty(dims) ? bits[1] : reshape(bits, dims...)
    elseif c.type == TpString
        isempty(dims) || error("ISM string arrays not supported yet")
        total = Int(_u32(ism, dataoff))                       # counts the length word
        return String(ism.data[dataoff + ISM_UINT + 1 : dataoff + total])
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
    kind = _ismkind(c)
    scalar = kind === :scalar && c.type != TpString
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

# =====================  writer  =====================================
# Fresh sequential fill: buckets filled left-to-right, a value stored only
# when it differs from the value currently in effect ("store on change").
# Layout: [ISM_LEADER header][nbucket * bucketsize][AipsIO "ISMIndex"].

# append `x` (a bitstype) to `buf` in `endian` byte order; return its offset
function _append_val!(buf::Vector{UInt8}, x, endian::Symbol)
    off = length(buf)
    resize!(buf, off + sizeof(x))
    _wrbytes!(buf, off, x, endian)
    return off
end

# one stored value in the bucket data part
function _ism_encode!(buf::Vector{UInt8}, c::ColumnDesc, kind::Symbol, v,
                      endian::Symbol, afw::ArrayFileWriter)
    if kind === :ind
        foff = (v isa AbstractArray && isempty(v)) ? Int64(0) : af_put!(afw, c.type, v)
        _append_val!(buf, Int64(foff), endian)
    elseif c.type == TpBool
        n = kind === :scalar ? 1 : prod(_dims(c))
        packed = zeros(UInt8, cld(n, 8))
        vv = v isa AbstractArray ? vec(v) : (v,)
        for k in 0:n-1
            vv[k+1] && (packed[(k >> 3) + 1] |= (0x01 << (k & 7)))
        end
        append!(buf, packed)
    elseif c.type == TpString
        s = codeunits(String(v))
        _append_val!(buf, UInt32(ISM_UINT + length(s)), endian)   # length word counts itself
        append!(buf, s)
    else
        J = juliatype(c.type)
        vv = v isa AbstractArray ? vec(v) : (v,)
        for x in vv
            _append_val!(buf, J(x), endian)
        end
    end
end

# casacore's per-column contribution to the minimum bucket size
# (ISMBase::init): one index-entry pair plus one stored value.
function _ism_fixedsize(c::ColumnDesc, kind::Symbol)
    nrelem() = kind === :scalar ? 1 : prod(_dims(c))
    valbytes = kind === :ind ? sizeof(Int64) :
               c.type == TpString ? 2 * ISM_UINT :           # variable: length word + one char
               c.type == TpBool ? cld(nrelem(), 8) :
               sizeof(juliatype(c.type)) * nrelem()
    return ISM_INDEX_ENTRY + valbytes
end

"""
    write_incrementalstman(dir, sequ, cols, coldata, nrow, endian) -> Vector{UInt8}

Write `table.f<sequ>` (+ `table.f<sequ>i` for indirect columns) for an
IncrementalStMan holding `cols` in order, and return the `"ISM"` record for
the table.dat column-set section.
"""
function write_incrementalstman(dir::AbstractString, sequ::Int,
                                cols::Vector{<:ColumnDesc}, coldata::Vector,
                                nrow::Int, endian::Symbol)
    ncol = length(cols)
    kinds = Symbol[_ismkind(c) for c in cols]
    # per-bucket index header: `woffset` + one `nr` word per column
    headersize = ISM_UINT * (ncol + 1)
    perrow = sum(_ism_fixedsize(cols[i], kinds[i]) for i in 1:ncol; init=0)  # ~worst case
    bucketsize = clamp(headersize + ISM_TARGET_ROWS * perrow,
                       ISM_MIN_BUCKET, ISM_MAX_BUCKET)
    rpb = max(1, (bucketsize - headersize) ÷ max(perrow, 1))
    nbucket = max(1, cld(nrow, rpb))

    afw = ArrayFileWriter(; endian, version=1)               # ISM array files are version 1
    have_ind = any(k -> k === :ind, kinds)

    # build every bucket
    bkts = Vector{Tuple{Vector{UInt8},Vector{Vector{Tuple{Int,Int}}}}}(undef, nbucket)
    for b in 0:nbucket-1
        r0 = b * rpb
        r1 = min(nrow, r0 + rpb)
        databuf = UInt8[]
        entries = [Tuple{Int,Int}[] for _ in 1:ncol]
        for i in 1:ncol
            haveprev = false
            prev = nothing
            for lr in 0:(r1 - r0 - 1)
                v = coldata[i][r0 + lr + 1]
                if !haveprev || !isequal(v, prev)
                    off = length(databuf)
                    _ism_encode!(databuf, cols[i], kinds[i], v, endian, afw)
                    push!(entries[i], (lr, off))
                    prev = v
                    haveprev = true
                end
            end
        end
        bkts[b + 1] = (databuf, entries)
    end

    # grow the bucket size if a bucket's data + index part needs more, and
    # keep casacore's `>= headersize + 2*perrow` floor (ISMBase::init)
    for (databuf, entries) in bkts
        idxlen = ISM_UINT * ncol +
                 sum(length(e) for e in entries; init=0) * ISM_INDEX_ENTRY
        bucketsize = max(bucketsize, ISM_UINT + length(databuf) + idxlen)
    end
    bucketsize = max(bucketsize, headersize + 2 * perrow)

    # ISMIndex blob
    iw = AipsWriter(; endian)
    putstart(iw, "ISMIndex", ISMINDEX_VERSION)
    wr_u32(iw, nbucket)                                      # nused
    startrows = UInt32[b * rpb for b in 0:nbucket-1]
    push!(startrows, UInt32(nrow))                           # sentinel
    wr_block(iw, startrows)                                  # 0-based bucket start rows
    wr_block(iw, UInt32.(0:nbucket-1))                       # bucket numbers
    putend(iw)
    idxblob = bytes(iw)

    # header
    hw = AipsWriter(; endian)
    putstart(hw, "IncrementalStMan", endian === :big ? ISM_HDR_VERSION - 1 : ISM_HDR_VERSION)
    endian === :big || wr_scalar(hw, false)                  # bigEndian flag
    wr_u32(hw, bucketsize)
    wr_u32(hw, nbucket)
    wr_u32(hw, 0)                                            # persCacheSize
    wr_u32(hw, count(k -> k === :ind, kinds))                # uniqnr
    wr_u32(hw, 0)                                            # nFreeBucket
    wr_i32(hw, -1)                                           # firstFreeBucket
    putend(hw)
    hdr = bytes(hw)
    @assert length(hdr) <= ISM_LEADER

    file = zeros(UInt8, ISM_LEADER + nbucket * bucketsize + length(idxblob))
    copyto!(file, 1, hdr, 1, length(hdr))
    for b in 0:nbucket-1
        databuf, entries = bkts[b + 1]
        base = ISM_LEADER + b * bucketsize
        woffset = ISM_UINT + length(databuf)                 # offset of the index part
        _wrbytes!(file, base, UInt32(woffset), endian)
        copyto!(file, base + ISM_UINT + 1, databuf, 1, length(databuf))
        p = base + woffset
        for i in 1:ncol
            _wrbytes!(file, p, UInt32(length(entries[i])), endian); p += ISM_UINT
            for (rr, _) in entries[i]
                _wrbytes!(file, p, UInt32(rr), endian); p += ISM_UINT
            end
            for (_, oo) in entries[i]
                _wrbytes!(file, p, UInt32(oo), endian); p += ISM_UINT
            end
        end
    end
    copyto!(file, ISM_LEADER + nbucket * bucketsize + 1, idxblob, 1, length(idxblob))

    write(joinpath(dir, "table.f$sequ"), file)
    have_ind && write(joinpath(dir, "table.f$(sequ)i"), arrayfile_bytes(afw))

    # the "ISM" record for table.dat (always canonical big-endian there)
    bw = AipsWriter(; endian=:big)
    putstart(bw, "ISM", ISM_DM_VERSION)
    wr_string(bw, "ISM")
    putend(bw)
    return bytes(bw)
end
