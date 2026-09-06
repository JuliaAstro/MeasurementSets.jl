# On-disk data-manager name -> Julia type.
#
# The on-disk `DataManagerInfo.name` is a string, which Julia can't dispatch
# on directly -- these tables are the one unavoidable name -> type lookup,
# isolated here so the actual "open" logic (in each of this directory's
# other files) can be ordinary multiple dispatch: `_dm_instance`
# (`tables/column.jl`) maps the name to a type via `_dmtype`, then calls
# `open(T, t, dm)`, which resolves to the right
# `Base.open(::Type{T}, t::Table, dm::DataManagerInfo)` method.
#
# Both start empty -- each data manager registers itself in its own file
# (e.g. `DATAMANAGERS["StandardStMan"] = StandardStMan` in standard.jl),
# right after its struct definition, once that file is included below.
# `DATAMANAGERS` holds the exact on-disk names; `DATAMANAGER_PATTERNS`
# holds the templated virtual-engine names (casacore C++ template
# instantiations, e.g. `"ScaledArrayEngine<Float,Int>"`, whose exact string
# depends on the scalar types the column was created with and so can't be
# enumerated) as a `Regex` matched by prefix -- see virtual.jl.
const DATAMANAGERS = Dict{String,Type}()
const DATAMANAGER_PATTERNS = Dict{Regex,Type}()

function _dmtype(name::AbstractString)
    T = get(DATAMANAGERS, name, nothing)
    T !== nothing && return T
    for (pattern, S) in DATAMANAGER_PATTERNS
        occursin(pattern, name) && return S
    end
    return nothing
end
