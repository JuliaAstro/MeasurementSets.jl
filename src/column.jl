# Column data access: a lazy `Column <: AbstractVector` that dispatches to
# the bound data manager.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{Table,Dict{Int,Any}}()

_dm_instance(::Table, ::Nothing) = error("column is not bound to a data manager")

# The on-disk `DataManagerInfo.name` is a string, which Julia can't dispatch
# on directly -- this is the one unavoidable name -> type lookup, isolated
# here so the actual "open" logic can be ordinary multiple dispatch (see the
# `Base.open(::Type{<:...}, t::Table, dm::DataManagerInfo)` methods in
# datamanagers/{standard,tiled,incremental,virtual,dysco}.jl).  Every *exact*
# on-disk name -- including the three non-templated virtual engines -- has an
# entry; the templated engine names (`"ScaledArrayEngine<Float,Int>"` and
# friends, which can't be enumerated) fall back to `_is_engine_dm`'s prefix
# check on a `KeyError`.
const DATAMANAGERS = Dict{String,Type}(
    "StandardStMan"     => StandardStMan,
    "SSM"               => StandardStMan,
    "TiledShapeStMan"   => TiledStMan,
    "TiledColumnStMan"  => TiledStMan,
    "TiledCellStMan"    => TiledStMan,
    "TiledStMan"        => TiledStMan,
    "IncrementalStMan"  => IncrementalStMan,
    "ISM"               => IncrementalStMan,
    "DyscoStMan"        => DyscoStMan,
    "CompressFloat"     => VirtualEngine,
    "CompressComplex"   => VirtualEngine,
    "CompressComplexSD" => VirtualEngine,
)

function _dmtype(name::AbstractString)
    try
        return DATAMANAGERS[name]
    catch e
        e isa KeyError || rethrow()
        _is_engine_dm(name) && return VirtualEngine
        return nothing
    end
end

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

struct Column{T} <: AbstractVector{T}
    table::Table
    desc::ColumnDesc
    inst::Any            # opened data-manager instance
    index::Int           # DM-local column index (SSM/ISM)
    cols::Int            # number of columns bound to the DM instance (ISM)
end

# Best-known element type: a scalar, a fixed-shape Array, or an Array of
# (possibly unknown) dimensionality.
function _eltype(c::ColumnDesc, inst)
    E = juliatype(c.type)
    s = c.shape
    s isa Dims && isempty(s) && return E
    s isa Dims && return Array{E,length(s)}
    if s isa VariableShape && inst isa TiledStMan
        nd = inst.kind === :cell ? inst.dims : inst.dims - 1
        return Array{E, nd}
    end
    return Array{E}
end

_eltype(c::ColumnDesc, ::VirtualEngine) = Array{juliatype(c.type)}

"""
    column(t::Table, name) -> Column

A lazy `AbstractVector` over a column: `col[i]` reads one cell, `col[r]` a
range, `col[:]` the whole column (fast path).
"""
function column(t::Table, name::AbstractString)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.sequ)
    idx, n = _dm_local(t, c)
    Column{_eltype(c, inst)}(t, c, inst, idx, n)
end

Base.size(c::Column) = (c.table.rows,)
Base.IndexStyle(::Type{<:Column}) = IndexLinear()

function Base.getindex(c::Column, i::Int)
    @boundscheck checkbounds(c, i)
    getcell(c.inst, c.index, c.desc, i, c.cols)
end

function Base.getindex(c::Column, ::Colon)
    getcolumn(c.inst, c.index, c.desc, c.table.rows, c.cols)
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

function column(t::RefTable, name::AbstractString)
    haskey(t.namemap, name) || throw(KeyError(name))
    pc = column(t.parent, t.namemap[name])
    MappedColumn{eltype(pc),typeof(pc)}(pc, t.rows)
end

function column(t::ConcatTable, name::AbstractString)
    pcs = AbstractVector[column(p, name) for p in t.parts]
    T = mapreduce(eltype, typejoin, pcs)
    ConcatColumn{T}(pcs, t.offsets)
end

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
    getcolumn(t, name) -> Vector / Vector{Array}

Read an entire column's data (eager; equivalent to `column(t, name)[:]`).
"""
getcolumn(t::AbstractTable, name::AbstractString) = column(t, name)[:]

"""
    getcell(t, name, row) -> value

Read one cell (`row` is 1-based).
"""
getcell(t::AbstractTable, name::AbstractString, row::Integer) = column(t, name)[row]

Base.getindex(t::AbstractTable, name::AbstractString) = column(t, name)
Base.getindex(t::AbstractTable, name::Symbol) = column(t, String(name))

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    column(subtable(ms, sub), name)[:]
