# MS v2 view over a tree of CTDS tables.

struct MeasurementSet
    path::String
    main::CTDSTable
    subtables::Dict{String,CTDSTable}       # lazily populated
end

"""
    MeasurementSet(path) -> MeasurementSet

Open the MAIN table of a Measurement Set directory and read its metadata.
Subtables are read on first access via `getproperty` / `subtable`.
"""
function MeasurementSet(path::AbstractString)
    dir = String(rstrip(path, '/'))
    main = readtable(dir)
    MeasurementSet(dir, main, Dict{String,CTDSTable}())
end

Base.propertynames(ms::MeasurementSet) =
    (:path, :main, :subtables, Symbol.(first.(subtables(ms.main)))...)

function Base.getproperty(ms::MeasurementSet, s::Symbol)
    s in (:path, :main, :subtables) && return getfield(ms, s)
    return subtable(ms, String(s))
end

"""
    subtable(ms, name) -> CTDSTable

Read (and cache) the subtable referenced by keyword `name` in MAIN.
"""
function subtable(ms::MeasurementSet, name::String)
    cache = getfield(ms, :subtables)
    haskey(cache, name) && return cache[name]
    for (kw, p) in subtables(getfield(ms, :main))
        if kw == name
            t = readtable(p)
            cache[name] = t
            return t
        end
    end
    throw(KeyError(name))
end

subtablenames(ms::MeasurementSet) = first.(subtables(getfield(ms, :main)))

function Base.show(io::IO, ms::MeasurementSet)
    m = getfield(ms, :main)
    print(io, "MeasurementSet(\"", basename(getfield(ms, :path)), "\", ",
          m.rows, " rows, ", length(subtablenames(ms)), " subtables)")
end
