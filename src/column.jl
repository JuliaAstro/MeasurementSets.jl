# Column data access: a lazy `Column <: AbstractVector` that dispatches to
# the bound data manager.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{Table,Dict{Int,Any}}()

_dm_instance(::Table, ::Nothing) = error("column is not bound to a data manager")

function _dm_instance(t::Table, sequ::Int)
    cache = get!(() -> Dict{Int,Any}(), _DM_CACHE, t)
    haskey(cache, sequ) && return cache[sequ]
    dm = t.managers[findfirst(d -> d.sequ == sequ, t.managers)]
    inst = if dm.name in ("StandardStMan", "SSM")
        open_standardstman(t, dm)
    elseif dm.name in ("TiledShapeStMan", "TiledColumnStMan", "TiledCellStMan", "TiledStMan")
        open_tiledstman(t, dm)
    elseif dm.name in ("IncrementalStMan", "ISM")
        open_incrementalstman(t, dm)
    else
        error("data manager \"$(dm.name)\" not yet supported (column data)")
    end
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
    inst = c.inst
    if inst isa StandardStMan
        ssm_getcell(inst, c.index, c.desc, i)
    elseif inst isa TiledStMan
        tsm_getcell(inst, c.index, c.desc, i)
    else
        ism_getcell(inst, c.index, c.desc, i, c.cols)
    end
end

function Base.getindex(c::Column, ::Colon)
    inst = c.inst
    if inst isa StandardStMan
        ssm_getcolumn(inst, c.index, c.desc, c.table.rows)
    elseif inst isa TiledStMan
        tsm_getcolumn(inst, c.index, c.desc, c.table.rows)
    else
        ism_getcolumn(inst, c.index, c.desc, c.table.rows, c.cols)
    end
end

Base.getindex(c::Column, r::AbstractVector{<:Integer}) = [c[i] for i in r]
Base.collect(c::Column) = c[:]

# Rows `r` of `c` as a `Vector{Any}` of plain values / dense `Array`s (lazy
# wrappers collapsed so the reader's nested wrapper types stay out of
# downstream inference).  Per-cell; a whole-column fast path here trips a
# Julia 1.12 codegen bug.
function _read_cells(c::Column, r)
    out = Vector{Any}(undef, length(r))
    @inbounds for (k, i) in enumerate(r)
        v = c[i]
        out[k] = v isa AbstractArray ? Array(v) : v
    end
    return out
end

# --- convenience verbs + indexing ---------------------------------

"""
    getcolumn(t, name) -> Vector / Vector{Array}

Read an entire column's data (eager; equivalent to `column(t, name)[:]`).
"""
getcolumn(t::Table, name::AbstractString) = column(t, name)[:]

"""
    getcell(t, name, row) -> value

Read one cell (`row` is 1-based).
"""
getcell(t::Table, name::AbstractString, row::Integer) = column(t, name)[row]

Base.getindex(t::Table, name::AbstractString) = column(t, name)
Base.getindex(t::Table, name::Symbol) = column(t, String(name))

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    column(subtable(ms, sub), name)[:]
