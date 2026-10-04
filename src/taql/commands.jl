# TaQL-lite write commands (Phase 30): UPDATE / DELETE / SELECT ... INTO.
#
# Thin wrappers over the existing mutation primitives -- `edit()` +
# `EditColumn` setindex! (Phases 9-11), `removerows!`, `copytable`
# (Phase 15) -- plus the TaQL-lite expression engine (Phases 22-25) for
# the WHERE / SET expressions.  `taql(target, "...")` is a string-command
# dispatcher on top of the Julia functions.

# `limit >= 0` -> the first `limit` rows; `limit < 0` -> the last
# `|limit|` rows (TaQL's UPDATE/DELETE `ORDER BY ... LIMIT n` form).
function _apply_limit(rows::Vector{Int}, limit::Integer)
    n = length(rows)
    limit >= 0 ? rows[1:min(limit, n)] : rows[max(1, n + limit + 1):n]
end

_cmd_path(x::AbstractString) = String(rstrip(x, '/'))
function _cmd_path(t::AbstractTable)
    t isa Table ||
        error("update!/delete!: target is a $(typeof(t)); only a plain on-disk Table " *
              "(or a path) is supported")
    return t.path
end

# Writing a floating value into an integer column (Phase 247, live-verified vs
# real TaQL): truncate toward zero, saturate at the type's limits (`1e12` ->
# typemax, `Inf` -> typemax), `NaN` -> 0. Anything else is unchanged.
# an integer into a NARROWER integer column wraps (two's complement, live-verified Phase 359: `INSERT .. SET H=40000` -> -25536 in an Int16 column)
_tql_coerce(::Type{J}, v) where {J<:Integer} = v isa AbstractFloat ?
    (isnan(v) ? zero(J) : v >= typemax(J) ? typemax(J) : v <= typemin(J) ? typemin(J) : trunc(J, v)) :
    (v isa Integer && !(v isa Bool) ? v % J : v)
_tql_coerce(::Type{Bool}, v) = v
_tql_coerce(::Type, v) = v

"""
    update!(target; set, where=nothing) -> Int

Change column values in the CTDS table at `target` (a path or an open
`Table` / `subtable(ms, …)`). `set` is `"COL" => "expr"` pairs, applied
**in the given order, each RHS seeing any earlier entries' already-
written values for that row** — matching real casacore's own per-row,
per-item `UPDATE` semantics (`TableParseQuery::doUpdate`, verified live:
`set = ["A" => "B", "B" => "A"]` does **not** swap — `A` becomes `B`'s
old value, then `B` reads *that already-updated* `A`, so both end up
equal to the old `B`; to actually swap, stage a temporary column, or
give both new values from a pre-computed constant). The `set` key may
also be an array-slice or boolean-mask target,
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
`nothing` (every row). `orderby` (like [`query`](@ref)'s — a bare
column name/`Symbol`, ascending, or a `name => :asc`/`name => :desc`
pair) sorts the matched rows before `limit` (an `Integer`) keeps only
the first `limit` of them (`limit < 0` keeps the *last* `|limit|`
instead) — "update the N oldest/newest rows matching a condition", e.g.
`update!(t; set=[...], where="...", orderby=["TIME"], limit=10)`.
**A deliberate MeasurementSets extension, not a port of real TaQL's own
`UPDATE ... ORDER BY ... LIMIT n`**: real casacore's `UPDATE`/`DELETE`
`ORDER BY` does not sort the matched rows by the given key before
`LIMIT` truncates them (verified live — `ORDER BY T LIMIT 3` and plain
`LIMIT 3` give byte-identical results on the same data; `T`'s values
play no role). This package's `orderby`/`limit` do a genuine
sort-then-limit instead. Returns the number of rows changed.
"""
function update!(target; set::AbstractVector{<:Pair}, where=nothing,
                 orderby::Union{Nothing,AbstractVector}=nothing,
                 limit::Union{Nothing,Integer}=nothing)
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
        tcol = lhs isa TQLCol ? lhs.name : (fl0 = _flatten_lhs(lhs); fl0 === nothing ? nothing : fl0[1])
        tcol === nothing || (rhs = _unit_assign(rhs, _u1(_col_units(rd, tcol)), n -> _col_units(rd, n)))
        if lhs isa TQLCol
            push!(specs, (lhs.name, nothing, rhs))
        else
            fl = _flatten_lhs(lhs)
            fl === nothing && throw(ArgumentError(
                "update!: SET target \"$lhskey\" must be a column or COL[subscripts]"))
            push!(specs, (fl[1], fl[2], rhs))
        end
    end

    orderkeys = orderby === nothing ? TQLOrderKey[] : [_normalize_orderkey(rd, o) for o in orderby]

    needed = Set{String}(s[1] for s in specs)
    for (_, levels, a) in specs
        _tqlrefs!(needed, a)
        levels === nothing || foreach(ax -> _axes_refs!(needed, ax), levels)
    end
    for k in orderkeys
        push!(needed, k.name)
    end
    whereast = nothing
    if where isa AbstractString
        union!(needed, _tql_where_refs(where, rd))
        whereast = _unit_conv(_taqllite_parse(String(where), vn), rd)
    elseif where isa Function
        union!(needed, columnnames(rd))
    end
    cols = _tql_cols(rd, needed, [s[3] for s in specs], whereast)
    # every SET *target* column must be a genuinely mutable `Vector` --
    # `_tql_cols`/`_load_col` deliberately keeps an array-eltype column
    # as a lazy, read-only `Column` (no `setindex!`) for read-side
    # performance; force materialisation only for columns this update
    # actually writes into (Phase 149 -- needed so a later SET item can
    # observe an earlier one's write, see below).
    for c in Set(s[1] for s in specs)
        cols[c] isa Vector{Any} || (cols[c] = Any[v for v in cols[c]])
    end

    # unit-strip a `Quantity` SET RHS to each target column's own unit
    _qty = whereast !== nothing && _has_qty(whereast) || any(_has_qty(s[3]) for s in specs)
    colunit(c) = _qty ? columnunit(rd, c) : nothing

    rows = _where_rows(rd, where, cols)
    rows = _apply_orderby(rows, orderkeys, cols)
    limit === nothing || (rows = _apply_limit(rows, limit))
    limited = orderby !== nothing || limit !== nothing
    nr = nrow(rd)

    sliced = Set(s[1] for s in specs if s[2] !== nothing)
    fullcols = Dict{String,AbstractVector}()
    if !isempty(sliced)
        rdf = readtable(path; precision=:full)
        for c in sliced
            fullcols[c] = column(rdf, c)
        end
    end

    if isempty(rows)
        # Real TaQL type-checks the whole SET list once, independent of how
        # many rows WHERE actually matches (Phase 287, live-verified: `UPDATE
        # t SET FA[B] = x WHERE <condition matching nothing>` still errors --
        # e.g. a scalar Bool used where an array mask is required for a
        # subscript). Our own evaluation is lazily per matched row, so with
        # none matched nothing was ever checked and the (no-op) update
        # silently "succeeded". Emulate the static check, without a real
        # type system, by running the exact per-row apply logic once against
        # row 1 (if the table has one) into a throwaway copy -- for whatever
        # error it raises, never persisted.
        if nr >= 1
            for (c, levels, a) in specs
                u = colunit(c)
                ev = x -> _tql_write_strip(_unwrap_marray(_tqleval(x, cols, 1)), u)
                if levels === nothing
                    ev(a)
                else
                    cur = copy(haskey(fullcols, c) ? fullcols[c][1] : cols[c][1])
                    if length(levels) == 1 && _as_mask(levels[1], ev) === nothing
                        _slice_assign!(cur, _tql_index_tuple(cur, levels[1], ev), ev(a))
                    else
                        _apply_index_chain!(cur, levels, ev, ev(a))
                    end
                end
            end
        end
        return 0
    end

    # Phase 149: casacore's own `TableParseQuery::doUpdate` applies the
    # SET list one item at a time, per row, writing straight to the live
    # (writable) column -- so a LATER item's RHS sees an EARLIER item's
    # already-written value for that same row (live-verified: `SET A=B,
    # B=A` does NOT swap in real casacore). Previously this function
    # grouped `specs` by target column and evaluated every item's RHS
    # against one fixed pre-update snapshot (`cols`), giving true "swap"
    # semantics -- a real, confirmed divergence. Fixed by processing
    # `specs` in their ORIGINAL given order (no more grouping-by-column)
    # and updating `cols[c][i]` (for a plain overwrite) / `curval[(c,i)]`
    # (the full-precision seed a later slice/mask op on the same cell
    # continues from) immediately after each write, so every subsequent
    # spec — on the same or a different column — observes it.
    curval = Dict{Tuple{String,Int},Any}()
    _curbase(c, i) = get(curval, (c, i)) do
        haskey(fullcols, c) ? fullcols[c][i] : cols[c][i]
    end

    # a scalar written into an ARRAY column fills the cell's current shape; an array into a FIXED-shape column must have exactly that shape
    # (real TaQL, live-verified Phase 359 -- it used to be silently truncated here)
    function fit_cell(c, i, x)
        cd = columndesc(rd, c)
        isarr = !(cd.shape isa Dims && isempty(cd.shape))
        isarr || return x
        fs = cd.shape isa Dims ? cd.shape : nothing
        if x isa AbstractArray
            fs !== nothing && size(x) != fs && throw(ArgumentError("update!: column \"$c\" has the fixed shape $fs, got an array of size $(size(x))"))
            return x
        elseif x isa Number || x isa AbstractString
            cur = _curbase(c, i)
            return fill(x, cur isa AbstractArray ? size(cur) : fs === nothing ? (1,) : fs)
        end
        return x
    end
    edit(path) do t
        for (c, levels, a) in specs
            u = colunit(c)
            ec = t[c]
            Jc = juliatype(columndesc(rd, c).type)
            if levels === nothing
                if where === nothing && !limited
                    vals = [fit_cell(c, i, _tql_coerce(Jc, _tql_write_strip(_unwrap_marray(_tqleval(a, cols, i)), u))) for i in 1:nr]
                    ec[:] = vals
                    for i in 1:nr
                        cols[c][i] = vals[i]
                        curval[(c, i)] = vals[i]
                    end
                else
                    for i in rows
                        val = fit_cell(c, i, _tql_coerce(Jc, _tql_write_strip(_unwrap_marray(_tqleval(a, cols, i)), u)))
                        ec[i] = val
                        cols[c][i] = val
                        curval[(c, i)] = val
                    end
                end
            else
                for i in rows
                    ev = x -> _tql_write_strip(_unwrap_marray(_tqleval(x, cols, i)), u)
                    cur = copy(_curbase(c, i))
                    if length(levels) == 1 && _as_mask(levels[1], ev) === nothing
                        _slice_assign!(cur, _tql_index_tuple(cur, levels[1], ev), ev(a))
                    else
                        _apply_index_chain!(cur, levels, ev, ev(a))
                    end
                    ec[i] = _unwrap_marray(cur)
                    cols[c][i] = cur
                    curval[(c, i)] = cur
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
        # Phase 149: push the MASK entry BEFORE the data entry. `update!`'s
        # SET items apply strictly in order, each mutating the live `cols`
        # snapshot so a LATER item sees an EARLIER item's write (the real-
        # casacore semantics fixed in that phase) -- but `me` (or the
        # default `TQLMaskOf`, below) re-evaluates the ORIGINAL expression
        # from `cols`, not from `D`'s already-computed result, so it must
        # run BEFORE `D`'s own write overwrites the data it reads from.
        # no explicit mask: use the data expr's own mask when it is a
        # masked array, else flag its non-finite elements (Phase 59).
        push!(out, mn => (me === nothing ? TQLMaskOf(_taqllite_parse(de, vn)) : me))
        push!(out, dn => de)
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
    delete!(target; where=nothing, orderby=nothing, limit=nothing) -> Int

Remove rows from the CTDS table at `target` (a path or an open `Table`).
`where` is a TaQL-lite WHERE string, a `row -> Bool` closure, or
`nothing` (**every row** — leaves a 0-row table). `orderby`/`limit` — see
[`update!`](@ref) — sort the matched rows then keep only `limit` of them
(`limit < 0` keeps the *last* `|limit|`) before deleting, e.g. "delete
the 10 oldest rows matching a condition":
`delete!(t; where="...", orderby=["TIME"], limit=10)`. Returns the
number of rows removed. Extends `Base.delete!`.
"""
function Base.delete!(target::Union{AbstractString,AbstractTable}; where=nothing,
                      orderby::Union{Nothing,AbstractVector}=nothing,
                      limit::Union{Nothing,Integer}=nothing)
    path = _cmd_path(target)
    rd = readtable(path)
    orderkeys = orderby === nothing ? TQLOrderKey[] : [_normalize_orderkey(rd, o) for o in orderby]
    names =
        where isa Function ? columnnames(rd) :
        where isa AbstractString ? collect(_tql_where_refs(where, rd)) :
        String[]
    names = union(names, (k.name for k in orderkeys))
    # the parsed WHERE decides unit attachment / epoch-date conversion in `_tql_cols` (a quantity literal or date function in a DELETE condition)
    cols = _tql_cols(rd, names, where isa AbstractString ? _taqllite_parse(String(where), Set(columnnames(rd))) : nothing)
    rows = _where_rows(rd, where, cols)
    isempty(rows) && return 0
    rows = _apply_orderby(rows, orderkeys, cols)
    limit === nothing || (rows = _apply_limit(rows, limit))
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
    fixed = Dict(n => (cd = columndesc(rd, n); cd.shape isa Dims && !isempty(cd.shape) ? cd.shape : nothing) for n in vn)
    old = nrow(rd)
    # a FIXED-shape array column takes a scalar (broadcast to every element) or an array of exactly its shape (real TaQL, Phase 359)
    function cell(c, v)
        sc[c] && v isa Number && return convert(J[c], _tql_coerce(J[c], v))
        fs = fixed[c]
        fs === nothing && return v
        v isa Number && return fill(convert(J[c], _tql_coerce(J[c], v)), fs)
        (v isa AbstractString && J[c] === String) && return fill(String(v), fs)
        v isa AbstractArray && (size(v) == fs || throw(ArgumentError("insert!: column \"$c\" has the fixed shape $fs, got an array of size $(size(v))")))
        return v
    end
    for r in rows, (c, v) in r
        cell(c, v)                      # validate every cell before any row is added
    end
    edit(path) do t
        addrows!(t, k)
        for (ri, r) in enumerate(rows), (c, v) in r
            t[c][old + ri] = cell(c, v)
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

# "K1 DESC, K2, K3 ASC" -> ["K1"=>:desc, "K2", "K3"=>:asc], for update!'s
# / delete!'s `orderby=` kwarg (Phase 111's UPDATE/DELETE ORDER BY).
function _taql_orderby_list(s::AbstractString)
    out = Any[]
    for tok in split(s, ',')
        t = strip(tok)
        om = match(r"^(\w+)\s*(ASC|DESC)?$"i, t)
        om === nothing && throw(ArgumentError("taql: malformed ORDER BY term \"$t\""))
        name = String(om.captures[1])
        dir = om.captures[2]
        push!(out, dir === nothing ? name :
              (uppercase(dir) == "DESC" ? name => :desc : name => :asc))
    end
    return out
end

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

# ---- SELECT LIMIT / OFFSET (Phase 255; live-probed vs real TaQL) -------------
# `LIMIT n [OFFSET m]`, `OFFSET m [LIMIT n]`, or the 0-based half-open range
# `LIMIT a:b[:s]` (each part optional).  Over the `nr` result rows:
#  * n > 0 = that many rows; n == 0 = no limit; n < 0 = `nr + n` rows (all but the
#    last |n|, counted from the START row, then clipped);
#  * m < 0 counts from the end (clipped at 0); m >= nr is an error;
#  * a range: a/b default 0/end, a negative a/b counts from the end, b == 0 = end,
#    b is clipped to nr, an empty range / a >= nr / step <= 0 are errors; a range
#    cannot be combined with OFFSET.
function _parse_select_window(tail::AbstractString)
    limit = nothing; offset = nothing; range = nothing
    rest = String(strip(tail))
    while !isempty(rest)
        m = match(r"^(LIMIT|OFFSET)\s+(-?\d*(?::-?\d*(?::\d*)?)?)(?:\s+(.*))?$"is, rest)
        m === nothing && throw(ArgumentError("taql: malformed LIMIT/OFFSET clause \"$tail\""))
        kw = uppercase(m.captures[1]); v = m.captures[2]
        rest = m.captures[3] === nothing ? "" : String(strip(m.captures[3]))
        if kw == "LIMIT"
            (limit === nothing && range === nothing) || throw(ArgumentError("taql: duplicate LIMIT"))
            if occursin(':', v)
                ps = split(v, ':')
                num(x) = isempty(x) ? nothing : parse(Int, x)
                range = (num(ps[1]), num(ps[2]), length(ps) > 2 ? num(ps[3]) : nothing)
            else
                isempty(v) && throw(ArgumentError("taql: LIMIT needs a number"))
                limit = parse(Int, v)
            end
        else
            (offset === nothing && !occursin(':', v) && !isempty(v)) ||
                throw(ArgumentError("taql: bad OFFSET \"$v\""))
            offset = parse(Int, v)
        end
    end
    (range !== nothing && offset !== nothing) &&
        throw(ArgumentError("taql: LIMIT a:b cannot be combined with OFFSET"))
    return (; limit, offset, range)
end

function _select_window(nr::Integer, w)
    if w.range !== nothing
        a, b, s = w.range
        a = a === nothing ? 0 : (a < 0 ? nr + a : a)
        b = (b === nothing || b == 0) ? nr : (b < 0 ? nr + b : min(b, nr))
        s = s === nothing ? 1 : s
        (s > 0 && 0 <= a < nr && a < b) ||
            throw(ArgumentError("taql: invalid LIMIT range"))
        return (a + 1):s:b
    end
    start = w.offset === nothing ? 0 : (w.offset < 0 ? max(0, nr + w.offset) : w.offset)
    (w.offset === nothing || start < nr) || throw(ArgumentError("taql: OFFSET beyond the end"))
    l = w.limit === nothing ? 0 : w.limit
    cnt = l > 0 ? l : l == 0 ? nr : max(0, nr + l)
    return (start + 1):min(start + cnt, nr)
end

# row subset (in the given order) of a `query`/`groupby` result, keeping its kind
_select_rows(r::RefTable, keep) =
    RefTable(r.path, r.parent, r.rows[keep], r.namemap, r.order, r.type, r.subtype, r.readme)
_select_rows(r::GroupedTable, keep) =
    GroupedTable(getfield(r, :names), AbstractVector[getfield(r, :cols)[j][keep] for j in eachindex(getfield(r, :cols))])

# ---- SELECT ... FROM $1 a JOIN $2 b ON a.K == b.K (Phase 259; live-probed) ----
# Real TaQL's JOIN is a LEFT join with type sentinels for unmatched left rows:
# Int -> typemax(Int64), Float -> NaN, Complex -> NaN+NaNim, Bool -> false,
# String -> "none".  `taql(target, cmd, others...)`: `\$1` is `target`, `\$2` ... the
# extra tables.  The joined columns are named `a.COL` / `b.COL`.  One `==` condition
# (real TaQL rejects `AND`); the right key must be unique.
function _taql_sentinel(c::AbstractVector)
    Missing <: eltype(c) || return c
    T = nonmissingtype(eltype(c))
    T <: Bool && return Bool[ismissing(x) ? false : x for x in c]
    T <: Integer && return Int64[ismissing(x) ? typemax(Int64) : Int64(x) for x in c]
    T <: AbstractFloat && return Float64[ismissing(x) ? NaN : Float64(x) for x in c]      # widened like real TaQL's computed columns
    T <: Complex && return ComplexF64[ismissing(x) ? ComplexF64(NaN, NaN) : ComplexF64(x) for x in c]
    T <: AbstractString && return String[ismissing(x) ? "none" : String(x) for x in c]
    if T <: AbstractArray      # an unmatched row is an EMPTY array; elements are widened like a plain column's (real TaQL, Phase 358)
        E = eltype(T); N = ndims(T)
        W = E <: Bool ? Bool : E <: Integer ? Int64 : E <: AbstractFloat ? Float64 : E <: Complex ? ComplexF64 : E <: AbstractString ? String : E
        return Array{W,N}[ismissing(x) ? Array{W,N}(undef, ntuple(_ -> 0, N)...) : Array{W,N}(x) for x in c]
    end
    throw(ArgumentError("taql: JOIN of a column of type $T is not supported"))
end

# `FROM $1 a JOIN $2 b ON <cond> [JOIN $3 c ON <cond> ...]`, <cond> = `x.p == y.q`
# (`=` / `IN` too, either order); `q` may be `rowid()` (an INDEX lookup: the other
# side's value is the 0-based right row).  A duplicate right key matches its FIRST
# row (real TaQL).  Chained joins match against the joined table so far.  `a.rowid()`
# / `b.rowid()` are the 0-based source row of each side (sentinel when unmatched).
const _JOIN_SIDE = raw"(\w+)\.(\w+(?:\(\))?)"
function _taql_join_from(target, body::AbstractString, others)
    m = match(Regex("\\bFROM\\s+\\\$(\\d+)\\s+(?:AS\\s+)?(\\w+)\\s+JOIN\\b", "i"), body)
    m === nothing && return target, body
    tab(k) = (i = parse(Int, k);
              i == 1 ? (target isa AbstractTable ? target : readtable(_cmd_path(target))) :
              (i - 1 <= length(others) ? (o = others[i-1]; o isa AbstractTable ? o : readtable(_cmd_path(o))) :
               throw(ArgumentError("taql: no table \$$i (pass it as an extra argument)"))))
    left = tab(m.captures[1]); la = String(m.captures[2])
    names = String[la * "." * n for n in columnnames(left)]
    cols = AbstractVector[collect(column(left, n)[:]) for n in columnnames(left)]
    jun = Dict{Symbol,Vector{String}}(); jep = Set{Symbol}()
    for n in columnnames(left); _join_meta!(jun, jep, left, n, la * "." * n); end
    push!(names, la * ".__rowid"); push!(cols, collect(0:nrow(left)-1))
    pos = m.offset + length(m.match) - length("JOIN")       # start of the first JOIN
    jre = Regex("^JOIN\\s+\\\$(\\d+)\\s+(?:AS\\s+)?(\\w+)\\s+ON\\s+" * _JOIN_SIDE *
                "\\s*(?:==|=|\\bIN\\b)\\s*" * _JOIN_SIDE * "\\s*", "i")
    rest = body[pos:end]
    while (jm = match(jre, rest)) !== nothing
        right = tab(jm.captures[1]); ra = String(jm.captures[2])
        (q1, c1, q2, c2) = (String(jm.captures[3]), String(jm.captures[4]), String(jm.captures[5]), String(jm.captures[6]))
        if q1 == ra && q2 != ra
            (rc, oq, oc) = (c1, q2, c2)
        elseif q2 == ra && q1 != ra
            (rc, oq, oc) = (c2, q1, c1)
        else
            throw(ArgumentError("taql: the JOIN condition must relate the new alias \"$ra\" to an earlier one"))
        end
        oc == "rowid()" && throw(ArgumentError("taql: rowid() is only supported on the joined (right) side of ON"))
        lidx = findfirst(==(oq * "." * oc), names)
        lidx === nothing && throw(ArgumentError("taql: unknown column \"$oq.$oc\" in the JOIN condition"))
        lk = cols[lidx]; nr = nrow(right)
        if rc == "rowid()"
            mr = Int[(ismissing(v) ? 0 : (0 <= v < nr ? Int(v) + 1 : 0)) for v in lk]
        else
            rcol = collect(column(right, rc)[:])
            first = Dict{Any,Int}()
            for (i, v) in enumerate(rcol); haskey(first, v) || (first[v] = i); end
            mr = Int[get(first, v, 0) for v in lk]
        end
        for n in columnnames(right)
            rcx = collect(column(right, n)[:])
            T = eltype(rcx)
            push!(names, ra * "." * n)
            _join_meta!(jun, jep, right, n, ra * "." * n)
            # sentinel-fill unmatched rows; the values are widened (Float32 -> Float64, ...) like real TaQL's result columns either way
            push!(cols, (any(iszero, mr) || T <: Union{Number,AbstractString,AbstractArray}) ?
                        _taql_sentinel(Union{T,Missing}[r == 0 ? missing : rcx[r] for r in mr]) : T[rcx[r] for r in mr])
        end
        push!(names, ra * ".__rowid")
        push!(cols, Int64[r == 0 ? typemax(Int64) : Int64(r - 1) for r in mr])
        rest = rest[length(jm.match)+1:end]
    end
    joined = GroupedTable(Symbol.(names), cols, jun, jep)
    body = body[1:m.offset-1] * "FROM __join " * rest
    body = replace(body, r"\b(\w+)\.rowid\(\)" => s"\1.__rowid")
    return joined, body
end

# ---- SELECT sub-queries + table aliases (Phase 257; live-probed vs real TaQL) ----
# `FROM (SELECT ...)` runs the inner SELECT and queries its result; `x IN (SELECT
# col ...)` / `NOT IN` become a literal list (an empty one: FALSE / TRUE);
# `[NOT] EXISTS (SELECT ...)` becomes TRUE / FALSE (real TaQL errors on a POSITIVE
# `EXISTS` / `IN` of an empty sub-query -- 0 rows here); `FROM t [AS] a` strips
# the `a.` qualifier from every column reference.
function _matching_paren(s::AbstractString, i::Int)
    depth = 0; q = '\0'
    for j in i:lastindex(s)
        c = s[j]
        if q != '\0'
            c == q && (q = '\0')
        elseif c == '\'' || c == '"'
            q = c
        elseif c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return j
        end
    end
    throw(ArgumentError("taql: unbalanced parentheses in a sub-query"))
end

_sub_literal(x::AbstractString) = "'" * replace(String(x), "'" => "\\'") * "'"
_sub_literal(x::Bool) = x ? "TRUE" : "FALSE"
_sub_literal(x) = repr(x)

# `x [NOT] IN (SELECT ...)` / `[NOT] EXISTS (SELECT ...)` -> literals (evaluated on `target`)
function _taql_subst_subqueries(target, body::AbstractString)
    body = String(body)
    while (m = match(r"\b(NOT\s+)?(IN|EXISTS)\s*\(\s*SELECT\b"i, body)) !== nothing
        open = findnext('(', body, m.offset)
        close = _matching_paren(body, open)
        inner = String(strip(body[open+1:close-1]))
        r = taql(target, inner)
        neg = m.captures[1] !== nothing
        if uppercase(m.captures[2]) == "EXISTS"
            v = nrow(r) > 0
            # real TaQL treats `EXISTS (... LIMIT n)` as empty when fewer than n rows match (a positive one errors)
            lm = match(r"^(.*)\bLIMIT\s+(\d+)\s*$"is, inner)
            lm !== nothing && nrow(taql(target, String(lm.captures[1]))) < parse(Int, lm.captures[2]) && (v = false)
            body = body[1:m.offset-1] * (xor(v, neg) ? "TRUE" : "FALSE") * body[close+1:end]
        else
            names = columnnames(r)
            vals = isempty(names) ? Any[] : collect(column(r, first(names))[:])
            lit = isempty(vals) ? "[]" : "[" * join((_sub_literal(v) for v in unique(vals)), ", ") * "]"
            head = body[1:m.offset-1] * (neg ? "NOT " : "") * "IN "
            body = head * lit * body[close+1:end]
        end
    end
    return body
end

# UPDATE / DELETE: sub-queries in the WHERE, and `UPDATE t [AS] a SET` /
# `DELETE FROM t [AS] a` aliases (dropped, with their `a.` qualifiers)
function _taql_preprocess_write(target, cmd::AbstractString)
    cmd = _taql_subst_subqueries(target, cmd)
    am = match(r"^UPDATE\s+\S+\s+(?:AS\s+)?(?!SET\b)(\w+)\s+SET\b"i, cmd)
    am === nothing && (am = match(r"^DELETE\s+FROM\s+\S+\s+(?:AS\s+)?(?!(?:WHERE|ORDER|LIMIT)\b)(\w+)"i, cmd))
    if am !== nothing
        alias = String(am.captures[1])
        cmd = replace(am.match, Regex("\\s+(?:AS\\s+)?" * alias * "(?=\\s+SET\\b|\\z)", "i") => "") * cmd[length(am.match)+1:end]
        cmd = replace(cmd, Regex("\\b" * alias * "\\.(?=[A-Za-z_])") => "")
    end
    return cmd
end

function _taql_preprocess_select(target, body::AbstractString)
    body = String(body)
    # `SELECT FROM t ...` / `SELECT WHERE ...` (no column list) = `SELECT *`
    body = replace(body, r"^SELECT\s+(?=(?:FROM|WHERE|ORDER|LIMIT|OFFSET|GROUP|HAVING)\b)"i => "SELECT * ")
    body = replace(body, r"^SELECT\s+ALL\s+"i => "SELECT ")          # `SELECT ALL` = the default
    body = replace(body, r"\bORDERBY\b"i => "ORDER BY")               # one-word spelling
    # FROM (SELECT ...) -> the inner result becomes the queried table (sub-queries in the WHERE still name the original table, `$1`)
    orig = target
    m = match(r"\bFROM\s*\("i, body)
    if m !== nothing
        open = m.offset + length(m.match) - 1
        close = _matching_paren(body, open)
        inner = String(strip(body[open+1:close-1]))
        occursin(r"^SELECT\b"i, inner) || throw(ArgumentError("taql: FROM (...) must hold a SELECT"))
        target = taql(target, inner)
        body = body[1:m.offset-1] * "FROM __sub" * body[close+1:end]
    end
    body = _taql_subst_subqueries(orig, body)
    # `FROM name [AS] alias` -> drop the alias and its `alias.` qualifiers
    am = match(r"\bFROM\s+\S+\s+(?:AS\s+)?(?!(?:WHERE|GROUP|HAVING|ORDER|LIMIT|OFFSET|INTO|GIVING)\b)(\w+)"i, body)
    if am !== nothing
        alias = String(am.captures[1])
        body = body[1:am.offset-1] * replace(am.match, Regex("\\s+(?:AS\\s+)?" * alias * "\\z", "i") => "") *
               body[am.offset+length(am.match):end]
        body = replace(body, Regex("\\b" * alias * "\\.(?=[A-Za-z_])") => "")
    end
    return target, body
end

# ---- Phase 346: `ALTER TABLE` (live-probed against real TaQL) ---------------------------------------------------------
# `ALTER TABLE tbl clause [clause ...]` with the clauses `ADD COLUMN name type [[NDIM=n, SHAPE=[..]]] [, ...] [DMINFO [..]]`,
# `DROP COLUMN a[, b]`, `RENAME COLUMN a TO b[, c TO d]`, `SET KEYWORD k=expr[, ...]` (`COL::k` for a column keyword),
# `DROP KEYWORD k[, ...]`, `RENAME KEYWORD a TO b`.  A keyword value is a constant expression.  `ADD COLUMN` fills the new
# column with zeros / empty strings / `false` (undefined cells for an array column with only an NDIM).
const _ALTER_CLAUSE = r"\b(ADD\s+COLUMN|DROP\s+COLUMN|RENAME\s+COLUMN|SET\s+KEYWORD|DROP\s+KEYWORD|RENAME\s+KEYWORD)\b"i
const _ALTER_TYPES = Dict{String,DataType}("B" => Bool, "BOOL" => Bool, "BOOLEAN" => Bool, "U1" => UInt8, "UCHAR" => UInt8,
    "I2" => Int16, "SHORT" => Int16, "U2" => UInt16, "USHORT" => UInt16, "I4" => Int32, "INT" => Int32, "INTEGER" => Int32,
    "U4" => UInt32, "UINT" => UInt32, "I8" => Int64, "R4" => Float32, "FLOAT" => Float32, "R8" => Float64, "DOUBLE" => Float64,
    "C4" => ComplexF32, "COMPLEX" => ComplexF32, "C8" => ComplexF64, "DCOMPLEX" => ComplexF64, "S" => String, "STRING" => String)

function _alter_add_column(path::String, item::AbstractString)
    m = match(r"^(\w+)\s+(\w+)\s*(?:\[(.*)\])?\s*$"s, strip(item))
    m === nothing && throw(ArgumentError("taql: malformed ADD COLUMN item \"$item\""))
    name = String(m.captures[1]); T = get(_ALTER_TYPES, uppercase(m.captures[2]), nothing)
    T === nothing && throw(ArgumentError("taql: unknown column type \"$(m.captures[2])\" in ALTER TABLE ADD COLUMN"))
    ndim = nothing; shp = nothing
    if m.captures[3] !== nothing
        for a in _split_commas(m.captures[3])
            am = match(r"^(\w+)\s*=\s*(.+)$"s, strip(a))
            am === nothing && throw(ArgumentError("taql: malformed column attribute \"$a\""))
            key = uppercase(am.captures[1]); val = strip(am.captures[2])
            if key == "NDIM"
                ndim = parse(Int, val)
            elseif key == "SHAPE"
                shp = Tuple(parse.(Int, split(strip(val, ['[', ']']), ',')))
            else
                throw(ArgumentError("taql: unsupported column attribute $key in ALTER TABLE ADD COLUMN"))
            end
        end
    end
    n = nrow(readtable(path))
    z(T) = T === String ? "" : zero(T)
    if shp !== nothing
        data = [fill(z(T), shp...) for _ in 1:n]; cs = shp
    elseif ndim !== nothing && ndim > 0
        data = [fill(z(T), ntuple(_ -> 0, ndim)...) for _ in 1:n]; cs = VariableShape(ndim)
    elseif ndim !== nothing && ndim == 0
        data = [fill(z(T), 0) for _ in 1:n]; cs = VariableDims()
    else
        data = fill(z(T), n); cs = nothing
    end
    edit(path) do t
        addcolumn!(t, name, data; type=_casatype_of(T), shape=cs)
    end
end

# Replay the clauses on the column names and keyword (name => value class) sets only, raising what the real run would raise.
function _alter_dryrun(path::String, clauses)
    rd = readtable(path)
    cols = Set(columnnames(rd))
    kws = Dict{Union{Nothing,String},Dict{String,String}}(nothing => Dict(String(rd.desc.public.names[i]) => _kw_class(rd.desc.public.types[i]) for i in eachindex(rd.desc.public.names)))
    function scope(col)
        col === nothing || col in cols || throw(KeyError(col))
        get!(kws, col) do
            col === nothing ? Dict{String,String}() :
                (k = columndesc(rd, col).keywords; Dict(String(k.names[i]) => _kw_class(k.types[i]) for i in eachindex(k.names)))
        end
    end
    for (kind, rest) in clauses
        if kind == "ADD COLUMN"
            body = replace(rest, r"\s+DMINFO\s*\[.*\]\s*$"is => "")
            for it in _split_commas(body)
                nm = match(r"^(\w+)", strip(it)); nm === nothing && continue
                String(nm.captures[1]) in cols && throw(ArgumentError("taql: ALTER TABLE ADD COLUMN: column \"$(nm.captures[1])\" already exists"))
                push!(cols, String(nm.captures[1]))
            end
        elseif kind == "DROP COLUMN"
            for it in _split_commas(rest)
                nm = String(strip(it)); nm in cols || throw(KeyError(nm)); delete!(cols, nm)
            end
        elseif kind == "RENAME COLUMN"
            for it in _split_commas(rest)
                rm = match(r"^(\w+)\s+TO\s+(\w+)$"i, strip(it)); rm === nothing && continue
                a, b = String(rm.captures[1]), String(rm.captures[2])
                a in cols || throw(KeyError(a)); b in cols && throw(ArgumentError("taql: ALTER TABLE: the table already has a column \"$b\""))
                delete!(cols, a); push!(cols, b)
                haskey(kws, a) && (kws[b] = pop!(kws, a))
            end
        elseif kind == "SET KEYWORD"
            for it in _split_commas(rest)
                am = match(r"^((?:\w+::)?\w+)\s*=\s*(.+)$"s, strip(it)); am === nothing && continue
                col, kn = _alter_kwname(am.captures[1]); sc = scope(col)
                v = _taql_const(String(strip(am.captures[2])))
                haskey(sc, kn) && !startswith(sc[kn], "array") && v isa AbstractVector && length(v) == 1 && (v = v[1])
                cls = _kw_class(_kw_value(_kw_normalize(v))[1])
                haskey(sc, kn) && sc[kn] != cls && throw(ArgumentError("taql: keyword \"$kn\" holds a $(sc[kn]) value; cannot replace it by a $cls one"))
                sc[kn] = cls
            end
        elseif kind == "DROP KEYWORD"
            for it in _split_commas(rest)
                col, kn = _alter_kwname(strip(it)); sc = scope(col)
                haskey(sc, kn) || throw(KeyError(kn)); delete!(sc, kn)
            end
        else
            for it in _split_commas(rest)
                rm = match(r"^((?:\w+::)?\w+)\s+TO\s+(\w+)$"i, strip(it)); rm === nothing && continue
                col, kn = _alter_kwname(rm.captures[1]); sc = scope(col); nn = String(rm.captures[2])
                haskey(sc, kn) || throw(KeyError(kn))
                kn == nn && continue
                haskey(sc, nn) && throw(ArgumentError("taql: keyword \"$nn\" already exists"))
                sc[nn] = pop!(sc, kn)
            end
        end
    end
    return nothing
end

function _taql_alter(target, command::AbstractString)
    path = _cmd_path(target)
    m = match(r"^ALTER\s+TABLE\s+(\S+)\s+(.+)$"is, strip(command))
    m === nothing && throw(ArgumentError("taql: malformed ALTER TABLE command"))
    body = String(m.captures[2])
    starts = collect(eachmatch(_ALTER_CLAUSE, body))
    isempty(starts) && throw(ArgumentError("taql: ALTER TABLE needs ADD COLUMN / DROP COLUMN / RENAME COLUMN / SET KEYWORD / DROP KEYWORD / RENAME KEYWORD"))
    strip(body[1:starts[1].offset-1]) == "" || throw(ArgumentError("taql: unexpected text before the first ALTER TABLE clause"))
    clauses = Tuple{String,String}[]
    for (i, cm) in enumerate(starts)
        stop = i < length(starts) ? starts[i+1].offset - 1 : lastindex(body)
        push!(clauses, (uppercase(replace(String(cm.match), r"\s+" => " ")), String(strip(body[cm.offset+length(cm.match):stop]))))
    end
    _alter_dryrun(path, clauses)       # real TaQL leaves the table untouched when any clause fails: check them all first
    for (kind, rest) in clauses
        if kind == "ADD COLUMN"
            # real TaQL needs one `DMINFO [..]` per ADD COLUMN clause (after all its columns); without it, or with several, it fails
            length(collect(eachmatch(r"\bDMINFO\b"i, rest))) == 1 && occursin(r"\s+DMINFO\s*\[.*\]\s*$"is, rest) ||
                throw(ArgumentError("taql: ADD COLUMN needs exactly one DMINFO [...] after its column list"))
            rest = String(strip(replace(rest, r"\s+DMINFO\s*\[.*\]\s*$"is => "")))
            foreach(it -> _alter_add_column(path, it), _split_commas(rest))
        elseif kind == "DROP COLUMN"
            names = String[String(strip(s)) for s in _split_commas(rest)]
            rd = readtable(path)
            for nm in names
                nm in columnnames(rd) || throw(KeyError(nm))
            end
            edit(path) do t
                for nm in names
                    removecolumn!(t, nm)
                end
            end
        elseif kind == "RENAME COLUMN"
            for it in _split_commas(rest)
                rm = match(r"^(\w+)\s+TO\s+(\w+)$"i, strip(it))
                rm === nothing && throw(ArgumentError("taql: malformed RENAME COLUMN item \"$it\""))
                renamecolumn!(path, String(rm.captures[1]), String(rm.captures[2]))
            end
        elseif kind == "SET KEYWORD"
            for it in _split_commas(rest)
                am = match(r"^((?:\w+::)?\w+)\s*=\s*(.+)$"s, strip(it))
                am === nothing && throw(ArgumentError("taql: malformed SET KEYWORD item \"$it\""))
                col, kwname = _alter_kwname(am.captures[1])
                setkeyword!(path, kwname, _taql_const(String(strip(am.captures[2]))); column=col)
            end
        elseif kind == "DROP KEYWORD"
            for it in _split_commas(rest)
                col, kwname = _alter_kwname(strip(it))
                removekeyword!(path, kwname; column=col)
            end
        else   # RENAME KEYWORD a TO b
            for it in _split_commas(rest)
                rm = match(r"^((?:\w+::)?\w+)\s+TO\s+(\w+)$"i, strip(it))
                rm === nothing && throw(ArgumentError("taql: malformed RENAME KEYWORD item \"$it\""))
                col, kwname = _alter_kwname(rm.captures[1])
                renamekeyword!(path, kwname, String(rm.captures[2]); column=col)
            end
        end
    end
    return path
end
function _alter_kwname(s)
    if occursin("::", s)
        a, b = split(s, "::"; limit=2)
        return (String(a), String(b))
    end
    return (nothing, String(s))
end


# ---- Phase 347: `CREATE TABLE` / `DROP TABLE` (live-probed against real TaQL) -----------------------------------------
# `CREATE TABLE path [AS [storage="multifile", blocksize=n]] [name type [[NDIM=n, SHAPE=[..], UNIT="m", COMMENT=".."]], ...]
#  [LIMIT nrow] [DMINFO [TYPE="IncrementalStMan", COLUMNS=["A", ..]]]` makes a new table of default-valued rows (zeros, empty
# strings, `false`; undefined cells for an NDIM-only array column); `DROP TABLE path` deletes one.  Both work without a target
# table: `taql("CREATE TABLE ...")`.
function _bracket_group(s::AbstractString, i::Int)       # s[i] == '[' -> (inner text, index after the matching ']')
    depth = 0; q = '\0'
    for k in i:lastindex(s)
        c = s[k]
        if q != '\0'
            c == q && (q = '\0')
        elseif c == '\'' || c == '"'
            q = c
        elseif c == '['
            depth += 1
        elseif c == ']'
            depth -= 1
            depth == 0 && return (s[nextind(s, i):prevind(s, k)], nextind(s, k))
        end
    end
    throw(ArgumentError("taql: unbalanced '[' in \"$s\""))
end

function _taql_table_path(tok::AbstractString)
    t = strip(tok)
    return String(length(t) >= 2 && t[1] in ('\'', '"') && t[end] == t[1] ? t[2:end-1] : t)
end

function _taql_create(command::AbstractString)
    s = String(strip(command))
    m = match(r"^CREATE\s+TABLE\s+('[^']*'|\"[^\"]*\"|[^\s\[]+)\s*"i, s)
    m === nothing && throw(ArgumentError("taql: malformed CREATE TABLE command"))
    path = _taql_table_path(m.captures[1])
    i = m.offset + length(m.match)
    rest(i) = lstrip(s[i:end])
    storage = :sepfile; blocksize = DEFAULT_MF_BLOCKSIZE
    am = match(r"^AS\s*(?=\[)"i, rest(i))
    if am !== nothing
        i += (length(s[i:end]) - length(rest(i))) + length(am.match)
        inner, i = _bracket_group(s, i)
        for opt in _split_commas(inner)
            om = match(r"^(\w+)\s*=\s*(.+)$"s, strip(opt))
            om === nothing && throw(ArgumentError("taql: malformed CREATE TABLE option \"$opt\""))
            key = lowercase(om.captures[1]); val = strip(strip(om.captures[2]), ['"', '\''])
            if key == "storage"
                storage = Symbol(lowercase(val))
            elseif key == "blocksize"
                blocksize = parse(Int, val)
            else
                throw(ArgumentError("taql: unsupported CREATE TABLE option $key"))
            end
        end
    end
    i += length(s[i:end]) - length(rest(i))
    (i <= lastindex(s) && s[i] == '[') || throw(ArgumentError("taql: CREATE TABLE needs a column list [name type, ...]"))
    colstr, i = _bracket_group(s, i)
    tail = String(strip(s[i:end]))
    nrows = 0; dminfo = nothing
    lm = match(r"^LIMIT\s+(.+?)(?=\s+DMINFO\b|$)"is, tail)
    if lm !== nothing
        nrows = Int(_taql_const(String(strip(lm.captures[1]))))
        nrows >= 0 || throw(ArgumentError("taql: CREATE TABLE LIMIT must not be negative"))
        tail = String(strip(tail[length(lm.match)+1:end]))
    end
    dm = match(r"^DMINFO\s*(?=\[)"i, tail)
    if dm !== nothing
        j = findfirst('[', tail)
        dminfo, j2 = _bracket_group(tail, j)
        tail = String(strip(tail[j2:end]))
    end
    isempty(tail) || throw(ArgumentError("taql: unexpected text after CREATE TABLE: \"$tail\""))
    cols = Pair{String,Any}[]; shapes = Dict{String,Any}(); units = Dict{String,Any}(); comments = Dict{String,String}()
    for item in (isempty(strip(colstr)) ? String[] : _split_commas(colstr))
        im = match(r"^(\w+)\s+(\w+)\s*(?:\[(.*)\])?\s*$"s, strip(item))
        im === nothing && throw(ArgumentError("taql: malformed column \"$item\" in CREATE TABLE (need `name type`)"))
        name = String(im.captures[1]); T = get(_ALTER_TYPES, uppercase(im.captures[2]), nothing)
        T === nothing && throw(ArgumentError("taql: unknown column type \"$(im.captures[2])\" in CREATE TABLE"))
        any(p -> first(p) == name, cols) && throw(ArgumentError("taql: duplicate column \"$name\" in CREATE TABLE"))
        ndim = nothing; shp = nothing
        if im.captures[3] !== nothing
            for a in _split_commas(im.captures[3])
                aa = match(r"^(\w+)\s*=\s*(.+)$"s, strip(a))
                aa === nothing && throw(ArgumentError("taql: malformed column attribute \"$a\""))
                key = uppercase(aa.captures[1]); val = String(strip(aa.captures[2]))
                if key == "NDIM"
                    ndim = parse(Int, val)
                elseif key == "SHAPE"
                    shp = Tuple(parse.(Int, split(strip(val, ['[', ']']), ',')))
                elseif key == "UNIT"
                    u = _taql_const(val); units[name] = u isa AbstractString ? [String(u)] : String.(u)
                elseif key == "COMMENT"
                    comments[name] = String(_taql_const(val))
                else
                    throw(ArgumentError("taql: unsupported column attribute $key in CREATE TABLE"))
                end
            end
        end
        z = T === String ? "" : zero(T)
        if shp !== nothing
            ndim === nothing || ndim == length(shp) || throw(ArgumentError("taql: NDIM and SHAPE disagree for column \"$name\""))
            data = Array{T,length(shp)}[fill(z, shp...) for _ in 1:nrows]; shapes[name] = shp
        elseif ndim !== nothing && ndim > 0
            data = Array{T,ndim}[fill(z, ntuple(_ -> 0, ndim)...) for _ in 1:nrows]; shapes[name] = VariableShape(ndim)   # typed: a zero-row column keeps its eltype
        elseif ndim !== nothing && ndim == 0
            data = Vector{T}[fill(z, 0) for _ in 1:nrows]; shapes[name] = VariableDims()
        else
            data = fill(z, nrows)
        end
        push!(cols, name => data)
    end
    ism = String[]
    if dminfo !== nothing
        dt = match(r"TYPE\s*=\s*[\"']([^\"']+)[\"']"i, dminfo)
        dcols = match(r"COLUMNS\s*=\s*\[(.*?)\]"is, dminfo)
        dtype = dt === nothing ? "StandardStMan" : String(dt.captures[1])
        if dtype == "IncrementalStMan"
            ism = dcols === nothing ? String[first(c) for c in cols] :
                  String[String(strip(x, [' ', '"', '\''])) for x in split(dcols.captures[1], ',')]
        elseif dtype != "StandardStMan"
            throw(ArgumentError("taql: CREATE TABLE DMINFO TYPE \"$dtype\" is not supported (StandardStMan / IncrementalStMan)"))
        end
    end
    ispath(path) && throw(ArgumentError("taql: $path already exists"))
    write_table(path, "", cols; nrow=nrows, units, shapes, comments, ism, storage, blocksize)
    return path
end

function _taql_drop_table(target, command::AbstractString)
    m = match(r"^DROP\s+TABLE\s+(\S+)\s*$"i, strip(command))
    m === nothing && throw(ArgumentError("taql: malformed DROP TABLE command"))
    tok = String(m.captures[1])
    path = occursin(r"^\$\d+$", tok) ? _cmd_path(target) : _taql_table_path(tok)
    isfile(joinpath(path, "table.dat")) || throw(ArgumentError("taql: $path is not a table"))
    rm(path; recursive=true)
    return path
end


"""
    taql(target, command::AbstractString)

Run one TaQL-lite write / select command against `target` (a path or an
open `Table`):

* `UPDATE [t] SET c1 = e1, c2 = e2 [WHERE cond] [ORDER BY k [ASC|DESC], …] [LIMIT n]`
  → [`update!`](@ref), returns `Int`
* `DELETE [FROM t] [WHERE cond] [ORDER BY k [ASC|DESC], …] [LIMIT n]`
  → [`delete!`](@ref), returns `Int`
* `SELECT [DISTINCT] [*|col [AS a], …] [FROM t] [WHERE cond] [GROUP BY k, …] [HAVING cond] [ORDER BY k] [LIMIT n [OFFSET m]] [(INTO|GIVING) 'path']`  → [`copytable`](@ref), returns the path
* `SELECT …` with no `INTO`/`GIVING`              → [`query`](@ref), returns the result
* `INSERT INTO t [(c1, c2)] VALUES (v1, v2), (…) [LIMIT n]`  → [`insert!`](@ref), returns `Int`
* `INSERT [LIMIT n] INTO t SET c1 = v1, c2 = v2`   → [`insert!`](@ref), returns `Int`
* `INSERT INTO t SELECT col [AS a], … FROM 'path' [WHERE cond] [LIMIT n]`
  → [`insert!`](@ref) from a query of the table at `'path'`, returns `Int`

`INSERT … VALUES`/`SET` values must be constant expressions (no column
references) — `INSERT … SELECT … FROM 'path'` is the row-copying form,
its `col`s (and `WHERE`) are ordinary expressions over the *source*
table (`*` selects every source column as-is; `AS a` renames a column
to match `t`'s own column name). Clause keywords (`SET` / `WHERE` /
`INTO` / `GIVING` / `FROM` / `SELECT`) are found by a case-insensitive
split; a quoted literal containing one of them is not supported — use
the Julia functions for that. `GROUP BY` / aggregates in a `SELECT`
string are not supported (use `copytable(dst, groupby(…))`, or
`insert!(t, groupby(…))`).
"""
taql(command::AbstractString) = taql(nothing, command)    # target-less commands: `taql("CREATE TABLE ...")` / `taql("DROP TABLE 'path'")`

function taql(target, command::AbstractString, others...)
    cmd = strip(command)
    kw = uppercase(String(first(split(cmd; limit=2))))
    if kw == "UPDATE" || kw == "DELETE"
        cmd = _taql_preprocess_write(target isa AbstractTable ? target : readtable(_cmd_path(target)), cmd)
    end
    if kw == "ALTER"
        return _taql_alter(target, cmd)
    elseif kw == "CREATE"
        return _taql_create(cmd)
    elseif kw == "DROP"
        return _taql_drop_table(target, cmd)
    end
    if kw == "UPDATE"
        m = match(Regex("^UPDATE\\s+(?:\\S+\\s+)?SET\\s+(.+?)(?:\\s+WHERE\\s+(.+?))?" *
                        "(?:\\s+ORDER\\s+BY\\s+(.+?))?(?:\\s+LIMIT\\s+(-?\\d+))?\\s*\$",
                        "is"), cmd)
        m === nothing && throw(ArgumentError("taql: malformed UPDATE command"))
        set = Pair{String,String}[]
        for piece in _split_commas(m.captures[1])
            am = match(r"^(.+?)\s*=\s*(.+)$"s, piece)
            am === nothing && throw(ArgumentError("taql: malformed SET assignment \"$piece\""))
            push!(set, String(strip(am.captures[1])) => String(strip(am.captures[2])))
        end
        return update!(target; set,
            where = m.captures[2] === nothing ? nothing : String(strip(m.captures[2])),
            orderby = m.captures[3] === nothing ? nothing : _taql_orderby_list(m.captures[3]),
            limit = m.captures[4] === nothing ? nothing : parse(Int, m.captures[4]))
    elseif kw == "DELETE"
        m = match(Regex("^DELETE\\s+(?:FROM\\s+\\S+\\s*)?(?:WHERE\\s+(.+?))?" *
                        "(?:\\s+ORDER\\s+BY\\s+(.+?))?(?:\\s+LIMIT\\s+(-?\\d+))?\\s*\$",
                        "is"), cmd)
        m === nothing && throw(ArgumentError("taql: malformed DELETE command"))
        return delete!(target;
            where = m.captures[1] === nothing ? nothing : String(strip(m.captures[1])),
            orderby = m.captures[2] === nothing ? nothing : _taql_orderby_list(m.captures[2]),
            limit = m.captures[3] === nothing ? nothing : parse(Int, m.captures[3]))
    elseif kw == "SELECT"
        into = match(r"^(.*?)\s+(?:INTO|GIVING)\s+'([^']+)'\s*$"is, cmd)
        body = into === nothing ? cmd : String(strip(into.captures[1]))
        dst = into === nothing ? nothing : String(into.captures[2])
        target, body = _taql_join_from(target, body, others)
        target, body = _taql_preprocess_select(target, body)
        # Phase 242: SELECT [DISTINCT] cols [FROM t] [WHERE c] [ORDER BY k] [LIMIT n]
        # (was `cols [WHERE c]` only: `ORDER BY`/`LIMIT` without a WHERE, `FROM`,
        # and `DISTINCT` all mis-parsed or errored).
        bm = match(r"^SELECT\s+(DISTINCT\s+)?(.*?)(?:\s+FROM\s+\S+)?(?:\s+WHERE\s+(.+?))?" *
                   r"(?:\s+GROUP\s+BY\s+(.+?))?(?:\s+HAVING\s+(.+?))?" *
                   r"(?:\s+ORDER\s+BY\s+(.+?))?(?:\s+((?:LIMIT|OFFSET)\s+.+?))?\s*$"is, body)
        bm === nothing && throw(ArgumentError("taql: malformed SELECT command"))
        distinct = bm.captures[1] !== nothing
        groupstr = bm.captures[4] === nothing ? nothing : String(strip(bm.captures[4]))
        havingstr = bm.captures[5] === nothing ? nothing : String(strip(bm.captures[5]))
        orderstr = bm.captures[6] === nothing ? nothing : String(strip(bm.captures[6]))
        window = bm.captures[7] === nothing ? nothing : _parse_select_window(bm.captures[7])
        collist = String(strip(bm.captures[2]))
        wherestr = bm.captures[3] === nothing ? nothing : String(strip(bm.captures[3]))
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

        # Phase 256: aggregates (`gsum(K)`, ...) and/or GROUP BY / HAVING -> `groupby`
        # (no GROUP BY = ONE group over the whole table, like real TaQL)
        vn = Set(columnnames(t))
        isagg(e) = try _has_aggr(_taqllite_parse(String(e), vn)) catch; false end
        grouped = groupstr !== nothing || havingstr !== nothing ||
                  any(p -> isagg(last(p)), select)
        if grouped
            any(p -> first(p) isa AbstractString && startswith(first(p), "("), select) &&
                throw(ArgumentError("taql: `AS (val, mask)` is not supported with aggregates"))
            gkeys = groupstr === nothing ? String[] : String.(strip.(_split_commas(groupstr)))
            # an EXPRESSION key (`GROUP BY G+H`) is materialised as a hidden column
            # first (WHERE applied at that stage), then grouped on by name
            gt = t; gwhere = wherestr
            if !all(k -> k in vn, gkeys)
                # the hidden table is a plain GroupedTable (no MEASINFO), so when the command uses a date function its epoch columns are
                # passed on already converted to MJD days (`mjd(TIME)` is the identity on a column `_tql_cols` has converted; Phase 361)
                alltext = join(filter(!isnothing, vcat(String.(last.(select)), [wherestr, havingstr, orderstr], gkeys)), " ")
                datefn = occursin(Regex("\\b(" * join(_TQL_DATE_FUNCS, "|") * ")\\s*\\(", "i"), alltext)
                hidden = Pair{String,String}[n => (datefn && _epoch_seconds_column(t, n) ? "mjd($n)" : n) for n in columnnames(t)]
                for (i, k) in enumerate(gkeys)
                    k in vn && continue
                    push!(hidden, "_gk$i" => k)
                    gkeys[i] = "_gk$i"
                end
                gt = query(t, wherestr === nothing ? "TRUE" : wherestr; select = hidden)
                gwhere = nothing
            end
            sel = [String(first(p)) => String(last(p)) for p in select]
            outnames = Set(first.(sel))
            # HAVING may name a select alias (`HAVING Y > 10`): substitute its expression
            if havingstr !== nothing
                for (al, ex) in sel
                    (al == ex || al in vn) && continue
                    havingstr = replace(havingstr, Regex("\\b" * al * "\\b") => "(" * ex * ")")
                end
            end
            # ORDER BY: an output name, or ANY expression (evaluated as a hidden column)
            ob = nothing; nhid = 0
            if orderstr !== nothing
                ob = Any[]
                for piece in _split_commas(orderstr)
                    mo = match(r"^(.*?)(?:\s+(ASC|DESC))?$"is, strip(piece))
                    key = String(strip(mo.captures[1]))
                    desc = mo.captures[2] !== nothing && uppercase(mo.captures[2]) == "DESC"
                    if !(key in outnames)
                        nhid += 1; hn = "__ord$nhid"
                        push!(sel, hn => key); key = hn
                    end
                    push!(ob, desc ? key => :desc : key)
                end
            end
            result = groupby(gt, gkeys; select = sel, where = gwhere, having = havingstr, orderby = ob)
            if nhid > 0
                keepn = [n for n in columnnames(result) if !startswith(n, "__ord")]
                result = GroupedTable(Symbol.(keepn), AbstractVector[column(result, n) for n in keepn])
            end
        else
        qstr = (wherestr === nothing ? "TRUE" : wherestr) *
               (orderstr === nothing ? "" : " ORDER BY " * orderstr)
        result = query(t, qstr; select)
        end
        # DISTINCT (Phase 319): ours keeps the FIRST row of each distinct tuple of the
        # sorted result.  Real TaQL dedups with a no-duplicates heap sort that keeps an
        # arbitrary representative row per tuple, so with `DISTINCT ... ORDER BY k` the
        # order among rows tied on `k` -- and an `ORDER BY` on an unselected column, plus
        # any `LIMIT` cutting through such ties -- can differ.  The SET of rows is the same.
        if distinct || window !== nothing
            keep = collect(1:nrow(result))
            if distinct
                cols = [column(result, n) for n in columnnames(result)]
                seen = Set{Any}()
                keep = [i for i in keep if (k = Tuple(c[i] for c in cols); k in seen ? false : (push!(seen, k); true))]
            end
            window === nothing || (keep = keep[_select_window(length(keep), window)])
            result = _select_rows(result, keep)
        end
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

# a `[a, b, ...]` array literal evaluates to a plain `Vector{Any}` (or,
# nested, a `Vector{Vector{...}}`) -- turn a rectangular nesting into a
# real multi-dimensional `Array` (`[[1,2],[3,4]]` -> a (2,2) `Matrix`),
# matching what an array-shaped column cell needs. Element order matches
# real casacore TaQL's own nested-array-literal convention (cross-checked
# live): the flattened literal is reshaped *column-major*, i.e. each
# inner vector becomes one column of the result (`stack`'s default),
# not one row -- `[[1,2],[3,4]]` -> `[1 3; 2 4]`. A ragged nesting, or
# one that bottoms out in something other than plain numbers/strings/
# bools, is left as nested vectors.
_nest_to_array(x) = x
function _nest_to_array(v::AbstractVector)
    (isempty(v) || !all(x -> x isa AbstractVector, v)) && return v   # flat -- leave as-is
    ev = [_nest_to_array(x) for x in v]
    all(x -> x isa AbstractArray, ev) && allequal(size.(ev)) ? stack(ev) : ev
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
    return _nest_to_array(_tqleval(ast, Dict{String,AbstractVector}(), 1))
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
    msel = match(r"^INSERT\s+INTO\s+\S+\s*(?:\(([^)]*)\)\s*)?SELECT\s+(.*?)\s+FROM\s+(?:'([^']+)'|(\w+))\s*" *
                r"(?:WHERE\s+(.+))?\s*$"is, cmd)
    if msel !== nothing
        tcols = msel.captures[1] === nothing ? nothing : String.(strip.(split(msel.captures[1], ',')))
        collist = String(strip(msel.captures[2]))
        # `FROM 'path'` reads another table; a bare `FROM name` is the target itself
        # (real TaQL's `INSERT INTO t SELECT ... FROM t`; Phase 247)
        src = msel.captures[3] !== nothing ? readtable(String(msel.captures[3])) :
              (target isa AbstractTable ? target : readtable(_cmd_path(target)))
        wherestr = msel.captures[5] === nothing ? nothing : String(strip(msel.captures[5]))
        if collist == "*" || isempty(collist)
            select = [n => n for n in columnnames(src)]
        else
            select = Pair{String,String}[]
            for piece in _split_commas(collist)
                cm = match(r"^(.+?)(?:\s+AS\s+(\w+))?$"is, piece)
                cm === nothing && throw(ArgumentError("taql: malformed column \"$piece\""))
                srcname = String(strip(cm.captures[1]))
                alias = cm.captures[2]
                push!(select, (alias === nothing ? srcname : String(alias)) => srcname)
            end
        end
        if tcols !== nothing        # `INSERT INTO t (a, b) SELECT x, y ...`: positional
            length(tcols) == length(select) || throw(ArgumentError(
                "taql: INSERT column list has $(length(tcols)) names but the SELECT has $(length(select)) columns"))
            select = [tcols[k] => last(select[k]) for k in eachindex(select)]
        end
        result = wherestr === nothing ? query(src, "TRUE"; select) : query(src, wherestr; select)
        return insert!(target; values=result, limit)
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
