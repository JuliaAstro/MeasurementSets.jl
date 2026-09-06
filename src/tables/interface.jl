# Tables.jl integration: a Table (and a MeasurementSet, via its MAIN
# table) is both a column source and a row source.  Access is lazy — each
# column materialises only when asked for.

import Tables

# --- column access ------------------------------------------------

Tables.istable(::Type{<:AbstractTable}) = true
Tables.columnaccess(::Type{<:AbstractTable}) = true
Tables.rowaccess(::Type{<:AbstractTable}) = true

Tables.columns(t::AbstractTable) = t
Tables.columnnames(t::AbstractTable) = Symbol.(columnnames(t))
Tables.getcolumn(t::AbstractTable, nm::Symbol) = column(t, String(nm))
Tables.getcolumn(t::AbstractTable, i::Int) = column(t, columnnames(t)[i])

_col_eltype(t::AbstractTable, name::AbstractString) =
    try eltype(column(t, name)) catch; Any end

Tables.schema(t::AbstractTable) = Tables.Schema(
    Symbol.(columnnames(t)),
    Tuple(_col_eltype(t, n) for n in columnnames(t)))

# --- row access -------------------------------------------------

struct CTDSRows
    cols::Vector{AbstractVector}
    names::Vector{Symbol}
    n::Int
end

function Tables.rows(t::AbstractTable)
    CTDSRows(AbstractVector[column(t, n) for n in columnnames(t)],
             Symbol.(columnnames(t)), nrow(t))
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
Base.length(t::AbstractTable) = nrow(t)
Base.IteratorSize(::Type{<:AbstractTable}) = Base.HasLength()
Base.eltype(::Type{<:AbstractTable}) = CTDSRow
function Base.iterate(t::AbstractTable, state=(Tables.rows(t), 1))
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
