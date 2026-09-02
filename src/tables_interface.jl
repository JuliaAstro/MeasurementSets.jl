# Tables.jl integration: a CTDSTable (and a MeasurementSet, via its MAIN
# table) is both a column source and a row source.  Access is lazy — each
# column materialises only when asked for.

import Tables

# --- column access ------------------------------------------------

Tables.istable(::Type{CTDSTable}) = true
Tables.columnaccess(::Type{CTDSTable}) = true
Tables.rowaccess(::Type{CTDSTable}) = true

Tables.columns(t::CTDSTable) = t
Tables.columnnames(t::CTDSTable) = Symbol.(columnnames(t))
Tables.getcolumn(t::CTDSTable, nm::Symbol) = column(t, String(nm))
Tables.getcolumn(t::CTDSTable, i::Int) = column(t, t.desc.columns[i].name)

function _schema_eltype(t::CTDSTable, c::ColumnDesc)
    c.sequ === nothing && return Any
    try
        _eltype(c, _dm_instance(t, c.sequ))
    catch
        Any
    end
end

Tables.schema(t::CTDSTable) = Tables.Schema(
    Symbol.(columnnames(t)),
    Tuple(_schema_eltype(t, c) for c in t.desc.columns))

# --- row access -------------------------------------------------

struct CTDSRows
    cols::Vector{Column}
    names::Vector{Symbol}
    n::Int
end

function Tables.rows(t::CTDSTable)
    CTDSRows(Column[column(t, c.name) for c in t.desc.columns],
             Symbol.(columnnames(t)), t.rows)
end

Base.length(r::CTDSRows) = r.n
Base.IteratorSize(::Type{CTDSRows}) = Base.HasLength()

struct CTDSRow <: Tables.AbstractRow
    parent::CTDSRows
    i::Int
end

Base.eltype(::Type{CTDSRows}) = CTDSRow
Base.iterate(r::CTDSRows, i::Int=1) = i > r.n ? nothing : (CTDSRow(r, i), i + 1)

Tables.columnnames(row::CTDSRow) = getfield(row, :parent).names
Tables.getcolumn(row::CTDSRow, i::Int) =
    getfield(row, :parent).cols[i][getfield(row, :i)]
function Tables.getcolumn(row::CTDSRow, nm::Symbol)
    p = getfield(row, :parent)
    p.cols[findfirst(==(nm), p.names)][getfield(row, :i)]
end

# `for r in table`
Base.length(t::CTDSTable) = t.rows
Base.IteratorSize(::Type{CTDSTable}) = Base.HasLength()
Base.eltype(::Type{CTDSTable}) = CTDSRow
function Base.iterate(t::CTDSTable, state=(Tables.rows(t), 1))
    r, i = state
    i > r.n && return nothing
    (CTDSRow(r, i), (r, i + 1))
end

# --- MeasurementSet delegates to its MAIN table -----------------

Tables.istable(::Type{MeasurementSet}) = true
Tables.columnaccess(::Type{MeasurementSet}) = true
Tables.rowaccess(::Type{MeasurementSet}) = true
Tables.columns(ms::MeasurementSet) = Tables.columns(getfield(ms, :data))
Tables.rows(ms::MeasurementSet) = Tables.rows(getfield(ms, :data))
Tables.schema(ms::MeasurementSet) = Tables.schema(getfield(ms, :data))
