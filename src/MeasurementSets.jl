"""
    MeasurementSets

Pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others. No
C-library dependencies: `HDF5.jl` is an optional weak dependency, loaded
via a package extension only when you `import HDF5` to read or write a
`MultiHDF5` (`table.mfh5`) container.

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
module MeasurementSets

# --- wire-format codecs + the CTDS type system ---
include("io/aips.jl")
include("tables/typeenum.jl")
include("tables/record.jl")
include("io/lock.jl")

# --- table model + I/O ---
include("datamanagers/container.jl")
include("tables/table.jl")
include("measurementset.jl")
include("tables/writer.jl")

# --- storage managers + column engines ---
include("datamanagers/datamanager.jl")
include("datamanagers/arrayfile.jl")
include("datamanagers/standard.jl")
include("datamanagers/tiled.jl")
include("datamanagers/incremental.jl")
include("datamanagers/virtual.jl")
include("datamanagers/forwardcol.jl")
include("datamanagers/virtualtaql.jl")
include("datamanagers/dysco.jl")

# --- lazy columns, then the query engine, then the higher table verbs ---
include("tables/column.jl")
include("taql/taql.jl")
include("schema.jl")
include("tables/interface.jl")
include("tables/create.jl")
include("tables/edit.jl")
include("tables/resync.jl")
include("taql/commands.jl")

export AbstractTable, Table, RefTable, ConcatTable
export readtable, columnnames, columndesc, keywords, subtables, nrow
export MeasurementSet, subtable, subtablenames
export Record, SubTable, ColumnDesc, TableDesc, CasaType
export BFloat16                       # re-exported from BFloat16s (for `precision=BFloat16`)
export VariableShape, VariableDims, isarray
export Column, column, getcolumn, getcell
export StdColumn, StdTable, SCHEMAVER2, stdtable, stdcolumns, validate
export write_table, write_ms, copyms, create_ms
export write_reftable, write_concattable, copytable, reference_copy
export edit, addrows!, removerows!, addcolumn!, removecolumn!, setcell!, setcolumn!
export resync, is_stale, is_multiused
export query, groupby, GroupedTable
export update!, taql
# `join` extends `Base.join` (N:1 lookup join, see taql/join.jl);
# `delete!` extends `Base.delete!` and `insert!` extends `Base.insert!`
# (DELETE FROM / INSERT INTO, see taql/commands.jl) -- none is exported.

end
