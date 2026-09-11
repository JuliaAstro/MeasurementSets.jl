# Physical units for column data (casacore `Quanta` / the `QuantumUnits`
# column keyword).  The reader stores `QuantumUnits` as raw strings in
# `columndesc(t, name).keywords`; this file adds the string-normalisation
# layer plus stubs for `columnunit` / `qcolumn`, which get real methods
# from `UnitfulExt` once the caller does
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
# `UnitfulExt`.  The varargs fallbacks here just give a
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

# --- TaQL-lite quantity-literal support (Phase 69). ---------------------
# `_tql_quantity` builds a `Unitful.Quantity` from a parsed `NUMunit`
# literal -- it MUST fail without Unitful (the parser calls it), so the
# core stub errors. `_tql_unit_attach` gets a real method too. The other
# two are working identities in core: a plain (non-`Quantity`) value
# needs no stripping, and without Unitful there are no `Quantity`s.

_tql_quantity(args...) = error(
    "MeasurementSets: TaQL quantity literals (e.g. `1.4GHz`) need Unitful — " *
    "`import Unitful, UnitfulAngles, UnitfulAstro` first")

_tql_unit_attach(args...) = _unitful_load_hint()

# Does `s` look like a unit? -- the discriminator for a *spaced* postfix
# literal (`col > 3 km`).  Core: a small common-unit set (so the common
# case still lexes without Unitful and `_tql_quantity` then gives the
# load hint).  `UnitfulExt` overrides with a full `_ms_uparse` try.
#
# NOTE: the core signature here is deliberately untyped (not
# `s::AbstractString`) -- matching every other stub in this file
# (`_tql_write_strip(x, u)` etc). An extension can only ADD a method,
# never overwrite one with an identical signature (Julia forbids that
# during precompilation); giving the core fallback the exact same
# `::AbstractString` signature the extension wants to specialize on
# was a genuine bug here (surfaced as "Method overwriting is not
# permitted during Module precompilation" whenever Unitful was loaded).
const _COMMON_UNITS = Set([
    "m", "cm", "mm", "km", "au", "pc", "kpc", "mpc", "lyr",
    "s", "ms", "us", "ns", "min", "h", "hr", "d", "day", "yr",
    "hz", "khz", "mhz", "ghz", "thz",
    "rad", "mrad", "deg", "arcmin", "arcsec", "mas", "sr",
    "jy", "mjy", "ujy", "k", "mk", "w", "mw", "kw",
    "g", "kg", "n", "pa", "hpa", "bar", "t", "gauss", "nt",
    "m/s", "km/s", "cm/s", "rad/s"])
_tql_known_unit(s) = lowercase(strip(String(s))) in _COMMON_UNITS

"""Strip a dimensionless `Quantity` result of a TaQL-lite expression to a
plain number; error on a dimensional one. Identity for anything else."""
_tql_result_strip(x) = x

"""Convert/strip a `Quantity` written by an `update!` SET RHS to the
target column's unit `u`. Identity for a plain value."""
_tql_write_strip(x, u) = x

# --- write side: typed columns -> plain numbers + a unit string (Phase 70).
# `_ms_ustring` is the inverse of `_ms_uparse` -- Unitful.Units -> a
# casacore `QuantumUnits` token; real method in `UnitfulExt`.
# `_UNIT_ALIASES_INV` picks the canonical casacore spelling where
# `_UNIT_ALIASES` collapsed several onto one Unitful name.
const _UNIT_ALIASES_INV = Dict{String,String}(
    "arcsecond" => "arcsec", "arcminute" => "arcmin",
    "″" => "arcsec", "′" => "arcmin",        # how UnitfulAngles prints them
    "°" => "deg", "angstrom" => "Angstrom",
    "percent" => "%", "permille" => "%%", "Msun" => "M0")

_ms_ustring(args...) = _unitful_load_hint()

# a column of `Unitful.Quantity` -> (; data = plain numbers, units =
# ["<casacore unit>"]) or `nothing` (not a quantity column). Real method
# in `UnitfulExt`; the core stub (varargs, so the ext's `::AbstractVector`
# method wins) means the writer works with no Unitful.
_quantity_column_spec(args...) = nothing

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
