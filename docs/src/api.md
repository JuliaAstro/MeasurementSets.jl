# API reference

```@meta
CurrentModule = MeasurementSets
```

```@index
```

This API reference spans three pages — this one, [part 2](api-2.md)
(writing / editing / concurrency / the query engine / primary beams),
and [Measures](api-measures.md) — split apart to stay under
Documenter's HTML size limit; the search index above covers all three.

`BFloat16` is re-exported from
[`BFloat16s.jl`](https://github.com/JuliaMath/BFloat16s.jl) so that
`readtable(ms; precision = BFloat16)` works after `using MeasurementSets`.

## Opening tables

```@docs
readtable
MeasurementSet
subtable
subtablenames
```

## Table types

```@docs
AbstractTable
Table
RefTable
ConcatTable
GroupedTable
SubTable
```

## Columns and data

```@docs
column
Column
getcolumn(::MeasurementSets.AbstractTable, ::AbstractString)
getcell(::MeasurementSets.AbstractTable, ::AbstractString, ::Integer)
nrow
columnnames
```

### Physical units

`import Unitful, UnitfulAngles, UnitfulAstro` gives these real methods
(see [Concepts](concepts.md#Physical-units)).

```@docs
columnunit
qcolumn
UNITS_NO_JULIA_COUNTERPART
```

### Reference frames (measures)

`import SOFA` (and optionally `EarthOrientation`) activates
[`measconvert`](@ref); see [Concepts](concepts.md#Reference-frames-(measures)).
Split onto its own page — [Measures](api-measures.md) — since this
category alone (measure types, `measconvert`, and ~50 reference-frame
singleton types) is large enough to push the combined API page past
Documenter's HTML size limit.

## Schema and metadata

```@docs
columndesc
ColumnDesc
TableDesc
keywords
subtables
Record
CasaType
MeasurementSets.CellShape
VariableShape
VariableDims
isarray
```

## The standard schema

```@docs
SCHEMAVER2
StdTable
StdColumn
stdtable
stdcolumns
validate
```

Writing / editing / concurrency / the query engine / primary beams are
on a second page — [API reference (part 2)](api-2.md) — split off to
stay under Documenter's HTML size limit.
