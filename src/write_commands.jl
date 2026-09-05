# TaQL-lite write commands (Phase 30): UPDATE / DELETE / SELECT ... INTO.
#
# Thin wrappers over the existing mutation primitives -- `edit()` +
# `EditColumn` setindex! (Phases 9-11), `removerows!`, `copytable`
# (Phase 15) -- plus the TaQL-lite expression engine (Phases 22-25) for
# the WHERE / SET expressions.  `taql(target, "...")` is a string-command
# dispatcher on top of the Julia functions.

_cmd_path(x::AbstractString) = String(rstrip(x, '/'))
function _cmd_path(t::AbstractTable)
    t isa Table ||
        error("update!/delete!: target is a $(typeof(t)); only a plain on-disk Table " *
              "(or a path) is supported")
    return t.path
end

"""
    update!(target; set, where=nothing) -> Int

Change column values in the CTDS table at `target` (a path or an open
`Table` / `subtable(ms, …)`). `set` is `"COL" => "expr"` pairs — each
`expr` a TaQL-lite expression over the row's columns, **evaluated
against the pre-update values** (so `set = ["A" => "B", "B" => "A"]`
swaps). `where` is a TaQL-lite WHERE string, a `row -> Bool` closure, or
`nothing` (every row). Returns the number of rows changed.
"""
function update!(target; set::AbstractVector{<:Pair}, where=nothing)
    path = _cmd_path(target)
    rd = readtable(path)
    vn = Set(columnnames(rd))
    pairs = Tuple{String,Any}[(String(first(p)), _taqllite_parse(String(last(p)), vn))
                              for p in set]
    isempty(pairs) && throw(ArgumentError("update!: `set` must not be empty"))
    for (c, a) in pairs
        c in vn || throw(ArgumentError("update!: no column \"$c\""))
        !_has_aggr(a) ||
            throw(ArgumentError("update!: SET expression for \"$c\" must not aggregate"))
    end

    needed = Set{String}(first.(pairs))
    for (_, a) in pairs
        _tqlrefs!(needed, a)
    end
    if where isa AbstractString
        union!(needed, _tql_where_refs(where, rd))
    elseif where isa Function
        union!(needed, columnnames(rd))
    end
    cols = Dict{String,AbstractVector}(n => column(rd, n) for n in needed)

    rows = _where_rows(rd, where, cols)
    isempty(rows) && return 0
    nr = nrow(rd)
    edit(path) do t
        for (c, a) in pairs
            if where === nothing
                t[c][:] = [_tqleval(a, cols, i) for i in 1:nr]
            else
                ec = t[c]
                for i in rows
                    ec[i] = _tqleval(a, cols, i)
                end
            end
        end
    end
    return length(rows)
end

"""
    delete!(target; where=nothing) -> Int

Remove rows from the CTDS table at `target` (a path or an open `Table`).
`where` is a TaQL-lite WHERE string, a `row -> Bool` closure, or
`nothing` (**every row** — leaves a 0-row table). Returns the number of
rows removed. Extends `Base.delete!`.
"""
function Base.delete!(target::Union{AbstractString,AbstractTable}; where=nothing)
    path = _cmd_path(target)
    rd = readtable(path)
    names =
        where isa Function ? columnnames(rd) :
        where isa AbstractString ? collect(_tql_where_refs(where, rd)) :
        String[]
    cols = Dict{String,AbstractVector}(n => column(rd, n) for n in names)
    rows = _where_rows(rd, where, cols)
    isempty(rows) && return 0
    edit(path) do t
        removerows!(t, rows)
    end
    return length(rows)
end

# --- taql() string-command dispatcher --------------------------------

# paren-aware comma split (so `iif(a, b, c)` survives)
function _split_commas(s::AbstractString)
    out = String[]
    depth = 0
    start = firstindex(s)
    for i in eachindex(s)
        c = s[i]
        if c == '(' || c == '['
            depth += 1
        elseif c == ')' || c == ']'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(out, strip(s[start:prevind(s, i)]))
            start = nextind(s, i)
        end
    end
    push!(out, strip(s[start:end]))
    return out
end

"""
    taql(target, command::AbstractString)

Run one TaQL-lite write / select command against `target` (a path or an
open `Table`):

* `UPDATE [t] SET c1 = e1, c2 = e2 [WHERE cond]`  → [`update!`](@ref), returns `Int`
* `DELETE [FROM t] [WHERE cond]`                  → [`delete!`](@ref), returns `Int`
* `SELECT [*|col [AS a], …] [WHERE cond] (INTO|GIVING) 'path'`  → [`copytable`](@ref), returns the path
* `SELECT …` with no `INTO`/`GIVING`              → [`query`](@ref), returns the result

Clause keywords (`SET` / `WHERE` / `INTO` / `GIVING` / `FROM`) are found
by a case-insensitive split; a quoted literal containing one of them is
not supported — use the Julia functions for that. `GROUP BY` /
aggregates in a `SELECT` string are not supported (use
`copytable(dst, groupby(…))`).
"""
function taql(target, command::AbstractString)
    cmd = strip(command)
    kw = uppercase(String(first(split(cmd; limit=2))))
    if kw == "UPDATE"
        m = match(r"^UPDATE\s+(?:\S+\s+)?SET\s+(.+?)(?:\s+WHERE\s+(.+))?\s*$"is, cmd)
        m === nothing && throw(ArgumentError("taql: malformed UPDATE command"))
        set = Pair{String,String}[]
        for piece in _split_commas(m.captures[1])
            am = match(r"^(\w+)\s*=\s*(.+)$"s, piece)
            am === nothing && throw(ArgumentError("taql: malformed SET assignment \"$piece\""))
            push!(set, String(am.captures[1]) => String(strip(am.captures[2])))
        end
        return update!(target; set, where=m.captures[2] === nothing ? nothing : String(strip(m.captures[2])))
    elseif kw == "DELETE"
        m = match(r"^DELETE\s+(?:FROM\s+\S+\s*)?(?:WHERE\s+(.+))?\s*$"is, cmd)
        m === nothing && throw(ArgumentError("taql: malformed DELETE command"))
        return delete!(target; where=m.captures[1] === nothing ? nothing : String(strip(m.captures[1])))
    elseif kw == "SELECT"
        into = match(r"^(.*?)\s+(?:INTO|GIVING)\s+'([^']+)'\s*$"is, cmd)
        body = into === nothing ? cmd : String(strip(into.captures[1]))
        dst = into === nothing ? nothing : String(into.captures[2])
        bm = match(r"^SELECT\s+(.*?)(?:\s+WHERE\s+(.+))?\s*$"is, body)
        bm === nothing && throw(ArgumentError("taql: malformed SELECT command"))
        collist = String(strip(bm.captures[1]))
        wherestr = bm.captures[2] === nothing ? nothing : String(strip(bm.captures[2]))
        t = target isa AbstractTable ? target : readtable(_cmd_path(target))

        if collist == "*" || isempty(collist)
            select = [n => n for n in columnnames(t)]
        else
            select = Pair{String,String}[]
            for piece in _split_commas(collist)
                cm = match(r"^(\w+)(?:\s+AS\s+(\w+))?$"i, piece)
                cm === nothing && throw(ArgumentError("taql: malformed column \"$piece\""))
                src = String(cm.captures[1])
                push!(select, (cm.captures[2] === nothing ? src : String(cm.captures[2])) => src)
            end
        end

        result = wherestr === nothing ?
                 query(t, "TRUE"; select) : query(t, wherestr; select)
        dst === nothing && return result
        return copytable(dst, result)
    else
        throw(ArgumentError("taql: unknown command \"$kw\" (expected UPDATE / DELETE / SELECT)"))
    end
end
