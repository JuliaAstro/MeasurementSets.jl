# Physical units for column data (casacore `Quanta` / the `QuantumUnits`
# column keyword).  The reader stores `QuantumUnits` as raw strings in
# `columndesc(t, name).keywords`; this file adds the string-normalisation
# layer plus stubs for `columnunit` / `qcolumn`, which get real methods
# from `MeasurementSetsUnitfulExt` once the caller does
#
#     import Unitful, UnitfulAngles, UnitfulAstro
#
# The extension maps casacore units onto `Unitful` + `UnitfulAngles`
# (angle vocabulary: `arcsec`, `mas`, `°`) + `UnitfulAstro` (`Jy`, `pc`,
# `AU`).  NOTE: `UnitfulAngles` keeps angles SI-dimensionless
# (`dimension(u"rad") == NoDims`), unlike casacore where `rad` / `sr`
# are base dimensions -- the unit *names* and all angle<->angle /
# angle<->scalar conversions still work; use `DimensionfulAngles.jl` if
# you need strict casacore-style dimensional angles.

# casacore unit string -> a `Unitful.uparse`-able string.  Applied
# token-wise by `_normalize_unit` (after `.` -> `*`).
const _UNIT_ALIASES = Dict{String,String}(
    "%"        => "percent",
    "%%"       => "permille",
    "arcsec"   => "arcsecond",
    "as"       => "arcsecond",        # casacore alias
    "arcmin"   => "arcminute",
    "AE"       => "AU", "UA" => "AU",  # casacore spellings of the astronomical unit
    "M0"       => "Msun",
    "Angstrom" => "angstrom",
    "deg"      => "°",                # UnitfulAngles spells degree as `°`
)

"""
    _normalize_unit(s) -> String

Turn a casacore `QuantumUnits` string into one `Unitful.uparse` accepts:
trim, `"." -> "*"` (casacore multiply), whole-token alias substitution,
and map casacore's dimensionless markers (`""`, `" "`, `"_"`) to `""`.
"""
function _normalize_unit(s::AbstractString)
    t = strip(String(s))
    (isempty(t) || t == "_" || t == "_2") && return ""
    t = replace(t, "." => "*")
    # substitute whole tokens (letters/digits/°/µ runs) via the alias map
    return replace(t, r"[A-Za-z°µ%]+" => m -> get(_UNIT_ALIASES, m, m))
end

# `columnunit` / `qcolumn` get their real (table, name) methods from
# `MeasurementSetsUnitfulExt`.  The varargs fallbacks here just give a
# clear "load Unitful" message; the extension's methods are strictly
# more specific, so they win with no method-overwrite clash.
_unitful_load_hint() = error(
    "MeasurementSets: physical units need Unitful — " *
    "`import Unitful, UnitfulAngles, UnitfulAstro` first")

"""
    columnunit(t, name) -> Unitful.Units | Tuple | nothing

The physical unit of column `name`, from its `QuantumUnits` keyword,
as a `Unitful` unit. `nothing` when the column has no unit keyword; a
`Tuple` for a genuinely mixed-unit column. Needs the Unitful extension —
`import Unitful, UnitfulAngles, UnitfulAstro`.
"""
columnunit(args...; kwargs...) = _unitful_load_hint()

"""
    qcolumn(t, name; precision=nothing) -> Vector

The whole column with its unit attached as `Unitful` quantities
(materialised, not a lazy [`Column`](@ref)). A unitless column is
returned unchanged. Needs the Unitful extension.
"""
qcolumn(args...; kwargs...) = _unitful_load_hint()

"""
    UNITS_NO_JULIA_COUNTERPART

casacore units that no third-party Julia package (Unitful / UnitfulAngles
/ UnitfulAstro) implements, and how `MeasurementSets` handles each:

* `:pseudo` — registered as a **dimensionless** unit by the Unitful
  extension (so `Jy/beam` parses to `Jy beam⁻¹`, dimensionally `Jy`).
* `:nounits` — mapped to `Unitful.NoUnits` (casacore's canonical
  dimensionless markers).
* `:unsupported` — raises a clear error; use the suggested replacement.
* `:dimension` — exists in Unitful but with a different *dimension*
  than casacore (casacore treats it as a base dimension).
"""
const UNITS_NO_JULIA_COUNTERPART = Dict{String,NamedTuple{(:kind, :note),Tuple{Symbol,String}}}(
    "beam"    => (kind=:pseudo,      note="Jy/beam -- dimensionless 'per beam'"),
    "pixel"   => (kind=:pseudo,      note="Jy/pixel -- dimensionless 'per pixel'"),
    "channel" => (kind=:pseudo,      note="dimensionless spectral-channel count"),
    "count"   => (kind=:pseudo,      note="detector counts"),
    "adu"     => (kind=:pseudo,      note="analog-to-digital units"),
    "lambda"  => (kind=:pseudo,      note="uv distance in wavelengths (dimensionless)"),
    "klambda" => (kind=:pseudo,      note="1000 * lambda"),
    "_"       => (kind=:nounits,     note="casacore's 'undimensioned' marker"),
    ""        => (kind=:nounits,     note="empty unit string"),
    "WU"      => (kind=:unsupported, note="Westerbork flux Unit (0.05 Jy) -- write '0.05Jy'"),
    "FU"      => (kind=:unsupported, note="obscure flux unit -- write 'Jy'"),
    "fu"      => (kind=:unsupported, note="obscure flux unit -- write 'Jy'"),
    "cy"      => (kind=:unsupported, note="casacore century -- write '100yr'"),
    "deg_2"   => (kind=:unsupported, note="casacore squared-degree -- write '°^2'"),
    "sq_deg"  => (kind=:unsupported, note="squared degree -- write '°^2'"),
    "rad"     => (kind=:dimension,   note="dimensionless here; a base dimension in casacore"),
    "sr"      => (kind=:dimension,   note="dimensionless here; a base dimension in casacore"),
)
