"""
    MeasurementSetv2

Pure-Julia reader (and, in later phases, writer) for the Measurement Set
version 2 data format — casacore Table Data System tables.

Phase 1: CTDS metadata — table descriptions, keywords, data-manager
bindings, row counts, and the MS subtable tree.  Column *data* decoding
(StandardStMan / TiledStMan / IncrementalStMan) is added in later phases.
"""
module MeasurementSetv2

include("aipsio.jl")
include("typeenum.jl")
include("record.jl")
include("tables.jl")
include("measurementset.jl")
include("datamanagers/standard.jl")
include("column.jl")

export CTDSTable, readtable, columnnames, columndesc, keywords, subtables, nrow
export MeasurementSet, subtable, subtablenames
export CasaRecord, SubTable, ColumnDesc, TableDesc, CasaType
export getcolumn, getcell

end
