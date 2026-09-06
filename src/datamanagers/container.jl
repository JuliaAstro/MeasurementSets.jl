# MultiFile / MultiHDF5 --- casacore's two "container" formats that pack
# every small per-storage-manager private file of a table (`table.f<seq>`,
# `table.f<seq>i`, `table.f<seq>_TSM<k>`) into one real file on disk
# (`table.mf` / `table.mfh5`), to cut open-file-descriptor counts and help
# filesystems like Lustre.  Read + write (Phase 20 read, Phase 21 write).
# The writer only ever creates a *fresh* container in one shot -- adding a
# file to an existing container, or editing one, is not supported (no
# entry point in this package ever appends to an already-written table).
#
# Only StandardStMan / IncrementalStMan / TiledStMan ever use a container
# in real casacore -- `DataManager::hasMultiFileSupport()` defaults to
# `false` (DataManager.cc:251) and only those three override it to `true`
# (SSMBase.cc:948, ISMBase.cc:553, TiledStMan.cc:368); Dysco and the
# virtual engines never do, so `dysco.jl`/`virtual.jl` need no changes.
# A data manager registers its own `table.f<seq>...` name inside the
# container by *basename only* (`MultiFileBase::addFile`/`fileId`,
# MultiFileBase.cc:341-383, `String bname = Path(fname).baseName();`) --
# exactly what this package's callers already compute, no extra path
# manipulation needed beyond `basename(...)`.
#
# Mirrors casa/IO/MultiFile.{h,cc}, MultiFileBase.{h,cc} (MultiFile) and
# casa/IO/MultiHDF5.cc, casa/HDF5/HDF5Record.{h,cc} (MultiHDF5).  The
# container file itself lives at `<tabledir>/table.mf` or
# `<tabledir>/table.mfh5`, a sibling of `table.dat` (ColumnSet.cc:182,186).

import Mmap

# MultiHDF5 (`table.mfh5`) support lives in `ext/HDF5Ext.jl`
# and is active only when the caller has loaded `HDF5.jl` (a weak
# dependency).  The struct + entry-point stubs below are overridden there.

abstract type Container end

# ======================================================================
# write side: a task-local dynamic-scope sink shared by both formats
# ======================================================================
#
# Every per-DM writer this package has (`write_standardstman`,
# `write_incrementalstman`, the three tiled writers) already writes its
# own `table.f<seq>...` file at the very end of its own function body via
# `_atomic_write` (`tables/writer.jl`).  Rather than threading a "where do I
# write this file" parameter through every one of those signatures (and
# every caller of them), the three container-eligible families route
# through `_dmfile_write!` instead of `_atomic_write` directly; whether
# that actually touches disk or gets buffered into an in-progress
# container is decided by an ambient, task-local "sink" set up by
# `with_container_sink` around the whole per-DM-writer section of
# `_write_table_core`.  Dysco and the virtual engines are never routed
# through `_dmfile_write!` at all (they keep calling `_atomic_write`
# directly) -- matching real casacore, where neither ever opts into
# `hasMultiFileSupport()`.

const DEFAULT_MF_BLOCKSIZE = 4 * 1024 * 1024   # casacore's own StorageOption default
const _MF_SINK_KEY = :mf_container_sink

mutable struct ContainerBuilder
    kind::Symbol                                  # :multifile | :multihdf5
    blocksize::Int64
    files::Vector{Pair{String,Vector{UInt8}}}      # (basename, bytes), write order preserved
end

"""
    with_container_sink(f, dir, storage::Symbol, blocksize::Integer)

Run `f()` with every `_dmfile_write!` call inside it buffered into a new
`ContainerBuilder` instead of touching disk, then (if anything was
buffered) finalize it into a real `table.mf`/`table.mfh5` in `dir`.
`storage === :sepfile` is a pure passthrough -- `f()` runs with no sink at
all, so every `_dmfile_write!` call behaves exactly like `_atomic_write`
always has.  Call this so that it wraps only the per-DM-writer section of
a table write, finishing (and so writing the real container file) BEFORE
`table.dat` is written -- `table.dat` stays the last thing written / the
commit point, exactly as for the `:sepfile` path.
"""
function with_container_sink(f::Function, dir::AbstractString,
                             storage::Symbol, blocksize::Integer)
    storage === :sepfile && return f()
    storage in (:multifile, :multihdf5) ||
        throw(ArgumentError("storage must be :sepfile, :multifile, or :multihdf5 (got $(repr(storage)))"))
    sink = ContainerBuilder(storage, Int64(blocksize), Pair{String,Vector{UInt8}}[])
    task_local_storage(f, _MF_SINK_KEY, sink)
    isempty(sink.files) && return nothing     # no container-eligible DM in this table
    storage === :multifile ? _finalize_multifile(dir, sink) : _finalize_multihdf5(dir, sink)
    return nothing
end

# Used only by StandardStMan/IncrementalStMan/TiledStMan writers in place
# of a direct `_atomic_write(joinpath(dir, name), data)` call.
function _dmfile_write!(dir::AbstractString, name::AbstractString, data)
    sink = get(task_local_storage(), _MF_SINK_KEY, nothing)
    if sink === nothing
        _atomic_write(joinpath(dir, name), data)
    else
        push!(sink.files, name => Vector{UInt8}(data))
    end
    return nothing
end

# ======================================================================
# MultiFile
# ======================================================================

struct MultiFileEntry
    fsize::Int64
    blocknrs::Vector{Int64}    # physical block number per logical block, 0-based
end

struct MultiFileContainer <: Container
    path::String
    blocksize::Int64
    entries::Dict{String,MultiFileEntry}   # keyed by virtual-file basename
end

# Raw big-endian primitive reads -- the fixed 64-byte lead and the packed
# block indices are NOT AipsIO-framed (dodges AipsIO's 32-bit length
# limit, MultiFile.cc:209-210); only the middle `itsInfo` region is.
_mf_get(d::AbstractVector{UInt8}, ::Type{T}, off::Integer) where {T} =
    ntoh(reinterpret(T, @view d[off+1:off+sizeof(T)])[1])

# Unpack a run-length-compressed block index (MultiFile.cc:734-784): a
# non-negative entry starts a new ascending run at that block number; a
# following negative entry `-nr` extends the run by `nr` more consecutive
# block numbers.  E.g. `[5,-2,10,-1]` -> `[5,6,7,10,11]`.
function _mf_unpack_index(packed::Vector{Int64})
    out = Int64[]
    isempty(packed) && return out
    i = 1
    n = length(packed)
    while i <= n
        start = packed[i]
        push!(out, start)
        i += 1
        if i <= n && packed[i] < 0
            nr = -packed[i]
            for k in 1:nr
                push!(out, start + k)
            end
            i += 1
        end
    end
    return out
end

# Write-side mirror of `_mf_unpack_index` -- the literal inverse of
# casacore's own `packIndex` (MultiFile.cc:734-764): emit the first block
# number of each contiguous ascending run, followed by a negative count of
# any additional consecutive block numbers in that run.
function _mf_pack_index(blocknrs::Vector{Int64})
    isempty(blocknrs) && return Int64[]
    out = Int64[blocknrs[1]]
    next = blocknrs[1] + 1
    for j in 2:length(blocknrs)
        if blocknrs[j] != next
            nr = next - out[end] - 1
            nr > 0 && push!(out, -nr)
            next = blocknrs[j]
            push!(out, next)
        end
        next += 1
    end
    nr = next - out[end] - 1
    nr > 0 && push!(out, -nr)
    return out
end

# casacore's own (nonstandard, NOT zlib's) CRC32 variant (MultiFile.cc:
# 44-67,694-721): polynomial 0x04C11DB7 built MSB-first, custom
# crcinit=0x46AF6449, byte loop `crc = ((crc<<8)|byte) ^
# table[(crc>>24)&0xff]`, then 4 rounds of "augment with zero bytes",
# final XOR 0xFFFFFFFF.
const _MF_CRC_TABLE = let
    tbl = Vector{UInt32}(undef, 256)
    poly = UInt32(0x04c11db7)
    highbit = UInt32(1) << 31
    for i in 0:255
        crc = UInt32(i) << 24
        for _ in 1:8
            bit = crc & highbit
            crc <<= 1
            bit != 0 && (crc = xor(crc, poly))
        end
        tbl[i+1] = crc
    end
    tbl
end

function _mf_crc32(buf::AbstractVector{UInt8})
    crc = UInt32(0x46af6449)
    @inbounds for b in buf
        crc = xor((crc << 8) | UInt32(b), _MF_CRC_TABLE[((crc >> 24) & 0xff) + 1])
    end
    for _ in 1:4
        crc = xor(crc << 8, _MF_CRC_TABLE[((crc >> 24) & 0xff) + 1])
    end
    return xor(crc, UInt32(0xffffffff))
end

# One `MultiFileInfo` record as written by the generic
# `std::vector<MultiFileInfo>` AipsIO idiom (STLIO.tcc `operator<</>>`) +
# `MultiFileInfo::operator<</>>` (MultiFileBase.cc:51-56):
# `{String name; Int64 fsize; Bool nested}`.  An empty `name` marks a
# free/deleted slot (the vector keeps a fixed length, slots aren't removed).
struct MultiFileRawInfo
    name::String
    fsize::Int64
    nested::Bool
end
read_element(a::AipsIO, ::Type{MultiFileRawInfo}) =
    MultiFileRawInfo(read_string(a), Int(read_scalar(a, Int64)), read_scalar(a, Bool))

# Write-side mirror, used by `wr_block` (io/aips.jl) exactly like
# `read_block`/`read_element` are used to parse a `Vector<MultiFileInfo>`.
wr_element(w::AipsWriter, x::MultiFileRawInfo) =
    (wr_string(w, x.name); wr_scalar(w, Int64(x.fsize)); wr_scalar(w, x.nested))

function open_multifile(path::AbstractString)
    io = open(path, "r")
    lead = Vector{UInt8}(undef, 64)
    readbytes!(io, lead, 64)
    discr = _mf_get(lead, Int64, 0)
    discr == 0 ||
        error("MultiFile: version 1 container format is not supported (\"$path\")")
    contblk    = Int(_mf_get(lead, Int64, 8))
    version    = _mf_get(lead, Int32, 24)
    version == 2 ||
        error("MultiFile: header version $version is not supported (\"$path\")")
    headerCRC  = _mf_get(lead, UInt32, 28)
    headerSize = Int(_mf_get(lead, Int64, 32))
    blocksize  = Int(_mf_get(lead, Int64, 40))
    useCRC     = lead[57] != 0x00

    # Assemble the full (possibly multi-block) header buffer -- block 0 in
    # full (up to `blocksize` bytes; `headerSize` may be smaller), plus
    # continuation blocks if `headerSize > blocksize`.
    seek(io, 0)
    block0 = Vector{UInt8}(undef, blocksize)
    readbytes!(io, block0, blocksize)
    buf = Vector{UInt8}(undef, headerSize)
    n0 = min(headerSize, blocksize)
    buf[1:n0] = block0[1:n0]
    if headerSize > blocksize
        off = blocksize
        blknr = contblk
        while off < headerSize
            blknr > 0 ||
                error("MultiFile: truncated header continuation chain (\"$path\")")
            cblk = Vector{UInt8}(undef, blocksize)
            seek(io, blknr * blocksize)
            readbytes!(io, cblk, blocksize)
            nextblk = Int(_mf_get(cblk, Int64, 0))
            chunk = min(blocksize - 8, headerSize - off)
            buf[off+1:off+chunk] = cblk[9:8+chunk]
            off += chunk
            blknr = nextblk
        end
        blknr == 0 ||
            error("MultiFile: header continuation chain did not terminate (\"$path\")")
    end
    close(io)

    if useCRC
        chk = copy(buf)
        chk[29:32] .= 0x00                    # zero headerCRC field during calc
        _mf_crc32(chk) == headerCRC ||
            error("MultiFile: header CRC mismatch -- corrupted container (\"$path\")")
    end

    # AipsIO region starts at header-buffer offset 64 (the fixed lead).
    a = AipsIO(buf[65:end]; endian=:big)
    getstart(a, "MultiFile")
    infos = read_block(a, MultiFileRawInfo)
    getend(a)

    # Raw (non-AipsIO-framed) per-file packed block indices follow
    # immediately -- `position(a.io)` is exactly the byte right after the
    # AipsIO object's own recorded length, i.e. the start of this region.
    rd = IOBuffer(buf[65+position(a.io):end])
    entries = Dict{String,MultiFileEntry}()
    for info in infos
        sz = Int(ntoh(read(rd, Int64)))
        packed = Int64[ntoh(read(rd, Int64)) for _ in 1:sz]
        isempty(info.name) && continue
        entries[info.name] = MultiFileEntry(info.fsize, _mf_unpack_index(packed))
    end
    # The global free-block packed index and the per-block CRC table
    # follow next; unused by a read-only container (no write support,
    # and the header CRC check above already guards header integrity).

    return MultiFileContainer(String(path), Int64(blocksize), entries)
end

function _mf_entry(c::MultiFileContainer, name::AbstractString)
    e = get(c.entries, name, nothing)
    e === nothing &&
        error("MultiFile: no virtual file \"$name\" in \"$(c.path)\"")
    return e
end

function container_read(c::MultiFileContainer, name::AbstractString)
    e = _mf_entry(c, name)
    out = Vector{UInt8}(undef, e.fsize)
    bs = Int(c.blocksize)
    io = open(c.path, "r")
    done = 0
    b = 0
    chunk = Vector{UInt8}(undef, bs)
    while done < e.fsize
        seek(io, e.blocknrs[b+1] * c.blocksize)
        readbytes!(io, chunk, bs)
        take = min(bs, e.fsize - done)
        out[done+1:done+take] = chunk[1:take]
        done += take
        b += 1
    end
    close(io)
    return out
end

# A freshly-written, never-shrunk/deleted-from container always allocates
# new blocks sequentially at EOF (`MultiFile::extendVF`, MultiFile.cc:
# 634-651), so a virtual file's blocks are contiguous in the overwhelming
# common case -- exploit that for a genuine zero-copy `mmap`, matching
# this package's existing (non-container) `Mmap.mmap` performance
# characteristics exactly.  Fall back to a full materializing read
# (`container_read`) for the (real, if rarer) fragmented case.
function container_mmap(c::MultiFileContainer, name::AbstractString)
    e = _mf_entry(c, name)
    if !isempty(e.blocknrs) && all(diff(e.blocknrs) .== 1)
        whole = Mmap.mmap(c.path, Vector{UInt8})
        start = e.blocknrs[1] * c.blocksize
        return view(whole, start+1:start+e.fsize)
    end
    return container_read(c, name)
end

# --- write side: assemble a whole `table.mf` in one shot -------------
#
# Verified against casacore's own streaming write path (MultiFile.cc) that
# a from-scratch, single-shot writer needs none of its incremental extend/
# flush choreography: block placement need not be contiguous or in write
# order (the reader trusts `blockNrs[]` unconditionally), the free list can
# simply be empty, and `useCRC` has no `StorageOption`/TaQL knob to opt
# into at all -- this writer always emits `useCRC=false`.

# Build the logical (pre-chunking) header buffer for a given continuation-
# block count.  `contblocknrs` (final physical block numbers of the
# continuation chain, length `ncontblk`) only affects the fixed lead's
# `contBlockNr` field and the cont-set-0 raw vector's *values*; its
# *length* -- all that the fixed-point convergence in `_finalize_multifile`
# needs -- depends only on `ncontblk`, so this is called first with
# placeholder zeros and again once the real numbers are known.
function _mf_header_bytes(infos::Vector{MultiFileRawInfo}, packed::Vector{Vector{Int64}},
                          blocksize::Integer, nrblock::Integer,
                          contblocknrs::Vector{Int64})
    # AipsIO region (offset 64): putstart("MultiFile",2) << itsInfo << putend
    aw = AipsWriter(; endian=:big)
    putstart(aw, "MultiFile", 2)
    wr_block(aw, infos)
    putend(aw)
    aipsbytes = bytes(aw)

    # Raw (non-AipsIO-framed) trailing vectors, in casacore's own order:
    # per-file packed index, empty free list, empty CRC vector (useCRC
    # always false), cont-set-0, cont-set-1 (always empty here), nrContUsed.
    raw = AipsWriter(; endian=:big)   # reused only as a big-endian byte sink
    for p in packed
        wr_scalar(raw, Int64(length(p)))
        for x in p; wr_scalar(raw, Int64(x)); end
    end
    wr_scalar(raw, Int64(0))                          # free-block packed index: empty
    wr_scalar(raw, Int64(0))                          # CRC vector: empty (useCRC=false)
    wr_scalar(raw, Int64(length(contblocknrs)))       # cont-set-0 raw vector
    for x in contblocknrs; wr_scalar(raw, Int64(x)); end
    wr_scalar(raw, Int64(0))                          # cont-set-1 raw vector: empty
    wr_scalar(raw, UInt32(length(contblocknrs)))      # nrContUsed[0]
    wr_scalar(raw, UInt32(0))                         # nrContUsed[1]
    rawbytes = take!(raw.io)

    lead = zeros(UInt8, 64)
    lead[9:16]  = reinterpret(UInt8, [hton(Int64(isempty(contblocknrs) ? 0 : contblocknrs[1]))])
    lead[17:24] = reinterpret(UInt8, [hton(Int64(1))])              # hdrCounter
    lead[25:28] = reinterpret(UInt8, [hton(Int32(2))])              # version
    # lead[29:32] (headerCRC) stays 0 -- useCRC=false
    lead[33:40] = reinterpret(UInt8, [hton(Int64(0))])              # headerSize -- patched by caller
    lead[41:48] = reinterpret(UInt8, [hton(Int64(blocksize))])
    lead[49:56] = reinterpret(UInt8, [hton(Int64(nrblock))])
    # lead[57] (useCRC) stays 0; lead[58:64] spare, stays 0

    hdr = vcat(lead, aipsbytes, rawbytes)
    hdr[33:40] = reinterpret(UInt8, [hton(Int64(length(hdr)))])     # patch headerSize
    return hdr
end

function _finalize_multifile(dir::AbstractString, sink::ContainerBuilder)
    bs = Int64(sink.blocksize)
    blk = Int64(1)                                    # block 0 reserved for the header
    infos = MultiFileRawInfo[]
    packed = Vector{Int64}[]
    databuf = IOBuffer()
    for (name, data) in sink.files
        n = length(data)
        nblk = cld(n, bs)
        blocknrs = collect(Int64, blk:blk+nblk-1)
        blk += nblk
        write(databuf, data)
        pad = nblk * bs - n
        pad > 0 && write(databuf, zeros(UInt8, pad))
        push!(infos, MultiFileRawInfo(name, Int64(n), false))
        push!(packed, _mf_pack_index(blocknrs))
    end
    ndatablocks = blk - 1
    data = take!(databuf)

    # Converge the continuation-block count (almost always 0 -- see the
    # file-header comment above and the Phase 21 plan's convergence note).
    ncontblk = 0
    local hdrlen
    while true
        hdrlen = length(_mf_header_bytes(infos, packed, bs, 1 + ndatablocks + ncontblk,
                                         zeros(Int64, ncontblk)))
        need = max(0, hdrlen - bs)
        chunks = cld(need, bs - 8)
        chunks == ncontblk && break
        ncontblk = chunks
    end

    contblocknrs = collect(Int64, blk:blk+ncontblk-1)
    nrblock = blk + ncontblk
    hdr = _mf_header_bytes(infos, packed, bs, nrblock, contblocknrs)

    block0 = zeros(UInt8, bs)
    n0 = min(length(hdr), bs)
    block0[1:n0] = hdr[1:n0]
    contblocks = UInt8[]
    off = bs
    for (k, cb) in enumerate(contblocknrs)
        nextptr = k < length(contblocknrs) ? contblocknrs[k+1] : Int64(0)
        chunk = hdr[off+1:min(off + bs - 8, length(hdr))]
        cbuf = zeros(UInt8, bs)
        cbuf[1:8] = reinterpret(UInt8, [hton(Int64(nextptr))])
        cbuf[9:8+length(chunk)] = chunk
        append!(contblocks, cbuf)
        off += bs - 8
    end

    # Physical byte layout MUST match the block-number bookkeeping above:
    # block 0 = header, blocks [1, ndatablocks] = `data` (in that order),
    # blocks [ndatablocks+1, nrblock) = continuation blocks.
    _atomic_write(joinpath(dir, "table.mf"), vcat(block0, data, contblocks))
    return nothing
end

# ======================================================================
# MultiHDF5 -- weak-dependency entry points (real impl in
# ext/HDF5Ext.jl; loaded when the caller has `import`ed
# HDF5.jl).  The struct stays in the core namespace so callers /
# `test/container_tests.jl` can name it; `fid` holds an `HDF5.File`
# handle (typed `Any` here because HDF5 is not loaded).
# ======================================================================

struct MultiHDF5Container <: Container
    path::String
    blocksize::Int64
    sizes::Dict{String,Int64}     # keyed by virtual-file basename
    fid::Any                      # ::HDF5.File
end

const _NEED_HDF5 = "requires HDF5.jl — run `import HDF5` (or add it to your project) first"

# Untyped fallbacks -- the extension adds a more-specific method
# (`::AbstractString` / `::ContainerBuilder`) rather than overwriting
# these (overwrites are forbidden during precompilation).  All the
# `MultiHDF5Container` access methods (`container_read` / `container_mmap`)
# live in the extension too -- a `MultiHDF5Container` can only be
# constructed by `_open_multihdf5`, so they are unreachable without it.
_open_multihdf5(_) =
    error("MeasurementSets: reading a MultiHDF5 (`table.mfh5`) container $_NEED_HDF5")

_finalize_multihdf5(_, _) =
    error("MeasurementSets: writing a MultiHDF5 container (storage=:multihdf5) $_NEED_HDF5")

# ======================================================================
# detection
# ======================================================================

function open_container(dir::AbstractString)
    mf = joinpath(dir, "table.mf")
    isfile(mf) && return open_multifile(mf)
    h5 = joinpath(dir, "table.mfh5")
    isfile(h5) && return _open_multihdf5(h5)
    return nothing
end
