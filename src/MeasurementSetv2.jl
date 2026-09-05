"""
    MeasurementSetv2

Pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others. No
dependency on the casacore C++ library (the one exception is `HDF5.jl`,
for `MultiHDF5` containers).

Entry points:

* [`readtable`](@ref) — open one CTDS table (returns a [`Table`](@ref),
  [`RefTable`](@ref) or [`ConcatTable`](@ref)).
* [`MeasurementSet`](@ref) — open an MS directory; `ms.ANTENNA`,
  `ms[:DATA]`, [`subtable`](@ref), [`subtablenames`](@ref).
* [`column`](@ref) / [`columnnames`](@ref) / [`columndesc`](@ref) /
  [`keywords`](@ref) / [`nrow`](@ref) — the read surface (also a
  `Tables.jl` source).
* [`write_table`](@ref) / [`copyms`](@ref) / [`create_ms`](@ref) /
  [`copytable`](@ref) — create tables.
* [`edit`](@ref) — open a table for in-place update ([`addrows!`](@ref),
  [`removerows!`](@ref), [`addcolumn!`](@ref), …).
* [`query`](@ref) / [`groupby`](@ref) / [`update!`](@ref) /
  [`taql`](@ref) — the TaQL-lite query / write engine.
* [`validate`](@ref) / [`SCHEMAVER2`](@ref) — the MS v2 standard schema.

See the README and `CHANGELOG.md` for the full picture.
"""
module MeasurementSetv2

include("aipsio.jl")
include("datamanagers/container.jl")
include("lock.jl")
include("typeenum.jl")
include("record.jl")
include("tables.jl")
include("measurementset.jl")
include("writer.jl")
include("datamanagers/datamanager.jl")
include("datamanagers/arrayfile.jl")
include("datamanagers/standard.jl")
include("datamanagers/tiled.jl")
include("datamanagers/incremental.jl")
include("datamanagers/virtual.jl")
include("datamanagers/dysco.jl")
include("column.jl")
include("query.jl")
include("schema.jl")
include("tables_interface.jl")
include("create.jl")
include("edit.jl")
include("resync.jl")
include("write_commands.jl")

export AbstractTable, Table, RefTable, ConcatTable
export readtable, columnnames, columndesc, keywords, subtables, nrow
export MeasurementSet, subtable, subtablenames
export Record, SubTable, ColumnDesc, TableDesc, CasaType
export VariableShape, VariableDims, isarray
export Column, column, getcolumn, getcell
export StdColumn, StdTable, SCHEMAVER2, stdtable, stdcolumns, validate
export write_table, write_ms, copyms, create_ms
export write_reftable, write_concattable, copytable
export edit, addrows!, removerows!, addcolumn!, removecolumn!, setcell!, setcolumn!
export resync, is_stale, is_multiused
export query, groupby, GroupedTable
export update!, taql
# `join` extends `Base.join` (N:1 lookup join, see query.jl);
# `delete!` extends `Base.delete!` and `insert!` extends `Base.insert!`
# (DELETE FROM / INSERT INTO, see write_commands.jl) -- none is exported.

end
