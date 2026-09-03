# TiledStMan / TiledShapeStMan / TiledColumnStMan / TiledCellStMan
# reader + writer.
#
# Mirrors casacore/tables/DataMan/TiledStMan.cc, TiledShapeStMan.cc,
# TiledColumnStMan.cc, TiledCellStMan.cc, TSMCube.cc, TSMFile.cc.
#
# A hypercube of shape `cubeshape` is partitioned into tiles of shape
# `tileshape`.  Tiles are stored back-to-back in a `table.f<sequ>_TSM<n>`
# file starting at `offset`, in column-major tile order; within a tile the
# elements are column-major over `tileshape` (edge tiles are still
# full-size on disk).  The header file `table.f<sequ>` is a plain
# big-endian AipsIO stream.
#
# A hypercube may be shared by N data columns of identical cell shape.
# Within a tile the N columns are stored CONCATENATED (not interleaved),
# each a contiguous `prod(tileshape) * canonical-pixel-size` block (`Bool`
# bit-packed, `cld(prod,8)` bytes).  The block order is the columns'
# binding order (= `TableDesc.columns` order) STABLY SORTED by descending
# canonical pixel size (casacore `std::stable_sort`, `Sort::Descending`;
# `Bool` has size 0 and sorts last).  Coordinate / id columns are not
# supported (`values_p` is always an empty Record).
#
# Rows are 1-based in this file's API.

import Mmap

const TSM_TILE_TARGET   = 1 << 20   # writer: aim for ~1 MiB of data per tile (all columns)
const TSM_CELL_MAXCUBES = 1_000_000 # TiledCellStMan warn threshold (one cube per row)

# AipsIO object versions we write in `table.f<seqnr>`
const TSM_WRAPPER_VER = 1   # "TiledShapeStMan" / "TiledColumnStMan" / "TiledCellStMan" outer object
const TSM_BASE_VER    = 2   # nested "TiledStMan" object (little-endian tables)
const TSM_CUBE_VER    = 1   # TSMCube::putObject, small offset (< 2 GiB)
const TSM_FILE_VER    = 1   # a TSMFile record, small file (< 2 GiB)

struct TSMCube
    cubeshape::Dims
    tileshape::Dims
    sequ::Union{Int,Nothing}    # _TSM file number; nothing => no data
    offset::Int                 # byte offset of this cube within its _TSM file
end

isnull(c::TSMCube) = c.sequ === nothing || isempty(c.cubeshape)

mutable struct TiledStMan
    path::String
    endian::Symbol                 # :big or :little (element data in the _TSM files)
    kind::Symbol                   # :column | :shape | :cell
    sequ::Int                      # this data manager's sequence number
    types::Vector{CasaType}        # element type per bound column, binding order
    hyper::String                  # hypercolumn name (a label; no Hypercolumn_ keyword written)
    dims::Int                      # hypercube dimensionality
    files::Dict{Int,String}        # _TSM sequence nr -> file path
    data::Dict{Int,Vector{UInt8}}  # _TSM sequence nr -> lazily mmapped bytes
    cubes::Vector{TSMCube}
    # TiledShapeStMan row -> cube mapping (empty for TiledColumnStMan / TiledCellStMan)
    row::Vector{Int}              # 1-based last row of each interval
    cube::Vector{Int}             # 1-based cube index per interval
    pos::Vector{Int}              # 1-based last last-axis position per interval
end

# --- tile column layout -------------------------------------------

# canonical (on-disk) pixel size; the sort key only — `Bool` => 0 (bit-packed).
_canon(t::CasaType) = t == TpBool ? 0 : sizeof(juliatype(t))

# binding-index order in which the columns' blocks are laid out inside a
# tile.  casacore sorts `dataCols_p` descending by canonical pixel size
# (`GenSortIndirect`, `Sort::Descending`); its comparator
# `isAscending(i,j) = data[i] > data[j] || (data[i] == data[j] && i > j)`
# means a descending sort breaks ties by *descending original index*, so
# equal-size columns end up in reverse binding order.
_tile_order(types) = sortperm(1:length(types); by = i -> (-_canon(types[i]), -i))

# (bytes per full tile, byte offset of each binding column's block in a tile)
function _tile_layout(types::Vector{CasaType}, tileshape)
    np = prod(tileshape; init = 1)
    blk(t) = t == TpBool ? cld(np, 8) : np * sizeof(juliatype(t))
    offs = zeros(Int, length(types))
    acc = 0
    for i in _tile_order(types)
        offs[i] = acc
        acc += blk(types[i])
    end
    return acc, offs
end
_tile_layout(tsm::TiledStMan, cube::TSMCube) = _tile_layout(tsm.types, cube.tileshape)

# --- header parsing ----------------------------------------------

function _read_tsmcube(a::AipsIO)
    version = read_u32(a)
    read_record(a)                              # values_p (coord/id values; unsupported => empty)
    read_scalar(a, Bool)                        # extensible
    read_u32(a)                                 # nrdim (== length(cubeshape))
    cubeshape = read_iposition(a)
    tileshape = read_iposition(a)
    fs = Int(read_i32(a))
    sequ = fs < 0 ? nothing : fs
    offset = version == 1 ? Int(read_u32(a)) : Int(read_scalar(a, UInt64))
    return TSMCube(cubeshape, tileshape, sequ, offset)
end

function _headerfile_get!(a::AipsIO, tsm::TiledStMan, t::Table)
    version = getstart(a, "TiledStMan")
    version >= 2 && read_scalar(a, Bool)                   # bigEndian flag
    tsm.sequ = Int(read_u32(a))
    version >= 3 ? read_scalar(a, UInt64) : read_u32(a)    # nrrow
    ncol = Int(read_u32(a))
    tsm.types = CasaType[casatype(read_i32(a)) for _ in 1:ncol]
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

function open_tiledstman(t::Table, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.sequ)")
    a = AipsIO(read(path); endian=:big)             # header file is big-endian
    tsm = TiledStMan(path, t.endian, :column, dm.sequ, CasaType[], "", 0,
                     Dict{Int,String}(), Dict{Int,Vector{UInt8}}(),
                     TSMCube[], Int[], Int[], Int[])

    wrapper = getnexttype(a)                         # peek outer wrapper
    read_u32(a)                                      # wrapper version
    if wrapper == "TiledColumnStMan"
        tsm.kind = :column
        read_iposition(a)                           # tileShape_p (also in the cube)
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
    elseif wrapper == "TiledCellStMan"
        tsm.kind = :cell
        read_iposition(a)                           # defaultTileShape
        _headerfile_get!(a, tsm, t)
    elseif wrapper == "TiledDataStMan"
        error("TiledDataStMan not yet supported")
    else
        error("unknown tiled storage manager \"$wrapper\"")
    end
    getend(a)
    return tsm
end

# --- row -> (cube, last-axis position) ---------------------------

# `position === nothing` => the whole cube is the cell (TiledCellStMan).
function _cube_for_row(tsm::TiledStMan, rownr::Integer)
    if tsm.kind === :cell
        return tsm.cubes[Int(rownr)], nothing
    end
    if tsm.kind === :column                       # one cube, position == row
        c = tsm.cubes[findfirst(x -> !isnull(x), tsm.cubes)]
        return c, Int(rownr)
    end
    # TiledShapeStMan: interval search over the row map
    if isempty(tsm.row) || rownr > tsm.row[end]
        return tsm.cubes[1], 0                     # cube 0 == undefined cells
    end
    idx = findfirst(>=(rownr), tsm.row)
    c = tsm.cubes[tsm.cube[idx]]
    p = tsm.pos[idx] - (tsm.row[idx] - Int(rownr))
    return c, p
end

# --- tile data access -------------------------------------------

function _tsmbytes(tsm::TiledStMan, sequ::Int)
    get!(tsm.data, sequ) do
        Mmap.mmap(tsm.files[sequ], Vector{UInt8})
    end
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
    read_plane(tsm, cube, lastpos, colidx) -> Array

Read the sub-array at last-axis index `lastpos` (0-based) of `cube` for the
`colidx`-th bound column (binding index), de-tiling into a column-major
Julia array of shape `cube.cubeshape[1:end-1]`.
"""
function read_plane(tsm::TiledStMan, cube::TSMCube, lastpos::Int, colidx::Int)
    T = juliatype(tsm.types[colidx])
    nd = length(cube.cubeshape)
    cs = cube.cubeshape
    ts = cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    planeshape = cs[1:nd-1]
    out = Array{T}(undef, planeshape...)

    bytes = _tsmbytes(tsm, cube.sequ)
    bbytes, offs = _tile_layout(tsm, cube)
    coloff = offs[colidx]
    esz = T === Bool ? 0 : sizeof(T)
    swap = tsm.endian === :big ? ntoh : ltoh

    tlast_tile = lastpos ÷ ts[nd]
    tlast_in   = lastpos % ts[nd]

    for lt in CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd-1))
        tilecoord = ntuple(d -> d < nd ? lt[d] : tlast_tile, nd)
        tilenr = _colmajor_offset(tilecoord, tpd)
        base = cube.offset + tilenr * bbytes + coloff

        los = ntuple(d -> lt[d] * ts[d], nd-1)
        his = ntuple(d -> min((lt[d]+1) * ts[d], cs[d]) - 1, nd-1)

        for pix in CartesianIndices(ntuple(d -> los[d]:his[d], nd-1))
            tl = ntuple(d -> d < nd ? pix[d] - los[d] : tlast_in, nd)
            k = _colmajor_offset(tl, ts)          # element index within tile
            dst = CartesianIndex(ntuple(d -> pix[d] + 1, nd-1))
            if T === Bool
                byte = bytes[base + (k >> 3) + 1]
                out[dst] = (byte >> (k & 7)) & 0x01 == 0x01
            else
                b = base + k * esz
                out[dst] = swap(reinterpret(T, @view bytes[b+1 : b+esz])[1])
            end
        end
    end
    return out
end

"""
    read_cube_whole(tsm, colidx, cube) -> Array

Read an entire hypercube (TiledCellStMan: one cube == one cell) for the
`colidx`-th bound column.
"""
function read_cube_whole(tsm::TiledStMan, colidx::Int, cube::TSMCube)
    T = juliatype(tsm.types[colidx])
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    out = Array{T}(undef, cs...)

    bytes = _tsmbytes(tsm, cube.sequ)
    bbytes, offs = _tile_layout(tsm, cube)
    coloff = offs[colidx]
    esz = T === Bool ? 0 : sizeof(T)
    swap = tsm.endian === :big ? ntoh : ltoh

    for lt in CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd))
        tilenr = _colmajor_offset(ntuple(d -> lt[d], nd), tpd)
        base = cube.offset + tilenr * bbytes + coloff
        los = ntuple(d -> lt[d] * ts[d], nd)
        his = ntuple(d -> min((lt[d]+1) * ts[d], cs[d]) - 1, nd)
        for pix in CartesianIndices(ntuple(d -> los[d]:his[d], nd))
            k = _colmajor_offset(ntuple(d -> pix[d] - los[d], nd), ts)
            dst = CartesianIndex(ntuple(d -> pix[d] + 1, nd))
            if T === Bool
                byte = bytes[base + (k >> 3) + 1]
                out[dst] = (byte >> (k & 7)) & 0x01 == 0x01
            else
                b = base + k * esz
                out[dst] = swap(reinterpret(T, @view bytes[b+1 : b+esz])[1])
            end
        end
    end
    return out
end

"""
    tsm_getcell(tsm, colidx, coldesc, row) -> Array   (1-based row)
"""
function tsm_getcell(tsm::TiledStMan, colidx::Int, ::ColumnDesc, row::Integer)
    cube, p = _cube_for_row(tsm, row)
    isnull(cube) && error("row $row of this column has no stored data " *
                          "(the tiled cell is undefined)")
    p === nothing && return read_cube_whole(tsm, colidx, cube)
    return read_plane(tsm, cube, p - 1, colidx)
end

"Whether every row of this tiled column is an undefined (unwritten) cell."
alldefined_none(tsm::TiledStMan) =
    tsm.kind === :shape && (isempty(tsm.row) || all(isnull, tsm.cubes))

# Fast whole-column read for the common layout: a single hypercube whose
# leading axes are not tiled (tilesPerDim == 1 there), so each on-disk tile
# is a contiguous run of whole cells along the last (row) axis.
function _read_cube_bulk(tsm::TiledStMan, cube::TSMCube, rowpos::Function,
                         nrow::Int, colidx::Int)
    T = juliatype(tsm.types[colidx])
    T === Bool && return nothing            # bit unpacking: use the slow path
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    all(cld(cs[d], ts[d]) == 1 for d in 1:nd-1) || return nothing

    planeshape = cs[1:nd-1]
    planelen = prod(planeshape)
    rowspertile = ts[nd]
    bytes = _tsmbytes(tsm, cube.sequ)
    bbytes, offs = _tile_layout(tsm, cube)
    coloff = offs[colidx]
    swap = tsm.endian === :big ? ntoh : ltoh

    backing = Vector{T}(undef, nrow * planelen)
    for r in 1:nrow
        p = rowpos(r) - 1                    # 0-based last-axis position
        tile = p ÷ rowspertile
        within = (p % rowspertile) * planelen
        b = cube.offset + tile * bbytes + coloff + within * sizeof(T)
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
    tsm_getcolumn(tsm, colidx, coldesc, nrow) -> Vector{Array}
"""
function tsm_getcolumn(tsm::TiledStMan, colidx::Int, c::ColumnDesc, nrow::Integer)
    if tsm.kind === :cell
        return [read_cube_whole(tsm, colidx, tsm.cubes[r]) for r in 1:nrow]
    end
    alldefined_none(tsm) &&
        error("column has no stored data (all tiled cells are undefined)")

    real = findall(!isnull, tsm.cubes)
    if length(real) == 1
        cube = tsm.cubes[real[1]]
        rowpos = if tsm.kind === :column
            identity
        elseif length(tsm.row) == 1 && tsm.row[1] >= nrow
            r -> tsm.pos[1] - (tsm.row[1] - r)
        else
            nothing
        end
        if rowpos !== nothing
            fast = _read_cube_bulk(tsm, cube, rowpos, Int(nrow), colidx)
            fast === nothing || return fast
        end
    end
    return [tsm_getcell(tsm, colidx, c, r) for r in 1:nrow]
end

# =====================  writer  ====================================

# --- header building -------------------------------------------

struct _TSMFileSpec
    present::Bool
    seqnr::Int
    len::Int
end
struct _TSMCubeSpec
    cubeshape::Dims
    tileshape::Dims
    fileseqnr::Int
    offset::Int
end

# TSMCube::putObject writes no framing of its own.
function _tsm_putobject_cube(w::AipsWriter, c::_TSMCubeSpec; extensible::Bool=true)
    v1 = c.offset < (1 << 31)
    wr_u32(w, v1 ? 1 : 2)
    write_record(w, Record(); typename="Record")      # values_p (empty)
    wr_scalar(w, extensible)
    wr_u32(w, length(c.cubeshape))
    wr_iposition(w, c.cubeshape)
    wr_iposition(w, c.tileshape)
    wr_i32(w, c.fileseqnr)
    v1 ? wr_u32(w, c.offset) : wr_u64(w, c.offset)
end

# mirrors casacore TiledStMan::headerFilePut, inside an already-open wrapper
function _tsm_headerfileput!(w::AipsWriter, sequ::Int, types::Vector{CasaType},
                             hyper::AbstractString, nrdim::Int,
                             files::Vector{_TSMFileSpec}, cubes::Vector{_TSMCubeSpec},
                             nrow::Int, endian::Symbol; cube_extensible::Bool=true)
    putstart(w, "TiledStMan", TSM_BASE_VER)
    wr_scalar(w, endian === :big)                     # bigEndian flag
    wr_u32(w, sequ)
    wr_u32(w, nrow)
    wr_u32(w, length(types))
    for t in types
        wr_i32(w, Int(t))                             # dataType per column, binding order
    end
    wr_string(w, hyper)
    wr_u32(w, 0)                                      # persMaxCacheSize
    wr_u32(w, nrdim)
    wr_u32(w, length(files))
    for f in files
        wr_scalar(w, f.present)
        f.present || continue
        if f.len < (1 << 31)
            wr_u32(w, 1); wr_u32(w, f.seqnr); wr_u32(w, f.len)
        else
            wr_u32(w, 2); wr_u32(w, f.seqnr); wr_u64(w, f.len)
        end
    end
    wr_u32(w, length(cubes))
    for c in cubes
        _tsm_putobject_cube(w, c; extensible = c.fileseqnr < 0 ? true : cube_extensible)
    end
    putend(w)                                         # close "TiledStMan"
end

# The full `table.f<sequ>` bytes for a TiledShapeStMan.
function _tiledshape_header_bytes(sequ::Int, types::Vector{CasaType}, hyper::AbstractString,
                                  nrdim::Int, cubes::Vector{_TSMCubeSpec},
                                  files::Vector{_TSMFileSpec}, deftile,
                                  rowmap, cubemap, posmap, nrow::Int, endian::Symbol)
    w = AipsWriter(; endian=:big)
    putstart(w, "TiledShapeStMan", TSM_WRAPPER_VER)
    _tsm_headerfileput!(w, sequ, types, hyper, nrdim, files, cubes, nrow, endian)
    wr_iposition(w, deftile)                          # defaultTileShape
    wr_u32(w, length(rowmap))                         # nrUsedRowMap
    wr_block(w, UInt32.(rowmap))                      # rowMap  (0-based last row)
    wr_block(w, UInt32.(cubemap))                     # cubeMap (0-based cube index)
    wr_block(w, UInt32.(posmap))                      # posMap  (0-based last position)
    putend(w)
    return bytes(w)
end

_hyper_name(cols) = "TSM" * first(cols).name

# rows-per-tile so one full tile (all N columns) is ~`TSM_TILE_TARGET` bytes
function _tsm_trow(cell::Dims, types::Vector{CasaType}, navail::Int)
    per_row = sum(prod(cell; init=1) * max(_canon(t), 1) for t in types; init=1)
    clamp(TSM_TILE_TARGET ÷ max(per_row, 1), 1, max(navail, 1))
end

# write one row's plane for every column into a tile buffer
function _pack_planes!(buf::Vector{UInt8}, tilebase::Int, within::Int, planelen::Int,
                       types::Vector{CasaType}, offs::Vector{Int},
                       planes, endian::Symbol)
    for k in eachindex(types)
        T = juliatype(types[k])
        plane = planes[k]
        base = tilebase + offs[k]
        if T === Bool
            for e in 0:planelen-1
                if plane[e+1] != 0
                    b = within + e
                    buf[base + (b >> 3) + 1] |= (0x01 << (b & 7))
                end
            end
        else
            o = base + within * sizeof(T)
            for e in 1:planelen
                _wrbytes!(buf, o + (e-1)*sizeof(T), T(plane[e]), endian)
            end
        end
    end
end

# --- TiledShapeStMan ------------------------------------------

"""
    write_tiledshapestman(dir, sequ, cols, coldata, nrow, endian) -> UInt8[]

Write `table.f<sequ>` + one `table.f<sequ>_TSM<k>` per distinct cell shape
for a hypercube shared by `cols` (all cells of one row share a shape).
Returns the empty table.dat column-set block.
"""
function write_tiledshapestman(dir::AbstractString, sequ::Int,
                               cols::Vector{<:ColumnDesc}, coldata::Vector,
                               nrow::Int, endian::Symbol)
    ncol = length(cols)
    types = CasaType[c.type for c in cols]

    rowshape = Vector{Dims}(undef, nrow)
    for r in 1:nrow
        s = size(coldata[1][r])
        for k in 2:ncol
            size(coldata[k][r]) == s || error("TiledShapeStMan group: row $r column " *
                "$(cols[k].name) shape $(size(coldata[k][r])) ≠ $s")
        end
        rowshape[r] = s
    end
    shapes = unique(rowshape)                         # first-seen order
    nrdim = length(shapes[1]) + 1
    all(length(s) + 1 == nrdim for s in shapes) ||
        error("TiledShapeStMan group: mixed cell dimensionality $(shapes)")

    files = _TSMFileSpec[_TSMFileSpec(false, 0, 0)]   # slot 0: null placeholder
    cubes = _TSMCubeSpec[_TSMCubeSpec((), (), -1, 0)] # cube 0: undefined-cells dummy
    rowmap = Int[]; cubemap = Int[]; posmap = Int[]
    deftile = ntuple(_ -> 0, nrdim)

    for (si, s) in enumerate(shapes)
        rows_s = findall(==(s), rowshape)            # ascending 1-based row indices
        ns = length(rows_s)
        cell = Dims(s)
        planelen = prod(cell; init=1)
        trow = _tsm_trow(cell, types, ns)
        tileshape = (cell..., trow)
        cubeshape = (cell..., ns)
        bbytes, offs = _tile_layout(types, tileshape)
        buf = zeros(UInt8, cld(ns, trow) * bbytes)
        for (pos, r) in enumerate(rows_s)
            p = pos - 1
            tilebase = (p ÷ trow) * bbytes
            _pack_planes!(buf, tilebase, (p % trow) * planelen, planelen, types, offs,
                          ntuple(k -> vec(coldata[k][r]), ncol), endian)
        end
        write(joinpath(dir, "table.f$(sequ)_TSM$si"), buf)
        push!(files, _TSMFileSpec(true, si, length(buf)))
        push!(cubes, _TSMCubeSpec(cubeshape, tileshape, si, 0))
        si == 1 && (deftile = tileshape)

        # run-length row-map intervals over the ascending rows_s
        j = 1
        while j <= ns
            while j < ns && rows_s[j+1] == rows_s[j] + 1
                j += 1
            end
            push!(rowmap, rows_s[j] - 1)             # 0-based last row of interval
            push!(cubemap, si)                       # 0-based cube index (dummy = 0)
            push!(posmap, j - 1)                     # 0-based last position in the cube
            j += 1
        end
    end

    perm = sortperm(rowmap)                          # rowMap must be ascending
    rowmap, cubemap, posmap = rowmap[perm], cubemap[perm], posmap[perm]

    write(joinpath(dir, "table.f$sequ"),
          _tiledshape_header_bytes(sequ, types, _hyper_name(cols), nrdim, cubes,
                                   files, deftile, rowmap, cubemap, posmap, nrow, endian))
    return UInt8[]
end

# --- TiledColumnStMan ----------------------------------------

"""
    write_tiledcolumnstman(dir, sequ, cols, coldata, nrow, endian) -> UInt8[]

Write `table.f<sequ>` + `table.f<sequ>_TSM0` for a hypercube of fixed cell
shape shared by `cols`.
"""
function write_tiledcolumnstman(dir::AbstractString, sequ::Int,
                                cols::Vector{<:ColumnDesc}, coldata::Vector,
                                nrow::Int, endian::Symbol)
    ncol = length(cols)
    types = CasaType[c.type for c in cols]
    s = nrow > 0 ? size(coldata[1][1]) : ()
    for k in 1:ncol, r in 1:nrow
        size(coldata[k][r]) == s || error("TiledColumnStMan group: non-uniform cell " *
            "shape (column $(cols[k].name) row $r: $(size(coldata[k][r])) ≠ $s)")
    end
    cell = Dims(s)
    nrdim = length(cell) + 1
    planelen = prod(cell; init=1)
    trow = _tsm_trow(cell, types, nrow)
    tileshape = (cell..., trow)
    cubeshape = (cell..., nrow)
    bbytes, offs = _tile_layout(types, tileshape)
    buf = zeros(UInt8, cld(nrow, trow) * bbytes)
    for r in 0:nrow-1
        tilebase = (r ÷ trow) * bbytes
        _pack_planes!(buf, tilebase, (r % trow) * planelen, planelen, types, offs,
                      ntuple(k -> vec(coldata[k][r+1]), ncol), endian)
    end
    write(joinpath(dir, "table.f$(sequ)_TSM0"), buf)

    w = AipsWriter(; endian=:big)
    putstart(w, "TiledColumnStMan", TSM_WRAPPER_VER)
    wr_iposition(w, tileshape)                        # tileShape_p, before headerFilePut
    _tsm_headerfileput!(w, sequ, types, _hyper_name(cols), nrdim,
                        _TSMFileSpec[_TSMFileSpec(true, 0, length(buf))],
                        _TSMCubeSpec[_TSMCubeSpec(cubeshape, tileshape, 0, 0)],
                        nrow, endian)
    putend(w)
    write(joinpath(dir, "table.f$sequ"), bytes(w))
    return UInt8[]
end

# --- TiledCellStMan ------------------------------------------

"""
    write_tiledcellstman(dir, sequ, cols, coldata, nrow, endian) -> UInt8[]

Write `table.f<sequ>` + `table.f<sequ>_TSM0` for a per-row hypercube (one
cube per row; cell ndim == hypercube ndim, no row axis).
"""
function write_tiledcellstman(dir::AbstractString, sequ::Int,
                              cols::Vector{<:ColumnDesc}, coldata::Vector,
                              nrow::Int, endian::Symbol)
    ncol = length(cols)
    types = CasaType[c.type for c in cols]
    nrow > TSM_CELL_MAXCUBES &&
        @warn "TiledCellStMan: writing $nrow per-row hypercubes into one header"

    rowshape = Vector{Dims}(undef, nrow)
    for r in 1:nrow
        sh = size(coldata[1][r])
        for k in 2:ncol
            size(coldata[k][r]) == sh || error("TiledCellStMan group: row $r shape mismatch")
        end
        rowshape[r] = sh
    end
    nrdim = nrow > 0 ? length(rowshape[1]) : 1
    all(length(sh) == nrdim for sh in rowshape) ||
        error("TiledCellStMan group: mixed cell dimensionality")
    deftile = nrow > 0 ? rowshape[1] : ntuple(_ -> 1, nrdim)

    buf = UInt8[]
    cubes = _TSMCubeSpec[]
    for r in 1:nrow
        cell = Dims(rowshape[r])
        tile = ntuple(d -> min(deftile[d], cell[d]), nrdim)
        bbytes, offs = _tile_layout(types, tile)
        tpd = ntuple(d -> cld(cell[d], tile[d]), nrdim)
        ntiles = prod(tpd; init=1)
        offset = length(buf)
        cbuf = zeros(UInt8, ntiles * bbytes)
        for k in 1:ncol
            T = juliatype(types[k]); A = coldata[k][r]
            for ci in CartesianIndices(cell)
                tn = _colmajor_offset(ntuple(d -> (ci[d]-1) ÷ tile[d], nrdim), tpd)
                kk = _colmajor_offset(ntuple(d -> (ci[d]-1) % tile[d], nrdim), tile)
                base = tn * bbytes + offs[k]
                if T === Bool
                    A[ci] != 0 && (cbuf[base + (kk >> 3) + 1] |= (0x01 << (kk & 7)))
                else
                    _wrbytes!(cbuf, base + kk * sizeof(T), T(A[ci]), endian)
                end
            end
        end
        append!(buf, cbuf)
        push!(cubes, _TSMCubeSpec(cell, tile, 0, offset))
    end
    write(joinpath(dir, "table.f$(sequ)_TSM0"), buf)

    w = AipsWriter(; endian=:big)
    putstart(w, "TiledCellStMan", TSM_WRAPPER_VER)
    wr_iposition(w, deftile)                          # defaultTileShape, before headerFilePut
    _tsm_headerfileput!(w, sequ, types, _hyper_name(cols), nrdim,
                        _TSMFileSpec[_TSMFileSpec(true, 0, length(buf))],
                        cubes, nrow, endian; cube_extensible=false)
    putend(w)
    write(joinpath(dir, "table.f$sequ"), bytes(w))
    return UInt8[]
end

# =====================  in-place edit  ============================

# a writable, shared mmap over `table.f<sequ>_TSM<n>`
function _tsm_writable(tsm::TiledStMan, sequ::Int)
    io = open(tsm.files[sequ], "r+")
    m = Mmap.mmap(io, Vector{UInt8}, filesize(io); shared=true)
    close(io)                                        # mapping stays valid
    return m
end

# byte-exact inverse of `read_plane`: write `plane` into `bytes` at
# last-axis index `lastpos` (0-based) of `cube` for the `colidx`-th column.
function write_plane!(bytes::AbstractVector{UInt8}, tsm::TiledStMan, cube::TSMCube,
                      lastpos::Int, plane, colidx::Int)
    T = juliatype(tsm.types[colidx])
    nd = length(cube.cubeshape)
    cs, ts = cube.cubeshape, cube.tileshape
    tpd = Int[cld(cs[d], ts[d]) for d in 1:nd]
    planeshape = cs[1:nd-1]
    v = vec(plane)
    length(v) == prod(planeshape; init=1) ||
        error("write_plane!: value has $(size(plane)), cell shape is $planeshape")

    bbytes, offs = _tile_layout(tsm, cube)
    coloff = offs[colidx]
    esz = T === Bool ? 0 : sizeof(T)
    tlast_tile = lastpos ÷ ts[nd]
    tlast_in   = lastpos % ts[nd]

    for lt in CartesianIndices(ntuple(d -> 0:tpd[d]-1, nd-1))
        tilecoord = ntuple(d -> d < nd ? lt[d] : tlast_tile, nd)
        tilenr = _colmajor_offset(tilecoord, tpd)
        base = cube.offset + tilenr * bbytes + coloff
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
                bytes[bi] = (val != 0) ? (bytes[bi] | bit) : (bytes[bi] & ~bit)
            else
                _wrbytes!(bytes, base + k * esz, T(val), tsm.endian)
            end
        end
    end
    return bytes
end

"""
    tsm_setcell!(tsm, colidx, row, plane)

Overwrite one tiled cell (1-based `row`, binding column index `colidx`) in
place.  `plane` must match the existing cell shape.
"""
function tsm_setcell!(tsm::TiledStMan, colidx::Int, row::Integer, plane)
    cube, p = _cube_for_row(tsm, row)
    isnull(cube) && error("row $row of this column has no stored cube to write into")
    m = _tsm_writable(tsm, cube.sequ)
    if p === nothing                                 # :cell -> whole cube
        nd = length(cube.cubeshape)
        for lp in 0:cube.cubeshape[nd]-1
            write_plane!(m, tsm, cube, lp, selectdim(plane, nd, lp+1), colidx)
        end
    else
        write_plane!(m, tsm, cube, p - 1, plane, colidx)
    end
    Mmap.sync!(m)
    tsm.data[cube.sequ] = m                          # refresh the read cache
    return tsm
end

"""
    tsm_extend_rows!(tsm, cols, oldnrow, newnrow)

Grow the single hypercube's last axis from `oldnrow` to `newnrow`: append
zero-filled tiles to its `_TSM` file and rewrite the header.  New rows of
every bound column read back as zeros until written.  (Fast-path only —
one real hypercube, uniform cell shape.)
"""
function tsm_extend_rows!(tsm::TiledStMan, cols::Vector{<:ColumnDesc},
                          oldnrow::Integer, newnrow::Integer)
    ridx = findfirst(!isnull, tsm.cubes)
    ridx === nothing && error("tsm_extend_rows!: column has no real hypercube")
    cube = tsm.cubes[ridx]
    nd = length(cube.cubeshape)
    trow = cube.tileshape[nd]
    bbytes, _ = _tile_layout(tsm, cube)
    oldtiles = cld(Int(oldnrow), trow)
    newtiles = cld(Int(newnrow), trow)

    tsmpath = tsm.files[cube.sequ]
    if newtiles > oldtiles
        open(tsmpath, "a") do io
            write(io, zeros(UInt8, (newtiles - oldtiles) * bbytes))
        end
    end
    datalen = filesize(tsmpath)
    cubeshape = (cube.cubeshape[1:nd-1]..., Int(newnrow))

    if tsm.kind === :column
        w = AipsWriter(; endian=:big)
        putstart(w, "TiledColumnStMan", TSM_WRAPPER_VER)
        wr_iposition(w, cube.tileshape)
        _tsm_headerfileput!(w, tsm.sequ, tsm.types, tsm.hyper, nd,
                            _TSMFileSpec[_TSMFileSpec(true, cube.sequ, datalen)],
                            _TSMCubeSpec[_TSMCubeSpec(cubeshape, cube.tileshape, cube.sequ, cube.offset)],
                            Int(newnrow), tsm.endian)
        putend(w)
        write(tsm.path, bytes(w))
    else
        files = _TSMFileSpec[_TSMFileSpec(false, 0, 0)]
        for sfeq in 1:cube.sequ
            push!(files, _TSMFileSpec(sfeq == cube.sequ, sfeq,
                                      sfeq == cube.sequ ? datalen : 0))
        end
        cubes = _TSMCubeSpec[_TSMCubeSpec((), (), -1, 0),
                             _TSMCubeSpec(cubeshape, cube.tileshape, cube.sequ, cube.offset)]
        write(tsm.path,
              _tiledshape_header_bytes(tsm.sequ, tsm.types, tsm.hyper, nd, cubes, files,
                                       cube.tileshape, Int[Int(newnrow) - 1], Int[1],
                                       Int[Int(newnrow) - 1], Int(newnrow), tsm.endian))
    end

    tsm.cubes[ridx] = TSMCube(cubeshape, cube.tileshape, cube.sequ, cube.offset)
    tsm.row = [Int(newnrow)]
    tsm.cube = [ridx]
    tsm.pos = [Int(newnrow)]
    delete!(tsm.data, cube.sequ)
    return tsm
end
