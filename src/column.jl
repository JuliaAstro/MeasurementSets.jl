# Column data access: resolve a column to its data manager and dispatch.

# cache opened data-manager instances on the table
const _DM_CACHE = IdDict{CTDSTable,Dict{Int,Any}}()

function _dm_instance(t::CTDSTable, seqnr::Int)
    cache = get!(() -> Dict{Int,Any}(), _DM_CACHE, t)
    haskey(cache, seqnr) && return cache[seqnr]
    dm = t.datamanagers[findfirst(d -> d.seqnr == seqnr, t.datamanagers)]
    inst = if dm.name in ("StandardStMan", "SSM")
        open_standardstman(t, dm)
    else
        error("data manager \"$(dm.name)\" not yet supported (column data)")
    end
    cache[seqnr] = inst
    return inst
end

# 0-based index of a column among those bound to the same DM instance
function _ssm_local_index(t::CTDSTable, c::ColumnDesc)
    i = 0
    for x in t.desc.columns
        x === c && return i
        x.seqnr == c.seqnr && (i += 1)
    end
    error("column not found")
end

"""
    getcolumn(t::CTDSTable, name) -> Vector / Vector{Array}

Read an entire column's data.
"""
function getcolumn(t::CTDSTable, name::AbstractString)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.seqnr)
    inst isa StandardStMan ||
        error("column \"$name\" uses $(typeof(inst)); not supported yet")
    ssm_getcolumn(inst, _ssm_local_index(t, c), c, t.nrow)
end

"""
    getcell(t::CTDSTable, name, row) -> value

Read one cell (`row` is 1-based).
"""
function getcell(t::CTDSTable, name::AbstractString, row::Integer)
    c = columndesc(t, name)
    inst = _dm_instance(t, c.seqnr)
    inst isa StandardStMan ||
        error("column \"$name\" uses $(typeof(inst)); not supported yet")
    ssm_getcell(inst, _ssm_local_index(t, c), c, row - 1)
end

getcolumn(ms::MeasurementSet, sub::AbstractString, name::AbstractString) =
    getcolumn(subtable(ms, sub), name)
