"""
    MeasurementSetv2

Pure-Julia reader (and, in later phases, writer) for the Measurement Set
version 2 data format — casacore Table Data System tables.
"""
module MeasurementSetv2

include("aipsio.jl")
include("typeenum.jl")
include("record.jl")
include("tables.jl")
include("measurementset.jl")
include("writer.jl")
include("datamanagers/standard.jl")
include("datamanagers/tiled.jl")
include("datamanagers/incremental.jl")
include("column.jl")
include("schema.jl")
include("tables_interface.jl")
include("create.jl")

export CTDSTable, readtable, columnnames, columndesc, keywords, subtables, nrow
export MeasurementSet, subtable, subtablenames
export CasaRecord, SubTable, ColumnDesc, TableDesc, CasaType
export VariableShape, VariableDims, isarray
export Column, column, getcolumn, getcell
export StdColumn, StdTable, SCHEMAVER2, stdtable, stdcolumns, validate
export write_table, write_ms, copyms, create_ms

end
