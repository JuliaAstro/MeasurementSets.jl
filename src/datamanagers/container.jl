# MultiFile / MultiHDF5 --- casacore's two "container" formats that pack
# every small per-storage-manager private file of a table (`table.f<seq>`,
# `table.f<seq>i`, `table.f<seq>_TSM<k>`) into one real file on disk
# (`table.mf` / `table.mfh5`), to cut open-file-descriptor counts and help
# filesystems like Lustre.  Read-only (no write support).
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
import HDF5

abstract type Container end

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

# ======================================================================
# MultiHDF5
# ======================================================================

struct MultiHDF5Container <: Container
    path::String
    blocksize::Int64
    sizes::Dict{String,Int64}     # keyed by virtual-file basename
    fid::HDF5.File
end

function open_multihdf5(path::AbstractString)
    fid = HDF5.h5open(String(path), "r")
    g = fid["__MultiHDF5_Header__"]
    blocksize = Int64(HDF5.read(HDF5.attributes(g)["blockSize"]))
    names = Vector{String}(HDF5.read(HDF5.attributes(g)["names"]))
    rawsizes = Vector{Int64}(HDF5.read(HDF5.attributes(g)["sizes"]))
    sizes = Dict{String,Int64}(names[i] => rawsizes[i]
                               for i in eachindex(names) if !isempty(names[i]))
    return MultiHDF5Container(String(path), blocksize, sizes, fid)
end

# Read block `blknr` (0-based) of virtual file `name`'s "FileData"
# dataset.  Casacore's IPosition axes are reversed going into HDF5's
# C-order dataspace (MultiHDF5.cc/HDF5DataType.cc `fromShape`), so the
# growing "block" axis is axis 1 in HDF5.jl's own (native, un-transposed)
# dimension order -- `d[blknr+1, :]`.  NOT independently verified against
# a real casacore-written file: no casacore build on this machine has
# HDF5 support compiled in (confirmed for both Casacore.jl's bundled
# `casacorecxx_jll` and the real CASA.app install used as the Dysco
# oracle), so this axis-order choice is only exercised by our own
# self-authored fixture (test/container_tests.jl's `_pack_multihdf5!`,
# built with HDF5.jl following this same convention) -- a documented,
# standing gap.  Flip to `d[:, blknr+1]` here (and in `container_read`
# below) if a genuine casacore-written `table.mfh5` ever disagrees.
function container_read(c::MultiHDF5Container, name::AbstractString)
    haskey(c.sizes, name) ||
        error("MultiHDF5: no virtual file \"$name\" in \"$(c.path)\"")
    fsize = c.sizes[name]
    d = c.fid[name]["FileData"]
    out = Vector{UInt8}(undef, fsize)
    done = 0
    nblk = size(d, 1)
    for b in 1:nblk
        done >= fsize && break
        blk = Vector{UInt8}(d[b, :])
        take = min(length(blk), fsize - done)
        out[done+1:done+take] = blk[1:take]
        done += take
    end
    return out
end

# HDF5 has no mmap equivalent for a virtual file's bytes -- always
# materialize.  A known, documented performance follow-up for a huge
# TiledStMan cube stored specifically in MultiHDF5 (Dysco/engines never
# reach this path at all -- see the file header note).
container_mmap(c::MultiHDF5Container, name::AbstractString) = container_read(c, name)

# ======================================================================
# detection
# ======================================================================

function open_container(dir::AbstractString)
    mf = joinpath(dir, "table.mf")
    isfile(mf) && return open_multifile(mf)
    h5 = joinpath(dir, "table.mfh5")
    isfile(h5) && return open_multihdf5(h5)
    return nothing
end
