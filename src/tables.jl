# CTDS table metadata: `table.dat`, `table.info`, column descriptions and
# data-manager bindings.  (casacore/tables/Tables/PlainTable.cc,
# TableDesc.cc, ColumnDesc.cc, BaseColDesc.cc, ColumnSet.cc, PlainColumn.cc)

# --- ValType scalar default -----------------------------------------

function read_valtype(a::AipsIO, t::CasaType)
    isscalartype(t) || return nothing
    t == TpString && return read_string(a)
    return read_scalar(a, juliatype(t))
end

# --- column description --------------------------------------------

struct ColumnDesc
    name::String
    comment::String
    manager::String            # data-manager *type* the column is bound to
    group::String              # data-manager *group* (instance) name
    type::CasaType             # scalar or array CasaType
    isarray::Bool
    ndim::Int                  # 0 => unknown/scalar; -1 kept as-is
    shape::Dims                # fixed cell shape, () if not fixed
    option::Int32
    maxlength::UInt32
    keywords::CasaRecord
    default::Any               # scalar columns only
    # filled in from ColumnSet: data-manager instance sequence number
    # (`nothing` until the column is bound to a data manager)
    sequ::Union{Int,Nothing}
    fixedshape::Dims           # per-column stored shape (array cols)
end

Base.show(io::IO, c::ColumnDesc) = print(io, "ColumnDesc(", c.name, "::",
    c.type, c.isarray && !isempty(c.shape) ? string(c.shape) : "",
    " @", c.manager, "/", c.group, ")")

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
    shape       = isarray ? read_iposition(a) : ()
    maxlen      = read_u32(a)
    keywords    = read_record(a)

    default = nothing
    read_u32(a)                  # getDesc version
    if isarray
        read(a.io, UInt8)                     # obsolete "has default" switch
    elseif !isrecord
        default = read_valtype(a, dtype)
    end

    ColumnDesc(name, comment, manager, group, dtype, isarray, nrdim,
               shape, option, maxlen, keywords, default, nothing, ())
end

# --- table description --------------------------------------------

struct TableDesc
    name::String
    version::String
    comment::String
    public::CasaRecord         # public keyword set
    private::CasaRecord        # private (internal) keyword set
    columns::Vector{ColumnDesc}
end

function read_tabledesc(a::AipsIO)
    tvers = getstart(a, "TableDesc")
    name = read_string(a)
    version = read_string(a)
    comment = read_string(a)
    public = read_record(a)
    private = tvers != 1 ? read_record(a) : CasaRecord()

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

struct CTDSTable
    path::String
    type::String               # table.info Type
    subtype::String            # table.info SubType
    readme::String
    version::Int
    rows::Int                  # number of rows
    endian::Symbol             # :big or :little (storage-manager files)
    desc::TableDesc
    managers::Vector{DataManagerInfo}
end

nrow(t::CTDSTable) = t.rows
columnnames(t::CTDSTable) = [c.name for c in t.desc.columns]
Base.getindex(t::CTDSTable, name::AbstractString) = columndesc(t, name)
function columndesc(t::CTDSTable, name::AbstractString)
    i = findfirst(c -> c.name == name, t.desc.columns)
    i === nothing && throw(KeyError(name))
    t.desc.columns[i]
end
keywords(t::CTDSTable) = t.desc.public

function Base.show(io::IO, t::CTDSTable)
    print(io, "CTDSTable(\"", basename(t.path), "\", ", t.rows, " rows, ",
          length(t.desc.columns), " columns")
    isempty(t.type) || print(io, ", type=\"", t.type, "\"")
    print(io, ")")
end

"""
    subtables(t::CTDSTable) -> Vector{Pair{String,String}}

Keyword name => subtable directory path, for every `TpTable` keyword.
"""
function subtables(t::CTDSTable)
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
    normpath(isabspath(s) ? String(s) : joinpath(parent, s))
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
    readtable(path) -> CTDSTable

Read the metadata (description, keywords, data-manager bindings, row count)
of the casacore table directory at `path`.  Column *data* is not read.
"""
function readtable(path::AbstractString)
    dir = String(rstrip(path, '/'))
    isdir(dir) || throw(ArgumentError("not a table directory: $dir"))
    tp, st, readme = read_tableinfo(dir)

    a = AipsIO(read(joinpath(dir, "table.dat")))
    version = Int(getstart(a, "Table"))
    version <= 3 || error("Table version $version not supported")
    nr = version > 2 ? Int(read_scalar(a, UInt64)) : Int(read_u32(a))
    format = read_u32(a)
    endian = format == 0 ? :big : :little
    read_string(a)                                  # "PlainTable"

    desc = read_tabledesc(a)
    version == 1 && read_record(a)                  # legacy separate keyword set

    dms, colseq, colshape = read_columnset(a, desc.columns)

    # merge sequence numbers / stored shapes into the column descriptions
    cols = ColumnDesc[]
    for (i, c) in enumerate(desc.columns)
        push!(cols, ColumnDesc(c.name, c.comment, c.manager, c.group,
            c.type, c.isarray, c.ndim, c.shape, c.option, c.maxlength,
            c.keywords, c.default, get(colseq, i, nothing), get(colshape, i, ())))
    end
    desc2 = TableDesc(desc.name, desc.version, desc.comment, desc.public,
                      desc.private, cols)

    return CTDSTable(dir, tp, st, readme, version, nr, endian, desc2, dms)
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
        if col.isarray
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
