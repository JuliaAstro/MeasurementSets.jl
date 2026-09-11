# In-place edit through a `RefTable` view (Phase 125).
#
# **Finding, verified against real casacore source** (`tables/Tables/
# RefColumn.cc`): a `RefTable` cell/column write is architecturally
# trivial in casacore — `RefColumn::put`/`putArray`/`putSlice` are pure
# row-index translations (`colPtr_p->put(refTabPtr_p->rootRownr(rownr),
# dataPtr)`) that delegate straight through to the *parent* column's own
# `put`. There is no separate storage for a RefTable's ordinary columns
# to edit "in place" — editing a RefTable IS editing the parent's mapped
# rows. So this needs no new persist format at all: `edit(rt::RefTable)`
# opens the parent for edit and every `t[name][i] = v` on the view
# translates `i -> rt.rows[i]` / `name -> rt.namemap[name]` before
# delegating to the already-tested `EditTable`/`EditColumn` primitives —
# the exact same fast/regen paths a direct `edit(rt.parent.path)` uses.
#
# `RefTable.removeRow` (also verified) only shrinks casacore's own
# in-memory row-number list — it never touches the parent, so it isn't
# an I/O operation at all and needs no analogue here (filter with
# `query`/build a fresh `RefTable` instead). `RefTable` has no `addRow`
# in casacore either (a selection's row set is fixed at query time).
# Both are deliberate non-goals for `RefEditTable`.
#
# Phase 126 — `addcolumn!`, verified against `RefTable::addColumn`
# (`RefTable.cc:761-802`): with `addToParent=true` (casacore's normal
# case — `addToParent=false` requires the column to already exist on the
# parent), it calls straight through to `baseTabPtr_p->addColumn(...)`
# — the new column is added to the PARENT's schema, sized to the
# parent's FULL row count (defaulted everywhere) — then registers the
# name in the RefTable's own `nameMap_p` so it's visible through the
# view too. Our `addcolumn!(::RefEditTable, ...)` mirrors this exactly:
# it delegates to the already-tested `addcolumn!(::EditTable, ...)`,
# then extends `namemap`/`order` so the new column is reachable through
# the view — no new persist format, same reuse as the read/write path.
# `RefTable::removeColumn` (also read) is a genuinely different shape —
# it only edits the RefTable's OWN descriptor/name map, never touching
# the parent (a pure view-level "hide this column", unlike our
# `EditTable`'s `removecolumn!`, which always drops real storage).
#
# Phase 127 — implements that distinct semantic:
# `removecolumn!(::RefEditTable, name)` deletes `name` from the view's
# own `namemap`/`order` only. The parent (including any of ITS pending
# `addcols`/`dropcols` from this same session) is left completely
# untouched — so `addcolumn!(rv, "X", ...); removecolumn!(rv, "X")` in
# one session hides "X" from the rest of THIS view's own access, but
# "X" is still written to the parent at flush (matches real casacore
# exactly: `RefTable::removeColumn` never calls
# `baseTabPtr_p->removeColumn`, so a column dropped from a RefTable view
# never disappears from the table it was really stored in).

"""
    RefEditTable

The view returned by [`edit`](@ref)`(rt::RefTable)` — writing
`t[name][i] = v` translates `i`/`name` through `rt`'s row map / column
rename and delegates to the parent's [`EditTable`](@ref), so the write
lands on the parent's actual on-disk rows. `rt.parent` must be a plain
`Table` (matches `copytable`'s own RefTable-of-a-plain-table
restriction — Phase 15).
"""
struct RefEditTable
    parent::EditTable
    rows::Vector{Int}                  # 1-based row -> parent EditTable row index
    namemap::Dict{String,String}       # ref column name => parent column name
    order::Vector{String}              # ref column order
end

struct RefEditColumn{T} <: AbstractVector{T}
    ret::RefEditTable
    pcol::EditColumn{T}
end

"""
    edit(rt::RefTable) -> RefEditTable
    edit(f, rt::RefTable)                # runs `f(t)`, then flushes the parent

Open the table `rt` is a view of for update, through `rt`'s own row
selection / column projection — `t[name][i] = v` writes to the *parent*
table's mapped row. A thin wrapper over [`edit`](@ref)`(path)`: every
write goes through the exact same fast/regen machinery as editing the
parent directly. `rt.parent` must be a plain `Table` (not another
RefTable/ConcatTable — matches [`copytable`](@ref)'s own restriction).

Row-*count* changes have no RefTable analogue in casacore itself (a
selection's rows are fixed at query time, and removing a RefTable row
only shrinks the in-memory selection, never touching the parent) —
`addrows!`/`removerows!` are not supported on a `RefEditTable`; build a
new `RefTable` via `query` instead. `addcolumn!` adds to the parent's
schema, matching `RefTable::addColumn`; `removecolumn!` only hides a
column from this view (the parent keeps it), matching `RefTable::
removeColumn` — see its own docstring.
"""
function edit(rt::RefTable)
    rt.parent isa Table || error(
        "edit(::RefTable): the parent is a $(typeof(rt.parent)) — only a " *
        "RefTable over a plain Table is supported")
    p = edit(rt.parent.path)
    RefEditTable(p, copy(rt.rows), copy(rt.namemap), copy(rt.order))
end
function edit(f::Function, rt::RefTable)
    t = edit(rt)
    f(t)
    flush(t.parent)
    return t
end

Base.getindex(t::RefEditTable, name::AbstractString) = RefEditColumn(t, _refedit_pcol(t, name))
Base.getindex(t::RefEditTable, name::Symbol) = t[String(name)]

function _refedit_pcol(t::RefEditTable, name::AbstractString)
    haskey(t.namemap, name) || error("edit(::RefTable): no column \"$name\"")
    t.parent[t.namemap[name]]
end

Base.size(c::RefEditColumn) = (length(c.ret.rows),)
Base.IndexStyle(::Type{<:RefEditColumn}) = IndexLinear()

function Base.getindex(c::RefEditColumn, i::Int)
    @boundscheck 1 <= i <= length(c.ret.rows) || throw(BoundsError(c, i))
    c.pcol[c.ret.rows[i]]
end
Base.getindex(c::RefEditColumn, ::Colon) = [c[i] for i in 1:length(c.ret.rows)]

function Base.setindex!(c::RefEditColumn, v, i::Int)
    @boundscheck 1 <= i <= length(c.ret.rows) || throw(BoundsError(c, i))
    c.pcol[c.ret.rows[i]] = v
    return v
end
function Base.setindex!(c::RefEditColumn, vals, ::Colon)
    length(vals) == length(c.ret.rows) ||
        error("assigning $(length(vals)) values to a $(length(c.ret.rows))-row column")
    for (i, v) in enumerate(vals)
        c[i] = v
    end
    return vals
end

"""
    setcell!(t::RefEditTable, name, i, v) -> t
"""
setcell!(t::RefEditTable, name, i::Integer, v) = (t[name][Int(i)] = v; t)

"""
    setcolumn!(t::RefEditTable, name, vals) -> t
"""
setcolumn!(t::RefEditTable, name, vals) = (t[name][:] = vals; t)

"""
    addcolumn!(t::RefEditTable, name; kind=:ssm)
    addcolumn!(t::RefEditTable, name, data; kind=:ssm, type=nothing, shape=nothing)

Add a column, visible through this view — matches `RefTable::addColumn`
(`addToParent=true`): the column is added to the *parent*'s schema,
sized to the parent's full row count. With no `data`, the column comes
from the standard MS v2 schema and every parent row (not just this
view's) gets the default cell — identical to `addcolumn!(::EditTable,
name)`. With `data` (length `length(t)`, one value per row of *this
view*), the parent's other rows get the column's default cell and only
this view's mapped rows get `data`'s values — mirroring what a real
`RefTable::addColumn` + a follow-up `put` on just the selected rows
does in casacore.
"""
function addcolumn!(t::RefEditTable, name::AbstractString; kind::Symbol=:ssm)
    haskey(t.namemap, name) && error("addcolumn!: \"$name\" already exists in this view")
    addcolumn!(t.parent, name; kind)
    t.namemap[name] = name
    push!(t.order, name)
    return t
end

function addcolumn!(t::RefEditTable, name::AbstractString, data::AbstractVector;
                    kind::Symbol=:ssm, type::Union{CasaType,Nothing}=nothing, shape=nothing)
    haskey(t.namemap, name) && error("addcolumn!: \"$name\" already exists in this view")
    _check_new_col(t.parent, name)
    length(data) == length(t.rows) ||
        error("addcolumn!: expected $(length(t.rows)) values (one per RefTable row), got $(length(data))")
    desc, vals = _addcol_desc(name, data; type, shape)
    full = Any[_default_cell(desc, t.parent) for _ in 1:length(t.parent.rowmap)]
    for (i, r) in enumerate(t.rows)
        full[r] = vals[i]
    end
    push!(t.parent.addcols, (desc, kind, full))
    t.namemap[name] = name
    push!(t.order, name)
    return t
end

"""
    removecolumn!(t::RefEditTable, name) -> t

Hide `name` from this view — matches `RefTable::removeColumn`: only the
VIEW's own column list is edited. The parent's actual column (real
storage, and anything else about the parent's own edit session) is left
completely untouched — a column "removed" from a RefTable view is still
there in the table it's really stored in, exactly as in casacore.
"""
function removecolumn!(t::RefEditTable, name::AbstractString)
    haskey(t.namemap, name) || error("removecolumn!: no column \"$name\" in this view")
    delete!(t.namemap, name)
    filter!(!=(name), t.order)
    return t
end

# Phase 133: clear, actionable errors instead of a raw MethodError for
# the two row-count operations `RefEditTable` deliberately doesn't
# support (see this file's header comment — `RefTable` has no `addRow`
# in casacore at all, and `removeRow` only shrinks the in-memory
# selection, never touching the parent, so there's no I/O for
# `removerows!` to do here).
addrows!(::RefEditTable, ::Integer) = error(
    "addrows!: a RefTable view has no row-count analogue in casacore " *
    "(a selection's rows are fixed at query time) — build a new " *
    "RefTable via `query` instead, or `edit` the parent directly")
removerows!(::RefEditTable, rows) = error(
    "removerows!: a RefTable view has no row-count analogue in casacore " *
    "(`RefTable::removeRow` only shrinks the in-memory selection, never " *
    "touching the parent — there is no I/O for this to do) — build a " *
    "new RefTable via `query` instead")
