# ForwardColumnEngine -- a virtual column that forwards every read (and,
# on the write side, is created by `reference_copy`) to a *same-named*
# column in another table.  How casacore makes "reference-MS copies"
# (`MSTableImpl::referenceCopy`): every column is bound to this engine,
# then the writable ones are rebound to a real storage manager.
#
# Mirrors casacore/tables/DataMan/ForwardCol.{h,cc}.  Stores nothing
# itself (`VirtualColumnEngine::flush` -> False, empty per-DM block).
# The referenced table's path is a per-column String keyword
# `_ForwardColumn_TableName`, relative to this table's directory
# (`Path::stripDirectory` / `addDirectory` -- the same convention as
# subtable paths, so `_resolve_tabpath` / `_strip_directory` apply).
# `ForwardColumnIndexedRowEngine` (a per-row index column) and
# `RetypedArrayEngine` are not supported -- see `_UnsupportedDM`.

mutable struct ForwardColumnEngine
    owner::Table
    vdesc::ColumnDesc
    refpath::String
    reftable::Any            # ::Table, opened on first access
end

DATAMANAGERS["ForwardColumnEngine"] = ForwardColumnEngine

_is_forward_dm(name::AbstractString) = name == "ForwardColumnEngine"

function Base.open(::Type{ForwardColumnEngine}, t::Table, dm::DataManagerInfo)
    vi = findfirst(c -> c.sequ == dm.sequ, t.desc.columns)
    vi === nothing &&
        error("ForwardColumnEngine (seq $(dm.sequ)) has no bound column")
    vdesc = t.desc.columns[vi]
    rel = String(get(vdesc.keywords, "_ForwardColumn_TableName",
                     get(t.desc.private, "_ForwardColumn_TableName_$(dm.sequ)", "")))
    isempty(rel) && error("ForwardColumnEngine column \"$(vdesc.name)\": " *
                          "missing _ForwardColumn_TableName keyword")
    return ForwardColumnEngine(t, vdesc, _resolve_tabpath(rel, t.path), nothing)
end

_fce_ref(fce::ForwardColumnEngine) =
    fce.reftable === nothing ? (fce.reftable = readtable(fce.refpath)) : fce.reftable

getcell(fce::ForwardColumnEngine, ::Integer, ::ColumnDesc, row::Integer, ::Integer) =
    column(_fce_ref(fce), fce.vdesc.name)[Int(row)]

function getcolumn(fce::ForwardColumnEngine, ::Integer, ::ColumnDesc, nrow::Integer, ::Integer;
                   astype::Union{Nothing,Type}=nothing)
    out = _pcolumn(_fce_ref(fce), fce.vdesc.name, :full)[:]
    astype === nothing ? out : [astype.(x) for x in out]
end

# --- unsupported engines: a clear error (neither occurs in a standard MS)

struct _UnsupportedDM end
DATAMANAGERS["ForwardColumnIndexedRowEngine"] = _UnsupportedDM
DATAMANAGER_PATTERNS[r"^RetypedArrayEngine<"] = _UnsupportedDM

Base.open(::Type{_UnsupportedDM}, ::Table, dm::DataManagerInfo) = error(
    "data manager \"$(dm.name)\" is not supported -- RetypedArrayEngine needs the " *
    "C++ source-type class, ForwardColumnIndexedRowEngine is unimplemented. " *
    "Neither occurs in a standard Measurement Set.")
