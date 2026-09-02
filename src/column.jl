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
    elseif dm.name in ("IncrementalStMan", "ISM")
        open_incrementalstman(t, dm)
    else
        error("data manager \"$(dm.name)\" not yet supported (column data)")
    end
    cache[sequ] = inst
    return inst
end

# 1-based position of column `c` among those bound to the same DM instance,
# and the total number bound to it
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

"""
    getcolumn(t::CTDSTable, name) -> Vector / Vector{Array}

Read an entire column's data.
"""
function getcolumn(t::CTDSTable, name::AbstractString)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.sequ)
    if inst isa StandardStMan
        ssm_getcolumn(inst, first(_dm_local(t, c)), c, t.rows)
    elseif inst isa TiledStMan
        tsm_getcolumn(inst, c, t.rows)
    elseif inst isa IncrementalStMan
        idx, n = _dm_local(t, c)
        ism_getcolumn(inst, idx, c, t.rows, n)
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
        ssm_getcell(inst, first(_dm_local(t, c)), c, row)
    elseif inst isa TiledStMan
        tsm_getcell(inst, c, row)
    elseif inst isa IncrementalStMan
        idx, n = _dm_local(t, c)
        ism_getcell(inst, idx, c, row, n)
    else
        error("column \"$name\" uses $(typeof(inst)); not supported yet")
    end
end

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    getcolumn(subtable(ms, sub), name)
