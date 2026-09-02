# Column data access: a lazy `Column <: AbstractVector` that dispatches to
# the bound data manager.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{CTDSTable,Dict{Int,Any}}()

_dm_instance(::CTDSTable, ::Nothing) = error("column is not bound to a data manager")

function _dm_instance(t::CTDSTable, sequ::Int)
    cache = get!(() -> Dict{Int,Any}(), _DM_CACHE, t)
    haskey(cache, sequ) && return cache[sequ]
    dm = t.managers[findfirst(d -> d.sequ == sequ, t.managers)]
    inst = if dm.name in ("StandardStMan", "SSM")
        open_standardstman(t, dm)
    elseif dm.name in ("TiledShapeStMan", "TiledColumnStMan", "TiledStMan")
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
function _dm_local(t::CTDSTable, c::ColumnDesc)
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
    table::CTDSTable
    desc::ColumnDesc
    inst::Any            # opened data-manager instance
    localidx::Int        # DM-local column index (SSM/ISM)
    ncol::Int            # number of columns bound to the DM instance (ISM)
end

# Best-known element type: a scalar, a fixed-shape Array, or an Array of
# (possibly unknown) dimensionality.
function _eltype(c::ColumnDesc, inst)
    E = juliatype(c.type)
    s = c.shape
    s isa Dims && isempty(s) && return E
    s isa Dims && return Array{E,length(s)}
    if s isa VariableShape && inst isa TiledStMan
        return Array{E, inst.dims - 1}
    end
    return Array{E}
end

"""
    column(t::CTDSTable, name) -> Column

A lazy `AbstractVector` over a column: `col[i]` reads one cell, `col[r]` a
range, `col[:]` the whole column (fast path).
"""
function column(t::CTDSTable, name::AbstractString)
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
        ssm_getcell(inst, c.localidx, c.desc, i)
    elseif inst isa TiledStMan
        tsm_getcell(inst, c.desc, i)
    else
        ism_getcell(inst, c.localidx, c.desc, i, c.ncol)
    end
end

function Base.getindex(c::Column, ::Colon)
    inst = c.inst
    if inst isa StandardStMan
        ssm_getcolumn(inst, c.localidx, c.desc, c.table.rows)
    elseif inst isa TiledStMan
        tsm_getcolumn(inst, c.desc, c.table.rows)
    else
        ism_getcolumn(inst, c.localidx, c.desc, c.table.rows, c.ncol)
    end
end

Base.getindex(c::Column, r::AbstractVector{<:Integer}) = [c[i] for i in r]
Base.collect(c::Column) = c[:]

# --- convenience verbs + indexing ---------------------------------

"""
    getcolumn(t, name) -> Vector / Vector{Array}

Read an entire column's data (eager; equivalent to `column(t, name)[:]`).
"""
getcolumn(t::CTDSTable, name::AbstractString) = column(t, name)[:]

"""
    getcell(t, name, row) -> value

Read one cell (`row` is 1-based).
"""
getcell(t::CTDSTable, name::AbstractString, row::Integer) = column(t, name)[row]

Base.getindex(t::CTDSTable, name::AbstractString) = column(t, name)
Base.getindex(t::CTDSTable, name::Symbol) = column(t, String(name))

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    column(subtable(ms, sub), name)[:]
