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
# are all hard-coded `false` in casacore, and `removeRow` throws
# outright ("ConcatTable cannot remove rows") — no `addRow` override
# exists either. `removerows!`/`addrows!`/`removecolumn!` are therefore
# deliberate non-goals here, same as for `RefEditTable`.
# `ConcatTable::addColumn` genuinely IS supported by casacore (adds the
# column identically to every part, `ConcatTable.cc:530-560`) — real,
# but left for a future phase (mirrors how Phase 125 shipped cell/
# column write-through alone before Phase 126 added `addcolumn!`).

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

Row/column *count* changes have no `ConcatTable` analogue in casacore
(`canRemoveRow`/`canRemoveColumn`/`canRenameColumn` are all `false`,
and `removeRow` throws outright) — `addrows!`/`removerows!`/
`removecolumn!` are not supported on a `ConcatEditTable`. `addcolumn!`
is a real casacore capability (adds to every part) but not yet
implemented here — a future phase.
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
