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
`getcolumn` / `getcell` for the "store-on-change" manager behind most MAIN
metadata columns (`TIME`, `INTERVAL`, `EXPOSURE`, `FIELD_ID`, …).  Header,
`ISMIndex`, per-bucket per-column run-length index, and value decoding.
With this every column of a typical MAIN table is readable except ones
that were never written.  Scalar + direct-array + scalar-string values;
ISM indirect arrays and string arrays are not yet supported.

Not yet implemented: SSM/ISM indirect arrays and string arrays;
multi-column tiled managers; the high-level typed MS API; `Tables.jl`
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
getcell(t, "ANTENNA1", 1)                # Int32           (SSM)
getcell(t, "DATA", 42)                   # 4×64 ComplexF32 (TiledShapeStMan)
getcell(t, "UVW", 42)                    # 3-element Float64 (TiledColumnStMan)
```

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
