# CTDS table metadata: `table.dat`, `table.info`, column descriptions and
# data-manager bindings.  (casacore/tables/Tables/PlainTable.cc,
# TableDesc.cc, ColumnDesc.cc, BaseColDesc.cc, ColumnSet.cc, PlainColumn.cc)

import Mmap

# `ColumnDesc.option` is a bit mask (casacore ColumnDesc::Option)
const COLOPT_DIRECT     = Int32(1)   # array stored directly in the row (not indirect)
const COLOPT_UNDEFINED  = Int32(2)   # a cell value may be undefined
const COLOPT_FIXEDSHAPE = Int32(4)   # every cell has the same shape

# --- ValType scalar default -----------------------------------------

function read_valtype(a::AipsIO, t::CasaType)
    isscalartype(t) || return nothing
    t == TpString && return read_string(a)
    return read_scalar(a, juliatype(t))
end

# --- column description --------------------------------------------

"An array column with a fixed number of axes but a per-row-variable cell shape
(casacore ndim > 0 with no declared shape, e.g. `DATA`, `FLAG_CATEGORY`)."
struct VariableShape end

"An array column whose dimensionality itself varies per row
(casacore ndim == -1, e.g. `ASSOC_SPW_ID`)."
struct VariableDims end

"""
Cell-shape descriptor for a column:
  * `()`             — scalar
  * a `Dims` tuple   — array with a fixed cell shape
  * `VariableShape`  — array, fixed dimensionality, per-row-variable shape
  * `VariableDims`   — array whose dimensionality itself varies per row
"""
const CellShape = Union{Dims,VariableShape,VariableDims}

"""
    ColumnDesc

Description of one table column: its `name`, element `type` (a
[`CasaType`](@ref)), cell `shape` (a [`CellShape`](@ref) — `()` scalar,
a `Dims` tuple, `VariableShape`, or `VariableDims`), `comment`, per-column
`keywords` (a [`Record`](@ref), holding units / `MEASINFO` / engine
config), and the storage-manager `manager` type + `group` (instance) it is
bound to. Obtained from [`columndesc`](@ref); the fields are read-only.
"""
struct ColumnDesc{T<:CellShape}
    name::String
    comment::String
    manager::String            # data-manager *type* the column is bound to
    group::String              # data-manager *group* (instance) name
    type::CasaType             # scalar or array CasaType
    classname::String          # casacore ColumnDesc class, e.g. "ScalarColumnDesc<Int>"
    shape::T                   # () scalar / Dims fixed / VariableShape / VariableDims
    option::Int32
    maxlength::UInt32
    keywords::Record
    default::Any               # scalar columns only
    # filled in from ColumnSet: data-manager instance sequence number
    # (`nothing` until the column is bound to a data manager)
    sequ::Union{Int,Nothing}
end

"Whether column `c` holds arrays (`shape` other than `()`)."
isarray(::ColumnDesc{Tuple{}}) = false
isarray(::ColumnDesc) = true

function Base.show(io::IO, c::ColumnDesc)
    s = c.shape isa Dims && !isempty(c.shape) ? string(c.shape) :
        c.shape isa VariableShape ? "[var shape]" :
        c.shape isa VariableDims ? "[var dims]" : ""
    print(io, "ColumnDesc(", c.name, "::", c.type, s,
          " @", c.manager, "/", c.group, ")")
end

function read_columndesc(a::AipsIO)
    read_u32(a)                 # ColumnDesc wrapper version
    classname = read_string(a)               # e.g. "ScalarColumnDesc<Int>"
    isarray = startswith(classname, "Array")
    isrecord = startswith(classname, "ScalarRecord")

    read_u32(a)                  # BaseColumnDesc version
    name        = read_string(a)
    comment     = read_string(a)
    manager     = read_string(a)
    group       = read_string(a)
    dtype       = casatype(read_i32(a))
    option      = read_i32(a)
    nrdim       = Int(read_i32(a))
    schemashape = isarray ? read_iposition(a) : ()
    maxlen      = read_u32(a)
    keywords    = read_record(a)

    default = nothing
    read_u32(a)                  # getDesc version
    if isarray
        read(a.io, UInt8)                     # obsolete "has default" switch
    elseif !isrecord
        default = read_valtype(a, dtype)
    end

    shape = _cellshape(isarray, nrdim, schemashape)
    ColumnDesc(name, comment, manager, group, dtype, classname,
               shape, option, maxlen, keywords, default, nothing)
end

_cellshape(isarray::Bool, nrdim::Int, fixed::Dims)::CellShape =
    !isarray            ? () :
    !isempty(fixed)     ? fixed :
    nrdim == -1         ? VariableDims() :
                          VariableShape()

# --- table description --------------------------------------------

"""
    TableDesc

A table's schema: its `name`, format `version`, the `public` and
`private` keyword sets (each a [`Record`](@ref)), and the ordered list of
[`ColumnDesc`](@ref) `columns`. Reachable as `t.desc` on a [`Table`](@ref);
most code uses [`columnnames`](@ref) / [`columndesc`](@ref) /
[`keywords`](@ref) instead.
"""
struct TableDesc
    name::String
    version::String
    comment::String
    public::Record         # public keyword set
    private::Record        # private (internal) keyword set
    columns::Vector{ColumnDesc}
end

function read_tabledesc(a::AipsIO)
    tvers = getstart(a, "TableDesc")
    name = read_string(a)
    version = read_string(a)
    comment = read_string(a)
    public = read_record(a)
    private = tvers != 1 ? read_record(a) : Record()

    ncol = Int(read_u32(a))
    cols = ColumnDesc[read_columndesc(a) for _ in 1:ncol]
    getend(a)
    return TableDesc(name, version, comment, public, private, cols)
end

# --- data manager info -------------------------------------------

struct DataManagerInfo
    name::String               # instance name, e.g. "SSM" or "TiledData"
    sequ::Int                  # sequence number
    header::Vector{UInt8}      # raw AipsIO header block (decoded in later phases)
end

# --- the table ---------------------------------------------------

"""
Common supertype of the casacore table kinds this package can read:
[`Table`](@ref) (a plain table), [`RefTable`](@ref) (a row-number
reference into a parent table), and [`ConcatTable`](@ref) (a virtual
row-wise concatenation of same-schema tables).  All three answer
`nrow` / `columnnames` / `columndesc` / `keywords` / `subtables` /
`column` and interoperate with `Tables.jl`.
"""
abstract type AbstractTable end

"""
    Table <: AbstractTable

A plain on-disk casacore table, as returned by [`readtable`](@ref) for a
`table.dat` of subtype `"PlainTable"` (the MS MAIN table and every
standard subtable). Column data is read lazily and on demand through the
bound storage managers; cell reads go through [`column`](@ref) /
[`getcell`](@ref) / `t[:NAME]`. See also [`RefTable`](@ref) and
[`ConcatTable`](@ref) for the reference / concatenation kinds, and
[`edit`](@ref) to open one for update.
"""
struct Table <: AbstractTable
    path::String
    type::String               # table.info Type
    subtype::String            # table.info SubType
    readme::String
    version::Int
    rows::Int                  # number of rows
    endian::Symbol             # :big or :little (storage-manager files)
    desc::TableDesc
    managers::Vector{DataManagerInfo}
    syncmod::Int64             # table.lock modify counter at open (-1 = no sync blob)
    lockpath::String           # joinpath(path, "table.lock")
    container::Union{Nothing,Container}   # MultiFile/MultiHDF5, if present (Phase 20)
end

# Fetch a data manager's private file's whole bytes, transparently
# resolving through a MultiFile/MultiHDF5 container when the table uses
# one (Phase 20).  `name` is the file's basename, e.g. "table.f0",
# "table.f0i", "table.f0_TSM1" -- exactly what every data manager opener
# already computes via `joinpath(t.path, ...)`.
_dmfile_read(t::Table, name::AbstractString) =
    t.container === nothing ? read(joinpath(t.path, name)) :
    container_read(t.container, name)

# Same, but returns a real zero-copy `mmap` view when possible (no
# container, or a contiguous container-backed virtual file); otherwise a
# materializing read.  Only `TiledStMan`'s tile-data files use this today.
_dmfile_mmap(t::Table, name::AbstractString) =
    t.container === nothing ? Mmap.mmap(joinpath(t.path, name), Vector{UInt8}) :
    container_mmap(t.container, name)

"""
A casacore RefTable: a persistent row-number reference into a `parent`
table (what a TaQL `SELECT ... GIVING '<path>'` row selection or
`table.query` writes).  Stores no cell data of its own — every read
delegates to `parent` through `rows` (1-based parent row per ref row).
"""
struct RefTable <: AbstractTable
    path::String
    parent::AbstractTable
    rows::Vector{Int}                 # 1-based parent row per ref row
    namemap::Dict{String,String}      # ref column name => parent column name
    order::Vector{String}             # ref column order
    type::String
    subtype::String
    readme::String
end

"""
A casacore ConcatTable: a virtual row-wise concatenation of `parts`
(same-schema tables — e.g. the MAIN table of a MultiMS).  `offsets` is
the cumulative row map (`length(parts)+1` entries, `offsets[end]` = total
rows).  Stores no cell data of its own.
"""
struct ConcatTable <: AbstractTable
    path::String
    parts::Vector{AbstractTable}
    offsets::Vector{Int}              # cumulative; offsets[end] == nrow
    subtabnames::Vector{String}      # keyword subtables to concatenate
    type::String
    subtype::String
    readme::String
end

"""
    nrow(t) -> Int

Number of rows in table `t` (a [`Table`](@ref), [`RefTable`](@ref),
[`ConcatTable`](@ref) or [`GroupedTable`](@ref)).
"""
nrow(t::Table) = t.rows

"""
    columnnames(t) -> Vector{String}

The column names of table `t`, in schema order.
"""
columnnames(t::Table) = [c.name for c in t.desc.columns]

"""
    columndesc(t, name) -> ColumnDesc

The [`ColumnDesc`](@ref) (type, cell shape, keywords, storage-manager
binding) for column `name` of table `t`. Throws `KeyError` if there is no
such column.
"""
function columndesc(t::Table, name::AbstractString)
    i = findfirst(c -> c.name == name, t.desc.columns)
    i === nothing && throw(KeyError(name))
    t.desc.columns[i]
end

"""
    keywords(t) -> Record

The table-level keyword set of `t` as a [`Record`](@ref) (`MS_VERSION`,
`MEASURE_REFERENCE`, subtable references, …). Per-column keywords live on
[`columndesc`](@ref)`(t, name).keywords`.
"""
keywords(t::Table) = t.desc.public

function Base.show(io::IO, t::Table)
    print(io, "Table(\"", basename(t.path), "\", ", t.rows, " rows, ",
          length(t.desc.columns), " columns")
    isempty(t.type) || print(io, ", type=\"", t.type, "\"")
    print(io, ")")
end

# --- RefTable / ConcatTable accessors ---------------------------

nrow(t::RefTable) = length(t.rows)
nrow(t::ConcatTable) = t.offsets[end]

columnnames(t::RefTable) = copy(t.order)
columnnames(t::ConcatTable) = columnnames(t.parts[1])

# Rebuild a ColumnDesc under a new name (the parent's DM binding is
# irrelevant for a view and is carried through unused).
function _rename_columndesc(c::ColumnDesc, newname::AbstractString)
    ColumnDesc(String(newname), c.comment, c.manager, c.group, c.type,
               c.classname, c.shape, c.option, c.maxlength, c.keywords,
               c.default, c.sequ)
end

function columndesc(t::RefTable, name::AbstractString)
    haskey(t.namemap, name) || throw(KeyError(name))
    _rename_columndesc(columndesc(t.parent, t.namemap[name]), name)
end

function columndesc(t::ConcatTable, name::AbstractString)
    c0 = columndesc(t.parts[1], name)
    # casacore ConcatTable::initialize drops a fixed cell shape (and the
    # FIXEDSHAPE option) when it differs across parts.
    if c0.shape isa Dims && !isempty(c0.shape) &&
       any(columndesc(p, name).shape != c0.shape for p in @view t.parts[2:end])
        return ColumnDesc(c0.name, c0.comment, c0.manager, c0.group, c0.type,
                          c0.classname, VariableShape(),
                          c0.option & ~COLOPT_FIXEDSHAPE, c0.maxlength,
                          c0.keywords, c0.default, c0.sequ)
    end
    return c0
end

keywords(t::RefTable) = keywords(t.parent)
keywords(t::ConcatTable) = keywords(t.parts[1])

subtables(t::RefTable) = subtables(t.parent)
subtables(t::ConcatTable) = subtables(t.parts[1])

function Base.show(io::IO, t::RefTable)
    print(io, "RefTable(\"", basename(t.path), "\", ", nrow(t), " of ",
          nrow(t.parent), " rows, ", length(t.order), " columns)")
end
function Base.show(io::IO, t::ConcatTable)
    print(io, "ConcatTable(\"", basename(t.path), "\", ", nrow(t), " rows, ",
          length(t.parts), " parts)")
end

"""
    subtables(t::Table) -> Vector{Pair{String,String}}

Keyword name => subtable directory path, for every `TpTable` keyword.
"""
function subtables(t::Table)
    out = Pair{String,String}[]
    for (n, v) in t.desc.public
        v isa SubTable && push!(out, n => _subtable_path(t.path, v.name))
    end
    return out
end

# Stored form is usually "Table: /abs/path" or a path relative to the table.
function _subtable_path(parent::String, stored::String)
    s = strip(stored)
    startswith(s, "Table:") && (s = strip(s[7:end]))
    normpath(isabspath(s) ? _expandpath(String(s)) : joinpath(parent, s))
end

# casacore expands `~` and `$VAR` in a stored table name (Path::expandedName).
function _expandpath(s::AbstractString)
    s = expanduser(String(s))
    occursin('$', s) || return s
    s = replace(s, r"\$\{(\w+)\}" => m -> get(ENV, m[3:end-1], m))
    s = replace(s, r"\$(\w+)"     => m -> get(ENV, m[2:end], m))
    return s
end

# Resolve a table name stored by casacore's Path::stripDirectory (used for a
# RefTable's parent and a ConcatTable's parts) against `selfdir`, the
# ref/concat table's own absolute directory.  casacore strips every leading
# "./" pair, then: 2 chars removed => sibling; >=4 => inside selfdir;
# 0 => the name is absolute / $VAR / ~ and used as-is.
function _resolve_tabpath(stored::AbstractString, selfdir::AbstractString)
    s = String(stored)
    n = 0
    while startswith(s[n+1:end], "./")
        n += 2
    end
    rest = s[n+1:end]
    n == 0 && return normpath(_expandpath(s))
    n == 2 && return normpath(joinpath(dirname(String(selfdir)), rest))
    return normpath(joinpath(String(selfdir), rest))
end

# Write-side converse of `_resolve_tabpath` (casacore Path::stripDirectory),
# limited to the same two relative forms `_resolve_tabpath` understands so
# round-tripping stays symmetric: `name` inside `selfdir` -> "././rest";
# `name` a sibling of `selfdir` (same parent directory) -> "./rest"; else
# the absolute path.
function _strip_directory(name::AbstractString, selfdir::AbstractString)
    dir = rstrip(abspath(String(selfdir)), '/') * "/"
    aname = abspath(String(name))
    startswith(aname, dir) && return "././" * aname[length(dir)+1:end]
    pdir = rstrip(dirname(dir[1:end-1]), '/') * "/"
    startswith(aname, pdir) && return "./" * aname[length(pdir)+1:end]
    return aname
end

# --- readers ----------------------------------------------------

function read_tableinfo(dir::String)
    p = joinpath(dir, "table.info")
    isfile(p) || return ("", "", "")
    lines = readlines(p)
    gettype(prefix, i) = length(lines) >= i && startswith(lines[i], prefix) ?
        strip(lines[i][length(prefix)+1:end]) : ""
    tp = gettype("Type = ", 1)
    st = gettype("SubType = ", 2)
    readme = length(lines) > 3 ? join(lines[4:end], "\n") : ""
    return (String(tp), String(st), String(readme))
end

"""
    readtable(path) -> Table | RefTable | ConcatTable

Read the metadata (description, keywords, data-manager bindings, row count)
of the casacore table directory at `path`.  Column *data* is not read.

Returns a [`RefTable`](@ref) or [`ConcatTable`](@ref) when `path` is a
reference / concatenation table (its parent(s) are opened recursively);
otherwise a plain [`Table`](@ref).

A shared (read) lock on `<path>/table.lock` is held only while `table.dat`
is slurped; the row count then comes from the `table.lock` sync blob when
present (as casacore does), else from `table.dat`.  The lazy
storage-manager reads that a later `column()` triggers are *not* locked --
they rely on the writers' atomic renames.
"""
function readtable(path::AbstractString)
    dir = String(rstrip(path, '/'))
    isdir(dir) || throw(ArgumentError("not a table directory: $dir"))
    lockpath = joinpath(dir, "table.lock")
    tp, st, readme = read_tableinfo(dir)
    container = open_container(dir)

    local datbytes, sync
    withlock(dir, :read; create=false) do lk
        datbytes = read(joinpath(dir, "table.dat"))
        sync = read_syncinfo(lk)
    end

    a = AipsIO(datbytes)
    version = Int(getstart(a, "Table"))
    version <= 3 || error("Table version $version not supported")
    nr_dat = version > 2 ? Int(read_scalar(a, UInt64)) : Int(read_u32(a))
    nr = (sync.present && sync.nrow !== nothing) ? sync.nrow : nr_dat
    (sync.present && sync.nrow !== nothing && sync.nrow != nr_dat) &&
        @debug "readtable: table.lock nrow=$(sync.nrow) overrides table.dat nrow=$nr_dat" dir
    syncmod = sync.present ? sync.modifycounter : Int64(-1)
    format = read_u32(a)
    endian = format == 0 ? :big : :little
    subtype = read_string(a)                         # "PlainTable" | "RefTable" | "ConcatTable"

    subtype == "RefTable"    && return _read_reftable(a, dir, tp, st, readme)
    subtype == "ConcatTable" && return _read_concattable(a, dir, tp, st, readme)

    desc = read_tabledesc(a)
    version == 1 && read_record(a)                  # legacy separate keyword set

    dms, colseq, colshape = read_columnset(a, desc.columns)

    # merge sequence numbers / column-level fixed shapes into the descriptions
    cols = ColumnDesc[]
    for (i, c) in enumerate(desc.columns)
        shape = haskey(colshape, i) ? colshape[i] : c.shape   # column shape wins
        push!(cols, ColumnDesc(c.name, c.comment, c.manager, c.group,
            c.type, c.classname, shape, c.option, c.maxlength,
            c.keywords, c.default, get(colseq, i, nothing)))
    end
    desc2 = TableDesc(desc.name, desc.version, desc.comment, desc.public,
                      desc.private, cols)

    return Table(dir, tp, st, readme, version, nr, endian, desc2, dms, syncmod, lockpath, container)
end

# open a parent / part table, adding context on failure
function _open_referenced(stored::AbstractString, selfdir::AbstractString, what::AbstractString)
    p = _resolve_tabpath(stored, selfdir)
    isdir(p) || throw(ArgumentError(
        "$what table not found: \"$p\" (stored as \"$stored\", referenced by $selfdir)"))
    return readtable(p)
end

# RefTable body: str parent; SimpleOrderedMap nameMap; (rver>1) Array<str>
# names; rootNrow; u8 rowOrder; nrrow; nrrow raw parent row numbers.
function _read_reftable(a::AipsIO, dir::String, tp, st, readme)
    rver = Int(getstart(a, "RefTable"))
    rver <= 3 || error("RefTable version $rver not supported")
    parent = _open_referenced(read_string(a), dir, "RefTable parent")
    namemap = Dict{String,String}(read_map(a, String, String))
    order = rver > 1 ? read_array(a, String)[2] : sort!(collect(keys(namemap)))
    T = rver > 2 ? UInt64 : UInt32
    read_scalar(a, T)                                # rootNrow (unused; parent.nrow wins)
    read(a.io, UInt8)                                # rowOrder flag
    nrrow = Int(read_scalar(a, T))
    rows = _read_rownrs(a, T, nrrow)
    getend(a)
    # drop columns the parent no longer has (casacore RefTable::makeDesc)
    pcols = Set(columnnames(parent))
    filter!(n -> haskey(namemap, n) && namemap[n] in pcols, order)
    return RefTable(dir, parent, rows, namemap, order, tp, st, readme)
end

# ConcatTable body: u32 nrtab; nrtab str subtable names; Block<str> keyword
# subtable names.  Row offsets are recomputed from each part's nrow.
function _read_concattable(a::AipsIO, dir::String, tp, st, readme)
    cver = Int(getstart(a, "ConcatTable"))
    cver == 0 || error("ConcatTable version $cver not supported")
    nrtab = Int(read_u32(a))
    names = [read_string(a) for _ in 1:nrtab]
    subs = read_block(a, String)
    getend(a)
    isempty(names) && error("ConcatTable at $dir references no tables")
    parts = AbstractTable[_open_referenced(n, dir, "ConcatTable part") for n in names]
    offsets = zeros(Int, length(parts) + 1)
    for (i, p) in enumerate(parts)
        offsets[i+1] = offsets[i] + nrow(p)
    end
    return ConcatTable(dir, parts, offsets, subs, tp, st, readme)
end

# --- writers -------------------------------------------------------

# `select` ("output_name => parent_name" pairs, in output order) ->
# `(namemap, order)` for building a RefTable -- shared by `write_reftable`
# and `query` (query.jl) so both use identical validation/error text.
function _select_spec(parent::AbstractTable, select::AbstractVector{<:Pair})
    order = String[String(first(p)) for p in select]
    allunique(order) || throw(ArgumentError("duplicate output column name"))
    namemap = Dict{String,String}(String(first(p)) => String(last(p)) for p in select)
    pcols = Set(columnnames(parent))
    for s in values(namemap)
        s in pcols || throw(ArgumentError("parent has no column \"$s\""))
    end
    return namemap, order
end

"""
    write_reftable(dir, parent, rows; select) -> dir

Persist a row-number reference to `parent` (a `Table`, `RefTable`, or
`ConcatTable`) at `dir`, in casacore's RefTable format — openable by
`casa` / python-casacore.  `rows` are 1-based row indices into `parent`
(any order, repeats allowed).  `select` is `output_name => parent_name`
pairs in output order (default: every column of `parent`, unrenamed).
"""
function write_reftable(dir::AbstractString, parent::AbstractTable,
                        rows::AbstractVector{<:Integer};
                        select::AbstractVector{<:Pair}=[n => n for n in columnnames(parent)])
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")

    namemap, order = _select_spec(parent, select)
    any(x -> x < 1, rows) && throw(ArgumentError("write_reftable: row indices are 1-based"))

    mkpath(dir)
    rows0 = Int.(collect(rows)) .- 1
    bytes_ = reftable_dat_bytes(_strip_directory(parent.path, dir), rows0, namemap, order,
                                nrow(parent), length(rows0))
    _atomic_write(joinpath(dir, "table.dat"), bytes_)
    write_tableinfo(dir; type=parent.type, subtype=parent.subtype, readme=parent.readme)
    return dir
end

write_reftable(dir::AbstractString, rt::RefTable) =
    write_reftable(dir, rt.parent, rt.rows; select=[nm => rt.namemap[nm] for nm in rt.order])

"""
    write_concattable(dir, parts; subtabnames=String[]) -> dir

Persist a virtual row-wise concatenation of `parts` (same-schema tables)
at `dir`.  `subtabnames` lists keyword subtables to also concatenate
(rarely used; default none).
"""
function write_concattable(dir::AbstractString, parts::AbstractVector{<:AbstractTable};
                           subtabnames::AbstractVector{<:AbstractString}=String[])
    isempty(parts) && throw(ArgumentError("write_concattable: at least one table required"))
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")
    mkpath(dir)

    names = [_strip_directory(p.path, dir) for p in parts]
    total = sum(nrow, parts)
    bytes_ = concattable_dat_bytes(names, String.(subtabnames), total)
    _atomic_write(joinpath(dir, "table.dat"), bytes_)

    p1 = parts[1]
    lines = ["Virtual concatenation of the following tables:"; ("  " * p.path for p in parts)...]
    readme = isempty(p1.readme) ? join(lines, "\n") : p1.readme * "\n" * join(lines, "\n")
    write_tableinfo(dir; type=p1.type, subtype=p1.subtype, readme)
    return dir
end

function read_columnset(a::AipsIO, columns::Vector{ColumnDesc})
    ncol = length(columns)
    v = Int(read_i32(a))
    local setversion
    if v < 0
        setversion = -v
        if setversion <= 2
            read_u32(a)
        else
            read_scalar(a, UInt64)
        end
    else
        setversion = 1
    end
    if setversion >= 3
        read_i32(a); read_i32(a)   # StorageOption
    end
    read_u32(a)                               # nrman (seq counter)
    ndm = Int(read_u32(a))
    dmnames = String[]
    dmseq = Int[]
    for _ in 1:ndm
        push!(dmnames, read_string(a))
        push!(dmseq, Int(read_u32(a)))
    end

    colseq = Dict{Int,Int}()
    colshape = Dict{Int,Dims}()
    for (i, col) in enumerate(columns)
        read_u32(a)                           # PlainColumn version
        # version==1 would embed a keyword record here; unsupported (pre-2000)
        read_string(a)                                     # originalName
        read_u32(a)                           # derived version
        colseq[i] = Int(read_u32(a))          # data-manager seqnr
        if isarray(col)
            shapedef = read(a.io, UInt8) != 0x00
            shapedef && (colshape[i] = read_iposition(a))
        end
    end

    dms = DataManagerInfo[]
    for i in 1:ndm
        n = Int(read_u32(a))
        push!(dms, DataManagerInfo(dmnames[i], dmseq[i], read(a.io, n)))
    end
    return dms, colseq, colshape
end
