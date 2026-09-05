# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library. One deliberate exception to
"pure Julia": `HDF5.jl` (a thin wrapper over the C `libhdf5`), so
`MultiHDF5` container tables are readable too.

## At a glance

**Read** — every storage manager a real MS uses, decoded in pure Julia:
`StandardStMan`, `IncrementalStMan`, the three `Tiled*StMan` (single- and
multi-column hypercubes), `DyscoStMan` (lossy compression), and the
virtual scaling / compression engines (`ScaledArrayEngine`,
`CompressComplex`, …).  `MultiFile` / `MultiHDF5` container tables, and
`RefTable` / `ConcatTable` (TaQL selections, MultiMS MAIN), too.  Columns
are lazy `AbstractVector`s; tables are `Tables.jl` sources
(`DataFrame(subtable(ms, "ANTENNA"))`).  A MAIN table's `DATA` /
`MODEL_DATA` / `CORRECTED_DATA` read back as `ComplexF16` by default
(the visibilities derive from 8-bit samples — nothing real is lost, and
the working set halves); `readtable(ms; precision=:full)` for
`ComplexF32`, or `precision=BFloat16` to narrow `WEIGHT` / `SIGMA` too
(`BFloat16` has `Float32`'s range, so no overflow).

**Write** — `write_table` / `create_ms` / `copyms` / `copytable` create
conformant tables, preserving each column's storage-manager / engine /
compression kind (or choosing one via `tsm=` / `ism=` / `engines=` /
`dysco=` / `storage=` kwargs).  Verified byte-for-byte against casacore.

**Edit in place** — `edit(path) do t … end`: overwrite cells / whole
columns, `addrows!`, `removerows!`, `addcolumn!`, `removecolumn!`.  Tiled
cells are patched in the tile file; other managers regenerate from
resolved column data.

**Concurrency** — cooperative `fcntl` locking + `table.lock` sync-blob
row-count tracking, so a table is safe to share with another Julia
session or a live `casa` / python-casacore process.  `is_stale` /
`resync` / `is_multiused`.

**Query** — a small TaQL-like engine: `query` (WHERE with arithmetic,
`LIKE` / regex, a function library, `ORDER BY`, column projection → a
`RefTable`), `groupby` (GROUP BY + `g*` aggregates + HAVING, string or
closure form), `join` (an N:1 lookup join), and the row-level write
commands `update!` / `delete!` / `insert!` / `SELECT … INTO`, plus a
`taql("…")` string dispatcher.  Results chain — each is an
`AbstractTable`.

**Schema** — the MS v2 standard schema (NRAO Memo 229) as data
(`SCHEMAVER2`, `stdtable`, `stdcolumns`); `validate(ms)` checks a table
against it (informational, never throws).

See **[CHANGELOG.md](CHANGELOG.md)** for the full phase-by-phase history
and the precise scope / non-goals of each area.

## Concepts

**Tables.** `readtable(path)` returns one of three `AbstractTable` kinds,
all with the same `column` / `nrow` / `columnnames` / `columndesc` /
`keywords` / `subtables` surface and `Tables.jl` interop:

| kind | what it is |
|------|------------|
| `Table` | a plain on-disk table (MAIN, every subtable) |
| `RefTable` | a persistent row-number reference into a parent (a TaQL `SELECT … GIVING`) |
| `ConcatTable` | a virtual row-wise concatenation of same-schema tables (a MultiMS MAIN) |

`query` / `groupby` / `join` add a fourth, `GroupedTable` — an in-memory
columnar result that is *also* an `AbstractTable`, so the query verbs
chain into one another.

**Storage managers** are how casacore lays a column's data on disk —
`StandardStMan` for scalars, the `Tiled*` managers for visibility cubes,
`IncrementalStMan` for slowly-varying metadata, `DyscoStMan` for lossy
compression, the virtual engines for scaled integers.  The reader and
writer handle all of them transparently; you name one only to choose a
layout when creating a table.

**The query engine is a deliberate subset of TaQL** — enough for real MS
filtering, aggregation and joins, and verified against real TaQL wherever
the two grammars overlap.  `CHANGELOG.md` lists exactly what is and isn't
supported.

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
            ["NUM_CHAN" => [64, 32],
             "CHAN_FREQ" => [collect(1.0:64.0), collect(1.0:32.0)]];  # ragged
            nrow=2)

# editing in place
edit("/tmp/copy.ms") do t
    t[:FLAG][5] = trues(4, 64)           # patched in the tile file
    t[:SCAN_NUMBER][10] = 7
    addrows!(t, 10)                      # every storage manager grows
    for r in 91:100; t[:TIME][r] = 4.6e9 + r end
end

# row / schema mutation (regen path)
edit("/tmp/copy.ms") do t
    removerows!(t, [2, 5, 9])
    addcolumn!(t, "WEIGHT_SPECTRUM")
    removecolumn!(t, "FLAG_CATEGORY")
end

# querying (TaQL-lite)
sel = query(ms.MAIN, "ANTENNA1 != ANTENNA2 AND mean(abs(DATA)) > 3 ORDER BY TIME")
per_ant = join(ms.MAIN, subtable(ms, "ANTENNA");
               on = "ANTENNA1", rightcols = ["NAME" => "ANT"]) |>
          r -> groupby(r, "ANT"; select = ["ANT" => :ANT, "N" => "gcount()",
                                           "AMP" => "gmean(mean(abs(DATA)))"])

# row-level write commands
update!("/tmp/copy.ms/ANTENNA"; set = ["MOUNT" => "'ALT-AZ'"], where = "STATION ~ p/PM*/")
insert!("/tmp/copy.ms/STATE"; values = (; OBS_MODE = "CALIBRATE_PHASE", SIG = true))
taql("/tmp/copy.ms", "DELETE FROM t WHERE FLAG_ROW")
```

## Documentation

Every exported binding has a docstring — `?nrow`, `?query`, `?edit` in the
REPL. The full HTML site (this README + a concepts overview, a task
guide, and the API reference) builds locally:

```
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Output lands in `docs/build/` (open `docs/build/index.html`). It is not
deployed anywhere yet.

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
