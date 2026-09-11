# API reference (part 2)

```@meta
CurrentModule = MeasurementSets
```

Writing tables, editing in place, concurrency, the query engine, and
primary beams — continued from the main [API reference](api.md) page,
split off to stay under Documenter's HTML size limit.

`join`, `delete!` and `insert!` below are methods added to `Base.join` /
`Base.delete!` / `Base.insert!` (an N:1 lookup join and the `DELETE` /
`INSERT` write commands); they are not exported.

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

## Primary beams

```@docs
PrimaryBeam
GaussianBeam
AiryBeam
PolynomialBeam
EllipticalGaussianBeam
SquintBeam
power_response
voltage_response
attenuate
correct_flux
angular_separation
pointing_offset
reffreq
```
