# Tables.jl integration: a Table (and a MeasurementSet, via its MAIN
# table) is both a column source and a row source.  Access is lazy — each
# column materialises only when asked for.

import Tables

# --- column access ------------------------------------------------

Tables.istable(::Type{Table}) = true
Tables.columnaccess(::Type{Table}) = true
Tables.rowaccess(::Type{Table}) = true

Tables.columns(t::Table) = t
Tables.columnnames(t::Table) = Symbol.(columnnames(t))
Tables.getcolumn(t::Table, nm::Symbol) = column(t, String(nm))
Tables.getcolumn(t::Table, i::Int) = column(t, t.desc.columns[i].name)

function _schema_eltype(t::Table, c::ColumnDesc)
    c.sequ === nothing && return Any
    try
        _eltype(c, _dm_instance(t, c.sequ))
    catch
        Any
    end
end

Tables.schema(t::Table) = Tables.Schema(
    Symbol.(columnnames(t)),
    Tuple(_schema_eltype(t, c) for c in t.desc.columns))

# --- row access -------------------------------------------------

struct CTDSRows
    cols::Vector{Column}
    names::Vector{Symbol}
    n::Int
end

function Tables.rows(t::Table)
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
Base.length(t::Table) = t.rows
Base.IteratorSize(::Type{Table}) = Base.HasLength()
Base.eltype(::Type{Table}) = CTDSRow
function Base.iterate(t::Table, state=(Tables.rows(t), 1))
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
