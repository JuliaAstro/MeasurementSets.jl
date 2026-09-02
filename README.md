# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader (and, in later phases, writer) for the **Measurement Set
version 2** data format — the casacore Table Data System (CTDS) tables used
for interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library.

## Status

**Phase 1 — CTDS metadata (read).** Implemented:

- `AipsIO` primitive decoder (object framing, strings, `IPosition`,
  `Block`, `Array`, canonical big-endian scalars).
- `table.dat` / `table.info` parsing: table description, column
  descriptions, keyword sets (including nested `Record`s, `QuantumUnits`
  and `MEASINFO` measure info), data-manager bindings and instance
  headers, row counts, endianness.
- The MS subtable tree (`TpTable` keywords → subtable paths).

Not yet implemented: column *data* decoding (`StandardStMan`,
`TiledStMan`/`TiledShapeStMan`, `IncrementalStMan`), the high-level typed
MS API, `Tables.jl` integration, and all writers.

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
```

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
