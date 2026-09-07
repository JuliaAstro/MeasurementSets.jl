# Concepts

## Tables

[`readtable`](@ref)`(path)` returns one of three [`AbstractTable`](@ref)
kinds. They all answer the same verbs — [`column`](@ref), [`nrow`](@ref),
[`columnnames`](@ref), [`columndesc`](@ref), [`keywords`](@ref),
[`subtables`](@ref) — and are all `Tables.jl` sources.

| kind | what it is |
|------|------------|
| [`Table`](@ref) | a plain on-disk table (the MS MAIN table and every standard subtable) |
| [`RefTable`](@ref) | a persistent row-number reference into a parent table — what a TaQL `SELECT … GIVING '<path>'` writes; reads delegate to the parent |
| [`ConcatTable`](@ref) | a virtual row-wise concatenation of same-schema tables — a MultiMS (MMS) MAIN table |

The query verbs add a fourth, [`GroupedTable`](@ref) — an in-memory
columnar result (from [`query`](@ref) on a result, [`groupby`](@ref), or
`join`). It is *also* an `AbstractTable`, so a pipeline like
`query(groupby(join(...)))` type-checks and each stage feeds the next.

An MS directory is opened as a [`MeasurementSet`](@ref), which wraps the
MAIN [`Table`](@ref) and lazily opens subtables on demand:

```julia
ms = MeasurementSet("/path/to/my.ms")
ms.ANTENNA              # subtable(ms, "ANTENNA")
ms[:DATA]               # a lazy column of MAIN
subtablenames(ms)
```

## Storage managers

A *storage manager* is how casacore lays one column's data out on disk.
MeasurementSets reads and writes all of the ones a real MS uses, and
picks a sensible one for you when you create a table:

| manager | used for |
|---------|----------|
| `StandardStMan` | scalar columns, fixed-shape arrays, strings |
| `IncrementalStMan` | slowly-varying scalar metadata (`TIME`, `FIELD_ID`, …) — "store on change" |
| `TiledShapeStMan` / `TiledColumnStMan` / `TiledCellStMan` | visibility cubes (`DATA`, `FLAG`, `WEIGHT_SPECTRUM`, `UVW`) |
| `DyscoStMan` | lossy-compressed `DATA` / `WEIGHT_SPECTRUM` (the `aroffringa/dysco` format) |
| virtual engines (`ScaledArrayEngine`, `CompressComplex`, …) | a column mapped onto a hidden column of scaled integers |
| `BitFlagsEngine` | an `Array{Bool}` column (e.g. `FLAG`) mapped onto a stored integer, one bit per flag category |
| `ForwardColumnEngine` | a column that forwards every read to a same-named column in another table (see [`reference_copy`](@ref)) |
| `VirtualTaQLColumn` | a column whose per-row value is a stored TaQL-lite CALC expression over the table's own columns (`write_table(...; virtualtaql=Dict("CV" => "TIME - 4.6e9"))`) |

Column data is read lazily — [`column`](@ref) returns a [`Column`](@ref)
(an `AbstractVector`); `col[i]` fetches one cell, `col[:]` takes the
manager's whole-column fast path. You only ever name a manager explicitly
to choose a layout when *creating* a table (`write_table(...; tsm=[...],
ism=[...], engines=..., dysco=..., storage=...)`).

Tables can also be packed into a single `MultiFile` (`table.mf`) or
`MultiHDF5` (`table.mfh5`) container file; [`readtable`](@ref) detects and
resolves through these transparently. `MultiHDF5` needs `HDF5.jl` — do
`import HDF5` first (it is an optional weak dependency).

## The query engine

[`query`](@ref) / [`groupby`](@ref) / `join` / [`update!`](@ref) /
[`taql`](@ref) implement a **deliberate subset of TaQL** — casacore's
Table Query Language. It is enough for real MS filtering, aggregation and
joins, and almost every operator / function / clause it accepts is a
genuine subset of TaQL's own (checked against TaQL's grammar, and
against a live cross-check that runs the same string through both
engines). A few conveniences go beyond TaQL — notably `join`'s
non-equi forms (`on = (lrow, rrow) -> Bool`, or a string
`"L.T BETWEEN R.T0 AND R.T1"`), which TaQL has no equivalent for.

It is *not* a full TaQL implementation. The [Changelog](changelog.md)
(phases 22–31) spells out what each area does and does not support —
briefly: 1-based array element/slice indexing (`DATA[1,1]`, `V[1:4,1]`,
`UVW[-1]`, `V[end-2:end,1]`), `BETWEEN` / `NOT BETWEEN`, bitwise
`& | ^ ~` (`^` = xor), `~=` / `!~=` approximate equality, and
`UPDATE … SET col[i,j] = …` array-slice / boolean-mask
(`SET col[maskexpr] = …`) / `(col, maskcol)` paired assignment, and
computed `query` `select` columns (`"amp" => "sqrt(abs(V))"`), and
masked arrays (`V[boolexpr]`, `marray` / `arraydata` / `arraymask`,
`SELECT expr AS (val, mask)`, masked `g*` / `gs*` aggregates;
reductions skip masked elements) *are* supported. So are array literals
(`[a, b, c]`), scientific-notation numbers (`1.4e9`), **quantity
literals** (`1.4GHz`, `10arcsec` — compared against a column that
carries a `QuantumUnits` keyword; needs the Unitful extension), and
**date/time + angle functions** (`datetime`, `mjd`, `mjdtodate`,
`date`, `time`, `year`/`month`/`day`/`weekday`, `cdate`/`ctime`/…,
`hms`/`dms`, `normangle`, `angdist`/`angdistx` — dates are an MJD
`Float64`). Measures-frame functions (`mscal.azel()` etc.) are still
deferred.

## Physical units

`import Unitful, UnitfulAngles, UnitfulAstro` loads an extension that
maps a column's `QuantumUnits` keyword onto a `Unitful` unit:
`columnunit(t, "CHAN_FREQ")` → `u"Hz"`, `qcolumn(t, "UVW")` → the whole
column as `… m` quantities. `UnitfulAngles` supplies the angle
vocabulary (`arcsec`, `mas`, `°`) and `UnitfulAstro` the astronomy units
(`Jy`, `pc`, `AU`); the extension also registers the dimensionless
"pseudo-units" casacore uses that no Julia package provides (`beam`,
`pixel`, `lambda`, …). Note that angles are **SI-dimensionless** here
(`dimension(u"rad") == NoDims`), unlike casacore where `rad`/`sr` are
base dimensions — angle↔angle and angle↔scalar conversions still work;
use `DimensionfulAngles.jl` for strict casacore-style dimensional
angles. `MeasurementSets.UNITS_NO_JULIA_COUNTERPART` lists every
casacore unit without a third-party Julia implementation and how it is
handled. TaQL unit *literals* (`1.4GHz`) landed in the query engine.

The write side is symmetric: a `write_table` column whose Julia element
type is a `Unitful` quantity (or a `Measure` — see below) is stored as
plain numbers with the right `QuantumUnits` / `MEASINFO` keyword stamped
automatically, so `qcolumn` / `measure` read it straight back.
`write_table(...; units = Dict("CHAN_FREQ" => "Hz"))` stamps the keyword
explicitly (and overrides the auto-detection for that column).

## Reference frames (measures)

A measure-valued column declares its physical quantity and reference
frame in a `MEASINFO` keyword — `TIME` is an epoch in `UTC`, `UVW` a
baseline in `ITRF`, `ANTENNA.POSITION` a position in `ITRF`,
`FIELD.PHASE_DIR` a direction whose frame is a per-row code
(`VarRefCol`), `SPECTRAL_WINDOW.CHAN_FREQ` a frequency likewise.

`measinfo(t, col)` parses that keyword; `measure(t, col[, row])` reads a
cell as a typed value — [`MEpoch`](@ref) (MJD days), [`MDirection`](@ref)
(radians), [`MPosition`](@ref) (metres), [`MFrequency`](@ref) (Hz) —
carrying its frame as a type parameter (`MEpoch{UTC}`,
`MDirection{J2000}`).

Writing is symmetric: a `write_table` column of `Measure` values
(`[MEpoch{UTC}(...) for ...]`) is stored as plain numbers in the
canonical unit (epoch → seconds, direction → radians, …) with the
`MEASINFO` + `QuantumUnits` keyword stamped — no `measures=` kwarg
needed. The auto path is fixed-`Ref` only (from the first row's frame);
a per-row `VarRefCol` still needs an explicit `measures=` entry.

`import SOFA` loads an extension that converts between frames:

```julia
import SOFA, EarthOrientation          # SOFA alone works; EO adds ΔUT1 / polar motion

fr = MeasFrame(epoch    = measure(main, "TIME", 1),
               position = measure(subtable(ms, "ANTENNA"), "POSITION", 1),
               direction = measure(subtable(ms, "FIELD"), "PHASE_DIR", 1))

measconvert(measure(main, "TIME", 1), TAI)            # UTC → TAI
measconvert(MDirection{J2000}(2.0, 0.5), AZEL; frame = fr)
measconvert(MFrequency{TOPO}(100e9), LSRK; frame = fr)
```

- **Epoch**: `UTC` / `TAI` / `TT` / `TDB` / `UT1`.
- **Direction**: `J2000` / `ICRS` / `B1950` / `APP` / `GALACTIC` /
  `ECLIPTIC` / `AZEL` / `AZELGEO` / `HADEC` / `ITRF`.
- **Frequency**: `TOPO` / `GEO` / `BARY` / `LSRK` / `LSRD` / `GALACTO`.

Backed by the pure-Julia [`SOFA.jl`](https://github.com/JuliaAstro/SOFA.jl)
(v2, IAU SOFA port). Without `EarthOrientation.jl` the conversions run at
~1 arcsecond (ΔUT1 = 0, no polar motion) with a one-time warning. `J2000`
is treated as `ICRS` (a ~0.02″ frame-bias simplification). Solar-system
bodies as direction frames, `MeasComet` / ephemeris tables, and
pulsar-timing-grade precision are out of scope. TaQL date/time and
angle functions landed in the query engine (see above); measures
*frame-conversion* functions (`mscal.azel()`) remain deferred.

The write path takes a `measures =` keyword on
[`write_table`](@ref) — `Dict("D" => (; kind = :direction, ref =
"J2000"))` or the per-row `(; kind, varrefcol, tabtypes, tabcodes)`
form — and `copyms` / `copytable` round-trip a column's `MEASINFO`
verbatim.
