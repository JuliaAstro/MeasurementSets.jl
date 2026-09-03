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
          (c.option | COLOPT_DIRECT | COLOPT_FIXEDSHAPE) : Int32(0)
    mgr = kind === :ism ? "IncrementalStMan" : "StandardStMan"
    return ColumnDesc(c.name, c.comment, mgr, mgr,
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
                           public::Record=Record(),
                           private::Record=Record(),
                           tsm::AbstractSet{<:AbstractString}=Set{String}(),
                           ism::AbstractSet{<:AbstractString}=Set{String}(),
                           tablename::AbstractString="",
                           type::AbstractString="", subtype::AbstractString="",
                           readme::AbstractString="")
    mkpath(dir)
    tsm_i = findall(c -> c.name in tsm, descs)
    ism_i = findall(c -> c.name in ism, descs)
    ssm_i = setdiff(1:length(descs), vcat(tsm_i, ism_i))  # scalars, direct + indirect

    out = Vector{ColumnDesc}(undef, length(descs))
    dms = DMWrite[]
    seq = 0
    varndim = Dict{String,Int}()

    # true per-row cell dimensionality for every variable-shape column
    for i in 1:length(descs)
        d = descs[i]
        (d.shape isa VariableShape && !isempty(data[i])) || continue
        varndim[d.name] = ndims(data[i][1])
    end

    if !isempty(ssm_i)
        cols = ColumnDesc[_withsequ(_normalize_desc(descs[i], :ssm), seq) for i in ssm_i]
        blk = write_standardstman(dir, seq, cols, data[ssm_i], Int(nrow), endian)
        push!(dms, DMWrite("StandardStMan", seq, blk))
        for (k, i) in enumerate(ssm_i); out[i] = cols[k]; end
        seq += 1
    end
    if !isempty(ism_i)
        cols = ColumnDesc[_withsequ(_normalize_desc(descs[i], :ism), seq) for i in ism_i]
        blk = write_incrementalstman(dir, seq, cols, data[ism_i], Int(nrow), endian)
        push!(dms, DMWrite("IncrementalStMan", seq, blk))
        for (k, i) in enumerate(ism_i); out[i] = cols[k]; end
        seq += 1
    end
    for i in tsm_i
        c = _withsequ(_normalize_desc(descs[i], :tsm), seq)
        blk = write_tiledshapestman(dir, seq, c, data[i], Int(nrow), endian)
        push!(dms, DMWrite("TiledShapeStMan", seq, blk))
        out[i] = c
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
                     tsm=String[], ism=String[],
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
            Record(), nothing, nothing))
        push!(data, vals)
    end

    _write_table_core(dir, descs, data; nrow, endian, tsm = Set(String.(tsm)),
                      ism = Set(String.(ism)),
                      tablename = String(name) * "Desc", type, subtype, readme)
end

# --- whole-MeasurementSet writers ---------------------------------

# Read every readable column of `t` (rows `r`) and write it to `dir`.
# `public` overrides the table's public keyword set (used for MAIN).
function _copy_table(dir::AbstractString, t::CTDSTable, r;
                     public::Record=t.desc.public,
                     private::Record=t.desc.private)
    descs = ColumnDesc[]
    data = Vector{Any}[]
    tsm = Set{String}()
    ism = Set{String}()
    skipped = String[]
    for c in t.desc.columns
        col = try
            column(t, c.name)
        catch
            push!(skipped, c.name); continue
        end
        vals = try
            _read_cells(col, r)
        catch
            push!(skipped, c.name); continue
        end
        # preserve the source's storage-manager kind
        dm = _source_dm(t, c)
        if _is_tsm(c.shape) && occursin("Tiled", dm)
            length(unique(size.(vals))) == 1 || (push!(skipped, c.name); continue)
            push!(tsm, c.name)
        elseif dm in ("IncrementalStMan", "ISM")
            push!(ism, c.name)
        end
        push!(descs, c)
        push!(data, vals)
    end
    isempty(skipped) ||
        @warn "$(basename(dir)): skipped unreadable columns: $(join(skipped, ", "))"
    _write_table_core(dir, descs, data; nrow=length(r), endian=:little,
                      public, private=Record(), tsm, ism,
                      tablename=t.desc.name, type=t.type, subtype=t.subtype,
                      readme=t.readme)
    return descs
end

# the storage-manager instance a source column is actually bound to
# (the ColumnDesc.manager string is unreliable — the reference MS labels
# ISM-bound columns "StandardStMan").
function _source_dm(t::CTDSTable, c::ColumnDesc)
    i = findfirst(d -> d.sequ == c.sequ, t.managers)
    i === nothing ? c.manager : t.managers[i].name
end

"""
    write_ms(dir, ms::MeasurementSet; rows=Colon(), subtables=Colon())

Write `ms` to a new MeasurementSet directory `dir`: MAIN restricted to
`rows`, and every subtable in full (or only those named in `subtables`, a
collection of keyword names).  A column the reader cannot decode is skipped
with a warning.
"""
function write_ms(dir::AbstractString, ms::MeasurementSet;
                  rows=Colon(), subtables=Colon())
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")
    mkpath(dir)

    main = getfield(ms, :data)
    mrows = rows === Colon() ? (1:main.rows) : rows
    want(kw) = subtables === Colon() || kw in subtables

    # write subtables, remember which ones succeeded
    written = String[]
    for (kw, path) in MeasurementSetv2.subtables(main)
        want(kw) || continue
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
    pub = Record()
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
    copyms(src, dst; rows=Colon(), subtables=Colon())

Copy the MeasurementSet at `src` to a new directory `dst` (MAIN rows
optionally sliced; `subtables` optionally restricted to a set of names).
"""
copyms(src::AbstractString, dst::AbstractString; rows=Colon(), subtables=Colon()) =
    write_ms(dst, MeasurementSet(src); rows, subtables)

# --- synthesise a minimal standard MS -----------------------------

const SYNTH_TIME0 = 4.6e9      # arbitrary epoch (MJD seconds) for synthesised TIME

_mkdesc(name, ct, shape; opt=Int32(0), keywords=Record()) =
    ColumnDesc(name, "", "", "", ct, _classname(ct, shape !== ()),
               shape, opt, UInt32(0), keywords, nothing, nothing)

# concrete cell shape for a `VariableShape` standard column, given problem size
function _synth_shape(name, nchan, ncorr, nrec)
    name in ("CHAN_FREQ", "CHAN_WIDTH", "EFFECTIVE_BW", "RESOLUTION") && return (nchan,)
    name == "CORR_TYPE" && return (ncorr,)
    name == "CORR_PRODUCT" && return (2, ncorr)
    name in ("DELAY_DIR", "PHASE_DIR", "REFERENCE_DIR", "DIRECTION", "TARGET") && return (2, 1)
    name == "BEAM_OFFSET" && return (2, nrec)
    name == "POL_RESPONSE" && return (nrec, nrec)
    name in ("RECEPTOR_ANGLE", "POLARIZATION_TYPE") && return (nrec,)
    name in ("SIGMA", "WEIGHT") && return (ncorr,)
    name == "FLAG_CATEGORY" && return (ncorr, nchan, 1)
    (name == "DATA" || name == "FLAG") && return (ncorr, nchan)
    return (1,)
end

# a length-`n` data vector for one standard column
function _synth_col(sc::StdColumn, n, nchan, ncorr, nrec)
    T = sc.type
    if sc.shape === ()
        T == TpString && return fill("", n)
        J = juliatype(T)
        v = zeros(J, n)
        sc.name == "TIME" || sc.name == "TIME_CENTROID" ?
            (v .= J(SYNTH_TIME0) .+ (0:n-1)) :
        sc.name == "INTERVAL" || sc.name == "EXPOSURE" ? (v .= J(1)) :
        sc.name == "NUM_CHAN" ? (v .= J(nchan)) :
        sc.name == "NUM_CORR" ? (v .= J(ncorr)) :
        sc.name == "NUM_RECEPTORS" ? (v .= J(nrec)) : nothing
        return v
    end
    shp = sc.shape isa Dims ? sc.shape : _synth_shape(sc.name, nchan, ncorr, nrec)
    T == TpString && return [fill("", shp) for _ in 1:n]
    return [zeros(juliatype(T), shp) for _ in 1:n]
end

# build (descs, data) for one standard table
function _synth_table(tbl, nrows, nchan, ncorr, nrec)
    std = SCHEMAVER2[tbl]
    descs = ColumnDesc[]
    data = Vector{Any}[]
    for sc in std.columns
        sc.required || continue
        vals = _synth_col(sc, nrows, nchan, ncorr, nrec)
        shape = sc.shape isa Dims ? sc.shape :
                sc.shape isa VariableDims ? VariableDims() :
                VariableShape()
        push!(descs, _mkdesc(sc.name, sc.type, shape))
        push!(data, vals)
    end
    descs, data
end

"""
    create_ms(dir; nrow=10, nchan=4, ncorr=2, nant=3, nrec=2)

Synthesise a minimal, `validate`-clean MeasurementSet v2 at `dir` (zero /
default-valued data).  MAIN's `DATA`/`FLAG` go through TiledShapeStMan;
scalars and fixed-shape arrays through StandardStMan direct cells;
variable-shape array columns (`CHAN_FREQ`, `CORR_TYPE`, `POLARIZATION_TYPE`,
…) through StandardStMan indirect arrays.
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
    mdescs, mdata = _synth_table("MAIN", nrow, nchan, ncorr, nrec)
    push!(mdescs, _mkdesc("DATA", TpComplex, VariableShape()))
    push!(mdata, [zeros(ComplexF32, ncorr, nchan) for _ in 1:nrow])
    pub = Record()
    push!(pub.names, "MS_VERSION"); push!(pub.types, TpFloat)
    push!(pub.values, MS_VERSION); push!(pub.comments, "")
    for (tbl, _) in subrows
        push!(pub.names, tbl); push!(pub.types, TpTable)
        push!(pub.values, SubTable("./" * tbl)); push!(pub.comments, "")
    end
    # MAIN's scalar per-integration metadata goes through IncrementalStMan,
    # as in a real MS
    ismcols = Set(["TIME", "INTERVAL", "EXPOSURE", "TIME_CENTROID", "FEED1",
        "FEED2", "FIELD_ID", "ARRAY_ID", "OBSERVATION_ID", "PROCESSOR_ID",
        "SCAN_NUMBER", "STATE_ID"])
    _write_table_core(dir, mdescs, mdata; nrow=nrow, endian=:little, public=pub,
                      tsm=Set(["DATA", "FLAG"]),
                      ism=intersect(ismcols, Set(c.name for c in mdescs)),
                      tablename="MSDesc", type="Measurement Set")
    return dir
end
