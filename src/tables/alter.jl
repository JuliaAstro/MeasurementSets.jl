# Phase 346: metadata-only table alterations -- rename a column, set / remove a table or column keyword.
# None of these touch a storage manager's data files (a data manager addresses its columns by position, not by
# name), so each one is a rewrite of `table.dat` with the existing data-manager blocks reused verbatim.

# rewrite `table.dat` / `table.info` of the plain on-disk table at `path` with the description `f(desc)` returns
function _rewrite_desc!(path::AbstractString, f::Function)
    dir = String(rstrip(String(path), '/'))
    withlock(dir, :write; create=true) do _
        rd = readtable(dir; precision=:full)
        rd isa Table || error("alter: $dir is a RefTable / ConcatTable -- only a plain table can be altered")
        rd.container === nothing || error("alter: $dir uses a MultiFile / MultiHDF5 container; copy it to a plain table first")
        dms = DMWrite[DMWrite(m.name, m.sequ, m.header) for m in rd.managers]
        sort!(dms; by = d -> d.sequ)
        td = f(rd.desc)
        write_table_files(dir, td, rd.rows, dms; type=rd.type, subtype=rd.subtype, readme=rd.readme, endian=rd.endian)
    end
    return dir
end

_with_columns(td::TableDesc, cols) = TableDesc(td.name, td.version, td.comment, td.public, td.private, cols)
_with_desc_keywords(c::ColumnDesc, kw::Record) =
    ColumnDesc(c.name, c.comment, c.manager, c.group, c.type, c.classname, c.shape, c.option, c.maxlength, kw, c.default, c.sequ)

# replace every `old` string in a keyword record's string / string-array values (engine links, hypercolumn lists)
function _rename_in_record(r::Record, old::AbstractString, new::AbstractString)
    vals = Any[v isa AbstractString && v == old ? String(new) :
               v isa AbstractVector{<:AbstractString} ? String[x == old ? String(new) : String(x) for x in v] :
               v isa Record ? _rename_in_record(v, old, new) : v for v in r.values]
    return Record(copy(r.names), copy(r.types), vals, copy(r.comments), r.rectype)
end

"""
    renamecolumn!(path, old, new) -> path

Rename column `old` of the plain table at `path` (a metadata-only change: no storage-manager file is touched). The links
other keywords hold to a renamed column -- a virtual engine's stored-column name, `Hypercolumn_*` lists -- follow it.
A column forwarded to another table by a `ForwardColumnEngine` cannot be renamed.
"""
function renamecolumn!(path::AbstractString, old::AbstractString, new::AbstractString)
    _rewrite_desc!(path, td -> begin
        names = [c.name for c in td.columns]
        old in names || throw(KeyError(old))
        old == new && throw(ArgumentError("renamecolumn!: the table already has a column \"$new\""))
        new in names && throw(ArgumentError("renamecolumn!: the table already has a column \"$new\""))
        cols = ColumnDesc[]
        for c in td.columns
            if c.name == old
                c.manager == "ForwardColumnEngine" && error("renamecolumn!: \"$old\" is forwarded to another table by a ForwardColumnEngine")
                c = ColumnDesc(String(new), c.comment, c.manager, c.group == old ? String(new) : c.group, c.type, c.classname,
                               c.shape, c.option, c.maxlength, c.keywords, c.default, c.sequ)
            end
            push!(cols, _with_desc_keywords(c, _rename_in_record(c.keywords, old, new)))
        end
        priv = Record(copy(td.private.names), copy(td.private.types), copy(td.private.values), copy(td.private.comments), td.private.rectype)
        for (i, nm) in enumerate(priv.names)
            startswith(nm, "Hypercolumn_") || continue
            nm == "Hypercolumn_" * old && (priv.names[i] = "Hypercolumn_" * new)
            priv.values[i] = priv.values[i] isa Record ? _rename_in_record(priv.values[i], old, new) : priv.values[i]
        end
        return TableDesc(td.name, td.version, td.comment, td.public, priv, cols)
    end)
end

# `column === nothing` -> the table keyword set, else that column's keyword set
function _alter_keywords(td::TableDesc, column, g::Function)
    column === nothing && return TableDesc(td.name, td.version, td.comment, g(td.public), td.private, td.columns)
    any(c -> c.name == column, td.columns) || throw(KeyError(column))
    return _with_columns(td, ColumnDesc[c.name == column ? _with_desc_keywords(c, g(c.keywords)) : c for c in td.columns])
end

"""
    setkeyword!(path, name, value; column=nothing) -> path

Set (add or replace) keyword `name` of the plain table at `path` -- or of column `column` -- to `value`: a number, `Bool`,
string, array of those, or a `Dict` / `Record`. Integers are stored as `Int64` and floats as `Float64`, and an existing keyword is replaced in place (a new one is appended) and must keep its data type, like real
TaQL's `ALTER TABLE ... SET KEYWORD`. A metadata-only change.
"""
function setkeyword!(path::AbstractString, name::AbstractString, value; column::Union{Nothing,AbstractString}=nothing)
    # real TaQL replaces an existing keyword in place (and refuses a value of another type)
    _rewrite_desc!(path, td -> _alter_keywords(td, column, r -> begin
        i = findfirst(==(String(name)), r.names)
        val = value   # a one-element array replacing an existing scalar keyword is that scalar (real TaQL)
        i !== nothing && !startswith(_kw_class(r.types[i]), "array") && val isa AbstractVector && length(val) == 1 && (val = val[1])
        t, v = _kw_value(_kw_normalize(val))
        i !== nothing && _kw_class(r.types[i]) != _kw_class(t) && throw(ArgumentError(
            "setkeyword!: keyword \"$name\" holds a $(_kw_class(r.types[i])) value; cannot replace it by a $(_kw_class(t)) one"))
        _set_kw(r, String(name), t, v)     # an existing keyword is replaced in place, a new one appended
    end))
end

# data-type class of a keyword value: integers share one (Int / Int64 / ...), likewise floats; scalar and array differ
function _kw_class(t::CasaType)
    s = String(Symbol(t)); arr = startswith(s, "TpArray"); b = arr ? s[8:end] : s[3:end]
    k = b in ("Int", "Int64", "Short", "UInt", "UShort", "UChar", "Char") ? "integer" :
        b in ("Float", "Double") ? "real" : b in ("Complex", "DComplex") ? "complex" : lowercase(b)
    return arr ? "array of $k" : k
end

"""
    renamekeyword!(path, old, new; column=nothing) -> path

Rename keyword `old` (in place -- it keeps its position) of the plain table at `path` or of column `column`. An absent `old` is
a `KeyError`, an existing `new` an `ArgumentError`; `old == new` changes nothing.
"""
function renamekeyword!(path::AbstractString, old::AbstractString, new::AbstractString; column::Union{Nothing,AbstractString}=nothing)
    _rewrite_desc!(path, td -> _alter_keywords(td, column, r -> begin
        i = findfirst(==(String(old)), r.names)
        i === nothing && throw(KeyError(old))
        old == new && return r
        new in r.names && throw(ArgumentError("renamekeyword!: keyword \"$new\" already exists"))
        names = copy(r.names); names[i] = String(new)
        Record(names, r.types, r.values, r.comments, r.rectype)
    end))
end

# integers -> Int64, floats -> Float64 (a mixed `[1.5, 2]` literal array is all Float64, as in real TaQL)
function _kw_normalize(v)
    v isa Bool && return v
    v isa Integer && return Int64(v)
    v isa AbstractFloat && return Float64(v)
    if v isa AbstractArray && !isconcretetype(eltype(v)) && !isempty(v) && all(x -> x isa Real && !(x isa Bool), v)
        return any(x -> x isa AbstractFloat, v) ? Float64.(v) : Int64.(v)
    end
    return v
end

function _kw_without(r::Record, name::AbstractString)
    keep = [j for j in eachindex(r.names) if r.names[j] != name]
    return Record(r.names[keep], r.types[keep], r.values[keep], r.comments[keep], r.rectype)
end

"""
    removekeyword!(path, name; column=nothing) -> path

Remove keyword `name` of the plain table at `path` (or of column `column`); an absent keyword is a `KeyError`.
"""
function removekeyword!(path::AbstractString, name::AbstractString; column::Union{Nothing,AbstractString}=nothing)
    _rewrite_desc!(path, td -> _alter_keywords(td, column, r -> begin
        i = findfirst(==(name), r.names)
        i === nothing && throw(KeyError(name))
        keep = [j for j in eachindex(r.names) if j != i]
        Record(r.names[keep], r.types[keep], r.values[keep], r.comments[keep], r.rectype)
    end))
end
