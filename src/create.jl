# High-level writers: create a table / MeasurementSet on disk.

# element CasaType a Julia value implies
_casatype_of(::Type{Bool}) = TpBool
_casatype_of(::Type{Int32}) = TpInt
_casatype_of(::Type{Int64}) = TpInt64
_casatype_of(::Type{Float16}) = TpFloat        # narrowed columns write back as Float32
_casatype_of(::Type{BFloat16}) = TpFloat
_casatype_of(::Type{Float32}) = TpFloat
_casatype_of(::Type{Float64}) = TpDouble
_casatype_of(::Type{ComplexF16}) = TpComplex
_casatype_of(::Type{Complex{BFloat16}}) = TpComplex
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
# writer will actually bind it to (`:ssm` / `:ism` / `:tsm` / `:tcm` / `:tcell`).
function _normalize_desc(c::ColumnDesc, kind::Symbol)
    arr = _is_tsm(c.shape) || (c.shape isa Dims && !isempty(c.shape))
    if kind === :tsm
        return ColumnDesc(c.name, c.comment, "TiledShapeStMan", "TSM" * c.name,
            c.type, _classname(c.type, true), c.shape, Int32(0),
            c.maxlength, c.keywords, c.default, c.sequ)
    end
    if kind === :tcm     # TiledColumnStMan — fixed cell shape, direct
        return ColumnDesc(c.name, c.comment, "TiledColumnStMan", "TSM" * c.name,
            c.type, _classname(c.type, true), c.shape,
            COLOPT_DIRECT | COLOPT_FIXEDSHAPE,
            c.maxlength, c.keywords, c.default, c.sequ)
    end
    if kind === :tcell   # TiledCellStMan — per-row hypercube
        return ColumnDesc(c.name, c.comment, "TiledCellStMan", "TSM" * c.name,
            c.type, _classname(c.type, true), c.shape, Int32(0),
            c.maxlength, c.keywords, c.default, c.sequ)
    end
    if kind === :dysco   # DyscoStMan — fixed cell shape, direct (like :tcm)
        return ColumnDesc(c.name, c.comment, "DyscoStMan", "Dysco" * c.name,
            c.type, _classname(c.type, true), c.shape,
            COLOPT_DIRECT | COLOPT_FIXEDSHAPE,
            c.maxlength, c.keywords, c.default, c.sequ)
    end
    cls = arr ? _classname(c.type, true) : _classname(c.type, false)
    opt = (arr && c.shape isa Dims && !isempty(c.shape)) ?
          (c.option | COLOPT_DIRECT | COLOPT_FIXEDSHAPE) : Int32(0)
    mgr = kind === :ism ? "IncrementalStMan" : "StandardStMan"
    return ColumnDesc(c.name, c.comment, mgr, mgr,
        c.type, cls, c.shape, opt, c.maxlength, c.keywords, c.default, c.sequ)
end

# Normalise a tiled-manager spec to a list of column-name groups: a flat
# collection of names → one single-column group each; a collection of
# collections → used verbatim (one shared hypercube per inner group).
function _tsm_groups(x)
    isempty(x) && return Vector{String}[]
    first(x) isa AbstractString ? [String[String(s)] for s in x] :
                                  [String[String(c) for c in g] for g in x]
end

# keyword-set merge: drop `_`-prefixed keys from `base`, append `extra`
function _merge_kw(base::Record, extra::Record)
    r = Record()
    for i in 1:length(base)
        startswith(base.names[i], "_") && continue
        push!(r.names, base.names[i]); push!(r.types, base.types[i])
        push!(r.values, base.values[i]); push!(r.comments, base.comments[i])
    end
    append!(r.names, extra.names); append!(r.types, extra.types)
    append!(r.values, copy(extra.values)); append!(r.comments, extra.comments)
    return r
end

_stored_casatype(::Type{Int16}) = TpShort
_stored_casatype(::Type{Int32}) = TpInt
_stored_casatype(::Type{ComplexF64}) = TpDComplex

"""
    _write_table_core(dir, descs, data; nrow, endian, public, private,
                      tsm, tcm, tcell, ism, engines, dysco, dysco_spec,
                      tablename, type, subtype, readme)

Write a CTDS table from explicit column descriptions + per-column data
vectors.  Columns not named in `tsm` / `tcm` / `tcell` / `ism` /
`engines` / `dysco` go to one StandardStMan.  `tsm` / `tcm` / `tcell` /
`dysco` each take either a flat list of names (one hypercube/instance per
column) or a list of name groups (one shared hypercube/instance per
group).  `engines` maps a virtual column name to `(; kind, stored=:tsm,
scale=nothing, offset=nothing, autoscale=false, stored_type=TpInt,
storedname=nothing)`.  `dysco_spec` maps a Dysco group's first column
name to `(; normalization=AFNorm(), distribution=TruncatedGaussian(),
dataBitCount=10, weightBitCount=12, distributionTruncation=2.5,
studentTNu=5.0, antenna1, antenna2, rowsPerBlock=nrow, dither=true)` --
`antenna1`/`antenna2` (0-based, length `nrow`) are mandatory (see
[`write_dyscostman`](@ref)).  `storage` (`:sepfile` default, or
`:multifile`/`:multihdf5`) packs every StandardStMan/IncrementalStMan/
TiledStMan private file into one `table.mf`/`table.mfh5` (`blocksize`,
default 4 MiB); Dysco and virtual-engine files are never packed, matching
real casacore. No container is created if nothing in the table binds to
one of those three managers.
"""
function _write_table_core(dir::AbstractString, descs::Vector{ColumnDesc},
                           data::Vector; nrow::Integer, endian::Symbol=:little,
                           public::Record=Record(),
                           private::Record=Record(),
                           tsm=Set{String}(), tcm=Set{String}(), tcell=Set{String}(),
                           ism::AbstractSet{<:AbstractString}=Set{String}(),
                           engines::AbstractDict=Dict{String,NamedTuple}(),
                           dysco=Vector{String}[],
                           dysco_spec::AbstractDict=Dict{String,NamedTuple}(),
                           storage::Symbol=:sepfile,
                           blocksize::Integer=DEFAULT_MF_BLOCKSIZE,
                           tablename::AbstractString="",
                           type::AbstractString="", subtype::AbstractString="",
                           readme::AbstractString="")
    mkpath(dir)
    tsmg = _tsm_groups(tsm)

    # --- virtual column engines: synthesise the stored / scale / offset
    #     columns, stamp the `_<Engine>_*` keywords on the virtual column
    engine_seq = Tuple{Int,String}[]        # (virtual desc index, engine type string)
    engine_virtual = Set{String}()
    for (vname, spec) in engines
        vi = findfirst(c -> c.name == vname, descs)
        vi === nothing && error("engines: no column \"$vname\"")
        vdesc = descs[vi]; vdata = data[vi]
        push!(engine_virtual, vname)
        kind = spec.kind
        autoscale = get(spec, :autoscale, false)
        stored_type = get(spec, :stored_type, TpInt)
        storedname  = something(get(spec, :storedname, nothing), vname * "_COMPRESSED")
        scalename   = something(get(spec, :scalename, nothing), vname * "_SCALE")
        offsetname  = something(get(spec, :offsetname, nothing), vname * "_OFFSET")

        storeddata, kw, sc, of = encode_engine(kind, vdata, vdesc.type;
            scale = get(spec, :scale, nothing), offset = get(spec, :offset, nothing),
            autoscale, stored_type, storedname, scalename, offsetname)

        typestr = _engine_typestr(kind, vdesc.type, stored_type)
        descs[vi] = ColumnDesc(vname, vdesc.comment, typestr, vname, vdesc.type,
            _classname(vdesc.type, true), VariableShape(), Int32(0), UInt32(0),
            _merge_kw(vdesc.keywords, kw), nothing, nothing)
        push!(engine_seq, (vi, typestr))

        st_ct = _stored_casatype(eltype(storeddata[1]))
        push!(descs, _mkdesc(storedname, st_ct, VariableShape()))
        push!(data, storeddata)
        if get(spec, :stored, :tsm) === :tsm
            push!(tsmg, String[storedname])
        end
        if sc !== nothing
            push!(descs, _mkdesc(scalename,  TpFloat, ())); push!(data, collect(sc))
            push!(descs, _mkdesc(offsetname, TpFloat, ())); push!(data, collect(of))
        end
    end

    tiledgroups = [(:tsm, "TiledShapeStMan", write_tiledshapestman, tsmg),
                   (:tcm, "TiledColumnStMan", write_tiledcolumnstman, _tsm_groups(tcm)),
                   (:tcell, "TiledCellStMan", write_tiledcellstman, _tsm_groups(tcell))]
    tiledn = Set{String}()
    for (_, _, _, gs) in tiledgroups, g in gs, n in g
        push!(tiledn, n)
    end
    dyscog = _tsm_groups(dysco)
    dyscon = Set{String}()
    for g in dyscog, n in g
        push!(dyscon, n)
    end
    ism_i = findall(c -> c.name in ism, descs)
    ssm_i = setdiff(1:length(descs),
                    vcat(findall(c -> c.name in tiledn || c.name in engine_virtual ||
                                      c.name in dyscon, descs),
                         ism_i))

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

    # The per-DM-writer section: wrapped so a container-eligible writer's
    # `_dmfile_write!` calls buffer into a fresh container instead of
    # touching disk when `storage != :sepfile`.  Runs (and, if anything
    # was buffered, finalizes the real table.mf/table.mfh5) BEFORE
    # `write_table_files` below writes table.dat -- table.dat stays the
    # last thing written / the commit point, exactly as for `:sepfile`.
    with_container_sink(dir, storage, blocksize) do
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
        for (kind, dmname, writer, groups) in tiledgroups, g in groups
            idxs = Int[]
            for nm in g
                i = findfirst(c -> c.name == nm, descs)
                i === nothing && error("$dmname group $g: unknown column \"$nm\"")
                push!(idxs, i)
            end
            sort!(idxs)                       # bind in TableDesc column order (= header dtype order)
            cols = ColumnDesc[_withsequ(_normalize_desc(descs[i], kind), seq) for i in idxs]
            blk = writer(dir, seq, cols, Any[data[i] for i in idxs], Int(nrow), endian)
            push!(dms, DMWrite(dmname, seq, blk))
            for (k, i) in enumerate(idxs); out[i] = cols[k]; end
            seq += 1
        end
        for g in dyscog
            idxs = Int[]
            for nm in g
                i = findfirst(c -> c.name == nm, descs)
                i === nothing && error("DyscoStMan group $g: unknown column \"$nm\"")
                push!(idxs, i)
            end
            sort!(idxs)
            cols = ColumnDesc[_withsequ(_normalize_desc(descs[i], :dysco), seq) for i in idxs]
            spec = get(dysco_spec, g[1], NamedTuple())
            haskey(spec, :antenna1) && haskey(spec, :antenna2) ||
                error("dysco group $g: dysco_spec[\"$(g[1])\"] must supply antenna1/antenna2 " *
                      "(0-based, length nrow)")
            blk = write_dyscostman(dir, seq, cols, Any[data[i] for i in idxs], Int(nrow), endian;
                normalization = get(spec, :normalization, AFNorm()),
                distribution = get(spec, :distribution, TruncatedGaussian()),
                dataBitCount = get(spec, :dataBitCount, 10),
                weightBitCount = get(spec, :weightBitCount, 12),
                distributionTruncation = get(spec, :distributionTruncation, 2.5),
                studentTNu = get(spec, :studentTNu, 5.0),
                antenna1 = spec.antenna1, antenna2 = spec.antenna2,
                rowsPerBlock = get(spec, :rowsPerBlock, Int(nrow)),
                dither = get(spec, :dither, true),
                rng = get(spec, :rng, Random.default_rng()))
            push!(dms, DMWrite("DyscoStMan", seq, blk))
            for (k, i) in enumerate(idxs); out[i] = cols[k]; end
            seq += 1
        end
        for (vi, typestr) in engine_seq         # virtual engines write no file, empty block
            out[vi] = _withsequ(descs[vi], seq)
            push!(dms, DMWrite(typestr, seq, UInt8[]))
            seq += 1
        end
    end

    td = TableDesc(isempty(tablename) ? "" : String(tablename), "2.0", "",
                   public, private, out)
    write_table_files(dir, td, Int(nrow), dms; type, subtype, readme, varndim, storage, blocksize)
    return dir
end

"""
    write_table(dir, name, columns; nrow, endian=:little,
               tsm, tcm, tcell, ism, engines, dysco, dysco_spec,
               storage=:sepfile, blocksize=DEFAULT_MF_BLOCKSIZE,
               type="", subtype="", readme="")

Write a CTDS table at `dir`.  `columns` is an iterable of `name => vector`
pairs (or a `Tables` columns source).  Column metadata (units, comments,
exact class names) is taken from `SCHEMAVER2[name]` when available.
`dysco`/`dysco_spec` compress one or more columns with `DyscoStMan` --
see `_write_table_core` for the exact shape.  `storage`/
`blocksize` pack every StandardStMan/IncrementalStMan/TiledStMan private
file into one `table.mf`/`table.mfh5` -- see `_write_table_core`.
"""
function write_table(dir::AbstractString, name::AbstractString, columns;
                     nrow::Integer, endian::Symbol=:little,
                     tsm=String[], tcm=String[], tcell=String[], ism=String[],
                     engines::AbstractDict=Dict{String,NamedTuple}(),
                     dysco=Vector{String}[], dysco_spec::AbstractDict=Dict{String,NamedTuple}(),
                     storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE,
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

    _write_table_core(dir, descs, data; nrow, endian, tsm, tcm, tcell,
                      ism = Set(String.(ism)), engines, dysco, dysco_spec,
                      storage, blocksize,
                      tablename = String(name) * "Desc", type, subtype, readme)
end

# --- whole-MeasurementSet writers ---------------------------------

# Read every readable column of `dmsrc` (whose ColumnDesc/DM bindings
# decide each output column's storage-manager kind) for rows `rows`, taking
# the actual cell values from `valsrc` (== `dmsrc` for a plain Table or a
# RefTable's parent; the ConcatTable itself for a ConcatTable, since its
# rows span multiple parts) via `cols` (output name => source-column-name
# pairs, in output order), and write it to `dir`.  `public` overrides the
# table's public keyword set (used for MAIN).
function _copy_table_cols(dir::AbstractString, dmsrc::Table, valsrc::AbstractTable,
                          cols::Vector{Tuple{String,String}}, rows;
                          public::Record, private::Record, tablename::AbstractString,
                          type::AbstractString, subtype::AbstractString, readme::AbstractString,
                          storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    descs = ColumnDesc[]
    data = Vector{Any}[]
    ism = Set{String}()
    tiled = Dict{Int,Vector{String}}()       # source sequ -> output column names (desc order)
    tiledkind = Dict{Int,String}()           # source sequ -> manager type string
    dysco = Dict{Int,Vector{String}}()       # source sequ -> output column names
    skipped = String[]

    # --- virtual column engines: re-encode; skip the implied companions ---
    engines = Dict{String,NamedTuple}()
    implied = Set{String}()
    for c in dmsrc.desc.columns
        _is_engine_dm(_source_dm(dmsrc, c)) || continue
        kw = c.keywords
        sn = String(get(kw, "_BaseMappedArrayEngine_Name", ""))
        isempty(sn) || push!(implied, sn)
        for k in ("_ScaledArrayEngine_", "_ScaledComplexData_",
                  "_CompressComplex_", "_CompressFloat_")
            for suf in ("ScaleName", "OffsetName")
                nm = String(get(kw, k * suf, ""))
                isempty(nm) || push!(implied, nm)
            end
        end
    end

    for (outname, srcname) in cols
        srcname in implied && continue
        sc = columndesc(dmsrc, srcname)          # source column desc (pre-rename)
        col = try
            _pcolumn(valsrc, srcname, :full)     # copies stay byte-exact (never Float16)
        catch
            push!(skipped, outname); continue
        end
        vals = try
            _read_cells(col, rows)
        catch
            push!(skipped, outname); continue
        end
        oc = outname == srcname ? sc : _rename_columndesc(sc, outname)
        dm = _source_dm(dmsrc, sc)
        if _is_engine_dm(dm)
            engines[outname] = _engine_spec_from_source(dmsrc, sc, dm)
            push!(descs, oc); push!(data, vals)
            continue
        end
        # preserve the source's storage-manager kind
        if occursin("Tiled", dm)
            push!(get!(() -> String[], tiled, sc.sequ), outname)
            tiledkind[sc.sequ] = dm
        elseif dm == "DyscoStMan"
            push!(get!(() -> String[], dysco, sc.sequ), outname)
        elseif dm in ("IncrementalStMan", "ISM")
            push!(ism, outname)
        end
        push!(descs, oc)
        push!(data, vals)
    end

    _rows(nm) = data[findfirst(d -> d.name == nm, descs)]
    tsmg = Vector{String}[]; tcmg = Vector{String}[]; tcellg = Vector{String}[]
    for (sequ, names) in sort(collect(tiled); by = first)
        uniform = all(length(unique(size.(_rows(nm)))) == 1 for nm in names)
        if tiledkind[sequ] == "TiledColumnStMan" && uniform
            push!(tcmg, names)
        elseif tiledkind[sequ] == "TiledCellStMan"
            push!(tcellg, names)
        else
            tiledkind[sequ] == "TiledColumnStMan" &&
                @warn "$(basename(dir)): $(join(names, ',')) not uniform — writing as TiledShapeStMan"
            push!(tsmg, names)
        end
    end

    dyscog = Vector{String}[]
    dysco_spec = Dict{String,NamedTuple}()
    for (sequ, names) in sort(collect(dysco); by = first)
        push!(dyscog, names)
        dysco_spec[names[1]] = _dysco_spec_from_source(dmsrc, sequ, rows)
    end

    isempty(skipped) ||
        @warn "$(basename(dir)): skipped unreadable columns: $(join(skipped, ", "))"
    _write_table_core(dir, descs, data; nrow=length(rows), endian=:little,
                      public, private=Record(), tsm=tsmg, tcm=tcmg, tcell=tcellg, ism,
                      engines, dysco=dyscog, dysco_spec, storage, blocksize,
                      tablename, type, subtype, readme)
    return descs
end

# reconstruct the `dysco_spec=` entry for a source DyscoStMan-bound group
# (parallel to `_engine_spec_from_source`): the compression parameters are
# already live fields on the opened instance (no keyword-record parsing
# needed, unlike engines) -- `rows` selects/reorders which source rows are
# actually being copied, so antenna1/antenna2 (and the block-size clamp)
# are read through that same selection.
function _dysco_spec_from_source(t::Table, sequ::Int, rows)
    inst = _dm_instance(t, sequ)
    return (; normalization=inst.normalization, distribution=inst.distribution,
            dataBitCount=inst.dataBitCount, weightBitCount=inst.weightBitCount,
            distributionTruncation=inst.distributionTruncation, studentTNu=inst.studentTNu,
            antenna1=inst.ant1[rows], antenna2=inst.ant2[rows],
            rowsPerBlock=min(inst.rowsPerBlock, length(rows)))
end

"""
    _copy_table(dir, t::Table|RefTable|ConcatTable, r=1:nrow(t); public, private)

Deep-copy `t`'s columns (rows `r`) to a fresh plain table at `dir`,
preserving each column's storage-manager / virtual-engine kind.  For a
`RefTable` the layout is taken from its parent (renamed/projected per its
`namemap`/`order`); for a `ConcatTable`, from its first part -- mirroring
casacore's own `RefTable::dataManagerInfo` / `ConcatTable::dataManagerInfo`.
"""
function _copy_table(dir::AbstractString, t::Table, r=1:nrow(t);
                     public::Record=t.desc.public, private::Record=t.desc.private,
                     storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    cols = Tuple{String,String}[(c.name, c.name) for c in t.desc.columns]
    _copy_table_cols(dir, t, t, cols, r; public, private, tablename=t.desc.name,
                     type=t.type, subtype=t.subtype, readme=t.readme, storage, blocksize)
end

function _copy_table(dir::AbstractString, rt::RefTable, r=1:nrow(rt);
                     public::Record=keywords(rt), private::Record=Record(),
                     storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    rt.parent isa Table || error("materialise: RefTable parent is a " *
                                 "$(typeof(rt.parent)); only a plain-table parent is supported")
    p = rt.parent
    cols = Tuple{String,String}[(nm, rt.namemap[nm]) for nm in rt.order]
    _copy_table_cols(dir, p, p, cols, rt.rows[r]; public, private, tablename=p.desc.name,
                     type=p.type, subtype=p.subtype, readme=p.readme, storage, blocksize)
end

function _copy_table(dir::AbstractString, ct::ConcatTable, r=1:nrow(ct);
                     public::Record=keywords(ct), private::Record=Record(),
                     storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    p1 = ct.parts[1]
    p1 isa Table || error("materialise: ConcatTable's first part is a " *
                          "$(typeof(p1)); only a plain-table part is supported")
    cols = Tuple{String,String}[(c.name, c.name) for c in p1.desc.columns]
    _copy_table_cols(dir, p1, ct, cols, r; public, private, tablename=p1.desc.name,
                     type=p1.type, subtype=p1.subtype, readme=p1.readme, storage, blocksize)
end

# A GroupedTable (from `groupby`/`join`/`query` on a result) has no CTDS
# data-manager layout to preserve -- materialise its columns via the
# generic Tables.jl `write_table` path.
function _copy_table(dir::AbstractString, gt::GroupedTable, r=1:nrow(gt);
                     name::AbstractString="TABLE", kwargs...)
    nms = columnnames(gt)
    cols = Pair{Symbol,Any}[Symbol(n) => collect(column(gt, n))[r] for n in nms]
    write_table(dir, name, cols; nrow=length(r))
end

"""
    copytable(dst, t; rows=Colon(), name="TABLE",
             storage=:sepfile, blocksize=DEFAULT_MF_BLOCKSIZE) -> dst

Deep-copy `t` into a fresh plain table at `dst`.  For a `Table` /
`RefTable` / `ConcatTable` each column's storage-manager / virtual-engine
kind is preserved (casacore's `GIVING ... AS PLAIN`); for a
`GroupedTable` the columns are materialised (`name` sets the table's
schema name).  `rows` selects/reorders rows (1-based into `t`);
`storage`/`blocksize` pack the destination into one `table.mf` /
`table.mfh5` -- see `_write_table_core`.  This is "SELECT ...
INTO" for any query result.
"""
function copytable(dst::AbstractString, t::AbstractTable; rows=Colon(),
                   name::AbstractString="TABLE",
                   storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    dst = String(rstrip(dst, '/'))
    ispath(dst) && error("$dst already exists")
    r = rows === Colon() ? (1:nrow(t)) : rows
    t isa GroupedTable ? _copy_table(dst, t, r; name) :
        _copy_table(dst, t, r; storage, blocksize)
    return dst
end

# reconstruct the `engines=` spec for a source virtual column
function _engine_spec_from_source(t::Table, c::ColumnDesc, dm::AbstractString)
    kw = c.keywords
    kind = _engine_kind(dm, kw)
    storedname = String(kw["_BaseMappedArrayEngine_Name"])
    sd = _source_dm(t, columndesc(t, storedname))
    stored_type = columndesc(t, storedname).type
    kind isa Mapped && return (; kind, stored = occursin("Tiled", sd) ? :tsm : :ssm,
                                stored_type, storedname)
    pfx = PREFIXENGINE[kind]
    autoscale = kind isa CompressKind && Bool(get(kw, pfx * "AutoScale", false))
    scale  = get(kw, pfx * "Scale", nothing)
    offset = get(kw, pfx * "Offset", nothing)
    scalename  = String(get(kw, pfx * "ScaleName", ""))
    offsetname = String(get(kw, pfx * "OffsetName", ""))
    return (; kind, stored = occursin("Tiled", sd) ? :tsm : :ssm, stored_type,
            scale = autoscale ? nothing : scale, offset = autoscale ? nothing : offset,
            autoscale, storedname,
            scalename = isempty(scalename) ? nothing : scalename,
            offsetname = isempty(offsetname) ? nothing : offsetname)
end

# the storage-manager instance a source column is actually bound to
# (the ColumnDesc.manager string is unreliable — the reference MS labels
# ISM-bound columns "StandardStMan").
function _source_dm(t::Table, c::ColumnDesc)
    i = findfirst(d -> d.sequ == c.sequ, t.managers)
    i === nothing ? c.manager : t.managers[i].name
end

"""
    write_ms(dir, ms::MeasurementSet; rows=Colon(), subtables=Colon(),
            storage=:sepfile, blocksize=DEFAULT_MF_BLOCKSIZE)

Write `ms` to a new MeasurementSet directory `dir`: MAIN restricted to
`rows`, and every subtable in full (or only those named in `subtables`, a
collection of keyword names).  A column the reader cannot decode is skipped
with a warning.  `storage`/`blocksize`, if not `:sepfile`, pack **every**
table written (MAIN and each subtable) into its own `table.mf`/
`table.mfh5` -- matching what a real casacore MS created under a global
`StorageOption` would look like (one container per table, not one shared
container for the whole MS tree).
"""
function write_ms(dir::AbstractString, ms::MeasurementSet;
                  rows=Colon(), subtables=Colon(),
                  storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
    dir = String(rstrip(dir, '/'))
    ispath(dir) && error("$dir already exists")
    mkpath(dir)

    main = getfield(ms, :data)
    mrows = rows === Colon() ? (1:nrow(main)) : rows
    want(kw) = subtables === Colon() || kw in subtables

    # write subtables, remember which ones succeeded
    written = String[]
    for (kw, path) in MeasurementSets.subtables(main)
        want(kw) || continue
        sub = try
            subtable(ms, kw)
        catch e
            @warn "skipping subtable $kw" err=e; continue
        end
        try
            _copy_table(joinpath(dir, kw), sub, 1:nrow(sub); storage, blocksize)
            push!(written, kw)
        catch e
            @warn "skipping subtable $kw (unsupported source)" typeof(sub) err=e
        end
    end

    # MAIN public keywords: keep non-table entries, point table entries at
    # the freshly written subtable dirs
    src = keywords(main)
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

    _copy_table(dir, main, mrows; public=pub, storage, blocksize)
    return dir
end

"""
    copyms(src, dst; rows=Colon(), subtables=Colon(),
          storage=:sepfile, blocksize=DEFAULT_MF_BLOCKSIZE)

Copy the MeasurementSet at `src` to a new directory `dst` (MAIN rows
optionally sliced; `subtables` optionally restricted to a set of names).
`storage`/`blocksize` -- see [`write_ms`](@ref).
"""
copyms(src::AbstractString, dst::AbstractString; rows=Colon(), subtables=Colon(),
      storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE) =
    write_ms(dst, MeasurementSet(src); rows, subtables, storage, blocksize)

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
    create_ms(dir; nrow=10, nchan=4, ncorr=2, nant=3, nrec=2,
             storage=:sepfile, blocksize=DEFAULT_MF_BLOCKSIZE)

Synthesise a minimal, `validate`-clean MeasurementSet v2 at `dir` (zero /
default-valued data).  MAIN's `DATA`/`FLAG` go through TiledShapeStMan;
scalars and fixed-shape arrays through StandardStMan direct cells;
variable-shape array columns (`CHAN_FREQ`, `CORR_TYPE`, `POLARIZATION_TYPE`,
…) through StandardStMan indirect arrays.  `storage`/`blocksize`, if not
`:sepfile`, pack every table (MAIN and each subtable) into its own
`table.mf`/`table.mfh5` -- see [`write_ms`](@ref).
"""
function create_ms(dir::AbstractString; nrow::Integer=10, nchan::Integer=4,
                   ncorr::Integer=2, nant::Integer=3, nrec::Integer=2,
                   storage::Symbol=:sepfile, blocksize::Integer=DEFAULT_MF_BLOCKSIZE)
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
                          storage, blocksize,
                          tablename=tbl * "Desc", type=titlecase(replace(tbl, '_'=>' ')))
    end

    # MAIN: DATA + FLAG + WEIGHT_SPECTRUM share one TiledShapeStMan hypercube
    mdescs, mdata = _synth_table("MAIN", nrow, nchan, ncorr, nrec)
    push!(mdescs, _mkdesc("DATA", TpComplex, VariableShape()))
    push!(mdata, [zeros(ComplexF32, ncorr, nchan) for _ in 1:nrow])
    push!(mdescs, _mkdesc("WEIGHT_SPECTRUM", TpFloat, VariableShape()))
    push!(mdata, [zeros(Float32, ncorr, nchan) for _ in 1:nrow])
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
                      tsm=[["DATA", "FLAG", "WEIGHT_SPECTRUM"]],
                      ism=intersect(ismcols, Set(c.name for c in mdescs)),
                      storage, blocksize,
                      tablename="MSDesc", type="Measurement Set")
    return dir
end
