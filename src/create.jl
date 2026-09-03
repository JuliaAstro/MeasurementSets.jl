# High-level writers: create a table / MeasurementSet on disk.

# element CasaType a Julia value implies
_casatype_of(::Type{Bool}) = TpBool
_casatype_of(::Type{Int32}) = TpInt
_casatype_of(::Type{Int64}) = TpInt64
_casatype_of(::Type{Float32}) = TpFloat
_casatype_of(::Type{Float64}) = TpDouble
_casatype_of(::Type{ComplexF32}) = TpComplex
_casatype_of(::Type{ComplexF64}) = TpDComplex
_casatype_of(::Type{<:AbstractString}) = TpString
_casatype_of(::Type{T}) where {T<:AbstractArray} = _casatype_of(eltype(T))

# infer a CellShape from a column of values
function _infer_shape(vals)
    eltype(vals) <: AbstractArray || return ()
    shapes = unique(size.(vals))
    length(shapes) == 1 || return VariableShape()
    s = shapes[1]
    isempty(s) && return ()
    return s               # uniform fixed shape -> SSM direct array
end

_is_tsm(shape) = shape isa VariableShape || shape isa VariableDims

"""
    write_table(dir, name, columns; nrow, endian=:little, type="", subtype="", readme="")

Write a CTDS table at `dir`.  `columns` is an iterable of `name => vector`
pairs (or a `Tables` columns source).  Scalar / fixed-shape / string columns
go in one StandardStMan; variable-shape numeric/Bool array columns each get
their own TiledShapeStMan.  Column metadata (units, comments, exact class
names) is taken from `SCHEMAVER2[name]` when available.
"""
function write_table(dir::AbstractString, name::AbstractString, columns;
                     nrow::Integer, endian::Symbol=:little,
                     type::AbstractString="", subtype::AbstractString="",
                     readme::AbstractString="")
    pairs = columns isa AbstractDict ? collect(columns) :
            Tables.istable(columns) ?
                [Symbol(n) => Tables.getcolumn(columns, Symbol(n))
                 for n in Tables.columnnames(columns)] :
            collect(columns)

    std = get(SCHEMAVER2, uppercase(name), nothing)
    stdcol(cn) = std === nothing ? nothing :
                 findfirst(c -> c.name == cn, std.columns) |>
                 (i -> i === nothing ? nothing : std.columns[i])

    descs = ColumnDesc[]
    data = Vector{Any}[]
    for (nm, vals) in pairs
        cn = String(nm)
        vals = collect(vals)
        length(vals) == nrow || error("column $cn: $(length(vals)) values, expected $nrow")
        et = _casatype_of(eltype(vals))
        shp = _infer_shape(vals)
        sc = stdcol(cn)
        ct = sc === nothing ? et : sc.type
        fixedarr = shp isa Dims && !isempty(shp)
        arr = fixedarr || _is_tsm(shp)
        opt = fixedarr ? Int32(5) : Int32(0)   # Direct | FixedShape
        push!(descs, ColumnDesc(cn, sc === nothing ? "" : sc.comment,
            "", "", ct, _classname(ct, arr), shp, opt, UInt32(0),
            CasaRecord(), nothing, nothing))
        push!(data, vals)
    end

    mkpath(dir)
    ssm_idx = findall(c -> !(_is_tsm(c.shape)), descs)
    tsm_idx = findall(c -> _is_tsm(c.shape), descs)

    dms = DMWrite[]
    seq = 0
    if !isempty(ssm_idx)
        for i in ssm_idx
            descs[i] = _withsequ(descs[i], seq)
        end
        blk = write_standardstman(dir, seq, descs[ssm_idx], data[ssm_idx],
                                  Int(nrow), endian)
        push!(dms, DMWrite("StandardStMan", seq, blk))
        seq += 1
    end
    for i in tsm_idx
        descs[i] = _withsequ(descs[i], seq)
        blk = write_tiledshapestman(dir, seq, descs[i], data[i], Int(nrow), endian)
        push!(dms, DMWrite("TiledShapeStMan", seq, blk))
        seq += 1
    end

    td = TableDesc(String(name) * "Desc", "2.0", "", CasaRecord(), CasaRecord(), descs)
    write_table_files(dir, td, Int(nrow), dms; type, subtype, readme)
    return dir
end

_withsequ(c::ColumnDesc, s) = ColumnDesc(c.name, c.comment, c.manager, c.group,
    c.type, c.classname, c.shape, c.option, c.maxlength, c.keywords, c.default, s)
