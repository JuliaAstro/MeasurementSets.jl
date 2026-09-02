# Column data access: resolve a column to its data manager and dispatch.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{CTDSTable,Dict{Int,Any}}()

function _dm_instance(t::CTDSTable, sequ::Nothing)
    error("column is not bound to a data manager")
end

function _dm_instance(t::CTDSTable, sequ::Int)
    cache = get!(() -> Dict{Int,Any}(), _DM_CACHE, t)
    haskey(cache, sequ) && return cache[sequ]
    dm = t.managers[findfirst(d -> d.sequ == sequ, t.managers)]
    inst = if dm.name in ("StandardStMan", "SSM")
        open_standardstman(t, dm)
    elseif dm.name in ("TiledShapeStMan", "TiledColumnStMan", "TiledStMan")
        open_tiledstman(t, dm)
    else
        error("data manager \"$(dm.name)\" not yet supported (column data)")
    end
    cache[sequ] = inst
    return inst
end

# 1-based position of a column among those bound to the same DM instance
function _dm_local_index(t::CTDSTable, c::ColumnDesc)
    i = 1
    for x in t.desc.columns
        x === c && return i
        x.sequ == c.sequ && (i += 1)
    end
    error("column not found")
end

"""
    getcolumn(t::CTDSTable, name) -> Vector / Vector{Array}

Read an entire column's data.
"""
function getcolumn(t::CTDSTable, name::AbstractString)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.sequ)
    if inst isa StandardStMan
        ssm_getcolumn(inst, _dm_local_index(t, c), c, t.rows)
    elseif inst isa TiledStMan
        tsm_getcolumn(inst, c, t.rows)
    else
        error("column \"$name\" uses $(typeof(inst)); not supported yet")
    end
end

"""
    getcell(t::CTDSTable, name, row) -> value

Read one cell (`row` is 1-based).
"""
function getcell(t::CTDSTable, name::AbstractString, row::Integer)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.sequ)
    if inst isa StandardStMan
        ssm_getcell(inst, _dm_local_index(t, c), c, row)
    elseif inst isa TiledStMan
        tsm_getcell(inst, c, row)
    else
        error("column \"$name\" uses $(typeof(inst)); not supported yet")
    end
end

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    getcolumn(subtable(ms, sub), name)
