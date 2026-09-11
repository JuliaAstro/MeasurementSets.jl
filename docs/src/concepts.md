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
carries a `QuantumUnits` keyword; needs the Unitful extension),
**sexagesimal literals** (`10h30m`, `45d51m16s`, `12h`, `45d` → radians;
`h` = hour angle ×15, `d` = degrees), and
**date/time + angle functions** (`datetime`, `mjd`, `mjdtodate`,
`date`, `time`, `year`/`month`/`day`/`weekday`, `cdate`/`ctime`/…,
`hms`/`dms`, `angle` (sexagesimal `'10h30m'` → radians), `normangle`,
`angdist`/`angdistx` — dates are an MJD
`Float64`). With `import SOFA`, **`mscal.*` derived-MS functions** —
`mscal.ha1()` / `mscal.hadec1()` / `mscal.azel1()` / `mscal.az1()` /
`mscal.el1()` / `mscal.pa1()` (parallactic angle) / `mscal.last1()`
(local sidereal time) / `mscal.itrf()` / `mscal.uvw_j2000()` /
`mscal.delay()` — computed per MAIN row from `TIME` + the `ANTENNA` /
`FIELD` subtables (`query(main, "mscal.el1() > 0.3")`,
`groupby(main, "FIELD_ID"; select = ["az" => "gmean(mscal.az1())"])`).
The direction functions take an optional direction argument — a body
name (`mscal.el1('SUN')`), a FIELD direction column
(`mscal.az1('DELAY_DIR')`), a `[ra, dec]` J2000 pair (radians), or a
sexagesimal `'RA, DEC'` string (`mscal.el1('10h42m31, 45d51m16')`).
`mscal.stokes(col [, 'types'] [, rescale])` converts a `DATA` / `FLAG` /
`WEIGHT` array cell between correlation bases (`'IQUV'` / `'CIRC'` /
`'LIN'` / a comma-list), keyed by `POLARIZATION.CORR_TYPE`.
`mscal.<sel>('spec')` (`baseline` / `field` / `spw` / `scan` / `state` /
`array` / `obs`) is MSSelection-lite row selection — a comma-list of
ids / `N~M` ranges / name globs, `!` to subtract, `L & R` (cross only) /
`L && R` (cross + auto) / `L &&&` (auto only) baselines
(`query(main, "mscal.baseline('ea01 & *') AND mscal.field('3C*')")`).
`mscal.baseline` also takes a physical baseline-length range/bound with
no `&` (`'100~500m'` / `'<200m'` / `'>1km'`, from `ANTENNA.POSITION`).
`mscal.time('t0~t1')` (ISO / `YYYY/MM/DD` endpoints) and
`mscal.uvdist('a~b[m|km|klambda|…]')` select `TIME` / 2-D uv-distance
ranges. `mscal.spw('0:5~20')` takes an optional `:chanlist` (channel
index ranges `a~b`/`a~b^step` or `CHAN_FREQ` ranges `f1~f2GHz`);
`mscal.chan('0:5~20')` returns the per-row selected-channel `BitVector`.
`mscal.corr('RR,LL')` (polarization-setup match) and `mscal.feed('0 & 1')`
(the `mscal.baseline` form on `FEED1`/`FEED2`) round out the selection
set.  **`mscal.pbresponse('gaussian:HPBW' | 'airy:D:FREQ[:BLK]' [, dir])`**
(a MeasurementSets extension, not a real `derivedmscal` UDF) is the
[`GaussianBeam`](@ref) / [`AiryBeam`](@ref) power response toward `dir`
(default `FIELD.PHASE_DIR`) as seen through ANTENNA1's *actual* pointing
(`POINTING.DIRECTION`) — the attenuation from a pointing/tracking error,
computed automatically from the row's `TIME`/`ANTENNA1`/`FIELD_ID`
geometry, matching how `mscal.azel1()` etc. work.  **`meas.*`** (a
subset of casacore's `libmeas` UDFs) does measure
conversions on ordinary expressions:
`meas.<frame>(['SRC', ]lon, lat[, mjd[, x, y, z]])` →
`[lon, lat]` in `j2000` / `b1950` / `app` / `galactic` / `ecliptic` /
`azel` / `hadec` / `itrf`; `meas.epoch('TAI', mjd)` converts a time
scale; `meas.last(mjd, x, y, z)` is the local apparent sidereal time.

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
`uvw` coordinate in `ITRF`, `ANTENNA.POSITION` a position in `ITRF`,
`FIELD.PHASE_DIR` a direction whose frame is a per-row code
(`VarRefCol`), `SPECTRAL_WINDOW.CHAN_FREQ` a frequency likewise.

`measinfo(t, col)` parses that keyword; `measure(t, col[, row])` reads a
cell as a typed value — [`MEpoch`](@ref) (MJD days), [`MDirection`](@ref)
(radians), [`MPosition`](@ref) (metres), [`MFrequency`](@ref) (Hz),
[`MuvW`](@ref) / [`MBaseline`](@ref) (metres) — carrying its frame as a
type parameter (`MEpoch{UTC}`, `MDirection{J2000}`, `MuvW{ITRF}`).

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
measconvert(MRadialVelocity{LSRK}(2e4), BARY; frame = fr)
measconvert(measure(main, "UVW", 1), J2000; frame = fr)   # uvw needs frame.direction
```

- **Epoch**: `UTC` / `TAI` / `TT` / `TDB` / `UT1`.
- **Direction**: `J2000` / `ICRS` / `B1950` / `APP` / `GALACTIC` /
  `ECLIPTIC` / `AZEL` / `AZELGEO` / `HADEC` / `ITRF`.
- **Frequency** and **radial velocity**: `TOPO` / `GEO` / `BARY` /
  `LSRK` / `LSRD` / `GALACTO` / `LGROUP` (Local Group, ~308 km/s) /
  `CMB` (CMB dipole, ~369.5 km/s).
- **Baseline** ([`MBaseline`](@ref)) and **uvw** ([`MuvW`](@ref), the
  `UVW` column): rotated between any direction frame; a `uvw` conversion
  also needs `frame.direction` (the phase centre) for the pole rotation.
- **Earth magnetic field** ([`MEarthMagnetic`](@ref), nano-tesla):
  [`earthfield(pos, epoch)`](@ref) evaluates the bundled IGRF-14 model
  (a direct port of casacore's `EarthField::calcField` spherical-harmonic
  synthesis, coefficients 1900–2030) at an ITRF position; a field vector
  rotates between direction frames like a plain vector.
  `measconvert(MEarthMagnetic{IGRF}(...), R; frame)` evaluates the model
  at `frame.position` / `frame.epoch` and rotates to `R`. casacore ships
  IGRF-12, so a cross-check differs by ~100–200 nT (model generation).
  [`EarthMagneticMachine`](@ref)`(height, pos, epoch)` (or
  [`emm_lineofsight`](@ref)) gives the field where the line of sight to a
  source pierces a shell `height` metres up.
  [`rotation_measure`](@ref)`(dir, epoch, pos; stec)` folds that with a
  slant TEC into an ionospheric RM (rad/m²) — thin-shell
  `RM_IONOSPHERE · STEC · B∥`; [`faraday_rotation`](@ref)`(rm, freq)` is
  the resulting `RM·λ²` polarization-angle rotation and
  [`derotate_angle`](@ref) removes it.

- **Solar-system body** (`SUN` / `MOON` / `MERCURY` / `VENUS` / `MARS`
  / `JUPITER` / `SATURN` / `URANUS` / `NEPTUNE`): a `FIELD.PHASE_DIR`
  column can name a body as its frame (a moving target). `measure()`
  reads it as `MDirection{SUN}` (the stored `(lon, lat)` is a
  placeholder); `measconvert(MDirection{SUN}(0,0), AZEL; frame)`
  resolves the body's geocentric apparent place via `SOFA.plan94` /
  `moon98` — accuracy ~arcsec (Sun / Moon / Venus / Mercury) to ~arcmin
  (Jupiter / Saturn). The Moon's topocentric parallax is applied when
  `frame.position` is set. Body frames are source-only (you cannot
  convert a direction *to* one). `PLUTO` has no `plan94` entry.

- **Ephemeris (`MeasComet`) tables**: a `FIELD` row with a non-negative
  `EPHEMERIS_ID` points at an `EPHEM<id>_*.tab` polynomial position
  table in the FIELD subtable directory. [`field_ephemeris`](@ref)
  opens it; [`ephemeris_direction`](@ref) / `_radvel` / `_distance`
  evaluate it (linear interpolation of the bracketing rows, matching
  casacore's `MeasComet::get`); `measure(fld, "PHASE_DIR", row; epoch)`
  and the `mscal.*` functions use it automatically for a moving-target
  field. Sub-arcmin, so it supersedes `plan94` when a real ephemeris is
  present. A `FIELD` with `NUM_POLY > 0` (a `(2, NUM_POLY+1)` `PHASE_DIR`
  cell) is evaluated as a time polynomial about `FIELD.TIME`;
  [`ephemeris_diskpos`](@ref) gives the sub-observer point on the body
  from the table's optional `DiskLong` / `DiskLat` columns.

- **Observatories**: [`observatory("VLA")`](@ref) returns the ITRF
  position of a known telescope (a bundled snapshot of casacore's
  `Observatories` data table — VLA / ALMA / ATCA / GBT / WSRT / GMRT /
  MeerKAT / … ~50 entries). Used as the array-centre reference for the
  suffix-less `mscal.ha()` / `mscal.azel()` / … (keyed by
  `OBSERVATION.TELESCOPE_NAME`).

Backed by the pure-Julia [`SOFA.jl`](https://github.com/JuliaAstro/SOFA.jl)
(v2, IAU SOFA port). Without `EarthOrientation.jl` the conversions run at
~1 arcsecond (ΔUT1 = 0, no polar motion) with a one-time warning. `J2000`
is treated as `ICRS` (a ~0.02″ frame-bias simplification). `MeasComet` /
ephemeris tables and pulsar-timing-grade precision are out of scope.
TaQL date/time / angle functions and the `mscal.*` derived-MS functions
landed in the query engine (see above).

The write path takes a `measures =` keyword on
[`write_table`](@ref) — `Dict("D" => (; kind = :direction, ref =
"J2000"))` or the per-row `(; kind, varrefcol, tabtypes, tabcodes)`
form — and `copyms` / `copytable` round-trip a column's `MEASINFO`
verbatim.

**Doppler shifts** are the other spectral axis — the *convention*
(`RADIO` / `OPTICAL` / `RATIO` / `BETA` / `GAMMA`) rather than a
reference frame. `MDoppler{RADIO}(0.01)`; `measconvert(d, OPTICAL)`
changes convention (pure algebra — no `SOFA`); and, given a rest
frequency, `doppler(f, ν₀)` / `frequency(d, ν₀)` / `restfrequency(f, d)`
bridge to/from [`MFrequency`](@ref), `doppler(v)` / `radialvelocity(d)`
to/from [`MRadialVelocity`](@ref). A Doppler value is frame-agnostic —
`measconvert` the frequency to the frame you want *first*, then bridge.

The bridge functions broadcast, so a whole spectral axis is one call —
`radialvelocity.(measure(spw, "CHAN_FREQ", 1), ν₀)` is the velocity of
each channel of a spectral window relative to a line rest frequency.
`shiftfreq(d, νs)` multiplies a frequency grid by the Doppler factor
`√((1−β)/(1+β))` (casacore `MDoppler::shiftFrequency`).

## Primary beams

Analytic primary-beam (voltage/power pattern) models for the apparent-
flux attenuation of a source away from the pointing centre — a
standalone MeasurementSets feature (no casacore/CASA source is vendored
on this machine for a real telescope's fitted polynomial coefficient
table, so none are bundled).
[`GaussianBeam`](@ref)`(freq; diameter)` — `HPBW = 1.02λ/D` — and
[`AiryBeam`](@ref)`(diameter; blockage)` — the diffraction pattern of a
(optionally centrally obstructed) circular aperture, via
`SpecialFunctions.besselj1` — are textbook optics, independently
verifiable. [`PolynomialBeam`](@ref) is the CASA `PBMath1DPoly`
functional form (`pb = 1 + Σ cₖ·(ν[GHz]·θ[arcmin])^(2k)`) for a
caller-supplied coefficient table. Every model implements
[`power_response`](@ref)`(beam, θ, freq)`; [`voltage_response`](@ref),
[`attenuate`](@ref) and [`correct_flux`](@ref) are generic over it.
[`angular_separation`](@ref)`(d1, d2)` (both `MDirection`s in the same
frame) gives the offset `θ`:
```julia
pb = GaussianBeam(1.4e9; diameter = 25.0)
θ = angular_separation(pointing, source)      # both MDirection{J2000}
correct_flux(pb, apparent_flux, θ)            # -> true flux
```

[`EllipticalGaussianBeam`](@ref)`(hpbw_major, hpbw_minor, pa, reffreq)`
and [`SquintBeam`](@ref)`(base, squint)` (feed/pointing squint) need the
offset *direction*, not just its magnitude — a `(dlon, dlat)` tangent-
plane pair from [`pointing_offset`](@ref)`(pointing, target)` rather than
a scalar `θ` (every `power_response`/`voltage_response`/`attenuate`/
`correct_flux` method also accepts this pair; a circularly symmetric
beam falls back to its magnitude). `pa` follows the `MDirection`
convention (from north through east).

The string form of [`query`](@ref) / [`groupby`](@ref) exposes three
pure-numeric wrappers for filtering/computing on beam response directly:
`pbgaussian(θ, hpbw)`, `pbairy(θ, diameter, freq[, blockage])`,
`pbellipse(dlon, dlat, hpbw_major, hpbw_minor, pa)` — e.g.
`query(cat, "pbairy(OFFSET, 25.0, 1.4e9) > 0.5")` on a source-catalogue
table carrying a per-row pointing-centre offset. **`mscal.pbresponse`**
wires the geometry in automatically instead — see the `mscal.*` section
above.
