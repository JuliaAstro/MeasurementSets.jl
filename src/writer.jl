# Table-metadata writer: `table.dat` + `table.info`.
#
# Mirrors casacore/tables/Tables/PlainTable.cc `putFile`, TableDesc.cc,
# ColumnDesc.cc, BaseColDesc.cc, ColumnSet.cc, TableRecordRep.cc.
# The write side always emits keyword sets as "TableRecord" (v1).

# --- AipsIO object versions the write side emits (casacore's read side
#     expects exactly these in the *.cc files named above) --------------
const V_TABLE       = 2    # "Table"
const V_TABLEDESC   = 2    # "TableDesc"
const V_RECORDDESC  = 2    # "RecordDesc"
const V_TABLERECORD = 1    # "TableRecord" / "Record"
const V_AIPS_ARRAY  = 3    # "Array<void>"
const V_COLUMNDESC  = 1    # ColumnDesc wrapper / BaseColumnDesc / {Array,Scalar}ColumnDesc
const V_PLAINCOLUMN = 2    # PlainColumn::putFile
const V_COL_DERIVED = 1    # {Scalar,Array}ColumnData::putFileDerived

const COLUMNSET_SEPFILE    = -2    # ColumnSet::putFile version; negative => per-DM files
const SMFILE_LITTLE_ENDIAN = 1     # table.dat "endian format" flag for the SM files
const SHAPECOL_FIXED  = 0x01       # PlainColumn shapeColDef byte: fixed cell shape
const SHAPECOL_VARIES = 0x00       # ... variable / indirect

# fixed-width (8-char) casacore type id used in ColumnDesc class names
const _TYPEID = Dict{CasaType,String}(
    TpBool => "Bool    ", TpUChar => "uChar   ", TpShort => "Short   ",
    TpInt => "Int     ", TpUInt => "uInt    ", TpInt64 => "Int64   ",
    TpFloat => "float   ", TpDouble => "double  ",
    TpComplex => "Complex ", TpDComplex => "DComplex", TpString => "String  ",
)
_classname(t::CasaType, isarr::Bool) =
    (isarr ? "ArrayColumnDesc<" : "ScalarColumnDesc<") * _TYPEID[t]

# --- records ----------------------------------------------------

const _ARRAY_CASATYPE = Dict(v => k for (k, v) in ARRAYTYPE)   # scalar -> array CasaType

function _write_recorddesc(w::AipsWriter, rec::Record)
    putstart(w, "RecordDesc", V_RECORDDESC)
    wr_i32(w, length(rec))
    for i in 1:length(rec)
        wr_string(w, rec.names[i])
        t = rec.types[i]
        wr_i32(w, Int(t))
        if t == TpRecord
            putstart(w, "RecordDesc", V_RECORDDESC); wr_i32(w, 0); putend(w)   # empty sub-desc
        elseif t == TpTable
            wr_string(w, "")                                        # tableDescName
        elseif isarraytype(t)
            wr_iposition(w, ())                                     # shape (variable)
        end
        wr_string(w, rec.comments[i])
    end
    putend(w)
end

function _write_aipsarray(w::AipsWriter, a::AbstractArray)
    putstart(w, "Array<void>", V_AIPS_ARRAY)
    wr_i32(w, ndims(a))
    for s in size(a); wr_u32(w, s); end
    wr_u32(w, length(a))
    for x in a; wr_element(w, x); end
    putend(w)
end

function _write_datafield(w::AipsWriter, t::CasaType, v)
    if isscalartype(t)
        t == TpString ? wr_string(w, v) : wr_scalar(w, v)
    elseif isarraytype(t)
        _write_aipsarray(w, v)
    else
        error("_write_datafield: unsupported type $t")
    end
end

"""
    write_record(w, rec)

Emit a casacore "TableRecord" (v1).  Nested records are written as empty
sub-descriptions followed by a full nested record; `SubTable` values are
written as their stored path string.
"""
function write_record(w::AipsWriter, rec::Record; typename="TableRecord")
    putstart(w, typename, V_TABLERECORD)
    _write_recorddesc(w, rec)
    wr_i32(w, rec.rectype)
    for i in 1:length(rec)
        t, v = rec.types[i], rec.values[i]
        if t == TpRecord
            write_record(w, v)
        elseif t == TpTable
            wr_string(w, v isa SubTable ? v.name : String(v))
        else
            _write_datafield(w, t, v)
        end
    end
    putend(w)
end

# --- column & table descriptions -------------------------------

function _write_columndesc(w::AipsWriter, c::ColumnDesc, varndim::Dict{String,Int}=Dict{String,Int}())
    arr = isarray(c)
    wr_u32(w, V_COLUMNDESC)               # ColumnDesc wrapper
    wr_string(w, c.classname)
    wr_u32(w, V_COLUMNDESC)               # BaseColumnDesc
    wr_string(w, c.name)
    wr_string(w, c.comment)
    wr_string(w, c.manager)
    wr_string(w, c.group)
    wr_i32(w, Int(c.type))
    wr_i32(w, c.option)
    wr_i32(w, get(varndim, c.name, _nrdim(c)))
    arr && wr_iposition(w, c.shape isa Dims ? c.shape : ())
    wr_u32(w, c.maxlength)
    write_record(w, c.keywords)
    # putDesc
    if arr
        wr_u32(w, V_COLUMNDESC)           # ArrayColumnDescBase
        write(w.io, 0x00)                 # obsolete "has default" switch
    elseif startswith(c.classname, "ScalarRecord")
        wr_u32(w, V_COLUMNDESC)
    else
        wr_u32(w, V_COLUMNDESC)           # ScalarColumnDesc
        _write_valtype(w, c.type, c.default)
    end
end

_nrdim(c::ColumnDesc) = c.shape isa Dims ? length(c.shape) :
                        c.shape isa VariableDims ? -1 :
                        2                                   # VariableShape: any >0

function _write_valtype(w::AipsWriter, t::CasaType, default)
    if t == TpString
        wr_string(w, default === nothing ? "" : String(default))
    else
        J = juliatype(t)
        wr_scalar(w, default === nothing ? zero(J) : J(default))
    end
end

function write_tabledesc(w::AipsWriter, td::TableDesc,
                         varndim::Dict{String,Int}=Dict{String,Int}())
    putstart(w, "TableDesc", V_TABLEDESC)
    wr_string(w, td.name)
    wr_string(w, td.version)
    wr_string(w, td.comment)
    write_record(w, td.public)
    write_record(w, td.private)
    wr_u32(w, length(td.columns))
    for c in td.columns
        _write_columndesc(w, c, varndim)
    end
    putend(w)
end

# --- column set ----------------------------------------------

"Info about one data-manager instance for the column-set section."
struct DMWrite
    type::String                 # data manager type name
    sequ::Int
    block::Vector{UInt8}         # AipsIO block for the table.dat column-set section
end

function _write_plaincolumn(w::AipsWriter, c::ColumnDesc)
    wr_u32(w, V_PLAINCOLUMN)             # PlainColumn::putFile
    wr_string(w, c.name)                  # originalName
    wr_u32(w, V_COL_DERIVED)             # ...ColumnData::putFileDerived
    wr_u32(w, c.sequ)                     # data-manager sequence number
    if isarray(c)
        # a virtual-engine column is not a stored/direct array, even if its
        # cell shape is fixed -> always SHAPECOL_VARIES
        if c.shape isa Dims && !isempty(c.shape) && !_is_engine_dm(c.manager)
            write(w.io, SHAPECOL_FIXED)   # cell shape is fixed
            wr_iposition(w, c.shape)      # -> casacore uses a direct-array column
        else
            write(w.io, SHAPECOL_VARIES)
        end
    end
end

function write_columnset(w::AipsWriter, cols::Vector{<:ColumnDesc},
                         dms::Vector{DMWrite}, nrow::Integer)
    wr_i32(w, COLUMNSET_SEPFILE)
    wr_u32(w, nrow)
    wr_u32(w, length(dms))                # seqCount
    wr_u32(w, length(dms))                # number of DMs with columns
    for dm in dms
        wr_string(w, dm.type)
        wr_u32(w, dm.sequ)
    end
    for c in cols
        _write_plaincolumn(w, c)
    end
    for dm in dms
        wr_u32(w, length(dm.block))
        write(w.io, dm.block)
    end
end

# --- table.dat / table.info ---------------------------------

function table_dat_bytes(td::TableDesc, nrow::Integer, dms::Vector{DMWrite},
                         varndim::Dict{String,Int}=Dict{String,Int}())
    w = AipsWriter(; endian=:big)         # table.dat is always canonical
    putstart(w, "Table", V_TABLE)
    wr_u32(w, nrow)
    wr_u32(w, SMFILE_LITTLE_ENDIAN)       # SM files are little-endian
    wr_string(w, "PlainTable")
    write_tabledesc(w, td, varndim)
    write_columnset(w, td.columns, dms, nrow)
    putend(w)
    return bytes(w)
end

# RefTable's own `table.dat`: root "Table" object (always big-endian --
# there are no storage-manager files of its own to have an endianness),
# `tp="RefTable"`, then a nested "RefTable" object.  Mirrors
# `RefTable::writeRefTable` (RefTable.cc:267-326).  `rows0` are 0-based
# parent row numbers.
function reftable_dat_bytes(parentstored::String, rows0::Vector{Int},
                            namemap::Dict{String,String}, order::Vector{String},
                            parentnrow::Integer, thisnrow::Integer)
    rver = (parentnrow < typemax(UInt32) && thisnrow < typemax(UInt32) &&
            all(x -> x < typemax(UInt32), rows0)) ? 2 : 3
    outerver = thisnrow > typemax(Int32) ? 3 : 2
    w = AipsWriter(; endian=:big)
    putstart(w, "Table", outerver)
    outerver == 3 ? wr_u64(w, thisnrow) : wr_u32(w, thisnrow)
    wr_u32(w, 0)                                  # endian flag (unused -- no SM files)
    wr_string(w, "RefTable")
    putstart(w, "RefTable", rver)
    wr_string(w, parentstored)
    wr_map(w, namemap)
    wr_array(w, order)
    rver == 2 ? wr_u32(w, parentnrow) : wr_u64(w, parentnrow)
    wr_scalar(w, length(rows0) < 2 || all(rows0[i] > rows0[i-1] for i in 2:length(rows0)))
    rver == 2 ? wr_u32(w, thisnrow) : wr_u64(w, thisnrow)
    for x in rows0
        rver == 2 ? wr_u32(w, x) : wr_u64(w, x)
    end
    putend(w)                                     # close "RefTable"
    putend(w)                                     # close "Table"
    return bytes(w)
end

# ConcatTable's own `table.dat`, mirroring `ConcatTable::writeConcatTable`
# (ConcatTable.cc:236-273).
function concattable_dat_bytes(partnames::Vector{String}, subtabnames::Vector{String},
                               thisnrow::Integer)
    outerver = thisnrow > typemax(Int32) ? 3 : 2
    w = AipsWriter(; endian=:big)
    putstart(w, "Table", outerver)
    outerver == 3 ? wr_u64(w, thisnrow) : wr_u32(w, thisnrow)
    wr_u32(w, 0)
    wr_string(w, "ConcatTable")
    putstart(w, "ConcatTable", 0)
    wr_u32(w, length(partnames))
    for n in partnames
        wr_string(w, n)
    end
    wr_block(w, subtabnames)
    putend(w)
    putend(w)
    return bytes(w)
end

function write_tableinfo(dir::AbstractString; type="", subtype="", readme="")
    open(joinpath(dir, "table.info"), "w") do io
        println(io, "Type = ", type)
        println(io, "SubType = ", subtype)
        println(io)
        isempty(readme) || print(io, readme)
    end
end

# atomic file replace: write to a hidden sibling, then rename over `path`.
# The dot prefix keeps the tmp out of `readdir` scans that count `table.f*`.
function _atomic_write(path::AbstractString, data)
    tmp = joinpath(dirname(path), "." * basename(path) * ".tmp")
    write(tmp, data)
    mv(tmp, path; force=true)
    return path
end

"""
    write_table_files(dir, td, nrow, dms; type, subtype, readme)

Write `table.dat` (atomically) and `table.info` for a table, holding an
exclusive lock on `table.lock` and updating its sync blob.  The data
managers in `dms` have already written their own `table.f<seq>*` files.
"""
function write_table_files(dir::AbstractString, td::TableDesc, nrow::Integer,
                           dms::Vector{DMWrite}; type="", subtype="", readme="",
                           varndim::Dict{String,Int}=Dict{String,Int}())
    mkpath(dir)
    withlock(dir, :write; create=true) do lk
        old = read_syncinfo(lk)
        _atomic_write(joinpath(dir, "table.dat"), table_dat_bytes(td, nrow, dms, varndim))
        write_tableinfo(dir; type, subtype, readme)
        write_syncinfo(lk, nrow; modifycounter = (old.present ? old.modifycounter : 0) + 1)
    end
end
