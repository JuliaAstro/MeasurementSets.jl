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

_withsequ(c::ColumnDesc, s) = ColumnDesc(c.name, c.comment, c.manager, c.group,
    c.type, c.classname, c.shape, c.option, c.maxlength, c.keywords, c.default, s)

# Rewrite a column description so it is consistent with the data manager the
# writer will actually bind it to (`:ssm` or `:tsm`).
function _normalize_desc(c::ColumnDesc, kind::Symbol)
    arr = _is_tsm(c.shape) || (c.shape isa Dims && !isempty(c.shape))
    if kind === :tsm
        return ColumnDesc(c.name, c.comment, "TiledShapeStMan", "TSM" * c.name,
            c.type, _classname(c.type, true), c.shape, Int32(0),
            c.maxlength, c.keywords, c.default, c.sequ)
    end
    cls = arr ? _classname(c.type, true) : _classname(c.type, false)
    opt = (arr && c.shape isa Dims && !isempty(c.shape)) ?
          (c.option | Int32(5)) : Int32(0)           # Direct | FixedShape
    return ColumnDesc(c.name, c.comment, "StandardStMan", "StandardStMan",
        c.type, cls, c.shape, opt, c.maxlength, c.keywords, c.default, c.sequ)
end

"""
    _write_table_core(dir, descs, data; nrow, endian, public, private,
                      tablename, type, subtype, readme)

Write a CTDS table from explicit column descriptions + per-column data
vectors.  Scalar / fixed-shape / string columns are bound to one
StandardStMan; each `VariableShape` / `VariableDims` array column gets its
own TiledShapeStMan.
"""
function _write_table_core(dir::AbstractString, descs::Vector{ColumnDesc},
                           data::Vector; nrow::Integer, endian::Symbol=:little,
                           public::CasaRecord=CasaRecord(),
                           private::CasaRecord=CasaRecord(),
                           tablename::AbstractString="",
                           type::AbstractString="", subtype::AbstractString="",
                           readme::AbstractString="")
    mkpath(dir)
    ssm_i = findall(c -> !_is_tsm(c.shape), descs)
    tsm_i = findall(c -> _is_tsm(c.shape), descs)

    out = Vector{ColumnDesc}(undef, length(descs))
    dms = DMWrite[]
    seq = 0

    if !isempty(ssm_i)
        cols = ColumnDesc[_withsequ(_normalize_desc(descs[i], :ssm), seq) for i in ssm_i]
        blk = write_standardstman(dir, seq, cols, data[ssm_i], Int(nrow), endian)
        push!(dms, DMWrite("StandardStMan", seq, blk))
        for (k, i) in enumerate(ssm_i); out[i] = cols[k]; end
        seq += 1
    end
    varndim = Dict{String,Int}()
    for i in tsm_i
        c = _withsequ(_normalize_desc(descs[i], :tsm), seq)
        blk = write_tiledshapestman(dir, seq, c, data[i], Int(nrow), endian)
        push!(dms, DMWrite("TiledShapeStMan", seq, blk))
        out[i] = c
        varndim[c.name] = ndims(data[i][1])       # true cell dimensionality
        seq += 1
    end

    td = TableDesc(isempty(tablename) ? "" : String(tablename), "2.0", "",
                   public, private, out)
    write_table_files(dir, td, Int(nrow), dms; type, subtype, readme, varndim)
    return dir
end

"""
    write_table(dir, name, columns; nrow, endian=:little, type="", subtype="", readme="")

Write a CTDS table at `dir`.  `columns` is an iterable of `name => vector`
pairs (or a `Tables` columns source).  Column metadata (units, comments,
exact class names) is taken from `SCHEMAVER2[name]` when available.
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
                 (i = findfirst(c -> c.name == cn, std.columns);
                  i === nothing ? nothing : std.columns[i])

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
        arr = _is_tsm(shp) || (shp isa Dims && !isempty(shp))
        push!(descs, ColumnDesc(cn, sc === nothing ? "" : sc.comment,
            "", "", ct, _classname(ct, arr), shp, Int32(0), UInt32(0),
            CasaRecord(), nothing, nothing))
        push!(data, vals)
    end

    _write_table_core(dir, descs, data; nrow, endian,
                      tablename = String(name) * "Desc", type, subtype, readme)
end

# --- whole-MeasurementSet writers ---------------------------------

# Read every readable column of `t` (rows `r`) and write it to `dir`.
# `public` overrides the table's public keyword set (used for MAIN).
function _copy_table(dir::AbstractString, t::CTDSTable, r;
                     public::CasaRecord=t.desc.public,
                     private::CasaRecord=t.desc.private)
    descs = ColumnDesc[]
    data = Vector{Any}[]
    skipped = String[]
    for c in t.desc.columns
        col = try
            column(t, c.name)
        catch
            push!(skipped, c.name); continue
        end
        vals = try
            Any[col[i] for i in r]
        catch
            push!(skipped, c.name); continue
        end
        # uniform-shape check for would-be TSM columns
        if _is_tsm(c.shape) && length(unique(size.(vals))) != 1
            push!(skipped, c.name); continue
        end
        push!(descs, c)
        push!(data, vals)
    end
    isempty(skipped) || @warn "$(basename(dir)): skipped unreadable columns" cols=skipped
    _write_table_core(dir, descs, data; nrow=length(r), endian=:little,
                      public, private=CasaRecord(),
                      tablename=t.desc.name, type=t.type, subtype=t.subtype,
                      readme=t.readme)
    return descs
end

"""
    write_ms(dir, ms::MeasurementSet; rows=Colon())

Write `ms` to a new MeasurementSet directory `dir`: every subtable in full,
MAIN restricted to `rows`.  Columns the reader cannot decode (SSM indirect
variable-shape arrays) and non-uniform `VariableShape` columns are skipped
with a warning.
"""
function write_ms(dir::AbstractString, ms::MeasurementSet; rows=Colon())
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")
    mkpath(dir)

    main = getfield(ms, :data)
    mrows = rows === Colon() ? (1:main.rows) : rows

    # write subtables, remember which ones succeeded
    written = String[]
    for (kw, path) in subtables(main)
        sub = try
            subtable(ms, kw)
        catch e
            @warn "skipping subtable $kw" err=e; continue
        end
        _copy_table(joinpath(dir, kw), sub, 1:sub.rows)
        push!(written, kw)
    end

    # MAIN public keywords: keep non-table entries, point table entries at
    # the freshly written subtable dirs
    src = main.desc.public
    pub = CasaRecord()
    for i in 1:length(src)
        nm, v = src.names[i], src.values[i]
        if v isa SubTable
            nm in written || continue
            push!(pub.names, nm); push!(pub.types, TpTable)
            push!(pub.values, SubTable("./" * nm)); push!(pub.comments, src.comments[i])
        else
            push!(pub.names, nm); push!(pub.types, src.types[i])
            push!(pub.values, v); push!(pub.comments, src.comments[i])
        end
    end

    _copy_table(dir, main, mrows; public=pub)
    return dir
end

"""
    copyms(src, dst; rows=Colon())

Copy the MeasurementSet at `src` to a new directory `dst` (MAIN rows
optionally sliced).
"""
copyms(src::AbstractString, dst::AbstractString; rows=Colon()) =
    write_ms(dst, MeasurementSet(src); rows)
