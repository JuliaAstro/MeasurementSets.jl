# In-place edits: open an existing CTDS table for update.
#
# `edit(path) do t
#     t[:FLAG][5]  = trues(2, 64)      # tiled cell  -> patched in the tile file
#     t[:SCAN_NUMBER][:] = 1:nrow      # SSM/ISM col -> that manager's file regen'd
#     addrows!(t, 10)                  # every manager's row count grows
#     removerows!(t, [3, 8])           # drop rows           (regen path)
#     addcolumn!(t, "WEIGHT_SPECTRUM") # schema change       (regen path)
#     removecolumn!(t, "FLAG_CATEGORY")
# end`
#
# Persist model:
#
# * Fast path (no schema change, rows only appended) — a touched
#   TiledShapeStMan column is patched in place (editing one cell of a
#   20 GB cube touches a few tile bytes); a touched StandardStMan /
#   IncrementalStMan file is regenerated wholesale from its in-memory
#   column data; `table.dat` is rewritten only when rows were appended.
#
# * Regen path (rows deleted/reordered, or a column added/removed) — every
#   affected storage-manager file is rebuilt from the resolved in-memory
#   column data (a tiled column's tile file included — the documented cost
#   of row deletion / column drop on a tiled column) and `table.dat` is
#   rewritten in full.  Untouched managers keep their files and header.
#
# The whole flush runs under an exclusive lock on `table.lock`; on the way
# out the `table.lock` sync blob is updated (new row count, bumped modify
# counter) so a concurrent casacore reader re-syncs.

mutable struct EditTable
    reader::Table
    rowmap::Vector{Int}                    # per current row: reader-row index, or 0 = appended
    override::Dict{String,Vector{Any}}     # SSM/ISM: whole materialised columns (len == length(rowmap))
    tsmedit::Dict{String,Dict{Int,Any}}    # TSM: column -> (current-row index -> new cell)
    addcols::Vector{Tuple{ColumnDesc,Symbol,Vector{Any}}}   # (desc, :ssm|:ism|:tsm, data)
    dropcols::Set{String}
    flushed::Bool
end

struct EditColumn{T} <: AbstractVector{T}
    tab::EditTable
    desc::ColumnDesc
end

"""
    edit(path) -> EditTable
    edit(f, path)            # runs `f(t)`, then `flush(t)`

Open the CTDS table at `path` for update.
"""
function edit(path::AbstractString)
    r = readtable(String(rstrip(path, '/')); precision=:full)   # edits work at native precision
    r isa Table || error("edit: $(r isa RefTable ? "RefTable" : "ConcatTable") " *
                         "at $path — in-place edit is not supported")
    r.container === nothing ||
        error("edit: $path uses a MultiFile/MultiHDF5 container — in-place edit " *
             "is not supported (Phase 20 is read-only)")
    any(m -> _is_forward_dm(m.name), r.managers) &&
        error("edit: $path has ForwardColumnEngine columns that reference another " *
              "table — edit that table instead")
    any(m -> _is_virtualtaql_dm(m.name), r.managers) &&
        error("edit: $path has VirtualTaQLColumn columns computed from a stored " *
              "TaQL expression — edit the source columns instead")
    EditTable(r, collect(1:r.rows), Dict{String,Vector{Any}}(),
              Dict{String,Dict{Int,Any}}(),
              Tuple{ColumnDesc,Symbol,Vector{Any}}[], Set{String}(), false)
end
function edit(f::Function, path::AbstractString)
    t = edit(path)
    f(t)
    flush(t)
    return t
end

_nrows(t::EditTable) = length(t.rowmap)

function _dmkind(inst)
    inst isa StandardStMan && return :ssm
    inst isa IncrementalStMan && return :ism
    inst isa VirtualEngine && return :engine
    inst isa DyscoStMan && return :dysco
    inst isa TiledStMan || return :ssm
    inst.kind === :column ? :tcm : inst.kind === :cell ? :tcell : :tsm
end

const _TILED_KINDS = (:tsm, :tcm, :tcell)
_tsm_dmname(k) = k === :tsm ? "TiledShapeStMan" :
                 k === :tcm ? "TiledColumnStMan" : "TiledCellStMan"
_tsm_writer(k) = k === :tsm ? write_tiledshapestman :
                 k === :tcm ? write_tiledcolumnstman : write_tiledcellstman

# the pending-add tuple for `name`, or nothing
function _added(t::EditTable, name::AbstractString)
    i = findfirst(x -> x[1].name == name, t.addcols)
    i === nothing ? nothing : t.addcols[i]
end

# effective description of `name` (an added column's, or the reader's)
function _desc(t::EditTable, name::AbstractString)
    a = _added(t, name)
    a !== nothing && return a[1]
    name in t.dropcols && error("column \"$name\" was removed in this edit session")
    columndesc(t.reader, name)
end

# storage-manager kind bound to `name` (:ssm / :ism / :tsm)
function _kind(t::EditTable, name::AbstractString)
    a = _added(t, name)
    a !== nothing && return a[2]
    _dmkind(_dm_instance(t.reader, _desc(t, name).sequ))
end

Base.getindex(t::EditTable, name::AbstractString) = EditColumn{Any}(t, _desc(t, name))
Base.getindex(t::EditTable, name::Symbol) = t[String(name)]

Base.size(c::EditColumn) = (length(c.tab.rowmap),)
Base.IndexStyle(::Type{<:EditColumn}) = IndexLinear()

function Base.getindex(c::EditColumn, i::Int)
    @boundscheck 1 <= i <= length(c.tab.rowmap) || throw(BoundsError(c, i))
    t = c.tab; n = c.desc.name
    haskey(t.override, n) && return t.override[n][i]
    e = get(t.tsmedit, n, nothing)
    e !== nothing && haskey(e, i) && return e[i]
    a = _added(t, n)
    a !== nothing && return a[3][i]
    src = t.rowmap[i]
    src > 0 && return column(t.reader, n)[src]
    return _default_cell(c.desc, t)
end
Base.getindex(c::EditColumn, ::Colon) = [c[i] for i in 1:length(c.tab.rowmap)]

function Base.setindex!(c::EditColumn, v, i::Int)
    @boundscheck 1 <= i <= length(c.tab.rowmap) || throw(BoundsError(c, i))
    t = c.tab; n = c.desc.name
    a = _added(t, n)
    if a !== nothing
        a[3][i] = v
    elseif _kind(t, n) in _TILED_KINDS
        get!(() -> Dict{Int,Any}(), t.tsmedit, n)[i] = v
    else
        _materialize!(t, n)
        t.override[n][i] = v
    end
    return v
end
function Base.setindex!(c::EditColumn, vals, ::Colon)
    length(vals) == length(c.tab.rowmap) ||
        error("assigning $(length(vals)) values to a $(length(c.tab.rowmap))-row column")
    for (i, v) in enumerate(vals)
        c[i] = v
    end
    return vals
end

"""
    setcell!(t, name, i, v) -> t

Set cell `i` of column `name` in the edit session `t` to `v` — the verb
behind `t[name][i] = v`.
"""
setcell!(t::EditTable, name, i::Integer, v) = (t[name][Int(i)] = v; t)

"""
    setcolumn!(t, name, vals) -> t

Replace the whole of column `name` in the edit session `t` with `vals`
(length must equal the current row count) — the verb behind
`t[name][:] = vals`.
"""
setcolumn!(t::EditTable, name, vals) = (t[name][:] = vals; t)

# --- appended-row default -----------------------------------------

function _default_cell(c::ColumnDesc, t::EditTable)
    J = juliatype(c.type)
    if c.shape isa Dims
        isempty(c.shape) && return c.type == TpString ? "" : zero(J)
        return zeros(J, c.shape)
    end
    if t.reader.rows > 0                              # VariableShape/Dims: last row's shape
        try
            return zeros(J, size(column(t.reader, c.name)[t.reader.rows]))
        catch
        end
    end
    return c.type == TpString ? String[] : J[]
end

# --- materialisation --------------------------------------------

# pull the whole column into `t.override`, aligned with `t.rowmap`
function _materialize!(t::EditTable, name::AbstractString)
    haskey(t.override, name) && return
    c = columndesc(t.reader, name)
    col = t.reader.rows > 0 ? column(t.reader, name) : nothing
    v = Vector{Any}(undef, length(t.rowmap))
    @inbounds for (i, src) in enumerate(t.rowmap)
        v[i] = src > 0 ? col[src] : _default_cell(c, t)
    end
    t.override[name] = v
end

# a length-`_nrows(t)` value vector for `name`, honouring every pending edit
function _resolve(t::EditTable, name::AbstractString)
    haskey(t.override, name) && return t.override[name]
    a = _added(t, name)
    a !== nothing && return a[3]
    c = columndesc(t.reader, name)
    e = get(t.tsmedit, name, nothing)
    col = nothing
    v = Vector{Any}(undef, length(t.rowmap))
    for (i, src) in enumerate(t.rowmap)
        if e !== nothing && haskey(e, i)
            v[i] = e[i]
        elseif src > 0
            col === nothing && (col = column(t.reader, name))
            v[i] = col[src]
        else
            v[i] = _default_cell(c, t)
        end
    end
    return v
end

# cheap per-row dimensionality probe for a variable-shape column
function _probe_ndim(t::EditTable, name::AbstractString)
    a = _added(t, name)
    a !== nothing && return isempty(a[3]) ? nothing : ndims(a[3][1])
    if haskey(t.override, name)
        v = t.override[name]
        return isempty(v) ? nothing : ndims(v[1])
    end
    i = findfirst(>(0), t.rowmap)
    i === nothing && return nothing
    return ndims(column(t.reader, name)[t.rowmap[i]])
end

# --- row operations -------------------------------------------

"""
    addrows!(t, n)

Append `n` rows.  Appended cells read back as zeros / `""` (or a
`VariableShape` cell as the previous row's shape) until written.
"""
function addrows!(t::EditTable, n::Integer)
    n >= 0 || error("addrows!: n must be >= 0")
    n == 0 && return t
    append!(t.rowmap, zeros(Int, Int(n)))
    for (name, v) in t.override
        c = columndesc(t.reader, name)
        for _ in 1:n; push!(v, _default_cell(c, t)); end
    end
    for (d, _, data) in t.addcols
        for _ in 1:n; push!(data, _default_cell(d, t)); end
    end
    return t
end

"""
    removerows!(t, rows)

Delete `rows` (1-based indices into the current row set).  Forces the
regen persist path on flush.
"""
function removerows!(t::EditTable, rows)
    idx = sort!(unique(Int[Int(r) for r in rows]))
    isempty(idx) && return t
    (idx[1] >= 1 && idx[end] <= length(t.rowmap)) ||
        throw(BoundsError(t, idx))
    deleteat!(t.rowmap, idx)
    for (_, v) in t.override; deleteat!(v, idx); end
    for (_, _, data) in t.addcols; deleteat!(data, idx); end
    dropset = Set(idx)
    for (name, e) in t.tsmedit
        ne = Dict{Int,Any}()
        for (k, val) in e
            k in dropset && continue
            ne[k - count(<(k), idx)] = val
        end
        t.tsmedit[name] = ne
    end
    return t
end

# --- column operations ---------------------------------------

function _check_new_col(t::EditTable, name::AbstractString)
    _added(t, name) === nothing || error("addcolumn!: \"$name\" already added this session")
    (name in t.dropcols) && return
    name in columnnames(t.reader) &&
        error("addcolumn!: column \"$name\" already exists")
end

# first standard column named `name` anywhere in the v2 schema
function _lookup_stdcol(name::AbstractString)
    for (_, tbl) in SCHEMAVER2, sc in tbl.columns
        sc.name == name && return sc
    end
    error("addcolumn!: \"$name\" is not a standard column; call " *
          "addcolumn!(t, name, data) with explicit values")
end

_stdshape(s) = s isa Dims ? s : s isa VariableDims ? VariableDims() : VariableShape()

"""
    addcolumn!(t, name; kind=:ssm)
    addcolumn!(t, name, data; kind=:ssm, type=nothing, shape=nothing)

Add a column.  With no data the column is taken from the standard MS v2
schema and filled with default cells; otherwise `data` (length
`length(t))`) supplies the values and its element type / shape are
inferred unless `type` / `shape` are given.  `kind` binds the column to a
new/shared StandardStMan (`:ssm`), IncrementalStMan (`:ism`) or a
per-column TiledShapeStMan (`:tsm`).
"""
function addcolumn!(t::EditTable, name::AbstractString; kind::Symbol=:ssm)
    _check_new_col(t, name)
    sc = _lookup_stdcol(name)
    desc = _mkdesc(name, sc.type, _stdshape(sc.shape))
    data = Any[_default_cell(desc, t) for _ in 1:length(t.rowmap)]
    push!(t.addcols, (desc, kind, data))
    return t
end

function addcolumn!(t::EditTable, name::AbstractString, data::AbstractVector;
                    kind::Symbol=:ssm, type::Union{CasaType,Nothing}=nothing,
                    shape=nothing)
    _check_new_col(t, name)
    vals = collect(data)
    length(vals) == length(t.rowmap) ||
        error("addcolumn!: expected $(length(t.rowmap)) values, got $(length(vals))")
    ct = type === nothing ? _casatype_of(eltype(vals)) : type
    shp = shape === nothing ? _infer_shape(vals) :
          (shape isa VariableShape || shape isa VariableDims ? shape : Tuple(shape))
    desc = _mkdesc(name, ct, shp)
    push!(t.addcols, (desc, kind, Any[v for v in vals]))
    return t
end

"""
    removecolumn!(t, name)

Drop a column.  If it takes a whole storage-manager instance with it,
that instance's files are deleted on flush.
"""
function removecolumn!(t::EditTable, name::AbstractString)
    if _added(t, name) !== nothing
        filter!(x -> x[1].name != name, t.addcols)
        return t
    end
    c = columndesc(t.reader, name)                    # KeyError if absent
    push!(t.dropcols, name)
    delete!(t.override, name)
    delete!(t.tsmedit, name)
    if _is_engine_dm(c.manager)                       # drop the implied companion columns too
        for kk in ("_BaseMappedArrayEngine_Name", "_ScaledArrayEngine_ScaleName",
                   "_ScaledArrayEngine_OffsetName", "_ScaledComplexData_ScaleName",
                   "_ScaledComplexData_OffsetName", "_CompressComplex_ScaleName",
                   "_CompressComplex_OffsetName", "_CompressFloat_ScaleName",
                   "_CompressFloat_OffsetName")
            v = String(get(c.keywords, kk, ""))
            isempty(v) || push!(t.dropcols, v)
        end
    end
    return t
end

# --- flush ----------------------------------------------------

# rowmap is the identity prefix of the reader rows, then only appended rows
function _append_only(t::EditTable)
    n = t.reader.rows
    length(t.rowmap) >= n &&
        all(i -> t.rowmap[i] == i, 1:n) &&
        all(i -> t.rowmap[i] == 0, n+1:length(t.rowmap))
end

_has_tcell(t::EditTable) = any(m -> m.name == "TiledCellStMan", t.reader.managers)
_has_engine(t::EditTable) = any(m -> _is_engine_dm(m.name), t.reader.managers)
_has_dysco(t::EditTable) = any(m -> m.name == "DyscoStMan", t.reader.managers)

# a virtual-engine column that was overwritten this session
function _engine_touched(t::EditTable)
    for m in t.reader.managers
        _is_engine_dm(m.name) || continue
        vi = findfirst(c -> c.sequ == m.sequ, t.reader.desc.columns)
        vi === nothing && continue
        nm = t.reader.desc.columns[vi].name
        (haskey(t.override, nm) || haskey(t.tsmedit, nm)) && return true
    end
    return false
end

# a Dysco-bound column that was overwritten this session -- like an
# engine cell, a touched Dysco cell needs its whole block re-decoded and
# re-encoded, nothing like a tiled cube's byte-addressable in-place patch,
# so any touch forces the regen path.
function _dysco_touched(t::EditTable)
    for m in t.reader.managers
        m.name == "DyscoStMan" || continue
        for c in t.reader.desc.columns
            c.sequ == m.sequ || continue
            (haskey(t.override, c.name) || haskey(t.tsmedit, c.name)) && return true
        end
    end
    return false
end

function Base.flush(t::EditTable)
    t.flushed && return t
    dir = t.reader.path
    newrows = length(t.rowmap)
    grew = newrows > t.reader.rows
    withlock(dir, :write; create=true) do lk
        old = read_syncinfo(lk)
        if isempty(t.addcols) && isempty(t.dropcols) && _append_only(t) &&
           !(grew && _has_tcell(t)) &&                     # TiledCellStMan can't grow in place
           !(grew && _has_engine(t)) && !_engine_touched(t) &&  # engines re-encode on regen
           !(grew && _has_dysco(t)) && !_dysco_touched(t)  # Dysco always re-encodes on regen
            _flush_fast(t)
        else
            _flush_regen(t)
        end
        write_syncinfo(lk, newrows; modifycounter = (old.present ? old.modifycounter : 0) + 1)
    end
    t.flushed = true
    return t
end

function _flush_fast(t::EditTable)
    rd = t.reader
    dir = rd.path
    endian = rd.endian
    oldrows, newrows = rd.rows, length(t.rowmap)
    added = newrows - oldrows

    bysequ = Dict{Int,Vector{ColumnDesc}}()
    for c in rd.desc.columns
        push!(get!(() -> ColumnDesc[], bysequ, c.sequ), c)
    end

    blocks = Dict{Int,Vector{UInt8}}()          # regenerated SSM/ISM table.dat blocks
    for (sequ, cols) in bysequ
        inst = _dm_instance(rd, sequ)
        kind = _dmkind(inst)
        touched = any(c -> haskey(t.override, c.name) || haskey(t.tsmedit, c.name), cols)

        if kind in _TILED_KINDS
            added > 0 && kind !== :tcell && tsm_extend_rows!(inst, cols, oldrows, newrows)
            for (li, c) in enumerate(cols)             # li = binding column index
                for (row, plane) in get(t.tsmedit, c.name, Dict{Int,Any}())
                    tsm_setcell!(inst, li, row, plane)
                end
            end
        elseif touched || added > 0
            data = Any[_resolve(t, c.name) for c in cols]
            blocks[sequ] = kind === :ssm ?
                write_standardstman(dir, sequ, cols, data, newrows, endian) :
                write_incrementalstman(dir, sequ, cols, data, newrows, endian)
        end
    end

    if added > 0
        # bucket geometry (rows-per-bucket) shifts with the row count, so the
        # regenerated SSM/ISM table.dat blocks (column offsets) must be
        # rewritten -- a full but cheap table.dat rebuild.
        dms = DMWrite[DMWrite(m.name, m.sequ, get(blocks, m.sequ, m.header))
                      for m in rd.managers]
        sort!(dms; by = d -> d.sequ)
        varndim = Dict{String,Int}()
        for c in rd.desc.columns
            c.shape isa VariableShape || continue
            nd = _probe_ndim(t, c.name)
            nd === nothing || (varndim[c.name] = nd)
        end
        td = TableDesc(rd.desc.name, rd.desc.version, rd.desc.comment,
                       rd.desc.public, rd.desc.private, rd.desc.columns)
        write_table_files(dir, td, newrows, dms; type=rd.type, subtype=rd.subtype,
                          readme=rd.readme, varndim)
    end
end

_norm(c::ColumnDesc, kind::Symbol, sequ::Int) = _withsequ(_normalize_desc(c, kind), sequ)

function _flush_regen(t::EditTable)
    rd = t.reader
    dir = rd.path
    endian = rd.endian
    newrows = length(t.rowmap)

    kept = ColumnDesc[c for c in rd.desc.columns if !(c.name in t.dropcols)]

    kindof = Dict{String,Symbol}()
    seqof  = Dict{String,Int}()
    for c in kept
        kindof[c.name] = _dmkind(_dm_instance(rd, c.sequ))
        seqof[c.name]  = c.sequ
    end
    nextseq = max(isempty(kept) ? -1 : maximum(c.sequ for c in kept),
                  isempty(rd.managers) ? -1 : maximum(m.sequ for m in rd.managers)) + 1

    firstkind(k) = begin
        s = nothing
        for c in kept
            kindof[c.name] === k || continue
            (s === nothing || c.sequ < s) && (s = c.sequ)
        end
        s
    end

    for (d, k, _) in t.addcols
        kindof[d.name] = k
        s = k in _TILED_KINDS ? nothing : firstkind(k)
        if s === nothing
            seqof[d.name] = nextseq; nextseq += 1
        else
            seqof[d.name] = s
        end
    end

    order = String[c.name for c in kept]
    append!(order, String[d.name for (d, _, _) in t.addcols])

    groups = Dict{Int,Vector{String}}()
    for nm in order
        push!(get!(() -> String[], groups, seqof[nm]), nm)
    end

    rows_changed = !(newrows == rd.rows && all(i -> t.rowmap[i] == i, 1:rd.rows))
    touched(nm) = haskey(t.override, nm) || haskey(t.tsmedit, nm) || _added(t, nm) !== nothing
    lost(sequ)  = any(c -> c.sequ == sequ && c.name in t.dropcols, rd.desc.columns)

    descfor(nm) = (a = _added(t, nm); a !== nothing ? a[1] : columndesc(rd, nm))

    resolved = Dict{String,Vector{Any}}()
    getres(nm) = get!(() -> _resolve(t, nm), resolved, nm)

    # --- virtual engines: re-encode a touched / row-changed engine column,
    #     feeding the fresh stored / scale / offset arrays to their SM groups
    engine_desc = Dict{String,ColumnDesc}()          # virtual name -> desc w/ refreshed keywords
    engine_regen_sequ = Set{Int}()
    for c in kept
        kindof[c.name] === :engine || continue
        (rows_changed || touched(c.name)) || continue
        e = _dm_instance(rd, c.sequ)                  # VirtualEngine
        kind = e.kind
        vtype = c.type
        st_kw = c.keywords
        storedname  = e.storedname
        scalename   = e.scalename
        offsetname  = e.offsetname
        vvals = getres(c.name)
        storeddata, kw, sc, of = encode_engine(kind, vvals, vtype;
            scale = e.autoscale ? nothing : e.scale,
            offset = e.autoscale ? nothing : e.offset,
            autoscale = e.autoscale,
            stored_type = columndesc(rd, storedname).type,
            storedname, scalename, offsetname)
        resolved[storedname] = storeddata
        push!(engine_regen_sequ, seqof[storedname])
        if sc !== nothing
            resolved[scalename]  = Any[x for x in sc]
            resolved[offsetname] = Any[x for x in of]
            push!(engine_regen_sequ, seqof[scalename], seqof[offsetname])
        end
        engine_desc[c.name] = ColumnDesc(c.name, c.comment, c.manager, c.group,
            c.type, c.classname, VariableShape(), c.option, c.maxlength,
            _merge_kw(c.keywords, kw), c.default, c.sequ)
    end

    varndim = Dict{String,Int}()
    for nm in order
        descfor(nm).shape isa VariableShape || continue
        nd = _probe_ndim(t, nm)
        nd === nothing || (varndim[nm] = nd)
    end

    dms = DMWrite[]
    normof = Dict{String,ColumnDesc}()

    for sequ in sort!(collect(keys(groups)))
        names = groups[sequ]
        k = kindof[names[1]]
        regen = rows_changed || lost(sequ) || any(touched, names) || sequ in engine_regen_sequ

        if k === :engine                              # writes no file, empty block
            nm = names[1]
            push!(dms, DMWrite(descfor(nm).manager, sequ, UInt8[]))
            normof[nm] = _withsequ(get(engine_desc, nm, descfor(nm)), sequ)
            continue
        end

        if !regen
            mi = findfirst(m -> m.sequ == sequ, rd.managers)
            if mi !== nothing
                push!(dms, DMWrite(rd.managers[mi].name, sequ, rd.managers[mi].header))
                for nm in names; normof[nm] = _norm(descfor(nm), k, sequ); end
                continue
            end
        end

        if k in _TILED_KINDS
            nds = ColumnDesc[_norm(descfor(nm), k, sequ) for nm in names]
            data = Any[getres(nm) for nm in names]
            blk = _tsm_writer(k)(dir, sequ, nds, data, newrows, endian)
            push!(dms, DMWrite(_tsm_dmname(k), sequ, blk))
            for (nm, nd) in zip(names, nds); normof[nm] = nd; end
        elseif k === :dysco
            # preserve the pre-edit instance's compression parameters;
            # antenna1/antenna2 are re-resolved through the *new* row
            # mapping (addrows!/removerows!-aware), not read stale off
            # the old instance -- mirrors _dysco_spec_from_source but
            # accounts for row changes mid-edit-session.
            nds = ColumnDesc[_norm(descfor(nm), k, sequ) for nm in names]
            data = Any[getres(nm) for nm in names]
            inst = _dm_instance(rd, sequ)
            a1new = Int.(getres("ANTENNA1"))
            a2new = Int.(getres("ANTENNA2"))
            blk = write_dyscostman(dir, sequ, nds, data, newrows, endian;
                normalization = inst.normalization, distribution = inst.distribution,
                dataBitCount = inst.dataBitCount, weightBitCount = inst.weightBitCount,
                distributionTruncation = inst.distributionTruncation, studentTNu = inst.studentTNu,
                antenna1 = a1new, antenna2 = a2new,
                rowsPerBlock = min(inst.rowsPerBlock, newrows))
            push!(dms, DMWrite("DyscoStMan", sequ, blk))
            for (nm, nd) in zip(names, nds); normof[nm] = nd; end
        else
            nds = ColumnDesc[_norm(descfor(nm), k, sequ) for nm in names]
            data = Any[getres(nm) for nm in names]
            blk = k === :ssm ?
                write_standardstman(dir, sequ, nds, data, newrows, endian) :
                write_incrementalstman(dir, sequ, nds, data, newrows, endian)
            push!(dms, DMWrite(k === :ssm ? "StandardStMan" : "IncrementalStMan", sequ, blk))
            for (nm, nd) in zip(names, nds); normof[nm] = nd; end
        end
    end

    outdescs = ColumnDesc[normof[nm] for nm in order]
    td = TableDesc(rd.desc.name, rd.desc.version, rd.desc.comment,
                   rd.desc.public, rd.desc.private, outdescs)
    write_table_files(dir, td, newrows, dms; type=rd.type, subtype=rd.subtype,
                      readme=rd.readme, varndim)

    live = Set(keys(groups))
    for m in rd.managers
        m.sequ in live && continue
        for f in readdir(dir)
            (f == "table.f$(m.sequ)" || f == "table.f$(m.sequ)i" ||
             startswith(f, "table.f$(m.sequ)_")) && rm(joinpath(dir, f); force=true)
        end
    end
end

Base.show(io::IO, t::EditTable) =
    print(io, "EditTable(\"", basename(t.reader.path), "\", ", length(t.rowmap), " rows",
          isempty(t.addcols) ? "" : ", +$(length(t.addcols)) col",
          isempty(t.dropcols) ? "" : ", -$(length(t.dropcols)) col",
          t.flushed ? ", flushed" : "", ")")
