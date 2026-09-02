# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader (and, in later phases, writer) for the **Measurement Set
version 2** data format — the casacore Table Data System (CTDS) tables used
for interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library.

## Status

**Phase 1 — CTDS metadata (read).**
`AipsIO` primitive decoder; `table.dat` / `table.info` parsing (table &
column descriptions, keyword sets incl. nested `Record`s / `QuantumUnits`
/ `MEASINFO`, data-manager bindings, row counts, endianness); the MS
subtable tree.

**Phase 2 — StandardStMan (SSM) column data (read).**
`getcolumn(t, name)` / `getcell(t, name, row)` for SSM-backed columns:
scalar numerics, `Bool` (bit-unpacked), variable-length `String`
(incl. multi-bucket string buckets), and direct fixed-shape numeric/`Bool`
arrays.  Little- and big-endian tables.  Verified column-by-column
against `Casacore.jl`.

Not yet implemented: SSM indirect arrays and string arrays;
`TiledStMan`/`TiledShapeStMan` (visibility cubes) and `IncrementalStMan`
(most MAIN metadata columns); the high-level typed MS API; `Tables.jl`
integration; all writers.

## Usage

```julia
using MeasurementSetv2

t = readtable("/path/to/my.ms")          # the MAIN table
nrow(t)                                   # 9_817_600
columnnames(t)                            # ["UVW", "FLAG", …, "DATA", …]
columndesc(t, "DATA")                     # ColumnDesc(DATA::TpComplex @TiledShapeStMan/TiledDATA)
keywords(t)["MS_VERSION"]                 # 2.0f0

ms = MeasurementSet("/path/to/my.ms")
subtablenames(ms)                         # ["ANTENNA", "SPECTRAL_WINDOW", …]
spw = subtable(ms, "SPECTRAL_WINDOW")
columndesc(spw, "CHAN_FREQ")

ant = subtable(ms, "ANTENNA")
getcolumn(ant, "NAME")                    # ["ea01", "ea02", …]  (SSM)
getcolumn(ant, "POSITION")               # Vector of 3-element Float64 arrays
getcell(readtable("/path/to/my.ms"), "ANTENNA1", 1)   # Int32
```

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
