# In-place edit through a `ConcatTable` view (Phase 129).
#
# **Finding, verified against real casacore source** (`tables/Tables/
# ConcatColumn.cc`): exactly the same shape as `RefColumn::put`
# (Phase 125) — `ConcatColumn::put` is a pure row-index translation:
# `refTabPtr_p->rows().mapRownr(tableNr, tabRownr, rownr);
# refColPtr_p[tableNr]->put(tabRownr, dataPtr)`. A `ConcatTable` has no
# storage of its own either — editing one in place IS editing whichever
# PART a given row belongs to, at that part's own local row number
# (exactly the `k = searchsortedlast(offsets, i-1); i - offsets[k]`
# split our own read-side `ConcatColumn` (`tables/column.jl`) already
# does). `isWritable()` requires every part writable.
#
# `ConcatTable::canRemoveRow()`/`canRemoveColumn()`/`canRenameColumn()`
# are all hard-coded `false` in casacore, and `removeRow`/`removeColumn`/
# `renameColumn` all THROW outright ("ConcatTable cannot remove rows" /
# "... remove columns" / "... rename columns", `ConcatTable.cc:563-583`)
# — unlike `RefTable::removeColumn` (Phase 127's genuinely different
# "pure view-level hide" case), `ConcatTable` really has no analogue at
# all here. `removerows!`/`addrows!`/`removecolumn!` stay deliberate
# non-goals.
#
# Phase 130 — `addcolumn!`, verified against `ConcatTable::addColumn`
# (`ConcatTable.cc:530-560`): both overloads simply call `tables_p[i].
# addColumn(...)` on EVERY part in turn (schema-only, like
# `Table::addColumn` in general — casacore's own API never carries
# values, a later `put` fills them in), then registers the column on
# the `ConcatTable`'s own descriptor. `addcolumn!(::ConcatEditTable,
# name; kind)` mirrors this directly: `addcolumn!` on every part.
# `addcolumn!(::ConcatEditTable, name, data; ...)` is a MeasurementSets
# convenience beyond casacore's own schema-only API (matching the same
# choice Phase 126 made for `RefEditTable`): `data` covers every row of
# the WHOLE concatenated view (there is no "selection" concept here,
# unlike RefTable), sliced by `offsets` into one `addcolumn!(part, name,
# slice; ...)` call per part — each part independently infers its own
# type/shape from its own slice, matching how `ConcatTable` itself only
# ever consults `parts[1]`'s schema for anything table-desc-level
# (Phase 15's own finding) rather than enforcing cross-part consistency.

"""
    ConcatEditTable

The view returned by [`edit`](@ref)`(ct::ConcatTable)` — writing
`t[name][i] = v` translates `i` through `ct`'s cumulative row offsets
to (part, local row) and delegates to that part's own
[`EditTable`](@ref), so the write lands on the actual part's on-disk
row. Every part of `ct` must be a plain `Table`.
"""
struct ConcatEditTable
    parts::Vector{EditTable}
    offsets::Vector{Int}                # cumulative; offsets[end] == nrow
end

struct ConcatEditColumn{T} <: AbstractVector{T}
    cet::ConcatEditTable
    pcols::Vector{EditColumn{T}}
end

"""
    edit(ct::ConcatTable) -> ConcatEditTable
    edit(f, ct::ConcatTable)             # runs `f(t)`, then flushes every part

Open every part of `ct` for update, through `ct`'s own row-offset
mapping — `t[name][i] = v` writes to whichever part row `i` actually
belongs to. Every part must be a plain `Table` (a part that is itself a
RefTable/ConcatTable/etc. is not supported).

Row-*count* changes have no `ConcatTable` analogue in casacore
(`canRemoveRow`/`canRemoveColumn`/`canRenameColumn` are all `false`,
and `removeRow`/`removeColumn`/`renameColumn` all throw outright) —
`addrows!`/`removerows!`/`removecolumn!` are not supported. `addcolumn!`
IS supported — it adds the column to every part, matching
`ConcatTable::addColumn`.
"""
function edit(ct::ConcatTable)
    all(p -> p isa Table, ct.parts) || error(
        "edit(::ConcatTable): every part must be a plain Table")
    ConcatEditTable([edit(p.path) for p in ct.parts], ct.offsets)
end
function edit(f::Function, ct::ConcatTable)
    t = edit(ct)
    f(t)
    for p in t.parts
        flush(p)
    end
    return t
end

Base.getindex(t::ConcatEditTable, name::AbstractString) =
    ConcatEditColumn(t, [p[name] for p in t.parts])
Base.getindex(t::ConcatEditTable, name::Symbol) = t[String(name)]

Base.size(c::ConcatEditColumn) = (c.cet.offsets[end],)
Base.IndexStyle(::Type{<:ConcatEditColumn}) = IndexLinear()

function _cet_locate(cet::ConcatEditTable, i::Int)
    k = searchsortedlast(cet.offsets, i - 1)
    return k, i - cet.offsets[k]
end

function Base.getindex(c::ConcatEditColumn, i::Int)
    @boundscheck 1 <= i <= c.cet.offsets[end] || throw(BoundsError(c, i))
    k, li = _cet_locate(c.cet, i)
    c.pcols[k][li]
end
Base.getindex(c::ConcatEditColumn, ::Colon) = [c[i] for i in 1:c.cet.offsets[end]]

function Base.setindex!(c::ConcatEditColumn, v, i::Int)
    @boundscheck 1 <= i <= c.cet.offsets[end] || throw(BoundsError(c, i))
    k, li = _cet_locate(c.cet, i)
    c.pcols[k][li] = v
    return v
end
function Base.setindex!(c::ConcatEditColumn, vals, ::Colon)
    n = c.cet.offsets[end]
    length(vals) == n || error("assigning $(length(vals)) values to a $n-row column")
    for (i, v) in enumerate(vals)
        c[i] = v
    end
    return vals
end

"""
    setcell!(t::ConcatEditTable, name, i, v) -> t
"""
setcell!(t::ConcatEditTable, name, i::Integer, v) = (t[name][Int(i)] = v; t)

"""
    setcolumn!(t::ConcatEditTable, name, vals) -> t
"""
setcolumn!(t::ConcatEditTable, name, vals) = (t[name][:] = vals; t)

"""
    addcolumn!(t::ConcatEditTable, name; kind=:ssm)
    addcolumn!(t::ConcatEditTable, name, data; kind=:ssm, type=nothing, shape=nothing)

Add a column, matching `ConcatTable::addColumn`: the column is added to
EVERY part in turn. With no `data`, every part gets the standard-schema
column with its own default cells (identical to `addcolumn!(::EditTable,
name)` on each part). With `data` (length `length(t)`, one value per
row of the whole concatenated view), it's sliced by `t.offsets` and
each part gets its own slice — each part independently infers its own
column type/shape from that slice.
"""
function addcolumn!(t::ConcatEditTable, name::AbstractString; kind::Symbol=:ssm)
    for p in t.parts
        addcolumn!(p, name; kind)
    end
    return t
end

function addcolumn!(t::ConcatEditTable, name::AbstractString, data::AbstractVector;
                    kind::Symbol=:ssm, type::Union{CasaType,Nothing}=nothing, shape=nothing)
    n = t.offsets[end]
    length(data) == n ||
        error("addcolumn!: expected $n values (one per ConcatTable row), got $(length(data))")
    for (i, p) in enumerate(t.parts)
        lo, hi = t.offsets[i] + 1, t.offsets[i + 1]
        addcolumn!(p, name, data[lo:hi]; kind, type, shape)
    end
    return t
end

# Phase 133: clear, actionable errors instead of a raw MethodError.
# `BaseTable::canAddRow()`/`canRemoveRow()` both hard-`false` for a
# ConcatTable (neither is overridden — confirmed by reading
# `BaseTable.cc:592-598`, the base-class default: `addRow` throws
# "Table: cannot add a row..."; `removeRow` throws the ConcatTable-
# specific "ConcatTable cannot remove rows" already cited above) — so
# `addrows!`/`removerows!` genuinely have no analogue here, and
# `removecolumn!` was already confirmed a hard non-goal in Phase 130
# (`ConcatTable::removeColumn` throws unconditionally, no view-level-
# hide analogue like `RefTable`'s).
addrows!(::ConcatEditTable, ::Integer) = error(
    "addrows!: a ConcatTable has no row-count analogue in casacore " *
    "(BaseTable::canAddRow() is false, addRow throws) — edit a part " *
    "directly, or build a new ConcatTable via `write_concattable`")
removerows!(::ConcatEditTable, rows) = error(
    "removerows!: a ConcatTable cannot remove rows in casacore " *
    "(ConcatTable::removeRow throws unconditionally) — edit a part " *
    "directly, or build a new ConcatTable via `write_concattable`")
removecolumn!(::ConcatEditTable, name::AbstractString) = error(
    "removecolumn!: a ConcatTable cannot remove columns in casacore " *
    "(ConcatTable::removeColumn throws unconditionally — unlike " *
    "RefTable, there's no view-level-hide analogue) — remove the " *
    "column from each part directly instead")
