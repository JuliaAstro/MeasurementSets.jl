# casacore Record / TableRecord / *KeywordSet decoding.
#
# Mirrors casacore/casa/Containers/RecordRep.cc and
# casacore/tables/Tables/TableRecordRep.cc.

"A reference to a subtable stored as a `TpTable` keyword value."
struct SubTable
    name::String        # path as stored on disk (usually "Table: <abs path>")
end

# casacore RecordInterface::RecordType
const RECORD_FIXED    = Int32(0)
const RECORD_VARIABLE = Int32(1)

"An ordered casacore (Table)Record: field name -> value, with the on-disk types."
mutable struct Record
    names::Vector{String}
    types::Vector{CasaType}
    values::Vector{Any}
    comments::Vector{String}
    rectype::Int32            # RECORD_FIXED / RECORD_VARIABLE
end
Record() = Record(String[], CasaType[], Any[], String[], RECORD_VARIABLE)

Base.length(r::Record) = length(r.names)
Base.keys(r::Record) = r.names
Base.haskey(r::Record, k::AbstractString) = k in r.names
function Base.getindex(r::Record, k::AbstractString)
    i = findfirst(==(k), r.names)
    i === nothing && throw(KeyError(k))
    r.values[i]
end
Base.get(r::Record, k::AbstractString, default) = haskey(r, k) ? r[k] : default
Base.iterate(r::Record, s=1) = s > length(r) ? nothing : (r.names[s] => r.values[s], s + 1)

function Base.show(io::IO, r::Record)
    print(io, "Record(")
    join(io, (string(n, "=", _short(v)) for (n, v) in r), ", ")
    print(io, ")")
end
_short(v::SubTable) = "→" * basename(rstrip(v.name))
_short(v::AbstractString) = repr(v)
_short(v::AbstractArray) = string(eltype(v), size(v))
_short(v) = repr(v)

# --- field description (RecordDesc) -----------------------------------

struct RecordField
    name::String
    type::CasaType
    shape::Dims             # for array fields
    subdesc::Vector{RecordField}
    tabledesc::String       # for TpTable fields
    comment::String
end

function read_recorddesc(a::AipsIO)
    version = getstart(a, "RecordDesc")
    n = Int(read_i32(a))
    fields = RecordField[]
    for _ in 1:n
        name = read_string(a)
        t = casatype(read_i32(a))
        shape = ()
        sub = RecordField[]
        tdesc = ""
        if t == TpRecord
            sub = read_recorddesc(a)
        elseif t == TpTable
            tdesc = read_string(a)
        elseif isarraytype(t)
            shape = read_iposition(a)
        end
        comment = version > 1 ? read_string(a) : ""
        push!(fields, RecordField(name, t, shape, sub, tdesc, comment))
    end
    getend(a)
    return fields
end

# --- scalar / array field values ------------------------------------

function read_datafield(a::AipsIO, t::CasaType)
    if isscalartype(t)
        return t == TpString ? read_string(a) : read_scalar(a, juliatype(t))
    elseif isarraytype(t)
        elt = juliatype(t)
        shape, data = read_array(a, elt == String ? String : elt)
        return isempty(shape) ? reshape(data, ()) : reshape(data, shape...)
    else
        error("read_datafield: unsupported type $t")
    end
end

# --- the dispatcher -------------------------------------------------

"""
    read_record(a) -> Record

Read whatever record-like object comes next (`TableRecord`, `Record`,
`TableKeywordSet`, `ScalarKeywordSet`, `ArrayKeywordSet`).
"""
function read_record(a::AipsIO)
    tp = getnexttype(a)
    if tp == "TableKeywordSet" || tp == "ScalarKeywordSet" || tp == "ArrayKeywordSet"
        version = read_u32(a)
        kind = tp == "ScalarKeywordSet" ? 0 : tp == "ArrayKeywordSet" ? 1 : 2
        rec = read_keyset(a, version, kind)
        getend(a)
        return rec
    else
        # "TableRecord" or "Record"
        version = read_u32(a)
        fields = read_recorddesc(a)
        rectype = read_i32(a)
        rec = read_recorddata(a, fields, version)
        rec.rectype = rectype
        getend(a)
        return rec
    end
end

function read_recorddata(a::AipsIO, fields::Vector{RecordField}, version)
    rec = Record()
    for f in fields
        if f.type == TpRecord
            val = isempty(f.subdesc) ? read_record(a) :
                  read_recorddata(a, f.subdesc, version)
        elseif f.type == TpTable
            val = SubTable(read_string(a))
        else
            val = read_datafield(a, f.type)
        end
        push!(rec.names, f.name)
        push!(rec.types, f.type)
        push!(rec.values, val)
        push!(rec.comments, f.comment)
    end
    return rec
end

# --- the old-style keyword sets (used by all MS tables) -------------

const SCALARKEY =
    (TpBool, TpInt, TpUInt, TpFloat, TpDouble, TpComplex, TpDComplex, TpString)
const ARRAYKEY =
    (TpArrayBool, TpArrayInt, TpArrayUInt, TpArrayFloat, TpArrayDouble,
     TpArrayComplex, TpArrayDComplex, TpArrayString)

function read_keyset(a::AipsIO, version, kind::Int)
    # --- key description: Map<String,void> --------------------------
    getstart(a, "Map<String,void>")
    n = Int(read_u32(a))
    read_i32(a); read_string(a)         # default attr (dt, comment)
    names = String[]
    types = CasaType[]
    for _ in 1:n
        push!(names, read_string(a))
        push!(types, casatype(read_i32(a)))
        read_string(a)                              # per-key comment
    end
    getend(a)
    read_block(a, Int32)                            # excluded dtypes
    read_block(a, String)                           # excluded names

    rec = Record()
    resize!(rec.names, n); resize!(rec.types, n)
    resize!(rec.values, n); resize!(rec.comments, n)
    for i in 1:n
        rec.names[i] = names[i]; rec.types[i] = types[i]; rec.comments[i] = ""
        rec.values[i] = nothing
    end
    idx(name) = findfirst(==(name), names)

    read_keygroup(a, rec, idx, SCALARKEY)
    kind > 0 && read_keygroup(a, rec, idx, ARRAYKEY)
    if kind > 1
        m = Int(read_u32(a))
        for _ in 1:m
            key = read_string(a)
            name = read_string(a)
            j = idx(key)
            j === nothing || (rec.values[j] = SubTable(name))
        end
    end
    if version > 1
        m = read_u32(a)
        m == 0 || error("read_keyset: nested keyword sets not supported")
    end
    return rec
end

function read_keygroup(a::AipsIO, rec, idx, order)
    for t in order
        m = Int(read_u32(a))
        for _ in 1:m
            name = read_string(a)
            val = read_datafield(a, t)
            j = idx(name)
            j === nothing || (rec.values[j] = val)
        end
    end
end
