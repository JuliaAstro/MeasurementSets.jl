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


# --- TaQL-lite quantity literals (Phase 69) ----------------------------

# `1.4GHz` -> a Unitful.Quantity (parse-time; errors on an unknown unit)
MS._tql_quantity(num::Real, unit::AbstractString) = num * _ms_uparse(unit)

# attach a column's QuantumUnits so a `col > 1.4GHz` comparison goes
# through Unitful; a unitless column (`u === nothing`) stays plain, so
# `col > 1.4GHz` then raises Unitful's DimensionError (casacore: "units
# do not conform").
MS._tql_unit_attach(col::AbstractVector, u) =
    u === nothing ? col :
    u isa Tuple  ? error("TaQL quantity comparison: column has a mixed unit $u — " *
                         "compare against a plain number instead") :
    col .* u

# a computed `select` / VirtualTaQL result that came out as a Quantity:
# dimensionless -> the plain number; dimensional -> a clear error.
function MS._tql_result_strip(x::Unitful.AbstractQuantity)
    try
        return Unitful.ustrip(Unitful.NoUnits, x)
    catch
        error("a TaQL-lite expression may not yield a dimensional quantity " *
              "($(Unitful.unit(x))) — compare it (`> 1GHz`) or normalise it (`/ 1GHz`)")
    end
end

# an `update!` SET RHS Quantity -> the target column's unit, stripped.
MS._tql_write_strip(x::Unitful.AbstractQuantity, u) =
    u === nothing ?
        error("update!: SET expression yields $(x) but the target column has no unit") :
        Unitful.ustrip(Unitful.uconvert(u, x))

# --- write side: Unitful.Units -> a casacore QuantumUnits string (Phase 70) ---

# casacore-canonical spellings for the compound / non-atomic units the
# `string(u)` heuristic below can't reconstruct (Unitful prints them with
# a space + Unicode superscript). Measures only ever need `m/s` here.
const _MS_USTRING_KNOWN = Dict{Unitful.Units,String}(
    Unitful.u"m/s" => "m/s", Unitful.u"km/s" => "km/s",
    Unitful.u"rad/s" => "rad/s", Unitful.u"m/s^2" => "m/s2")

function MS._ms_ustring(u::Unitful.Units)
    u === Unitful.NoUnits && return ""
    haskey(_MS_USTRING_KNOWN, u) && return _MS_USTRING_KNOWN[u]
    s = string(u)
    if !occursin(' ', s)                                    # atomic unit
        cand = get(MS._UNIT_ALIASES_INV, s, s)
        try
            _ms_uparse(cand) == u && return cand            # verified round-trip
        catch
        end
    end
    error("MeasurementSets: Unitful unit `$u` has no known casacore " *
          "`QuantumUnits` spelling — stamp it explicitly with " *
          "`write_table(...; units = Dict(col => \"...\"))`, or see " *
          "`MeasurementSets.UNITS_NO_JULIA_COUNTERPART`")
end

# a column of `Unitful.Quantity` (scalar or array-cell) -> plain numbers
# in the first element's unit + the `QuantumUnits` string; `nothing` if
# the eltype is not a quantity.
function MS._quantity_column_spec(vals::AbstractVector)
    E = eltype(vals)
    if E <: Unitful.AbstractQuantity
        isempty(vals) && return nothing
        u = Unitful.unit(first(vals))
        return (; data = [Unitful.ustrip(u, v) for v in vals],
                  units = String[MS._ms_ustring(u)])
    elseif E <: AbstractArray && eltype(E) <: Unitful.AbstractQuantity
        (isempty(vals) || isempty(first(vals))) && return nothing
        u = Unitful.unit(first(first(vals)))
        return (; data = [Unitful.ustrip.(u, cell) for cell in vals],
                  units = String[MS._ms_ustring(u)])
    end
    return nothing
end

end # module
