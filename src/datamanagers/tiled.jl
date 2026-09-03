# TiledStMan / TiledShapeStMan / TiledColumnStMan reader.
#
# Mirrors casacore/tables/DataMan/TiledStMan.cc, TiledShapeStMan.cc,
# TiledColumnStMan.cc, TSMCube.cc, TSMFile.cc.
#
# A hypercube of shape `cubeshape` is partitioned into tiles of shape
# `tileshape`.  Tiles are stored back-to-back in a `table.f<sequ>_TSM<n>`
# file starting at `offset`, in column-major tile order; within a tile the
# elements are column-major over `tileshape` (edge tiles are still
# full-size on disk).  The header file `table.f<sequ>` is a plain
# big-endian AipsIO stream.
#
# Only single-column tiled storage managers are supported (all the MS uses).
# Rows are 1-based in this file's API.

import Mmap

const TSM_TILE_TARGET = 1 << 20   # writer: aim for ~1 MiB of data per tile

# AipsIO object versions we write in `table.f<seqnr>`
const TSM_WRAPPER_VER = 1   # "TiledShapeStMan" outer object
const TSM_BASE_VER    = 2   # nested "TiledStMan" object
const TSM_CUBE_VER    = 1   # TSMCube::putObject (writes no framing)
const TSM_FILE_VER    = 1   # a TSMFile record

struct TSMCube
    cubeshape::Dims
    tileshape::Dims
    sequ::Union{Int,Nothing}    # _TSM file number; nothing => no data
    offset::Int                 # byte offset of this cube within its _TSM file
end

isnull(c::TSMCube) = c.sequ === nothing || isempty(c.cubeshape)

mutable struct TiledStMan
    path::String
    endian::Symbol                 # :big or :little
    kind::Symbol                   # :column or :shape
    sequ::Int                      # this data manager's sequence number
    type::CasaType                 # element type of the tiled column
    hyper::String                  # hypercolumn name
    dims::Int                      # hypercube dimensionality
    files::Dict{Int,String}        # _TSM sequence nr -> file path
    data::Dict{Int,Vector{UInt8}}  # _TSM sequence nr -> lazily mmapped bytes
    cubes::Vector{TSMCube}
    # TiledShapeStMan row -> cube mapping (empty for TiledColumnStMan)
    row::Vector{Int}              # 1-based last row of each interval
    cube::Vector{Int}             # 1-based cube index per interval
    pos::Vector{Int}              # 1-based last last-axis position per interval
end

# --- header parsing -------------------------------------------------

function _read_tsmcube(a::AipsIO)
    version = read_u32(a)
    read_record(a)                              # values_p (id values; empty here)
    read_scalar(a, Bool)                        # extensible
    read_u32(a)                                 # nrdim (== length(cubeshape))
    cubeshape = read_iposition(a)
    tileshape = read_iposition(a)
    fs = Int(read_i32(a))
    sequ = fs < 0 ? nothing : fs
    offset = version == 1 ? Int(read_u32(a)) : Int(read_scalar(a, UInt64))
    return TSMCube(cubeshape, tileshape, sequ, offset)
end

function _headerfile_get!(a::AipsIO, tsm::TiledStMan, t::CTDSTable)
    version = getstart(a, "TiledStMan")
    version >= 2 && read_scalar(a, Bool)                   # bigEndian flag
    tsm.sequ = Int(read_u32(a))
    version >= 3 ? read_scalar(a, UInt64) : read_u32(a)    # nrrow
    ncol = Int(read_u32(a))
    ncol == 1 || error("TiledStMan: only single-column tiled managers supported (got $ncol)")
    tsm.type = casatype(read_i32(a))
    tsm.hyper = read_string(a)
    version >= 3 ? read_scalar(a, UInt64) : read_u32(a)    # persMaxCacheSize
    tsm.dims = Int(read_u32(a))

    nrfile = Int(version >= 3 ? read_scalar(a, UInt64) : read_u32(a))
    for _ in 0:nrfile-1
        present = read_scalar(a, Bool)
        present || continue
        fv = read_u32(a)
        fseq = Int(read_u32(a))
        fv == 1 ? read_u32(a) : read_scalar(a, UInt64)     # file length
        tsm.files[fseq] = joinpath(t.path, "table.f$(tsm.sequ)_TSM$(fseq)")
    end

    nrcube = Int(version >= 3 ? read_scalar(a, UInt64) : read_u32(a))
    tsm.cubes = TSMCube[_read_tsmcube(a) for _ in 1:nrcube]
    getend(a)                                       # close "TiledStMan"
    return version
end

function open_tiledstman(t::CTDSTable, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.sequ)")
    a = AipsIO(read(path); endian=:big)             # header file is big-endian
    tsm = TiledStMan(path, t.endian, :column, dm.sequ, TpOther, "", 0,
                     Dict{Int,String}(), Dict{Int,Vector{UInt8}}(),
                     TSMCube[], Int[], Int[], Int[])

    wrapper = getnexttype(a)                         # peek outer wrapper
    read_u32(a)                                      # wrapper version
    if wrapper == "TiledColumnStMan"
        tsm.kind = :column
        read_iposition(a)                           # tileShape_p (also in cube)
        _headerfile_get!(a, tsm, t)
    elseif wrapper == "TiledShapeStMan"
        tsm.kind = :shape
        _headerfile_get!(a, tsm, t)
        read_iposition(a)                           # defaultTileShape
        nused = Int(read_u32(a))
        rawrow  = Int.(read_block(a, UInt32))
        rawcube = Int.(read_block(a, UInt32))
        rawpos  = Int.(read_block(a, UInt32))
        tsm.row  = Int[x + 1 for x in rawrow[1:nused]]        # -> 1-based
        tsm.cube = Int[x + 1 for x in rawcube[1:nused]]
        tsm.pos  = Int[x + 1 for x in rawpos[1:nused]]
    elseif wrapper in ("TiledCellStMan", "TiledDataStMan")
        error("$wrapper not yet supported")
    else
        error("unknown tiled storage manager \"$wrapper\"")
    end
    getend(a)
    return tsm
end

# --- row -> (cube, last-axis position) -----------------------------

function _cube_for_row(tsm::TiledStMan, rownr::Integer)
    if tsm.kind == :column                       # one cube, position == row
        c = tsm.cubes[findfirst(x -> !isnull(x), tsm.cubes)]
        return c, Int(rownr)
    end
    # TiledShapeStMan: interval search over the row map
    if isempty(tsm.row) || rownr > tsm.row[end]
        return tsm.cubes[1], 0                   # cube 0 == undefined cells
    end
    idx = findfirst(>=(rownr), tsm.row)
    c = tsm.cubes[tsm.cube[idx]]
    p = tsm.pos[idx] - (tsm.row[idx] - Int(rownr))
    return c, p
end

# --- tile data access ---------------------------------------------

function _tsmbytes(tsm::TiledStMan, sequ::Int)
    get!(tsm.data, sequ) do
        Mmap.mmap(tsm.files[sequ], Vector{UInt8})
    end
end

# bucket (tile) size in bytes for a single-column manager
function _bucketbytes(tsm::TiledStMan, cube::TSMCube)
    ntile = prod(cube.tileshape)
    tsm.type == TpBool ? cld(ntile, 8) : ntile * sizeof(juliatype(tsm.type))
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
    T = juliatype(tsm.type)
    nd = length(cube.cubeshape)
    cs = cube.cubeshape
    ts = cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    planeshape = cs[1:nd-1]
    out = Array{T}(undef, planeshape...)

    bytes = _tsmbytes(tsm, cube.sequ)
    bbytes = _bucketbytes(tsm, cube)
    swap = tsm.endian === :big ? ntoh : ltoh

    tlast_tile = lastpos ÷ ts[nd]
    tlast_in   = lastpos % ts[nd]

    # iterate over tiles in the leading nd-1 axes
    leadtiles = CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd-1))
    for lt in leadtiles
        tilecoord = ntuple(d -> d < nd ? lt[d] : tlast_tile, nd)
        tilenr = _colmajor_offset(tilecoord, tpd)
        base = cube.offset + tilenr * bbytes

        # overlap of this tile with the plane, per leading axis
        los = ntuple(d -> lt[d] * ts[d], nd-1)
        his = ntuple(d -> min((lt[d]+1) * ts[d], cs[d]) - 1, nd-1)

        for pix in CartesianIndices(ntuple(d -> los[d]:his[d], nd-1))
            tl = ntuple(d -> d < nd ? pix[d] - los[d] : tlast_in, nd)
            k = _colmajor_offset(tl, ts)          # element index within tile
            if T === Bool
                byte = bytes[base + (k >> 3) + 1]
                out[CartesianIndex(ntuple(d -> pix[d] + 1, nd-1))] =
                    (byte >> (k & 7)) & 0x01 == 0x01
            else
                b = base + k * sizeof(T)
                v = reinterpret(T, @view bytes[b+1 : b+sizeof(T)])[1]
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
    cube, p = _cube_for_row(tsm, row)
    isnull(cube) && error("row $row of this column has no stored data " *
                          "(the tiled cell is undefined)")
    return read_plane(tsm, cube, p - 1)
end

"Whether every row of this tiled column is an undefined (unwritten) cell."
alldefined_none(tsm::TiledStMan) =
    tsm.kind == :shape && (isempty(tsm.row) || all(isnull, tsm.cubes))

# Fast whole-column read for the common layout: a single hypercube whose
# leading axes are not tiled (tilesPerDim == 1 there), so each on-disk tile
# is a contiguous run of whole cells along the last (row) axis.
function _read_cube_bulk(tsm::TiledStMan, cube::TSMCube, rowpos::Function, nrow::Int)
    T = juliatype(tsm.type)
    T === Bool && return nothing            # bit unpacking: use the slow path
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    all(cld(cs[d], ts[d]) == 1 for d in 1:nd-1) || return nothing

    planeshape = cs[1:nd-1]
    planelen = prod(planeshape)
    rowspertile = ts[nd]
    bytes = _tsmbytes(tsm, cube.sequ)
    bbytes = _bucketbytes(tsm, cube)
    swap = tsm.endian === :big ? ntoh : ltoh

    backing = Vector{T}(undef, nrow * planelen)
    for r in 1:nrow
        p = rowpos(r) - 1                    # 0-based last-axis position
        tile = p ÷ rowspertile
        within = (p % rowspertile) * planelen
        b = cube.offset + tile * bbytes + within * sizeof(T)
        raw = reinterpret(T, @view bytes[b+1 : b + planelen*sizeof(T)])
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
        elseif length(tsm.row) == 1 && tsm.row[1] >= nrow
            r -> tsm.pos[1] - (tsm.row[1] - r)
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

# =====================  writer  =====================================
# Single hypercube covering all rows (uniform cell shape).

# TSMCube::putObject writes no framing of its own.
function _tsm_putobject_cube(w::AipsWriter, cubeshape, tileshape, fileseqnr, offset)
    wr_u32(w, TSM_CUBE_VER)
    write_record(w, CasaRecord(); typename="Record")     # values_p (empty)
    wr_scalar(w, true)                                    # extensible
    wr_u32(w, length(cubeshape))
    wr_iposition(w, cubeshape)
    wr_iposition(w, tileshape)
    wr_i32(w, fileseqnr)
    wr_u32(w, offset)
end

"""
    write_tiledshapestman(dir, sequ, col, celldata, nrow, endian) -> Vector{UInt8}

Write `table.f<sequ>` + `table.f<sequ>_TSM1` for one variable-shape numeric/
Bool array column, and return the (empty) block for the table.dat column-set
section.  All cells must share one shape.
"""
function write_tiledshapestman(dir::AbstractString, sequ::Int, col::ColumnDesc,
                               celldata::Vector, nrow::Int, endian::Symbol)
    shapes = unique(size.(celldata))
    length(shapes) == 1 ||
        error("TiledShapeStMan writer needs a uniform cell shape, got $shapes")
    cell = collect(shapes[1])
    J = juliatype(col.type)
    elemsz = J === Bool ? 0 : sizeof(J)              # 0 => bit-packed
    planelen = prod(cell; init=1)

    trow = clamp(TSM_TILE_TARGET ÷ max(planelen * max(elemsz, 1), 1), 1, nrow)
    tileshape = (cell..., trow)
    cubeshape = (cell..., nrow)
    ntiles = cld(nrow, trow)
    tilepix = prod(tileshape)
    tilebytes = J === Bool ? cld(tilepix, 8) : tilepix * elemsz

    # --- _TSM1 -----------------------------------------------------
    data = zeros(UInt8, ntiles * tilebytes)
    for r in 0:nrow-1
        plane = vec(celldata[r + 1])
        tile = r ÷ trow
        base = tile * tilebytes
        within = (r % trow) * planelen
        if J === Bool
            for e in 0:planelen-1
                if plane[e + 1]
                    b = within + e
                    data[base + (b >> 3) + 1] |= (0x01 << (b & 7))
                end
            end
        else
            off = base + within * elemsz
            for e in 1:planelen
                _wrbytes!(data, off + (e-1)*elemsz, J(plane[e]), endian)
            end
        end
    end
    write(joinpath(dir, "table.f$(sequ)_TSM1"), data)
    write(joinpath(dir, "table.f$sequ"),
          _tsm_header_bytes(sequ, col.type, "TSM$(col.name)", cubeshape,
                            tileshape, length(data), nrow, endian))

    return UInt8[]                                   # empty table.dat block
end

# The `table.f<sequ>` header for a single-column TiledShapeStMan with one
# hypercube covering all rows.  `datalen` = byte length of `_TSM1`.
function _tsm_header_bytes(sequ::Int, type::CasaType, hyper::AbstractString,
                           cubeshape, tileshape, datalen::Int, nrow::Int,
                           endian::Symbol)
    hw = AipsWriter(; endian=:big)
    putstart(hw, "TiledShapeStMan", TSM_WRAPPER_VER)
    putstart(hw, "TiledStMan", TSM_BASE_VER)
    wr_scalar(hw, endian === :big)                   # bigEndian flag
    wr_u32(hw, sequ)
    wr_u32(hw, nrow)
    wr_u32(hw, 1)                                    # ncolumn (single-column TSM)
    wr_i32(hw, Int(type))
    wr_string(hw, hyper)                             # hypercolumn name
    wr_u32(hw, 0)                                    # persMaxCacheSize
    wr_u32(hw, length(cubeshape))                    # nrdim
    wr_u32(hw, 2)                                    # nrFile (cube 0 absent, cube 1 present)
    wr_scalar(hw, false)                             # file 0 absent
    wr_scalar(hw, true)                              # file 1 present
    wr_u32(hw, TSM_FILE_VER); wr_u32(hw, 1); wr_u32(hw, datalen)  # TSMFile: seqnr 1
    wr_u32(hw, 2)                                    # nrCube (dummy + real)
    _tsm_putobject_cube(hw, Int[], Int[], -1, 0)     # cube 0 (empty)
    _tsm_putobject_cube(hw, cubeshape, tileshape, 1, 0)
    putend(hw)                                       # close "TiledStMan"
    wr_iposition(hw, tileshape)                      # defaultTileShape
    wr_u32(hw, 1)                                    # nrUsedRowMap
    wr_block(hw, UInt32[nrow - 1])                   # rowMap  (0-based last row)
    wr_block(hw, UInt32[1])                          # cubeMap
    wr_block(hw, UInt32[nrow - 1])                   # posMap
    putend(hw)
    return bytes(hw)
end

# =====================  in-place edit  ==============================

# a writable, shared mmap over `table.f<sequ>_TSM<n>`
function _tsm_writable(tsm::TiledStMan, sequ::Int)
    io = open(tsm.files[sequ], "r+")
    m = Mmap.mmap(io, Vector{UInt8}, filesize(io); shared=true)
    close(io)                                        # mapping stays valid
    return m
end

# byte-exact inverse of `read_plane`: write `plane` into `bytes` at
# last-axis index `lastpos` (0-based) of `cube`.
function write_plane!(bytes::Vector{UInt8}, tsm::TiledStMan, cube::TSMCube,
                      lastpos::Int, plane)
    T = juliatype(tsm.type)
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    planeshape = cs[1:nd-1]
    v = vec(plane)
    length(v) == prod(planeshape; init=1) ||
        error("write_plane!: value has $(size(plane)), cell shape is $planeshape")

    bbytes = _bucketbytes(tsm, cube)
    tlast_tile = lastpos ÷ ts[nd]
    tlast_in   = lastpos % ts[nd]

    for lt in CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd-1))
        tilecoord = ntuple(d -> d < nd ? lt[d] : tlast_tile, nd)
        tilenr = _colmajor_offset(tilecoord, tpd)
        base = cube.offset + tilenr * bbytes
        los = ntuple(d -> lt[d] * ts[d], nd-1)
        his = ntuple(d -> min((lt[d]+1) * ts[d], cs[d]) - 1, nd-1)
        for pix in CartesianIndices(ntuple(d -> los[d]:his[d], nd-1))
            pl = _colmajor_offset(ntuple(d -> pix[d], nd-1), planeshape)
            tl = ntuple(d -> d < nd ? pix[d] - los[d] : tlast_in, nd)
            k = _colmajor_offset(tl, ts)
            val = v[pl + 1]
            if T === Bool
                bi = base + (k >> 3) + 1
                bit = 0x01 << (k & 7)
                bytes[bi] = (val::Bool) ? (bytes[bi] | bit) : (bytes[bi] & ~bit)
            else
                _wrbytes!(bytes, base + k * sizeof(T), T(val), tsm.endian)
            end
        end
    end
    return bytes
end

"""
    tsm_setcell!(tsm, row, plane)

Overwrite one tiled cell (1-based `row`) in place.  `plane` must match the
existing cell shape.
"""
function tsm_setcell!(tsm::TiledStMan, row::Integer, plane)
    cube, p = _cube_for_row(tsm, row)
    isnull(cube) && error("row $row of this column has no stored cube to write into")
    m = _tsm_writable(tsm, cube.sequ)
    write_plane!(m, tsm, cube, p - 1, plane)
    Mmap.sync!(m)
    tsm.data[cube.sequ] = m                          # refresh the read cache
    return tsm
end

"""
    tsm_extend_rows!(tsm, col, oldnrow, newnrow)

Grow the single hypercube's last axis from `oldnrow` to `newnrow`:
append zero-filled tiles to `_TSM1` and rewrite the header.  The new
rows read back as zeros until written.
"""
function tsm_extend_rows!(tsm::TiledStMan, col::ColumnDesc,
                          oldnrow::Integer, newnrow::Integer)
    ridx = findfirst(!isnull, tsm.cubes)
    ridx === nothing && error("tsm_extend_rows!: column has no real hypercube")
    cube = tsm.cubes[ridx]
    nd = length(cube.cubeshape)
    trow = cube.tileshape[nd]
    tilebytes = _bucketbytes(tsm, cube)
    oldtiles = cld(Int(oldnrow), trow)
    newtiles = cld(Int(newnrow), trow)

    tsmpath = tsm.files[cube.sequ]
    if newtiles > oldtiles
        open(tsmpath, "a") do io
            write(io, zeros(UInt8, (newtiles - oldtiles) * tilebytes))
        end
    end
    datalen = filesize(tsmpath)

    cubeshape = (cube.cubeshape[1:nd-1]..., Int(newnrow))
    write(tsm.path,
          _tsm_header_bytes(tsm.sequ, tsm.type, tsm.hyper, cubeshape,
                            cube.tileshape, datalen, Int(newnrow), tsm.endian))

    # refresh in-memory reader state
    tsm.cubes[ridx] = TSMCube(cubeshape, cube.tileshape, cube.sequ, cube.offset)
    tsm.row = [Int(newnrow)]
    tsm.cube = [ridx]
    tsm.pos = [Int(newnrow)]
    delete!(tsm.data, cube.sequ)
    return tsm
end
