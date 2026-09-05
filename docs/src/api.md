# API reference

```@meta
CurrentModule = MeasurementSetv2
```

```@index
```

`join`, `delete!` and `insert!` below are methods added to `Base.join` /
`Base.delete!` / `Base.insert!` (an N:1 lookup join and the `DELETE` /
`INSERT` write commands); they are not exported.

`BFloat16` is re-exported from
[`BFloat16s.jl`](https://github.com/JuliaMath/BFloat16s.jl) so that
`readtable(ms; precision = BFloat16)` works after `using MeasurementSetv2`.

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
getcolumn(::MeasurementSetv2.AbstractTable, ::AbstractString)
getcell(::MeasurementSetv2.AbstractTable, ::AbstractString, ::Integer)
nrow
columnnames
```

## Schema and metadata

```@docs
columndesc
ColumnDesc
TableDesc
keywords
subtables
Record
CasaType
MeasurementSetv2.CellShape
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

## Writing tables

```@docs
write_table
write_ms
copyms
copytable
create_ms
write_reftable
write_concattable
```

## Editing in place

```@docs
edit
addrows!
removerows!
addcolumn!
removecolumn!
setcell!
setcolumn!
```

## Concurrency

```@docs
resync
is_stale
is_multiused
```

## Query engine

```@docs
query
groupby
GroupSlice
update!
taql
```

```@docs
Base.join(::MeasurementSetv2.AbstractTable, ::MeasurementSetv2.AbstractTable)
Base.delete!(::Union{AbstractString, MeasurementSetv2.AbstractTable})
Base.insert!(::Union{AbstractString, MeasurementSetv2.AbstractTable})
```
