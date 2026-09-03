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
    isempty(skipped) ||
        @warn "$(basename(dir)): skipped unreadable columns: $(join(skipped, ", "))"
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

# --- synthesise a minimal standard MS -----------------------------

_mkdesc(name, ct, shape; opt=Int32(0), keywords=CasaRecord()) =
    ColumnDesc(name, "", "", "", ct, _classname(ct, shape !== ()),
               shape, opt, UInt32(0), keywords, nothing, nothing)

# concrete cell shape for a `VariableShape` standard column, given problem size
function _synth_shape(tbl, name, nchan, ncorr, nrec)
    name in ("CHAN_FREQ", "CHAN_WIDTH", "EFFECTIVE_BW", "RESOLUTION") && return (nchan,)
    name == "CORR_TYPE" && return (ncorr,)
    name == "CORR_PRODUCT" && return (2, ncorr)
    name in ("DELAY_DIR", "PHASE_DIR", "REFERENCE_DIR", "DIRECTION", "TARGET") && return (2, 1)
    name == "BEAM_OFFSET" && return (2, nrec)
    name == "POL_RESPONSE" && return (nrec, nrec)
    name == "RECEPTOR_ANGLE" && return (nrec,)
    name in ("SIGMA", "WEIGHT") && return (ncorr,)
    name == "FLAG_CATEGORY" && return (ncorr, nchan, 1)
    (name == "DATA" || name == "FLAG") && return (ncorr, nchan)
    return (1,)
end

# a length-`n` data vector for one standard column
function _synth_col(tbl, sc::StdColumn, n, nchan, ncorr, nrec)
    T = sc.type
    if T == TpString
        return fill("", n)                       # scalars, incl. would-be arrays
    end
    J = juliatype(T)
    if sc.shape === ()
        v = zeros(J, n)
        sc.name == "TIME" || sc.name == "TIME_CENTROID" ?
            (v .= J(4.6e9) .+ (0:n-1)) :
        sc.name == "INTERVAL" || sc.name == "EXPOSURE" ? (v .= J(1)) :
        sc.name == "NUM_CHAN" ? (v .= J(nchan)) :
        sc.name == "NUM_CORR" ? (v .= J(ncorr)) :
        sc.name == "NUM_RECEPTORS" ? (v .= J(nrec)) : nothing
        return v
    end
    shp = sc.shape isa Dims ? sc.shape : _synth_shape(tbl, sc.name, nchan, ncorr, nrec)
    return [zeros(J, shp) for _ in 1:n]
end

# build (descs, data) for one standard table
function _synth_table(tbl, nrows, nchan, ncorr, nrec; force_tsm=String[])
    std = SCHEMAVER2[tbl]
    descs = ColumnDesc[]
    data = Vector{Any}[]
    for sc in std.columns
        sc.required || continue
        vals = _synth_col(tbl, sc, nrows, nchan, ncorr, nrec)
        shape = if sc.name in force_tsm
            VariableShape()
        elseif sc.type == TpString && !(sc.shape isa Dims)
            ()                                       # scalar string simplification
        elseif sc.shape isa Dims
            sc.shape
        elseif eltype(vals) <: AbstractArray
            size(vals[1])
        else
            ()
        end
        push!(descs, _mkdesc(sc.name, sc.type, shape))
        push!(data, vals)
    end
    descs, data
end

"""
    create_ms(dir; nrow=10, nchan=4, ncorr=2, nant=3, nrec=2)

Synthesise a minimal, `validate`-clean MeasurementSet v2 at `dir` (zero /
default-valued data).  MAIN's `DATA`/`FLAG` go through TiledShapeStMan;
everything else through StandardStMan.  Variable-shape string columns are
written as scalar strings.
"""
function create_ms(dir::AbstractString; nrow::Integer=10, nchan::Integer=4,
                   ncorr::Integer=2, nant::Integer=3, nrec::Integer=2)
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")
    mkpath(dir)

    subrows = ["ANTENNA"=>nant, "DATA_DESCRIPTION"=>1, "FEED"=>nant,
        "FIELD"=>1, "FLAG_CMD"=>1, "HISTORY"=>1, "OBSERVATION"=>1,
        "POINTING"=>1, "POLARIZATION"=>1, "PROCESSOR"=>1,
        "SPECTRAL_WINDOW"=>1, "STATE"=>1]

    for (tbl, nr) in subrows
        descs, data = _synth_table(tbl, nr, nchan, ncorr, nrec)
        nr = Int(nr)
        if tbl == "ANTENNA"
            i = findfirst(c -> c.name == "NAME", descs)
            i === nothing || (data[i] = ["ANT$(k-1)" for k in 1:nr])
        end
        _write_table_core(joinpath(dir, tbl), descs, data; nrow=nr, endian=:little,
                          tablename=tbl * "Desc", type=titlecase(replace(tbl, '_'=>' ')))
    end

    # MAIN (+ optional DATA); FLAG and DATA go through TiledShapeStMan
    mdescs, mdata = _synth_table("MAIN", nrow, nchan, ncorr, nrec;
                                 force_tsm=["FLAG"])
    push!(mdescs, _mkdesc("DATA", TpComplex, VariableShape()))
    push!(mdata, [zeros(ComplexF32, ncorr, nchan) for _ in 1:nrow])
    pub = CasaRecord()
    push!(pub.names, "MS_VERSION"); push!(pub.types, TpFloat)
    push!(pub.values, 2.0f0); push!(pub.comments, "")
    for (tbl, _) in subrows
        push!(pub.names, tbl); push!(pub.types, TpTable)
        push!(pub.values, SubTable("./" * tbl)); push!(pub.comments, "")
    end
    _write_table_core(dir, mdescs, mdata; nrow=nrow, endian=:little, public=pub,
                      tablename="MSDesc", type="Measurement Set")
    return dir
end
