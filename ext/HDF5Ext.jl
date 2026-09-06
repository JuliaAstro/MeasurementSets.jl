# MultiHDF5 (`table.mfh5`) container support -- a package extension,
# loaded automatically when the caller has `import`ed HDF5.jl.
#
# Everything here was moved verbatim from
# `src/datamanagers/container.jl` (Phases 20-21); see that file's header
# for the format notes and the standing "no real casacore oracle for
# MultiHDF5 on this machine" caveat.

module HDF5Ext

import HDF5
import MeasurementSets as MS

# --- read: open a `table.mfh5` -----------------------------------------

function MS._open_multihdf5(path::AbstractString)
    fid = HDF5.h5open(String(path), "r")
    g = fid["__MultiHDF5_Header__"]
    blocksize = Int64(HDF5.read(HDF5.attributes(g)["blockSize"]))
    names = Vector{String}(HDF5.read(HDF5.attributes(g)["names"]))
    rawsizes = Vector{Int64}(HDF5.read(HDF5.attributes(g)["sizes"]))
    sizes = Dict{String,Int64}(names[i] => rawsizes[i]
                               for i in eachindex(names) if !isempty(names[i]))
    return MS.MultiHDF5Container(String(path), blocksize, sizes, fid)
end

# Read virtual file `name`'s "FileData" dataset.  Casacore's IPosition
# axes are reversed going into HDF5's C-order dataspace, so the growing
# "block" axis is axis 1 in HDF5.jl's own (native, un-transposed)
# dimension order -- `d[b, :]`.  Only exercised by our own self-authored
# fixture (test/container_tests.jl's `_pack_multihdf5!`); flip to
# `d[:, b]` if a genuine casacore-written `table.mfh5` ever disagrees.
function MS.container_read(c::MS.MultiHDF5Container, name::AbstractString)
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

# HDF5 has no mmap equivalent -- always materialize (a documented
# performance follow-up for a huge TiledStMan cube in MultiHDF5).
MS.container_mmap(c::MS.MultiHDF5Container, name::AbstractString) =
    MS.container_read(c, name)

# --- write: assemble a whole `table.mfh5` in one shot -----------------
#
# Verified against casacore's own `doAddFile`/`extend`/`put`: creating
# each dataset directly at its final size with one write is bit-for-bit
# equivalent from any reader's point of view (nothing inspects the
# creation history; the header attributes are discovered, not enumerated).
function MS._finalize_multihdf5(dir::AbstractString, sink::MS.ContainerBuilder)
    bs = Int64(sink.blocksize)
    path = joinpath(dir, "table.mfh5")
    tmp = joinpath(dir, "." * basename(path) * ".tmp")
    ispath(tmp) && rm(tmp)
    names = String[]
    sizes = Int64[]
    HDF5.h5open(tmp, "w") do fid
        for (name, data) in sink.files
            n = length(data)
            nblk = cld(n, bs)
            g = HDF5.create_group(fid, name)
            padded = vcat(data, zeros(UInt8, nblk * bs - n))
            buf = Array{UInt8}(undef, nblk, bs)
            for b in 1:nblk
                s = (b - 1) * bs
                buf[b, :] = padded[s+1:s+bs]
            end
            d = HDF5.create_dataset(g, "FileData", HDF5.datatype(UInt8),
                                    HDF5.dataspace((nblk, bs)))
            d[:, :] = buf
            push!(names, name)
            push!(sizes, Int64(n))
        end
        hdr = HDF5.create_group(fid, "__MultiHDF5_Header__")
        HDF5.attributes(hdr)["blockSize"] = bs
        HDF5.attributes(hdr)["hdrCounter"] = Int64(1)
        HDF5.attributes(hdr)["names"] = names
        HDF5.attributes(hdr)["sizes"] = sizes
    end
    mv(tmp, path; force=true)
    return nothing
end

end # module
