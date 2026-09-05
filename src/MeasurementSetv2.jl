"""
    MeasurementSetv2

Pure-Julia reader (and, in later phases, writer) for the Measurement Set
version 2 data format — casacore Table Data System tables.
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
# `join` extends `Base.join` (N:1 lookup join, see query.jl) and
# `delete!` extends `Base.delete!` (DELETE FROM, see write_commands.jl)
# -- neither is exported.

end
