# A `MeasurementSet` acts as its MAIN table for the table verbs: `nrow(ms)`, `column(ms, "TIME")`,
# `query(ms, "FIELD_ID == 0")`, `groupby(ms, ...)`, `taql(ms, "UPDATE ...")`, `edit(ms)`, ....  (The
# three-argument `column` / `getcolumn` / `getcell` forms with a subtable name stay as they are.)
# Included last so every verb it forwards already exists.

for f in (:column, :getcolumn, :getcell, :groupby, :measure, :measinfo, :columnunit, :qcolumn, :rawblock, :subtables)
    @eval $f(ms::MeasurementSet, args...; kw...) = $f(getfield(ms, :data), args...; kw...)
end

query(ms::MeasurementSet, wherestr::AbstractString; kw...) = query(getfield(ms, :data), wherestr; kw...)
query(f::Function, ms::MeasurementSet; kw...) = query(f, getfield(ms, :data); kw...)
groupby(f::Function, ms::MeasurementSet, groupcols; kw...) = groupby(f, getfield(ms, :data), groupcols; kw...)

Base.join(ms::MeasurementSet, right::AbstractTable; kw...) = join(getfield(ms, :data), right; kw...)
Base.join(left::AbstractTable, ms::MeasurementSet; kw...) = join(left, getfield(ms, :data); kw...)
Base.join(ms::MeasurementSet, ms2::MeasurementSet; kw...) = join(getfield(ms, :data), getfield(ms2, :data); kw...)

copytable(dst::AbstractString, ms::MeasurementSet; kw...) = copytable(dst, getfield(ms, :data); kw...)
write_reftable(dir::AbstractString, ms::MeasurementSet, rows::AbstractVector{<:Integer}; kw...) =
    write_reftable(dir, getfield(ms, :data), rows; kw...)

# write commands (`update!` / `delete!` / `insert!` / `taql`) and `edit` act on the MAIN table's directory
_cmd_path(ms::MeasurementSet) = _cmd_path(getfield(ms, :data))
edit(ms::MeasurementSet) = (d = getfield(ms, :data); d isa Table ? edit(getfield(ms, :path)) : edit(d))
edit(f::Function, ms::MeasurementSet) = (d = getfield(ms, :data); d isa Table ? edit(f, getfield(ms, :path)) : edit(f, d))
Base.delete!(ms::MeasurementSet; kw...) = delete!(getfield(ms, :data); kw...)
Base.insert!(ms::MeasurementSet; kw...) = insert!(getfield(ms, :data); kw...)
Base.insert!(ms::MeasurementSet, source::AbstractTable; kw...) = insert!(getfield(ms, :data), source; kw...)

# iterating / measuring a MeasurementSet is iterating / measuring its MAIN table (Phase 391)
Base.length(ms::MeasurementSet) = nrow(ms)
Base.IteratorSize(::Type{MeasurementSet}) = Base.HasLength()
Base.eltype(::Type{MeasurementSet}) = CTDSRow
Base.iterate(ms::MeasurementSet, args...) = iterate(getfield(ms, :data), args...)
