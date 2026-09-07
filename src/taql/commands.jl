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
swaps). The `set` key may also be an array-slice or boolean-mask target,
`"COL[subscripts]" => "expr"` (TaQL's `UPDATE … SET NAME[i,j] = …` /
`NAME[maskexpr] = …`) — 1-based, `end`-relative and range subscripts,
or a single Bool-array subscript acting as a write mask — which writes
only the addressed elements, leaving the rest untouched; a scalar RHS
fills the region. `col[slice][mask]` and `col[mask][slice]` both work.

A `set` key may also be a **`(datacol, maskcol)` tuple** (TaQL's
`UPDATE … SET (NAME, MASKNAME) = …`). `("D", "M") => "dexpr"` writes
`dexpr` to `D` and, to `M`, the *mask* of `dexpr` when it is a masked
array (`SET (D, M) = V[goodcond]` → `M` gets `!goodcond`), else a Bool
array flagging where `dexpr`'s result is non-finite.
`("D", "M") => ("dexpr", "mexpr")` writes `mexpr` (any Bool expression)
to `M` instead. Either name may be a slice / mask target.

`where` is a TaQL-lite WHERE string, a `row -> Bool` closure, or
`nothing` (every row). Returns the number of rows changed.
"""
function update!(target; set::AbstractVector{<:Pair}, where=nothing)
    path = _cmd_path(target)
    rd = readtable(path)
    vn = Set(columnnames(rd))
    isempty(set) && throw(ArgumentError("update!: `set` must not be empty"))

    # expand `(D, M) => …` pair targets into plain per-column entries;
    # `_expand_set_pairs` may hand back an already-parsed TQLExpr as a
    # value (the default non-finite mask).
    flat = _expand_set_pairs(set, vn)

    # each entry: (colname, levels::Vector{Vector} | nothing, rhs_ast)
    specs = Tuple{String,Any,Any}[]
    for (lhskey, rv) in flat
        lhs = _taqllite_parse(lhskey, vn)
        rhs = rv isa TQLExpr ? rv : _taqllite_parse(String(rv), vn)
        !_has_aggr(rhs) ||
            throw(ArgumentError("update!: SET expression \"$(rv)\" must not aggregate"))
        if lhs isa TQLCol
            push!(specs, (lhs.name, nothing, rhs))
        else
            fl = _flatten_lhs(lhs)
            fl === nothing && throw(ArgumentError(
                "update!: SET target \"$lhskey\" must be a column or COL[subscripts]"))
            push!(specs, (fl[1], fl[2], rhs))
        end
    end

    needed = Set{String}(s[1] for s in specs)
    for (_, levels, a) in specs
        _tqlrefs!(needed, a)
        levels === nothing || foreach(ax -> _axes_refs!(needed, ax), levels)
    end
    whereast = nothing
    if where isa AbstractString
        union!(needed, _tql_where_refs(where, rd))
        whereast = _taqllite_parse(String(where), vn)
    elseif where isa Function
        union!(needed, columnnames(rd))
    end
    cols = _tql_cols(rd, needed, [s[3] for s in specs], whereast)

    # unit-strip a `Quantity` SET RHS to each target column's own unit
    _qty = whereast !== nothing && _has_qty(whereast) || any(_has_qty(s[3]) for s in specs)
    colunit(c) = _qty ? columnunit(rd, c) : nothing

    rows = _where_rows(rd, where, cols)
    isempty(rows) && return 0
    nr = nrow(rd)

    sliced = Set(s[1] for s in specs if s[2] !== nothing)
    fullcols = Dict{String,AbstractVector}()
    if !isempty(sliced)
        rdf = readtable(path; precision=:full)
        for c in sliced
            fullcols[c] = column(rdf, c)
        end
    end

    # group specs by target column, preserving order
    bycol = Pair{String,Vector{Tuple{Any,Any}}}[]
    for (c, axes, a) in specs
        i = findfirst(kv -> first(kv) == c, bycol)
        i === nothing ? push!(bycol, c => Tuple{Any,Any}[(axes, a)]) :
                        push!(last(bycol[i]), (axes, a))
    end

    edit(path) do t
        for (c, ops) in bycol
            u = colunit(c)
            if length(ops) == 1 && ops[1][1] === nothing
                a = ops[1][2]
                if where === nothing
                    t[c][:] = [_tql_write_strip(_unwrap_marray(_tqleval(a, cols, i)), u) for i in 1:nr]
                else
                    ec = t[c]
                    for i in rows
                        ec[i] = _tql_write_strip(_unwrap_marray(_tqleval(a, cols, i)), u)
                    end
                end
            else
                ec = t[c]
                base = get(fullcols, c, nothing)
                for i in rows
                    cur = nothing
                    for (levels, a) in ops
                        ev = x -> _tql_write_strip(_unwrap_marray(_tqleval(x, cols, i)), u)
                        if levels === nothing
                            cur = ev(a)
                        else
                            cur === nothing && (cur = copy(base[i]))
                            if length(levels) == 1 && _as_mask(levels[1], ev) === nothing
                                _slice_assign!(cur, _tql_index_tuple(cur, levels[1], ev), ev(a))
                            else
                                _apply_index_chain!(cur, levels, ev, ev(a))
                            end
                        end
                    end
                    ec[i] = _unwrap_marray(cur)
                end
            end
        end
    end
    return length(rows)
end

# "(a, b)" (paren-aware) -> ("a", "b"), else nothing
function _pair_split(s::AbstractString)
    t = strip(s)
    (startswith(t, "(") && endswith(t, ")")) || return nothing
    parts = _split_commas(chop(t; head=1, tail=1))
    length(parts) == 2 || throw(ArgumentError(
        "update!: a (col, maskcol) / (dexpr, mexpr) pair takes exactly two entries, got $(length(parts))"))
    return (String(strip(parts[1])), String(strip(parts[2])))
end

# expand `(D, M) => …` pair-LHS `set` entries into plain per-column
# entries. `(D, M) => "dexpr"` -> `D => dexpr` + `M => TQLMaskOf(dexpr)`
# (the array's own mask, or a non-finite flag); `(D, M) => ("dexpr",
# "mexpr")` -> `D => dexpr` + `M => mexpr`. Non-pair entries pass through.
function _expand_set_pairs(set, vn)
    out = Pair{String,Any}[]
    for p in set
        lk, rv = first(p), last(p)
        names = lk isa Tuple ?
            (length(lk) == 2 ? (String(lk[1]), String(lk[2])) :
             throw(ArgumentError("update!: a (col, maskcol) target takes exactly two names"))) :
            (lk isa AbstractString ? _pair_split(lk) : nothing)
        if names === nothing
            rv isa Tuple && throw(ArgumentError(
                "update!: a (dexpr, mexpr) RHS needs a (col, maskcol) target"))
            push!(out, String(lk) => rv)
            continue
        end
        dn, mn = names
        de, me = rv isa Tuple ?
            (length(rv) == 2 ? (String(rv[1]), String(rv[2])) :
             throw(ArgumentError("update!: a (dexpr, mexpr) RHS takes exactly two expressions"))) :
            (rv isa AbstractString ?
             (x = _pair_split(rv); x === nothing ? (String(rv), nothing) : x) :
             throw(ArgumentError("update!: unsupported RHS for a (col, maskcol) target")))
        push!(out, dn => de)
        # no explicit mask: use the data expr's own mask when it is a
        # masked array, else flag its non-finite elements (Phase 59).
        push!(out, mn => (me === nothing ? TQLMaskOf(_taqllite_parse(de, vn)) : me))
    end
    return out
end

# collect column names referenced inside array-subscript axis expressions
function _axes_refs!(seen, axes)
    for ax in axes
        if ax isa NamedTuple
            for x in (ax.lo, ax.hi, ax.step)
                x === nothing || _tqlrefs!(seen, x)
            end
        else
            _tqlrefs!(seen, ax)
        end
    end
    return seen
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
    cols = Dict{String,AbstractVector}(n => _load_col(column(rd, n)) for n in names)
    rows = _where_rows(rd, where, cols)
    isempty(rows) && return 0
    edit(path) do t
        removerows!(t, rows)
    end
    return length(rows)
end

"""
    insert!(target; values, limit = nothing) -> Int

Append rows to the CTDS table at `target` (a path or an open `Table`).
`values` is one row (`["A" => 1, "B" => 2.5]` or `(; A = 1, B = 2.5)`),
a vector of those, or any `Tables.jl` source (another table, a
[`query`](@ref) result, a `Vector{NamedTuple}`). Columns of `target`
not supplied get their default (`0` / `""` / a same-shape zero array).
Scalar values are coerced to the target column's element type. Returns
the number of rows inserted. Extends `Base.insert!`.

`limit` controls how many rows are appended (TaQL's `INSERT … LIMIT`):
`nothing` or `0` (default) inserts one row per `values` row; a positive
`limit` inserts exactly that many, cycling through the `values` rows; a
negative `limit` inserts `nrow(target) + limit` rows (also cycling),
clamped at zero.
"""
function Base.insert!(target::Union{AbstractString,AbstractTable}; values,
                      limit::Union{Nothing,Integer}=nothing)
    path = _cmd_path(target)
    rd = readtable(path)
    vn = Set(columnnames(rd))
    baserows = _norm_ins_rows(values)
    isempty(baserows) && return 0
    for r in baserows, c in Base.keys(r)
        c in vn || throw(ArgumentError("insert!: no column \"$c\""))
    end
    m = length(baserows)
    k = (limit === nothing || limit == 0) ? m :
        limit > 0 ? Int(limit) : max(0, nrow(rd) + Int(limit))
    k == 0 && return 0
    rows = k == m ? baserows : [baserows[(i - 1) % m + 1] for i in 1:k]
    J = Dict(n => juliatype(columndesc(rd, n).type) for n in vn)
    sc = Dict(n => (columndesc(rd, n).shape isa Dims && isempty(columndesc(rd, n).shape))
              for n in vn)
    old = nrow(rd)
    edit(path) do t
        addrows!(t, k)
        for (ri, r) in enumerate(rows), (c, v) in r
            t[c][old + ri] = (sc[c] && v isa Number) ? convert(J[c], v) : v
        end
    end
    return k
end

Base.insert!(target::Union{AbstractString,AbstractTable}, source) =
    insert!(target; values=source)

_ins_row(x::NamedTuple) = Dict{String,Any}(String(k) => v for (k, v) in pairs(x))
_ins_row(x::AbstractVector{<:Pair}) =
    Dict{String,Any}(String(first(p)) => last(p) for p in x)

function _norm_ins_rows(values)
    values isa NamedTuple &&
        return isempty(values) ? Dict{String,Any}[] : [_ins_row(values)]
    values isa AbstractVector{<:Pair} &&
        return isempty(values) ? Dict{String,Any}[] : [_ins_row(values)]
    if Tables.istable(values)
        ct = Tables.columntable(values)
        nms = keys(ct)
        n = isempty(nms) ? 0 : length(ct[first(nms)])
        return [Dict{String,Any}(String(nm) => ct[nm][r] for nm in nms) for r in 1:n]
    end
    if values isa AbstractVector
        out = Dict{String,Any}[]
        for x in values
            append!(out, _norm_ins_rows(x))
        end
        return out
    end
    throw(ArgumentError("insert!: `values` must be a NamedTuple, a Vector of Pairs, " *
                        "a vector of those, or a Tables.jl source"))
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
* `INSERT INTO t [(c1, c2)] VALUES (v1, v2), (…) [LIMIT n]`  → [`insert!`](@ref), returns `Int`
* `INSERT [LIMIT n] INTO t SET c1 = v1, c2 = v2`   → [`insert!`](@ref), returns `Int`

`INSERT` values must be constant expressions (no column references).
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
            am = match(r"^(.+?)\s*=\s*(.+)$"s, piece)
            am === nothing && throw(ArgumentError("taql: malformed SET assignment \"$piece\""))
            push!(set, String(strip(am.captures[1])) => String(strip(am.captures[2])))
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
                mp = match(r"^(.+?)\s+AS\s+\(\s*(\w+)\s*,\s*(\w+)\s*\)$"is, piece)
                if mp !== nothing              # expr AS (valname, maskname)
                    push!(select, "($(mp.captures[2]), $(mp.captures[3]))" =>
                          String(strip(mp.captures[1])))
                    continue
                end
                cm = match(r"^(.+?)(?:\s+AS\s+(\w+))?$"is, piece)
                cm === nothing && throw(ArgumentError("taql: malformed column \"$piece\""))
                src = String(strip(cm.captures[1]))
                alias = cm.captures[2]
                if alias === nothing
                    occursin(r"^\w+$", src) ||
                        throw(ArgumentError("taql: computed SELECT column \"$src\" needs an AS alias"))
                    push!(select, src => src)
                else
                    push!(select, String(alias) => src)
                end
            end
        end

        result = wherestr === nothing ?
                 query(t, "TRUE"; select) : query(t, wherestr; select)
        dst === nothing && return result
        return copytable(dst, result)
    elseif kw == "INSERT"
        return _taql_insert(target, cmd)
    else
        throw(ArgumentError(
            "taql: unknown command \"$kw\" (expected UPDATE / DELETE / SELECT / INSERT)"))
    end
end

# inside of each top-level (…) / […] group, in order
function _paren_groups(s::AbstractString)
    out = String[]
    depth = 0
    buf = IOBuffer()
    for c in s
        if c == '(' || c == '['
            depth += 1
            depth == 1 && continue
        elseif c == ')' || c == ']'
            depth -= 1
            depth == 0 && (push!(out, String(take!(buf))); continue)
        end
        depth >= 1 && print(buf, c)
    end
    return out
end

# evaluate a single TaQL-lite expression with no columns in scope
function _taql_const(exprstr::AbstractString)
    ast = try
        _taqllite_parse(String(strip(exprstr)), Set{String}())
    catch e
        e isa ArgumentError && throw(ArgumentError(
            "taql: INSERT values must be constant (no column references): $(e.msg)"))
        rethrow()
    end
    !_has_aggr(ast) ||
        throw(ArgumentError("taql: INSERT values must be constant, not aggregates"))
    return _tqleval(ast, Dict{String,AbstractVector}(), 1)
end

function _taql_insert(target, cmd::AbstractString)
    limit = nothing
    pm = match(r"^INSERT\s+LIMIT\s+(.+?)\s+INTO\s+(.*)$"is, cmd)
    if pm !== nothing
        limit = Int(_taql_const(pm.captures[1]))
        cmd = "INSERT INTO " * pm.captures[2]
    end
    tm = match(r"^(.*\S)\s+LIMIT\s+(.+?)\s*$"is, cmd)
    if tm !== nothing
        limit === nothing ||
            throw(ArgumentError("taql: INSERT has more than one LIMIT clause"))
        limit = Int(_taql_const(tm.captures[2]))
        cmd = String(tm.captures[1])
    end
    mv = match(r"^INSERT\s+INTO\s+\S+\s*(?:[([]([^)\]]*)[)\]]\s*)?VALUES\s+(.+)$"is, cmd)
    if mv !== nothing
        cols = mv.captures[1] === nothing ?
               columnnames(target isa AbstractTable ? target : readtable(_cmd_path(target))) :
               String.(strip.(split(mv.captures[1], ',')))
        groups = _paren_groups(mv.captures[2])
        isempty(groups) &&
            throw(ArgumentError("taql: INSERT ... VALUES has no value tuples"))
        rows = Vector{Pair{String,Any}}[]
        for g in groups
            vals = _split_commas(g)
            length(vals) == length(cols) || throw(ArgumentError(
                "taql: INSERT value count ($(length(vals))) != column count ($(length(cols)))"))
            push!(rows, Pair{String,Any}[cols[i] => _taql_const(vals[i]) for i in eachindex(cols)])
        end
        return insert!(target; values=rows, limit)
    end
    ms = match(r"^INSERT\s+INTO\s+\S+\s+SET\s+(.+)$"is, cmd)
    if ms !== nothing
        row = Pair{String,Any}[]
        for piece in _split_commas(ms.captures[1])
            am = match(r"^(\w+)\s*=\s*(.+)$"s, piece)
            am === nothing &&
                throw(ArgumentError("taql: malformed SET assignment \"$piece\""))
            push!(row, String(am.captures[1]) => _taql_const(am.captures[2]))
        end
        return insert!(target; values=row, limit)
    end
    throw(ArgumentError("taql: malformed INSERT command"))
end
