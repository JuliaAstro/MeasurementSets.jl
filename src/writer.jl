# Table-metadata writer: `table.dat` + `table.info`.
#
# Mirrors casacore/tables/Tables/PlainTable.cc `putFile`, TableDesc.cc,
# ColumnDesc.cc, BaseColDesc.cc, ColumnSet.cc, TableRecordRep.cc.
# The write side always emits keyword sets as "TableRecord" (v1).

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

function _write_recorddesc(w::AipsWriter, rec::CasaRecord)
    putstart(w, "RecordDesc", 2)
    wr_i32(w, length(rec))
    for i in 1:length(rec)
        wr_string(w, rec.names[i])
        t = rec.types[i]
        wr_i32(w, Int(t))
        if t == TpRecord
            putstart(w, "RecordDesc", 2); wr_i32(w, 0); putend(w)   # empty sub-desc
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
    putstart(w, "Array<void>", 3)
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
function write_record(w::AipsWriter, rec::CasaRecord; typename="TableRecord")
    putstart(w, typename, 1)
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

function _write_columndesc(w::AipsWriter, c::ColumnDesc)
    arr = isarray(c)
    wr_u32(w, 1)                          # ColumnDesc wrapper version
    wr_string(w, c.classname)
    wr_u32(w, 1)                          # BaseColumnDesc version
    wr_string(w, c.name)
    wr_string(w, c.comment)
    wr_string(w, c.manager)
    wr_string(w, c.group)
    wr_i32(w, Int(c.type))
    wr_i32(w, c.option)
    wr_i32(w, _nrdim(c))
    arr && wr_iposition(w, c.shape isa Dims ? c.shape : ())
    wr_u32(w, c.maxlength)
    write_record(w, c.keywords)
    # putDesc
    if arr
        wr_u32(w, 1)                      # ArrayColumnDescBase version
        write(w.io, 0x00)                 # obsolete "has default" switch
    elseif startswith(c.classname, "ScalarRecord")
        wr_u32(w, 1)
    else
        wr_u32(w, 1)                      # ScalarColumnDesc version
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

function write_tabledesc(w::AipsWriter, td::TableDesc)
    putstart(w, "TableDesc", 2)
    wr_string(w, td.name)
    wr_string(w, td.version)
    wr_string(w, td.comment)
    write_record(w, td.public)
    write_record(w, td.private)
    wr_u32(w, length(td.columns))
    for c in td.columns
        _write_columndesc(w, c)
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
    wr_u32(w, 2)                          # PlainColumn version 2
    wr_string(w, c.name)                  # originalName
    wr_u32(w, 1)                          # derived version
    wr_u32(w, c.sequ)                     # data-manager sequence number
    if isarray(c)
        if c.shape isa Dims && !isempty(c.shape)
            write(w.io, 0x01)             # shapeColDef: fixed cell shape
            wr_iposition(w, c.shape)      # -> casacore uses a direct-array column
        else
            write(w.io, 0x00)
        end
    end
end

function write_columnset(w::AipsWriter, cols::Vector{<:ColumnDesc},
                         dms::Vector{DMWrite}, nrow::Integer)
    wr_i32(w, -2)                         # version (negative), SepFile
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

function table_dat_bytes(td::TableDesc, nrow::Integer, dms::Vector{DMWrite})
    w = AipsWriter(; endian=:big)         # table.dat is always canonical
    putstart(w, "Table", 2)
    wr_u32(w, nrow)
    wr_u32(w, 1)                          # endian format: 1 = little-endian SM files
    wr_string(w, "PlainTable")
    write_tabledesc(w, td)
    write_columnset(w, td.columns, dms, nrow)
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

"""
    write_table_files(dir, td, nrow, dms; type, subtype, readme)

Write `table.dat` (atomically) and `table.info` for a table.  The data
managers in `dms` have already written their own `table.f<seq>*` files.
"""
function write_table_files(dir::AbstractString, td::TableDesc, nrow::Integer,
                           dms::Vector{DMWrite}; type="", subtype="", readme="")
    mkpath(dir)
    tmp = joinpath(dir, "table.dat_tmp")
    write(tmp, table_dat_bytes(td, nrow, dms))
    mv(tmp, joinpath(dir, "table.dat"); force=true)
    write_tableinfo(dir; type, subtype, readme)
end
