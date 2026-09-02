# TiledStMan / TiledShapeStMan / TiledColumnStMan reader.
#
# Mirrors casacore/tables/DataMan/TiledStMan.cc, TiledShapeStMan.cc,
# TiledColumnStMan.cc, TSMCube.cc, TSMFile.cc.
#
# A hypercube of shape `cubeshape` is partitioned into tiles of shape
# `tileshape`.  Tiles are stored back-to-back in a `table.f<seqnr>_TSM<n>`
# file starting at `fileoffset`, in column-major tile order; within a tile
# the elements are column-major over `tileshape` (edge tiles are still
# full-size on disk).  The header file `table.f<seqnr>` is a plain
# big-endian AipsIO stream.
#
# Only single-column tiled storage managers are supported (all the MS uses).
# Rows are 1-based in this file's API.

import Mmap

struct TSMCube
    cubeshape::Vector{Int}
    tileshape::Vector{Int}
    fileseqnr::Int              # -1 => no data (undefined cells)
    fileoffset::Int
end

isnull(c::TSMCube) = c.fileseqnr < 0 || isempty(c.cubeshape)

mutable struct TiledStMan
    path::String
    bigendian::Bool
    kind::Symbol                   # :column or :shape
    seqnr::Int
    dtype::CasaType
    hypercolumn::String
    nrdim::Int
    tsmfiles::Dict{Int,String}      # _TSM sequence nr -> file path
    tsmdata::Dict{Int,Vector{UInt8}}  # lazily mmapped
    cubes::Vector{TSMCube}
    # TiledShapeStMan row -> cube mapping (empty for TiledColumnStMan)
    rowmap::Vector{Int}            # 1-based last row of each interval
    cubemap::Vector{Int}          # 1-based cube index per interval
    posmap::Vector{Int}           # 1-based last last-axis position per interval
end

# --- header parsing -------------------------------------------------

function _read_iposition_be(a::AipsIO)          # always big-endian in the header
    read_iposition(a)
end

function _read_tsmcube(a::AipsIO)
    version = read_u32(a)
    read_record(a)                              # values_p (id values; empty here)
    read_scalar(a, Bool)                        # extensible
    nrdim = Int(read_u32(a))
    cubeshape = read_iposition(a)
    tileshape = read_iposition(a)
    fileseqnr = Int(read_i32(a))
    fileoffset = version == 1 ? Int(read_u32(a)) : Int(read_scalar(a, UInt64))
    return TSMCube(cubeshape, tileshape, fileseqnr, fileoffset)
end

function _headerfile_get!(a::AipsIO, tsm::TiledStMan, t::CTDSTable)
    version = getstart(a, "TiledStMan")
    version >= 2 && read_scalar(a, Bool)                   # bigEndian flag
    tsm.seqnr = Int(read_u32(a))
    version >= 3 ? read_scalar(a, UInt64) : read_u32(a)    # nrrow
    ncol = Int(read_u32(a))
    ncol == 1 || error("TiledStMan: only single-column tiled managers supported (got $ncol)")
    tsm.dtype = casatype(read_i32(a))
    tsm.hypercolumn = read_string(a)
    version >= 3 ? read_scalar(a, UInt64) : read_u32(a)    # persMaxCacheSize
    tsm.nrdim = Int(read_u32(a))

    nrfile = Int(version >= 3 ? read_scalar(a, UInt64) : read_u32(a))
    for i in 0:nrfile-1
        present = read_scalar(a, Bool)
        present || continue
        fv = read_u32(a)
        fseq = Int(read_u32(a))
        fv == 1 ? read_u32(a) : read_scalar(a, UInt64)     # file length
        tsm.tsmfiles[fseq] = joinpath(t.path, "table.f$(tsm.seqnr)_TSM$(fseq)")
    end

    nrcube = Int(version >= 3 ? read_scalar(a, UInt64) : read_u32(a))
    tsm.cubes = TSMCube[_read_tsmcube(a) for _ in 1:nrcube]
    getend(a)                                       # close "TiledStMan"
    return version
end

function open_tiledstman(t::CTDSTable, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.seqnr)")
    a = AipsIO(read(path); bigendian=true)          # header file is big-endian
    tsm = TiledStMan(path, t.bigendian, :column, dm.seqnr, TpOther, "", 0,
                     Dict{Int,String}(), Dict{Int,Vector{UInt8}}(),
                     TSMCube[], Int[], Int[], Int[])

    kind = getnexttype(a)                            # peek outer wrapper
    ver_outer = read_u32(a)
    if kind == "TiledColumnStMan"
        tsm.kind = :column
        read_iposition(a)                           # tileShape_p (also in cube)
        _headerfile_get!(a, tsm, t)
    elseif kind == "TiledShapeStMan"
        tsm.kind = :shape
        _headerfile_get!(a, tsm, t)
        read_iposition(a)                           # defaultTileShape
        nused = Int(read_u32(a))
        rowmap = Int.(read_block(a, UInt32))
        cubemap = Int.(read_block(a, UInt32))
        posmap = Int.(read_block(a, UInt32))
        tsm.rowmap  = Int[x + 1 for x in rowmap[1:nused]]     # -> 1-based
        tsm.cubemap = Int[x + 1 for x in cubemap[1:nused]]
        tsm.posmap  = Int[x + 1 for x in posmap[1:nused]]
    elseif kind in ("TiledCellStMan", "TiledDataStMan")
        error("$kind not yet supported")
    else
        error("unknown tiled storage manager \"$kind\"")
    end
    getend(a)
    return tsm
end

# --- row -> (cube, last-axis position) -----------------------------

function _cube_for_row(tsm::TiledStMan, row::Integer)
    if tsm.kind == :column                       # one cube, position == row
        cube = tsm.cubes[findfirst(c -> !isnull(c), tsm.cubes)]
        return cube, Int(row)
    end
    # TiledShapeStMan: interval search over the row map
    if isempty(tsm.rowmap) || row > tsm.rowmap[end]
        return tsm.cubes[1], 0                   # cube 0 == undefined cells
    end
    idx = findfirst(>=(row), tsm.rowmap)
    cube = tsm.cubes[tsm.cubemap[idx]]
    pos = tsm.posmap[idx] - (tsm.rowmap[idx] - Int(row))
    return cube, pos
end

# --- tile data access ---------------------------------------------

function _tsmbytes(tsm::TiledStMan, seqnr::Int)
    get!(tsm.tsmdata, seqnr) do
        Mmap.mmap(tsm.tsmfiles[seqnr], Vector{UInt8})
    end
end

_pixbytes(t::CasaType) = t == TpBool ? 0 : sizeof(juliatype(t))   # 0 => bit-packed

# bucket (tile) size in bytes for a single-column manager
function _bucketbytes(tsm::TiledStMan, cube::TSMCube)
    ntile = prod(cube.tileshape)
    tsm.dtype == TpBool ? cld(ntile, 8) : ntile * sizeof(juliatype(tsm.dtype))
end

_colmajor_offset(pos, dims) = begin
    off = 0; stride = 1
    @inbounds for d in eachindex(dims)
        off += pos[d] * stride
        stride *= dims[d]
    end
    off
end

"""
    read_plane(tsm, cube, lastpos) -> Array

Read the sub-array at last-axis index `lastpos` (0-based) of `cube`,
de-tiling into a column-major Julia array of shape `cube.cubeshape[1:end-1]`.
"""
function read_plane(tsm::TiledStMan, cube::TSMCube, lastpos::Int)
    T = juliatype(tsm.dtype)
    nd = length(cube.cubeshape)
    cs = cube.cubeshape
    ts = cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    planeshape = cs[1:nd-1]
    out = Array{T}(undef, planeshape...)

    data = _tsmbytes(tsm, cube.fileseqnr)
    bbytes = _bucketbytes(tsm, cube)
    swap = tsm.bigendian ? ntoh : ltoh

    tlast_tile = lastpos ÷ ts[nd]
    tlast_in   = lastpos % ts[nd]

    # iterate over tiles in the leading nd-1 axes
    leadtiles = CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd-1))
    for lt in leadtiles
        tilecoord = ntuple(d -> d < nd ? lt[d] : tlast_tile, nd)
        tilenr = _colmajor_offset(tilecoord, tpd)
        base = cube.fileoffset + tilenr * bbytes

        # overlap of this tile with the plane, per leading axis
        los = ntuple(d -> lt[d] * ts[d], nd-1)
        his = ntuple(d -> min((lt[d]+1) * ts[d], cs[d]) - 1, nd-1)

        for pix in CartesianIndices(ntuple(d -> los[d]:his[d], nd-1))
            tl = ntuple(d -> d < nd ? pix[d] - los[d] : tlast_in, nd)
            k = _colmajor_offset(tl, ts)          # element index within tile
            if T === Bool
                byte = data[base + (k >> 3) + 1]
                out[CartesianIndex(ntuple(d -> pix[d] + 1, nd-1))] =
                    (byte >> (k & 7)) & 0x01 == 0x01
            else
                b = base + k * sizeof(T)
                v = reinterpret(T, @view data[b+1 : b+sizeof(T)])[1]
                out[CartesianIndex(ntuple(d -> pix[d] + 1, nd-1))] = swap(v)
            end
        end
    end
    return out
end

"""
    tsm_getcell(tsm, coldesc, row) -> Array   (1-based row)
"""
function tsm_getcell(tsm::TiledStMan, ::ColumnDesc, row::Integer)
    cube, pos = _cube_for_row(tsm, row)
    isnull(cube) && error("row $row of this column has no stored data " *
                          "(the tiled cell is undefined)")
    return read_plane(tsm, cube, pos - 1)
end

"Whether every row of this tiled column is an undefined (unwritten) cell."
alldefined_none(tsm::TiledStMan) =
    tsm.kind == :shape && (isempty(tsm.rowmap) || all(isnull, tsm.cubes))

# Fast whole-column read for the common layout: a single hypercube whose
# leading axes are not tiled (tilesPerDim == 1 there), so each on-disk tile
# is a contiguous run of whole cells along the last (row) axis.
function _read_cube_bulk(tsm::TiledStMan, cube::TSMCube, rowpos::Function, nrow::Int)
    T = juliatype(tsm.dtype)
    T === Bool && return nothing            # bit unpacking: use the slow path
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    all(cld(cs[d], ts[d]) == 1 for d in 1:nd-1) || return nothing

    planeshape = cs[1:nd-1]
    planelen = prod(planeshape)
    rowspertile = ts[nd]
    data = _tsmbytes(tsm, cube.fileseqnr)
    bbytes = _bucketbytes(tsm, cube)
    swap = tsm.bigendian ? ntoh : ltoh

    backing = Vector{T}(undef, nrow * planelen)
    for r in 1:nrow
        p = rowpos(r) - 1                    # 0-based last-axis position
        tile = p ÷ rowspertile
        within = (p % rowspertile) * planelen
        b = cube.fileoffset + tile * bbytes + within * sizeof(T)
        raw = reinterpret(T, @view data[b+1 : b + planelen*sizeof(T)])
        dst = (r - 1) * planelen
        @inbounds for k in 1:planelen
            backing[dst + k] = swap(raw[k])
        end
    end
    return [reshape(view(backing, (r-1)*planelen+1 : r*planelen), planeshape...)
            for r in 1:nrow]
end

"""
    tsm_getcolumn(tsm, coldesc, nrow) -> Vector{Array}
"""
function tsm_getcolumn(tsm::TiledStMan, c::ColumnDesc, nrow::Integer)
    alldefined_none(tsm) &&
        error("column has no stored data (all tiled cells are undefined)")

    real = findall(!isnull, tsm.cubes)
    if length(real) == 1
        cube = tsm.cubes[real[1]]
        rowpos = if tsm.kind == :column
            identity
        elseif length(tsm.rowmap) == 1 && tsm.rowmap[1] >= nrow
            r -> tsm.posmap[1] - (tsm.rowmap[1] - r)
        else
            nothing
        end
        if rowpos !== nothing
            fast = _read_cube_bulk(tsm, cube, rowpos, Int(nrow))
            fast === nothing || return fast
        end
    end
    return [tsm_getcell(tsm, c, r) for r in 1:nrow]
end
