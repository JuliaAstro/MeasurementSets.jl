# MS v2 view over a tree of CTDS tables.

struct MeasurementSet
    path::String
    data::CTDSTable                     # the MAIN table
    tables::Dict{String,CTDSTable}      # subtable cache, lazily populated
end

"""
    MeasurementSet(path) -> MeasurementSet

Open the MAIN table of a Measurement Set directory and read its metadata.
Subtables are read on first access via `getproperty` / `subtable`.
"""
function MeasurementSet(path::AbstractString)
    dir = String(rstrip(path, '/'))
    MeasurementSet(dir, readtable(dir), Dict{String,CTDSTable}())
end

Base.propertynames(ms::MeasurementSet) =
    (:path, :data, :tables, Symbol.(first.(subtables(getfield(ms, :data))))...)

function Base.getproperty(ms::MeasurementSet, s::Symbol)
    s in (:path, :data, :tables) && return getfield(ms, s)
    return subtable(ms, String(s))
end

"""
    subtable(ms, name) -> CTDSTable

Read (and cache) the subtable referenced by keyword `name` in MAIN.
"""
function subtable(ms::MeasurementSet, name::String)
    cache = getfield(ms, :tables)
    haskey(cache, name) && return cache[name]
    for (kw, p) in subtables(getfield(ms, :data))
        if kw == name
            t = readtable(p)
            cache[name] = t
            return t
        end
    end
    throw(KeyError(name))
end

subtablenames(ms::MeasurementSet) = first.(subtables(getfield(ms, :data)))

# `ms[:DATA]` / `ms["DATA"]` -> a lazy column of the MAIN table
Base.getindex(ms::MeasurementSet, name::AbstractString) = getfield(ms, :data)[name]
Base.getindex(ms::MeasurementSet, name::Symbol) = getfield(ms, :data)[name]

function Base.show(io::IO, ms::MeasurementSet)
    print(io, "MeasurementSet(\"", basename(getfield(ms, :path)), "\", ",
          getfield(ms, :data).rows, " rows, ",
          length(subtablenames(ms)), " subtables)")
end
