# API reference

```@meta
CurrentModule = MeasurementSets
```

```@index
```

`join`, `delete!` and `insert!` below are methods added to `Base.join` /
`Base.delete!` / `Base.insert!` (an N:1 lookup join and the `DELETE` /
`INSERT` write commands); they are not exported.

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

```@docs
measinfo
MeasInfo
measure
measconvert
observatory
MeasFrame
MEpoch
MDirection
MPosition
MFrequency
MRadialVelocity
MDoppler
MBaseline
MuvW
Ephemeris
open_ephemeris
field_ephemeris
ephemeris_direction
ephemeris_radvel
ephemeris_distance
doppler
frequency
radialvelocity
restfrequency
shiftfreq
reftype
RefFrame
DopplerType
```

```@docs
UTC
TAI
TT
TDB
UT1
J2000
ICRS
B1950
APP
GALACTIC
ECLIPTIC
HADEC
AZEL
AZELGEO
ITRF
WGS84
TOPO
REST
LSRK
LSRD
BARY
GEO
GALACTO
LGROUP
CMB
MERCURY
VENUS
MARS
JUPITER
SATURN
URANUS
NEPTUNE
SUN
MOON
RADIO
OPTICAL
RATIO
BETA
GAMMA
Z
RELATIVISTIC
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

## Writing tables

```@docs
write_table
write_ms
copyms
copytable
create_ms
reference_copy
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
Base.join(::MeasurementSets.AbstractTable, ::MeasurementSets.AbstractTable)
Base.delete!(::Union{AbstractString, MeasurementSets.AbstractTable})
Base.insert!(::Union{AbstractString, MeasurementSets.AbstractTable})
```
