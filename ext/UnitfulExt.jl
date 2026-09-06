# Physical-unit column reads -- a package extension, loaded automatically
# when the caller has `import`ed Unitful, UnitfulAngles and UnitfulAstro.
#
# Maps casacore `QuantumUnits` strings onto Unitful (+ UnitfulAngles for
# the angle vocabulary, + UnitfulAstro for Jy / pc / AU), and registers
# the dimensionless "pseudo-units" casacore uses (`beam`, `pixel`, …)
# that no third-party Julia package provides.  See `src/tables/units.jl`
# and `MeasurementSets.UNITS_NO_JULIA_COUNTERPART`.

module UnitfulExt

import Unitful
import UnitfulAngles
import UnitfulAstro
import MeasurementSets as MS

# casacore's dimensionless user units.  All `= 1`, no dimension.
module PseudoUnits
using Unitful
@unit beam    "beam"    Beam    1 false
@unit pixel   "pixel"   Pixel   1 false
@unit channel "channel" Channel 1 false
@unit count   "count"   Count   1 false
@unit adu     "adu"     ADU     1 false
@unit lambda  "lambda"  Lambda  1 false
@unit klambda "klambda" KLambda 1000 false
end

const _CTX = [Unitful, UnitfulAngles, UnitfulAstro, PseudoUnits]

function __init__()
    Unitful.register(PseudoUnits)
end

# one casacore unit string -> Unitful.Units (or `Unitful.NoUnits`)
function _ms_uparse(s::AbstractString)
    n = MS._normalize_unit(s)
    isempty(n) && return Unitful.NoUnits
    try
        return Unitful.uparse(n; unit_context = _CTX)
    catch
        hit = get(MS.UNITS_NO_JULIA_COUNTERPART, strip(String(s)), nothing)
        extra = hit === nothing ? "" : " ($(hit.note))"
        error("MeasurementSets: casacore unit \"$s\" has no Unitful equivalent$extra " *
              "— see `MeasurementSets.UNITS_NO_JULIA_COUNTERPART`")
    end
end

# read a column's QuantumUnits keyword -> a Unitful.Units, a Tuple of
# them (a genuinely mixed-unit column), or `nothing` (no unit keyword).
function MS.columnunit(t::MS.AbstractTable, name::AbstractString)
    kw = MS.columndesc(t, name).keywords
    MS.haskey(kw, "QuantumUnits") || return nothing
    strs = String.(kw["QuantumUnits"])
    isempty(strs) && return nothing
    us = map(_ms_uparse, strs)
    all(==(us[1]), us) ? us[1] : Tuple(us)
end

"""
    qcolumn(t, name; precision=nothing) -> Vector

The whole column with its `QuantumUnits` attached as `Unitful` quantities
(materialised — not a lazy `Column`). A column with no unit keyword is
returned unchanged; a mixed-unit column errors — use [`columnunit`](@ref)
and multiply manually.
"""
function MS.qcolumn(t::MS.AbstractTable, name::AbstractString; precision=nothing)
    vals = MS.column(t, name; precision)[:]
    u = MS.columnunit(t, name)
    u === nothing && return vals
    u isa Tuple && error(
        "qcolumn: column \"$name\" has mixed units $u — use `columnunit` and multiply manually")
    return vals .* u
end

end # module
