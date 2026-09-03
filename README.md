# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library.

## Status

**Phase 1 — CTDS metadata (read).**
`AipsIO` primitive decoder; `table.dat` / `table.info` parsing (table &
column descriptions, keyword sets incl. nested `Record`s / `QuantumUnits`
/ `MEASINFO`, data-manager bindings, row counts, endianness); the MS
subtable tree.

**Phase 2 — StandardStMan (SSM) column data (read).**
`getcolumn` / `getcell` for SSM-backed columns: scalar numerics, `Bool`
(bit-unpacked), variable-length `String` (incl. multi-bucket string
buckets), and direct fixed-shape numeric/`Bool` arrays.

**Phase 3 — TiledStMan column data (read).**
`getcolumn` / `getcell` for `TiledShapeStMan` and `TiledColumnStMan`
columns — the visibility cubes (`DATA`, `FLAG`, `WEIGHT`, `SIGMA`,
`UVW`, …).  Header parsing, `row → hypercube` mapping, and tile
de-interleaving from the `table.f<n>_TSM<m>` files (mmapped).  Detects
never-written columns (`WEIGHT_SPECTRUM`).  Single-column tiled managers
only.

**Phase 4 — IncrementalStMan column data (read).**
The "store-on-change" manager behind most MAIN metadata columns (`TIME`,
`INTERVAL`, `EXPOSURE`, `FIELD_ID`, …).  With this every column of a
typical MAIN table is readable except ones that were never written.

**Phase 5 — high-level API, `Tables.jl`, standard schema.**
Lazy `Column <: AbstractVector` (`t[:DATA]`, `col[i]`, `col[1:5]`,
`col[:]`), `Tables.jl` column *and* row access (subtables drop straight
into `DataFrame`, `Tables.rowtable`, …), and a machine-readable encoding of
the MS v2 standard schema (`SCHEMAVER2`, `stdtable`, `validate`).

**Phase 6 — writers.**
Pure-Julia `table.dat` + StandardStMan + TiledShapeStMan writers, little-
endian storage-manager files, verified against `Casacore.jl`.

* `write_table(dir, name, cols; nrow)` — one CTDS table from `name => vector`
  pairs or a `Tables` source.
* `copyms(src, dst; rows=Colon())` — copy an MS (MAIN row-sliced); columns
  the reader can't decode (SSM indirect arrays) are skipped with a warning.
* `create_ms(dir; nrow, nchan, ncorr, nant)` — synthesise a minimal,
  `validate`-clean MS.

Not yet implemented: SSM/ISM indirect-array and string-array reading (so
those columns are dropped by `copyms`); multi-column tiled managers;
ISM / TiledColumnStMan writers.

## Usage

```julia
using MeasurementSetv2

ms = MeasurementSet("/path/to/my.ms")
subtablenames(ms)                        # ["ANTENNA", "SPECTRAL_WINDOW", …]

# lazy columns
ms[:DATA][42]                            # 4×64 ComplexF32   (one cell)
ms[:UVW][1:100]                          # first 100 baselines' UVW
column(ms.data, "TIME")[:]               # whole column (fast path)

t = readtable("/path/to/my.ms")          # the MAIN table directly
nrow(t); columnnames(t)
columndesc(t, "DATA")                    # schema of one column
keywords(t)["MS_VERSION"]                # 2.0f0

# Tables.jl — subtables interoperate with the data ecosystem
using DataFrames
DataFrame(subtable(ms, "ANTENNA"))       # 26×8
Tables.schema(subtable(ms, "SPECTRAL_WINDOW"))

# standard-schema check
validate(ms)                             # String[]  (conformant)
stdtable("SPECTRAL_WINDOW").columns

# writing
copyms("/path/to/my.ms", "/tmp/copy.ms"; rows=1:2000)
create_ms("/tmp/synth.ms"; nrow=100, nchan=64, ncorr=4, nant=6)
write_table("/tmp/spw", "SPECTRAL_WINDOW",
            ["NUM_CHAN" => [64], "REF_FREQUENCY" => [1.4e9]]; nrow=1)
```

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
