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
# Both are therefore deliberate non-goals for `RefEditTable`, along with
# `addcolumn!`/`removecolumn!` (casacore's `RefTable::addColumn` can add
# a column straight to the parent's schema — a real capability, but a
# separate, larger future phase, not attempted here).

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

Row/column *count* changes have no RefTable analogue in casacore
itself (a selection's rows are fixed at query time, and removing a
RefTable row only shrinks the in-memory selection, never touching the
parent) — `addrows!`/`removerows!`/`addcolumn!`/`removecolumn!` are not
supported on a `RefEditTable`; build a new `RefTable` via `query`
instead.
"""
function edit(rt::RefTable)
    rt.parent isa Table || error(
        "edit(::RefTable): the parent is a $(typeof(rt.parent)) — only a " *
        "RefTable over a plain Table is supported")
    p = edit(rt.parent.path)
    RefEditTable(p, rt.rows, rt.namemap, rt.order)
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
