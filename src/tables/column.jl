# Column data access: a lazy `Column <: AbstractVector` that dispatches to
# the bound data manager.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{Table,Dict{Int,Any}}()

_dm_instance(::Table, ::Nothing) = error("column is not bound to a data manager")

# `DATAMANAGERS` / `DATAMANAGER_PATTERNS` / `_dmtype` (the on-disk
# data-manager name -> Julia type lookup) live in
# datamanagers/datamanager.jl; each data manager registers itself into
# them from its own file (e.g. standard.jl, virtual.jl).

function _dm_instance(t::Table, sequ::Int)
    cache = get!(() -> Dict{Int,Any}(), _DM_CACHE, t)
    haskey(cache, sequ) && return cache[sequ]
    dm = t.managers[findfirst(d -> d.sequ == sequ, t.managers)]
    T = _dmtype(dm.name)
    T === nothing && error("data manager \"$(dm.name)\" not yet supported (column data)")
    inst = open(T, t, dm)
    cache[sequ] = inst
    return inst
end

# (1-based position of `c` among columns bound to its DM instance, count bound)
function _dm_local(t::Table, c::ColumnDesc)
    idx = 0
    n = 0
    for x in t.desc.columns
        if x.sequ == c.sequ
            n += 1
            x === c && (idx = n)
        end
    end
    idx == 0 && error("column not found")
    return idx, n
end

# --- the lazy column -------------------------------------------------

"""
    Column{T} <: AbstractVector{T}

A lazy view of one table column, returned by [`column`](@ref) and
`t[:NAME]`. Indexing reads on demand: `col[i]` fetches one cell, `col[:]`
takes the storage manager's whole-column fast path, `col[r]` a row
subset. `T` is the best-known element type — a scalar, a fixed-shape
`Array{E,N}`, or `Array{E}` when the rank is only known once a cell is
read.
"""
struct Column{T} <: AbstractVector{T}
    table::Table
    desc::ColumnDesc
    inst::Any            # opened data-manager instance
    index::Int           # DM-local column index (SSM/ISM)
    cols::Int            # number of columns bound to the DM instance (ISM)
    target::Union{Nothing,DataType}   # Phase 34-36: narrow scalar type (Float16/BFloat16) or nothing
end

# Best-known element type.  `target` (a scalar type) maps Float32 ->
# target / ComplexF32 -> Complex{target} in the element type.
function _eltype(c::ColumnDesc, inst; target::Union{Nothing,Type}=nothing)
    E = target === nothing ? juliatype(c.type) : _narrowtype(juliatype(c.type), target)
    s = c.shape
    s isa Dims && isempty(s) && return E
    s isa Dims && return Array{E,length(s)}
    if s isa VariableShape && inst isa TiledStMan
        nd = inst.kind === :cell ? inst.dims : inst.dims - 1
        return Array{E, nd}
    end
    return Array{E}
end

_eltype(c::ColumnDesc, ::VirtualEngine; target::Union{Nothing,Type}=nothing) =
    Array{target === nothing ? juliatype(c.type) : _narrowtype(juliatype(c.type), target)}

"""
    column(t::Table, name; precision=nothing) -> Column

A lazy `AbstractVector` over a column: `col[i]` reads one cell, `col[r]` a
range, `col[:]` the whole column (fast path).

`precision` (`nothing` follows `t.precision`; otherwise `:half` / `:full`
/ `Float16` / `BFloat16` / `Float32` — see [`readtable`](@ref)):
`:half` narrows only a `TpComplex` column (to `ComplexF16`); `Float16` /
`BFloat16` narrow any `Float32` / `ComplexF32` column to that scalar type
/ its `Complex`; `:full` keeps the column wide.
"""
function column(t::Table, name::AbstractString;
                precision::Union{Nothing,Symbol,Type}=nothing)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.sequ)
    idx, n = _dm_local(t, c)
    target = _narrowtarget(precision === nothing ? t.precision : precision, juliatype(c.type))
    Column{_eltype(c, inst; target)}(t, c, inst, idx, n, target)
end

# resolve an effective precision setting + a column's Julia type to the
# narrow scalar target (Float16 / BFloat16) or `nothing` (no narrowing)
function _narrowtarget(eff, jt::Type)
    (eff === :full || eff === Float32) && return nothing
    eff === :half && return jt === ComplexF32 ? Float16 : nothing
    eff isa Type && jt in (Float32, ComplexF32) && return eff
    return nothing
end

Base.size(c::Column) = (c.table.rows,)
Base.IndexStyle(::Type{<:Column}) = IndexLinear()

function Base.getindex(c::Column, i::Int)
    @boundscheck checkbounds(c, i)
    v = getcell(c.inst, c.index, c.desc, i, c.cols)
    c.target === nothing ? v : _narrowvalue(v, c.target)   # single cell: cheap post-convert
end

function Base.getindex(c::Column, ::Colon)
    # whole column: hand the narrowed element type down so the storage
    # manager decodes straight into a Float16/BFloat16 buffer (no wide
    # intermediate).  `astype === nothing` is byte-identical to before.
    astype = c.target === nothing ? nothing :
             _narrowtype(juliatype(c.desc.type), c.target)
    getcolumn(c.inst, c.index, c.desc, c.table.rows, c.cols; astype)
end

Base.getindex(c::Column, r::AbstractVector{<:Integer}) = [c[i] for i in r]
Base.collect(c::Column) = c[:]

# --- reference / concatenation views --------------------------------

"A column of a [`RefTable`](@ref): row `i` reads parent row `rows[i]`."
struct MappedColumn{T,P<:AbstractVector} <: AbstractVector{T}
    parent::P                # a Column of the parent table
    rows::Vector{Int}        # 1-based parent row per ref row
end

Base.size(m::MappedColumn) = (length(m.rows),)
Base.IndexStyle(::Type{<:MappedColumn}) = IndexLinear()
function Base.getindex(m::MappedColumn, i::Int)
    @boundscheck checkbounds(m, i)
    @inbounds m.parent[m.rows[i]]
end
Base.getindex(m::MappedColumn, ::Colon) = m.parent[m.rows]
Base.getindex(m::MappedColumn, r::AbstractVector{<:Integer}) = m.parent[m.rows[r]]
Base.collect(m::MappedColumn) = m[:]

"A column of a [`ConcatTable`](@ref): rows run through `parts` per `offsets`."
struct ConcatColumn{T} <: AbstractVector{T}
    parts::Vector{<:AbstractVector}
    offsets::Vector{Int}     # cumulative; offsets[end] == length
end

Base.size(c::ConcatColumn) = (c.offsets[end],)
Base.IndexStyle(::Type{<:ConcatColumn}) = IndexLinear()
function Base.getindex(c::ConcatColumn, i::Int)
    @boundscheck checkbounds(c, i)
    k = searchsortedlast(c.offsets, i - 1)
    @inbounds c.parts[k][i - c.offsets[k]]
end
Base.getindex(c::ConcatColumn, ::Colon) =
    isempty(c.parts) ? eltype(c)[] : reduce(vcat, (collect(p[:]) for p in c.parts))
Base.getindex(c::ConcatColumn, r::AbstractVector{<:Integer}) = [c[i] for i in r]
Base.collect(c::ConcatColumn) = c[:]

function column(t::RefTable, name::AbstractString; precision::Union{Nothing,Symbol,Type}=nothing)
    haskey(t.namemap, name) || throw(KeyError(name))
    pc = _pcolumn(t.parent, t.namemap[name], precision)
    MappedColumn{eltype(pc),typeof(pc)}(pc, t.rows)
end

function column(t::ConcatTable, name::AbstractString; precision::Union{Nothing,Symbol,Type}=nothing)
    pcs = AbstractVector[_pcolumn(p, name, precision) for p in t.parts]
    T = mapreduce(eltype, typejoin, pcs)
    ConcatColumn{T}(pcs, t.offsets)
end

# `column` with a `precision` override that may be `nothing` (= use the
# table's own setting); works for every AbstractTable kind.
_pcolumn(t::AbstractTable, name, precision::Union{Nothing,Symbol,Type}) =
    column(t, name; precision)

# Rows `r` of `c` as a `Vector{Any}` of plain values / dense `Array`s (lazy
# wrappers collapsed so the reader's nested wrapper types stay out of
# downstream inference -- some `getindex(::Colon)` fast paths return views
# into a shared backing buffer, e.g. TiledStMan's `_read_cube_bulk`).
#
# `r` an identity, full, in-order range (`1:length(c)`) uses the column's
# own whole-column fast path (`c[:]`) instead of indexing cell by cell --
# a real win for a big table (a `copyms` of a 925k-row subtable roughly
# halves).  Any other `r` (a `RefTable` selection, a genuine partial row
# slice) stays per-cell, where bulk-reading the whole source column to
# keep a small subset would be a regression, not a win.
function _read_cells(c::AbstractVector, r)
    full = r isa AbstractUnitRange{<:Integer} && !isempty(r) &&
           first(r) == 1 && last(r) == length(c)
    vals = full ? c[:] : (c[i] for i in r)
    out = Vector{Any}(undef, length(r))
    @inbounds for (k, v) in enumerate(vals)
        out[k] = v isa AbstractArray ? Array(v) : v
    end
    return out
end

# --- convenience verbs + indexing ---------------------------------

"""
    getcolumn(t, name; precision=nothing) -> Vector / Vector{Array}

Read an entire column's data (eager; equivalent to
`column(t, name; precision)[:]`).
"""
getcolumn(t::AbstractTable, name::AbstractString; precision::Union{Nothing,Symbol,Type}=nothing) =
    _pcolumn(t, name, precision)[:]

"""
    getcell(t, name, row; precision=nothing) -> value

Read one cell (`row` is 1-based).
"""
getcell(t::AbstractTable, name::AbstractString, row::Integer;
        precision::Union{Nothing,Symbol,Type}=nothing) = _pcolumn(t, name, precision)[row]

Base.getindex(t::AbstractTable, name::AbstractString) = column(t, name)
Base.getindex(t::AbstractTable, name::Symbol) = column(t, String(name))

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    column(subtable(ms, sub), name)[:]
