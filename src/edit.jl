# In-place edits: open an existing CTDS table for update.
#
# `edit(path) do t
#     t[:FLAG][5]  = trues(2, 64)      # tiled cell  -> patched in the tile file
#     t[:SCAN_NUMBER][:] = 1:nrow      # SSM/ISM col -> that manager's file regen'd
#     addrows!(t, 10)                  # every manager's row count grows
# end`
#
# Persist model (hybrid): a touched TiledShapeStMan column is patched in
# place (the point: editing one cell of a 20 GB cube touches a few tile
# bytes); a touched StandardStMan / IncrementalStMan file is regenerated
# wholesale from its in-memory column data (those files are small).  On
# flush the `nrow` field of `table.dat` is patched and `table.lock` is
# removed so casacore recomputes it.

mutable struct EditTable
    reader::Table
    rows::Int
    override::Dict{String,Vector{Any}}     # SSM/ISM: whole materialised columns
    tsmedit::Dict{String,Dict{Int,Any}}    # TSM: column -> (1-based row -> new cell)
    added::Int                             # rows appended this session
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
    r = readtable(String(rstrip(path, '/')))
    EditTable(r, r.rows, Dict{String,Vector{Any}}(),
              Dict{String,Dict{Int,Any}}(), 0, false)
end
function edit(f::Function, path::AbstractString)
    t = edit(path)
    f(t)
    flush(t)
    return t
end

_dmkind(inst) = inst isa StandardStMan ? :ssm :
                inst isa IncrementalStMan ? :ism : :tsm
_dminst(t::EditTable, name::AbstractString) =
    _dm_instance(t.reader, columndesc(t.reader, String(name)).sequ)

Base.getindex(t::EditTable, name::AbstractString) =
    EditColumn{Any}(t, columndesc(t.reader, name))
Base.getindex(t::EditTable, name::Symbol) = t[String(name)]

Base.size(c::EditColumn) = (c.tab.rows,)
Base.IndexStyle(::Type{<:EditColumn}) = IndexLinear()

function Base.getindex(c::EditColumn, i::Int)
    @boundscheck 1 <= i <= c.tab.rows || throw(BoundsError(c, i))
    t = c.tab; n = c.desc.name
    haskey(t.override, n) && return t.override[n][i]
    e = get(t.tsmedit, n, nothing)
    e !== nothing && haskey(e, i) && return e[i]
    i <= t.reader.rows && return column(t.reader, n)[i]
    return _default_cell(c.desc, t)
end
Base.getindex(c::EditColumn, ::Colon) = [c[i] for i in 1:c.tab.rows]

function Base.setindex!(c::EditColumn, v, i::Int)
    @boundscheck 1 <= i <= c.tab.rows || throw(BoundsError(c, i))
    t = c.tab; n = c.desc.name
    if _dmkind(_dminst(t, n)) === :tsm
        get!(() -> Dict{Int,Any}(), t.tsmedit, n)[i] = v
    else
        _materialize!(t, n)
        t.override[n][i] = v
    end
    return v
end
function Base.setindex!(c::EditColumn, vals, ::Colon)
    length(vals) == c.tab.rows ||
        error("assigning $(length(vals)) values to a $(c.tab.rows)-row column")
    for (i, v) in enumerate(vals)
        c[i] = v
    end
    return vals
end

"`setcell!(t, name, i, v)` / `setcolumn!(t, name, vals)` — verbs behind `t[name][i] = v`."
setcell!(t::EditTable, name, i::Integer, v) = (t[name][Int(i)] = v; t)
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

# pull the whole column into `t.override`, padded to `t.rows`
function _materialize!(t::EditTable, name::AbstractString)
    haskey(t.override, name) && return
    c = columndesc(t.reader, name)
    old = t.reader.rows > 0 ? column(t.reader, name)[:] : Any[]
    v = Vector{Any}(undef, t.rows)
    @inbounds for i in 1:t.reader.rows
        v[i] = old[i]
    end
    for i in t.reader.rows+1:t.rows
        v[i] = _default_cell(c, t)
    end
    t.override[name] = v
end

_coldata(t::EditTable, c::ColumnDesc) =
    (_materialize!(t, c.name); t.override[c.name])

# --- addrows ----------------------------------------------------

"""
    addrows!(t, n)

Append `n` rows to every storage manager of `t`.  Appended cells read
back as zeros / `""` (or a `VariableShape` cell as the previous row's
shape) until written.
"""
function addrows!(t::EditTable, n::Integer)
    n >= 0 || error("addrows!: n must be >= 0")
    n == 0 && return t
    t.rows += Int(n)
    t.added += Int(n)
    for (name, v) in t.override
        c = columndesc(t.reader, name)
        for _ in 1:n
            push!(v, _default_cell(c, t))
        end
    end
    return t
end

# --- flush ----------------------------------------------------

function Base.flush(t::EditTable)
    t.flushed && return t
    dir = t.reader.path
    endian = t.reader.endian
    oldrows, newrows = t.reader.rows, t.rows

    bysequ = Dict{Int,Vector{ColumnDesc}}()
    for c in t.reader.desc.columns
        push!(get!(() -> ColumnDesc[], bysequ, c.sequ), c)
    end

    for (sequ, cols) in bysequ
        inst = _dm_instance(t.reader, sequ)
        kind = _dmkind(inst)
        touched = any(c -> haskey(t.override, c.name) || haskey(t.tsmedit, c.name), cols)

        if kind === :tsm
            c = cols[1]                                # single-column TSM
            t.added > 0 && tsm_extend_rows!(inst, c, oldrows, newrows)
            for (row, plane) in get(t.tsmedit, c.name, Dict{Int,Any}())
                tsm_setcell!(inst, row, plane)
            end
        elseif touched || t.added > 0
            data = Any[_coldata(t, c) for c in cols]
            if kind === :ssm
                write_standardstman(dir, sequ, cols, data, newrows, endian)
            else
                write_incrementalstman(dir, sequ, cols, data, newrows, endian)
            end
        end
    end

    newrows == oldrows || _patch_nrow!(dir, newrows)
    lock = joinpath(dir, "table.lock")
    isfile(lock) && rm(lock; force=true)
    t.flushed = true
    return t
end

# patch the `nrow` UInt32 in the "Table" object of `table.dat` (big-endian)
function _patch_nrow!(dir::AbstractString, rows::Integer)
    p = joinpath(dir, "table.dat")
    data = read(p)
    a = AipsIO(IOBuffer(data); endian=:big)
    getstart(a, "Table")
    off = position(a)                                 # byte offset of the nrow field
    copyto!(data, off + 1, reinterpret(UInt8, [hton(UInt32(rows))]), 1, 4)
    tmp = p * "_tmp"
    write(tmp, data)
    mv(tmp, p; force=true)
end

Base.show(io::IO, t::EditTable) =
    print(io, "EditTable(\"", basename(t.reader.path), "\", ", t.rows, " rows",
          t.flushed ? ", flushed" : "", ")")
