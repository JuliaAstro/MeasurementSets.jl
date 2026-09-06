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
`on = (lrow, rrow) -> Bool` predicate form for range / non-equi joins,
which TaQL has no equivalent for.

It is *not* a full TaQL implementation. The [Changelog](changelog.md)
(phases 22–31) spells out what each area does and does not support —
briefly: 1-based array element/slice indexing (`DATA[1,1]`, `V[1:4,1]`,
`UVW[-1]`, `V[end-2:end,1]`), `BETWEEN` / `NOT BETWEEN`, bitwise
`& | ^ ~` (`^` = xor), `~=` / `!~=` approximate equality, and
`UPDATE … SET col[i,j] = …` array-slice / boolean-mask
(`SET col[maskexpr] = …`) / `(col, maskcol)` paired assignment, and
computed `query` `select` columns (`"amp" => "sqrt(abs(V))"`) *are*
supported, but no units or date/time / measures functions. The
`(col, maskcol)` form supplies the data and mask expressions
explicitly (TaQL-lite has no masked-array expressions).
