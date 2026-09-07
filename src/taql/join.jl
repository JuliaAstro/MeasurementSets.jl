# ======================================================================
# join -- N:1 lookup (Phase 28) + M:N equi (Phase 49) + predicate (Phase 56)
# ======================================================================
#
# `multi=false` (default): each `left` row maps to at most one `right`
# row (via a key), right columns pulled in per left row -- exactly what
# TaQL's own `JOIN ... ON` does. `multi=true`: a general M:N equi-join
# (inner / left / right / full via `unmatched`). An `on::Function`
# predicate `(lrow, rrow) -> Bool` is a nested-loop non-equi join (a
# MeasurementSets extension). The result is a
# `GroupedTable` whose columns are lazy `MappedColumn` views (zero-copy)
# except where an outer join's unmatched rows force a `missing`-filled
# materialisation.

_mapcol(c::AbstractVector, rows::Vector{Int}) =
    MappedColumn{eltype(c),typeof(c)}(c, rows)

# column selectors: `"NAME"` or `"NAME" => "ANT_NAME"` (source => output,
# DataFrames-style).  Normalised to `output => source` pairs internally.
_norm_pairs(xs) = Pair{String,String}[
    x isa Pair ? (String(last(x)) => String(first(x))) : (String(x) => String(x))
    for x in xs]

# left row -> right row (1-based), or 0 for no match
function _join_matchrow(left::AbstractTable, right::AbstractTable, on)
    nr = nrow(right)
    if on isa Union{AbstractString,Symbol}
        String(on) in columnnames(left) ||
            throw(ArgumentError("join: left table has no column \"$(on)\""))
        lc = column(left, String(on))
        return Int[(v = lc[i]; 0 <= v < nr ? Int(v) + 1 : 0) for i in 1:nrow(left)]
    end
    pairs = on isa Pair ? [on] : collect(on)
    isempty(pairs) && throw(ArgumentError("join: `on` must not be empty"))
    lkeys = String[String(first(p)) for p in pairs]
    rkeys = String[String(last(p)) for p in pairs]
    for k in lkeys
        k in columnnames(left) || throw(ArgumentError("join: left table has no column \"$k\""))
    end
    for k in rkeys
        k in columnnames(right) || throw(ArgumentError("join: right table has no column \"$k\""))
    end
    rcols = [column(right, k) for k in rkeys]
    lcols = [column(left, k) for k in lkeys]
    idx = Dict{Any,Int}()
    for j in 1:nr
        key = ntuple(t -> rcols[t][j], length(rkeys))
        haskey(idx, key) && throw(ArgumentError(
            "join: right key $(key) is not unique (rows $(idx[key]) and $j) -- the lookup is ambiguous"))
        idx[key] = j
    end
    return Int[get(idx, ntuple(t -> lcols[t][i], length(lkeys)), 0) for i in 1:nrow(left)]
end

# equi-join key columns for `on` (a Pair or vector of pairs); errors on
# a bare-column-name (index-lookup) `on`.
function _join_keycols(left::AbstractTable, right::AbstractTable, on)
    on isa Union{AbstractString,Symbol} && throw(ArgumentError(
        "join: `multi=true` needs an equi-join key (a `\"LK\" => \"RK\"` pair " *
        "or a vector of them), not an index-lookup column name"))
    pairs = on isa Pair ? [on] : collect(on)
    isempty(pairs) && throw(ArgumentError("join: `on` must not be empty"))
    lkeys = String[String(first(p)) for p in pairs]
    rkeys = String[String(last(p)) for p in pairs]
    for k in lkeys
        k in columnnames(left) || throw(ArgumentError("join: left table has no column \"$k\""))
    end
    for k in rkeys
        k in columnnames(right) || throw(ArgumentError("join: right table has no column \"$k\""))
    end
    return [column(left, k) for k in lkeys], [column(right, k) for k in rkeys]
end

# The (left-row, right-row) index pairs of the join (`0` on a side means
# "no match, fill that side's columns with missing"). `multi=false` ->
# the N:1 lookup; `multi=true` -> an M:N equi-join whose type is set by
# `unmatched`: :drop (inner) / :missing|:left (left outer) / :right /
# :full / :error (every left row must match >= 1).
function _join_pairs(left::AbstractTable, right::AbstractTable, on, multi::Bool,
                     unmatched::Symbol)
    if !multi
        unmatched in (:error, :drop, :missing) || throw(ArgumentError(
            "join: `unmatched` must be :error, :drop or :missing (or pass multi=true)"))
        mr = _join_matchrow(left, right, on)
        lr =
            unmatched === :error ? (b = findfirst(iszero, mr);
                b === nothing ? collect(1:nrow(left)) :
                throw(ArgumentError("join: left row $b has no match on the right " *
                                    "(pass unmatched=:drop or :missing to allow it)"))) :
            unmatched === :drop ? [i for i in eachindex(mr) if mr[i] != 0] :
            collect(1:nrow(left))
        return lr, mr[lr]
    end

    unmatched in (:error, :drop, :missing, :left, :right, :full) || throw(ArgumentError(
        "join: `unmatched` must be :error, :drop, :missing/:left, :right or :full"))
    keepL = unmatched in (:missing, :left, :full)      # keep unmatched left rows
    keepR = unmatched in (:right, :full)               # keep unmatched right rows
    lcols, rcols = _join_keycols(left, right, on)
    nk = length(lcols)
    ridx = Dict{Any,Vector{Int}}()
    for j in 1:nrow(right)
        push!(get!(() -> Int[], ridx, ntuple(t -> rcols[t][j], nk)), j)
    end
    lrows = Int[]; rrows = Int[]
    matched_r = falses(nrow(right))
    for i in 1:nrow(left)
        ms = get(ridx, ntuple(t -> lcols[t][i], nk), nothing)
        if ms === nothing
            unmatched === :error && throw(ArgumentError(
                "join: left row $i has no match on the right (use unmatched=:drop / :missing / ...)"))
            keepL && (push!(lrows, i); push!(rrows, 0))
        else
            for j in ms
                push!(lrows, i); push!(rrows, j); matched_r[j] = true
            end
        end
    end
    if keepR
        for j in 1:nrow(right)
            matched_r[j] || (push!(lrows, 0); push!(rrows, j))
        end
    end
    return lrows, rrows
end

# nested-loop join on a 2-arg predicate `pred(lrow, rrow) -> Bool`
# (a MeasurementSets extension -- TaQL's own JOIN is == / IN only).
# `oncols` = (leftnames, rightnames) or nothing (= every column).
# Returns (lrows, rrows); `0` on a side means an unmatched outer row.
function _join_pairs_pred(left::AbstractTable, right::AbstractTable, pred::Function,
                          unmatched::Symbol, oncols)
    unmatched in (:error, :drop, :missing, :left, :right, :full) || throw(ArgumentError(
        "join: `unmatched` must be :error, :drop, :missing/:left, :right or :full"))
    keepL = unmatched in (:missing, :left, :full)
    keepR = unmatched in (:right, :full)
    lnames = oncols === nothing ? columnnames(left) : String.(oncols[1])
    rnames = oncols === nothing ? columnnames(right) : String.(oncols[2])
    lrws = CTDSRows(AbstractVector[column(left, n) for n in lnames], Symbol.(lnames), nrow(left))
    rrws = CTDSRows(AbstractVector[column(right, n) for n in rnames], Symbol.(rnames), nrow(right))
    rrows_v = collect(rrws)
    lrows = Int[]; rrows = Int[]
    matched_r = falses(nrow(right))
    for (i, lr) in enumerate(lrws)
        hit = false
        for (j, rr) in enumerate(rrows_v)
            if pred(lr, rr)::Bool
                push!(lrows, i); push!(rrows, j); matched_r[j] = true; hit = true
            end
        end
        if !hit
            unmatched === :error && throw(ArgumentError(
                "join: left row $i has no match on the right (use unmatched=:drop / :missing / ...)"))
            keepL && (push!(lrows, i); push!(rrows, 0))
        end
    end
    if keepR
        for j in 1:nrow(right)
            matched_r[j] || (push!(lrows, 0); push!(rrows, j))
        end
    end
    return lrows, rrows
end

# nested-loop join on a TaQL-lite `on` STRING with `L.` / `R.`
# table-qualified column references (`"L.T BETWEEN R.T0 AND R.T1"`).
function _join_pairs_qexpr(left::AbstractTable, right::AbstractTable, onstr::AbstractString,
                           unmatched::Symbol)
    unmatched in (:error, :drop, :missing, :left, :right, :full) || throw(ArgumentError(
        "join: `unmatched` must be :error, :drop, :missing/:left, :right or :full"))
    keepL = unmatched in (:missing, :left, :full)
    keepR = unmatched in (:right, :full)
    validnames = Set{String}()
    for c in columnnames(left);  push!(validnames, "L.$c"); end
    for c in columnnames(right); push!(validnames, "R.$c"); end
    ast = _taqllite_parse(String(onstr), validnames)
    _has_aggr(ast) &&
        throw(ArgumentError("join: `on` string must not contain aggregate functions"))
    refs = Set{String}(); _tqlrefs!(refs, ast)
    lref = String[r for r in refs if startswith(r, "L.")]
    rref = String[r for r in refs if startswith(r, "R.")]
    (isempty(lref) || isempty(rref)) && throw(ArgumentError(
        "join: `on` string must reference at least one L.<col> and one R.<col>"))
    att = _has_qty(ast)
    _col(tab, r) = (c = column(tab, r[3:end]);
                    att ? _tql_unit_attach(c, columnunit(tab, r[3:end])) : c)
    lcols = Dict(r => _col(left, r) for r in lref)
    rcols = Dict(r => _col(right, r) for r in rref)
    qcd = Dict{String,Vector{Any}}(r => Vector{Any}(undef, 1) for r in refs)
    lrows = Int[]; rrows = Int[]
    matched_r = falses(nrow(right))
    for i in 1:nrow(left)
        for r in lref; qcd[r][1] = lcols[r][i]; end
        hit = false
        for j in 1:nrow(right)
            for r in rref; qcd[r][1] = rcols[r][j]; end
            if _tqleval(ast, qcd, 1)::Bool
                push!(lrows, i); push!(rrows, j); matched_r[j] = true; hit = true
            end
        end
        if !hit
            unmatched === :error && throw(ArgumentError(
                "join: left row $i has no match on the right (use unmatched=:drop / :missing / ...)"))
            keepL && (push!(lrows, i); push!(rrows, 0))
        end
    end
    if keepR
        for j in 1:nrow(right)
            matched_r[j] || (push!(lrows, 0); push!(rrows, j))
        end
    end
    return lrows, rrows
end

# post-assembly WHERE over the RESULT column names (a renamed right
# column is referenced by its output name).  String -> the TaQL-lite
# expression engine; Function -> a `row -> Bool` predicate.
function _result_filter(gt::GroupedTable, where)
    n = isempty(gt.cols) ? 0 : length(gt.cols[1])
    keep = if where isa Function
        rws = CTDSRows(gt.cols, gt.names, n)
        [i for (i, r) in enumerate(rws) if where(r)]
    else
        cd = Dict{String,AbstractVector}(String(nm) => c for (nm, c) in zip(gt.names, gt.cols))
        ast = _taqllite_parse(String(where), Set(Base.keys(cd)))
        !_has_aggr(ast) ||
            throw(ArgumentError("join: `where` must not contain aggregate functions"))
        [i for i in 1:n if _tqleval(ast, cd, i)]
    end
    return GroupedTable(copy(gt.names), AbstractVector[c[keep] for c in gt.cols])
end

"""
    join(left, right; on, rightcols, leftcols=nothing, where=nothing,
         unmatched=:error, multi=false, oncols=nothing, orderby=nothing) -> GroupedTable

Join `left` and `right` (extends `Base.join`). Either side is any
`AbstractTable` — a `Table`, a `RefTable`, or another `groupby` /
`join` / `query` result, so the verbs chain. The default (`multi =
false`) is an **N:1 lookup join** — each `left` row matches at most one
`right` row, right columns pulled in per left row (TaQL's `JOIN … ON`
semantics). `multi = true` is a general **M:N equi-join**.

`on` is either

* a **column name** (`String` / `Symbol`) — that `left` column holds a
  **0-based row index** into `right` (the MS subtable convention:
  `ANTENNA1` → the `ANTENNA` subtable row); N:1 only;
* a **`Pair`** `"LKEY" => "RKEY"` — equi-join, matching `left.LKEY`
  against `right.RKEY` (must be unique when `multi = false`);
* a **vector of pairs** — a composite key (all must match);
* a **2-arg predicate** `(lrow, rrow) -> Bool` — a general non-equi join
  (a MeasurementSets extension; TaQL's own `JOIN` is `==` / `IN` only).
  `lrow` / `rrow` support `row.COLNAME`. Evaluated by a nested loop over
  every `(left, right)` pair — **O(nrow(left) × nrow(right))**; `query`
  / `select` each side down first for a large table. `oncols =
  (leftnames, rightnames)` restricts which columns are loaded onto the
  predicate rows. `unmatched` sets the join type as for `multi = true`;
  `multi` itself is ignored;
* a **string condition** — a TaQL-lite expression with `L.` / `R.`
  table-qualified column references
  (`"L.TIME BETWEEN R.T0 AND R.T1"`). The declarative form of the
  predicate above — same nested loop, same cost, same `unmatched`
  semantics. Must reference at least one `L.<col>` and one `R.<col>`;
  a bare column name is still the index-lookup join.

`rightcols` lists the `right` columns to attach — `"NAME"` or
`"NAME" => "ANT_NAME"` to rename. `leftcols` (default: every `left`
column) likewise selects/renames left columns. Output names must be
unique across both. `where` filters the assembled result (a string over
the *output* column names, or a `row -> Bool` closure).

`unmatched` — for `multi = false`: `:error` (default — throw on a
dangling key), `:drop` (exclude that left row), `:missing` (keep it,
right columns `missing`). For `multi = true` it sets the join type:
`:drop` = inner, `:missing` / `:left` = left outer, `:right` = right
outer, `:full` = full outer, `:error` = every left row must match ≥ 1.
Unmatched rows on either side get `missing` in the other table's
columns.

`orderby` sorts the result by output column name (`"N"` / `"N" =>
:desc`). Returns a [`GroupedTable`](@ref) whose columns are lazy views
except where `missing`-fill forces materialisation.
"""
function Base.join(left::AbstractTable, right::AbstractTable; on,
                   rightcols::AbstractVector, leftcols=nothing,
                   where=nothing, unmatched::Symbol=:error, multi::Bool=false,
                   oncols=nothing, orderby::Union{Nothing,AbstractVector}=nothing)
    # a bare-identifier string is the index-lookup `on` (Phase 28); a
    # string with operators / `L.`/`R.` qualifiers is a join condition
    lrows, rrows =
        on isa Function ? _join_pairs_pred(left, right, on, unmatched, oncols) :
        (on isa AbstractString && !occursin(r"^\s*\w+\s*$", on)) ?
            _join_pairs_qexpr(left, right, on, unmatched) :
        _join_pairs(left, right, on, multi, unmatched)

    lpairs = leftcols === nothing ? Pair{String,String}[n => n for n in columnnames(left)] :
             _norm_pairs(leftcols)
    rpairs = _norm_pairs(rightcols)
    for (_, s) in lpairs
        s in columnnames(left) || throw(ArgumentError("join: left table has no column \"$s\""))
    end
    for (_, s) in rpairs
        s in columnnames(right) || throw(ArgumentError("join: right table has no column \"$s\""))
    end
    outnames = String[first(p) for p in vcat(lpairs, rpairs)]
    allunique(outnames) ||
        throw(ArgumentError("join: duplicate output column name (left and right collide?)"))

    # a side with any `0` index (an outer join's unmatched rows) must
    # materialise with `missing` (eltype narrowed via `identity.`);
    # otherwise a lazy `MappedColumn` view.
    _side(c, rows) = any(iszero, rows) ?
        identity.(Any[r == 0 ? missing : c[r] for r in rows]) : _mapcol(c, rows)

    cols = AbstractVector[]
    for (_, s) in lpairs
        push!(cols, _side(column(left, s), lrows))
    end
    for (_, s) in rpairs
        push!(cols, _side(column(right, s), rrows))
    end

    gt = GroupedTable(Symbol.(outnames), cols)
    where === nothing || (gt = _result_filter(gt, where))
    orderby === nothing ? gt : _gt_sort(gt, orderby)
end
