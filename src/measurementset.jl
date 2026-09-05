# MS v2 view over a tree of CTDS tables.

struct MeasurementSet
    path::String
    data::AbstractTable                  # the MAIN table (may be a ConcatTable for an MMS)
    tables::Dict{String,AbstractTable}   # subtable cache, lazily populated
end

"""
    MeasurementSet(path; precision=nothing) -> MeasurementSet

Open the MAIN table of a Measurement Set directory and read its metadata.
Subtables are read on first access via `getproperty` / `subtable`.

`precision` is forwarded to [`readtable`](@ref) for the MAIN table:
`:half` (the default) reads the `TpComplex` visibility columns (`DATA`,
…) as `ComplexF16`, `:full` keeps `ComplexF32`. Subtables always open at
`:full`.
"""
function MeasurementSet(path::AbstractString; precision::Union{Nothing,Symbol}=nothing)
    dir = String(rstrip(path, '/'))
    MeasurementSet(dir, readtable(dir; precision), Dict{String,AbstractTable}())
end

Base.propertynames(ms::MeasurementSet) =
    (:path, :data, :tables, Symbol.(first.(subtables(getfield(ms, :data))))...)

function Base.getproperty(ms::MeasurementSet, s::Symbol)
    s in (:path, :data, :tables) && return getfield(ms, s)
    return subtable(ms, String(s))
end

"""
    subtable(ms, name) -> Table

Read (and cache) the subtable referenced by keyword `name` in MAIN.
"""
function subtable(ms::MeasurementSet, name::String)
    cache = getfield(ms, :tables)
    haskey(cache, name) && return cache[name]
    data = getfield(ms, :data)

    # MMS: a keyword subtable listed in the ConcatTable is itself concatenated
    if data isa ConcatTable && name in data.subtabnames
        subs = AbstractTable[]
        for p in data.parts, (kw, pth) in subtables(p)
            kw == name && (push!(subs, readtable(pth)); break)
        end
        isempty(subs) && throw(KeyError(name))
        off = zeros(Int, length(subs) + 1)
        for (i, s) in enumerate(subs); off[i+1] = off[i] + nrow(s); end
        t = ConcatTable(joinpath(getfield(ms, :path), name), subs, off,
                        String[], "", "", "")
        cache[name] = t
        return t
    end

    for (kw, p) in subtables(data)
        if kw == name
            t = readtable(p)
            cache[name] = t
            return t
        end
    end
    throw(KeyError(name))
end

"""
    subtablenames(ms) -> Vector{String}

The names of `ms`'s subtables (`"ANTENNA"`, `"SPECTRAL_WINDOW"`, …). Open
one with [`subtable`](@ref)`(ms, name)` or `ms.NAME`.
"""
subtablenames(ms::MeasurementSet) = first.(subtables(getfield(ms, :data)))

# `ms[:DATA]` / `ms["DATA"]` -> a lazy column of the MAIN table
Base.getindex(ms::MeasurementSet, name::AbstractString) = getfield(ms, :data)[name]
Base.getindex(ms::MeasurementSet, name::Symbol) = getfield(ms, :data)[name]

function Base.show(io::IO, ms::MeasurementSet)
    print(io, "MeasurementSet(\"", basename(getfield(ms, :path)), "\", ",
          nrow(getfield(ms, :data)), " rows, ",
          length(subtablenames(ms)), " subtables)")
end
