# MeasurementSetv2.jl

A pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library. The one exception to "pure
Julia" is `HDF5.jl` (a thin wrapper over the C `libhdf5`), so `MultiHDF5`
container tables are readable too.

## Installation

The package is not yet registered. Add it by path or URL:

```julia
using Pkg
Pkg.develop(path = "/path/to/MeasurementSetv2.jl")   # or Pkg.add(url = "...")
```

Then:

```julia
using MeasurementSetv2
ms = MeasurementSet("/path/to/my.ms")
```

## At a glance

**Read** — every storage manager a real MS uses, decoded in pure Julia:
`StandardStMan`, `IncrementalStMan`, the three `Tiled*StMan` (single- and
multi-column hypercubes), `DyscoStMan` (lossy compression), and the
virtual scaling / compression engines (`ScaledArrayEngine`,
`CompressComplex`, …). `MultiFile` / `MultiHDF5` container tables, and
[`RefTable`](@ref) / [`ConcatTable`](@ref) (TaQL selections, MultiMS
MAIN), too. Columns are lazy `AbstractVector`s; tables are `Tables.jl`
sources (`DataFrame(subtable(ms, "ANTENNA"))`).

**Write** — [`write_table`](@ref) / [`create_ms`](@ref) / [`copyms`](@ref)
/ [`copytable`](@ref) create conformant tables, preserving each column's
storage-manager / engine / compression kind (or choosing one via `tsm=` /
`ism=` / `engines=` / `dysco=` / `storage=` kwargs). Verified
byte-for-byte against casacore.

**Edit in place** — [`edit`](@ref)`(path) do t … end`: overwrite cells /
whole columns, [`addrows!`](@ref), [`removerows!`](@ref),
[`addcolumn!`](@ref), [`removecolumn!`](@ref).

**Concurrency** — cooperative `fcntl` locking + `table.lock` sync-blob
row-count tracking, so a table is safe to share with another Julia
session or a live `casa` / python-casacore process
([`is_stale`](@ref) / [`resync`](@ref) / [`is_multiused`](@ref)).

**Query** — a small TaQL-like engine: [`query`](@ref) (WHERE with
arithmetic, `LIKE` / regex, a function library, `ORDER BY`, projection →
a [`RefTable`](@ref)), [`groupby`](@ref) (GROUP BY + `g*` aggregates +
HAVING), `join` (an N:1 lookup join), and the row-level write commands
[`update!`](@ref) / `delete!` / `insert!` / `SELECT … INTO`, plus a
[`taql`](@ref)`("…")` string dispatcher. Results chain — each is an
[`AbstractTable`](@ref).

**Schema** — the MS v2 standard schema (NRAO Memo 229) as data
([`SCHEMAVER2`](@ref), [`stdtable`](@ref), [`stdcolumns`](@ref));
[`validate`](@ref)`(ms)` checks a table against it.

## Contents

```@contents
Pages = ["concepts.md", "guide.md", "api.md", "changelog.md"]
Depth = 2
```
