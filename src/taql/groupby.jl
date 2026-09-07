# ======================================================================
# GROUP BY + aggregation  (Phase 26)
# ======================================================================
#
# `_geval(e, cols, g)` evaluates an expression for one group: `g` is the
# group's `Vector{Int}` of (filtered) row indices.  A `TQLAggr` reduces
# over the whole group; every other node evaluates on the group's FIRST
# row (a non-aggregate select expr is assumed constant across the group
# because you grouped by it -- SQL-lenient, not strictly verified).

_geval(::TQLGrouping, cols, g) = throw(ArgumentError(
    "TaQL-lite: GROUPING() must be resolved per grouping set (internal error)"))
function _geval(e::TQLAggr, cols, g)
    e.arg === nothing && return e.fn(g)                    # gcount()
    vals = Any[_tqleval(e.arg, cols, i) for i in g]
    e.mode === :perelem && return _perelem_reduce(e.fn, vals)
    any(x -> x isa TQLMArray, vals) && return e.fn(_pool_masked(vals))
    return e.fn(vals)
end

# flatten a group's per-row aggregate values into one vector, dropping
# masked elements of any `TQLMArray`.
_pool_masked(vals) = reduce(vcat, (x isa TQLMArray ? _mvalid(x) :
    x isa AbstractArray ? vec(x) : [x] for x in vals))

# per array-cell position, reduce (`f`) the values from the group's rows
# where that cell is not masked. Replaces the `gs*` closures; also
# reduces an unmasked `Vector` of same-shape arrays elementwise.
function _perelem_reduce(f, vals)
    isempty(vals) && throw(ArgumentError("groupby: empty group in a per-element aggregate"))
    d1 = vals[1] isa TQLMArray ? vals[1].data : vals[1]
    d1 isa AbstractArray || throw(ArgumentError(
        "groupby: a per-element (gs*) aggregate needs array-cell values"))
    sz = size(d1); T = eltype(d1)
    accs = [T[] for _ in CartesianIndices(sz)]
    for x in vals, p in CartesianIndices(sz)
        x isa TQLMArray ? (x.mask[p] || push!(accs[p], x.data[p])) : push!(accs[p], x[p])
    end
    nonempty = findfirst(!isempty, accs)
    nonempty === nothing && throw(ArgumentError(
        "groupby: every cell is masked in a per-element aggregate"))
    R = typeof(f(accs[nonempty]))
    out = Array{R}(undef, sz)
    for p in CartesianIndices(sz)
        out[p] = isempty(accs[p]) ? _pe_empty(R) : R(f(accs[p]))
    end
    return out
end
_pe_empty(::Type{T}) where {T<:AbstractFloat} = T(NaN)
_pe_empty(::Type{T}) where {T<:Complex} = T(NaN, NaN)
_pe_empty(::Type{Bool}) = false
_pe_empty(::Type{T}) where {T} = zero(T)
_geval(e::TQLCol, cols, g) = cols[e.name][g[1]]
_geval(e::TQLLit, cols, g) = e.value
_geval(e::TQLQuantityLit, cols, g) = e.value
_geval(e::TQLArrayLit, cols, g) = [_geval(x, cols, g) for x in e.elems]
_geval(e::TQLCmp, cols, g) = _bcast(e.op, _geval(e.lhs, cols, g), _geval(e.rhs, cols, g))
_geval(e::TQLArith, cols, g) = _bcast(e.op, _geval(e.lhs, cols, g), _geval(e.rhs, cols, g))
_geval(e::TQLNeg, cols, g) = _bcast(-, _geval(e.a, cols, g))
_geval(e::TQLBitNot, cols, g) = _bcast((~), _geval(e.a, cols, g))
_geval(e::TQLMaskOf, cols, g) = (v = _geval(e.e, cols, g);
    v isa TQLMArray ? v.mask : _bcast(!isfinite, _unwrap_marray(v)))
_geval(e::TQLAnd, cols, g) = _geval(e.a, cols, g) && _geval(e.b, cols, g)
_geval(e::TQLOr, cols, g) = _geval(e.a, cols, g) || _geval(e.b, cols, g)
_geval(e::TQLNot, cols, g) = _bcast(!, _geval(e.a, cols, g))
_geval(e::TQLIn, cols, g) = _geval(e.lhs, cols, g) in e.vals
_geval(e::TQLMatch, cols, g) =
    xor(occursin(e.regex, _geval(e.lhs, cols, g)::AbstractString), e.negate)
_geval(e::TQLFunc, cols, g) =
    e.fn(ntuple(k -> _geval(e.args[k], cols, g), length(e.args))...)
_geval(::TQLRowNum, cols, g) =
    throw(ArgumentError("TaQL-lite: rownumber() is not valid in groupby(...)"))
_geval(::TQLEnd, cols, g) = throw(ArgumentError(
    "TaQL-lite: `end` is only valid inside an array subscript `[...]`"))
_geval(e::TQLIndex, cols, g) = _tql_do_index(_geval(e.base, cols, g), e.axes,
                                             (x -> _geval(x, cols, g)))
_geval(e::TQLBetween, cols, g) = _tql_between(
    _geval(e.lhs, cols, g), _geval(e.lo, cols, g), _geval(e.hi, cols, g), e.negate)

"""
    GroupSlice

The per-group value passed to a closure-form [`groupby`](@ref) (the
do-block argument, and the argument of a `select` / `where` / `having`
closure). `g.COLNAME` is a materialised `Vector` of that column's values
for the group's rows; `length(g)` is the group size; `propertynames(g)`
lists the loaded columns.

Only the columns named in `cols=` (or every column, when `cols` is
omitted) are available — a closure's column use cannot be inferred. The
names `cols`, `rows`, `keys`, `level` are struct fields / synthesised
properties, so a column with one of those names is unreachable as
`g.<name>` (a non-issue for MS column names).

`g.keys` is a `NamedTuple` of the grouping-key values for this group
(one scalar per key). `g.level` is the number of *active* grouping keys
— always `length(groupcols)` for a plain groupby, but for a
`rollup=true` subtotal level the trailing keys are inactive and their
`g.keys` entries are `missing`. A `rollup` closure should build its
key output fields from `g.keys` (`(; g.keys..., N = length(g))`).
"""
struct GroupSlice
    cols::Dict{String,AbstractVector}
    rows::Vector{Int}
    keynames::Vector{String}
    active::Vector{Int}          # 1-based indices of the keys active for this group
end
GroupSlice(cols, rows) = GroupSlice(cols, rows, String[], Int[])
GroupSlice(cols, rows, kn::Vector{String}) =
    GroupSlice(cols, rows, kn, collect(1:length(kn)))
Base.length(g::GroupSlice) = length(getfield(g, :rows))
Base.propertynames(g::GroupSlice) =
    (Symbol.(keys(getfield(g, :cols)))..., :keys, :level, :grouping)
function Base.getproperty(g::GroupSlice, s::Symbol)
    (s === :cols || s === :rows) && return getfield(g, s)
    s === :level && return length(getfield(g, :active))
    kn = getfield(g, :keynames); act = getfield(g, :active)
    if s === :keys
        r1 = getfield(g, :rows)[1]
        return NamedTuple{Tuple(Symbol.(kn))}(
            ntuple(j -> j in act ? getfield(g, :cols)[kn[j]][r1] : missing, length(kn)))
    end
    # SQL GROUPING(): `true` for a key aggregated away in this group
    s === :grouping && return NamedTuple{Tuple(Symbol.(kn))}(
        ntuple(j -> !(j in act), length(kn)))
    c = get(getfield(g, :cols), String(s), nothing)
    c === nothing && throw(ArgumentError(
        "GroupSlice has no column $s -- pass it in `cols=` (a closure's column use can't be inferred)"))
    return c[getfield(g, :rows)]
end

"""
    GroupedTable

An in-memory columnar table — the result of [`groupby`](@ref),
[`join`](@ref), or `query` on one of those. It is a full
[`AbstractTable`](@ref) (so it chains back into `query` / `groupby` /
`join`) and a `Tables.jl` source. Access columns with `gt.OUTNAME`,
`gt["OUTNAME"]`, `column(gt, "OUTNAME")`, `DataFrame(gt)`, or persist
with `write_table(dst, "T", gt; nrow=nrow(gt))`.

`names` and `cols` are reserved field names (reached via `getfield`);
a column literally named `names` / `cols` is accessible only through
`gt["names"]` / `column(gt, "cols")`.
"""
struct GroupedTable <: AbstractTable
    names::Vector{Symbol}
    cols::Vector{AbstractVector}
end

nrow(gt::GroupedTable) = isempty(getfield(gt, :cols)) ? 0 : length(getfield(gt, :cols)[1])
columnnames(gt::GroupedTable) = String.(getfield(gt, :names))
function column(gt::GroupedTable, name::AbstractString;
                precision::Union{Nothing,Symbol,Type}=nothing)
    j = findfirst(==(Symbol(name)), getfield(gt, :names))
    j === nothing && throw(KeyError(name))
    return getfield(gt, :cols)[j]          # already materialised; `precision` is a no-op
end
keywords(::GroupedTable) = Record()
subtables(::GroupedTable) = Pair{String,String}[]

# best-effort synthesis -- only consulted by `validate` / direct user
# calls, never by the query verbs
function columndesc(gt::GroupedTable, name::AbstractString)
    col = column(gt, name)
    ct = try
        _casatype_of(Base.nonmissingtype(eltype(col)))
    catch
        TpOther
    end
    shp = _infer_shape(col)
    isarr = shp isa VariableShape || (shp isa Dims && !isempty(shp))
    return ColumnDesc(String(name), "", "", "", ct, _classname(ct, isarr), shp,
                      Int32(0), UInt32(0), Record(), nothing, nothing)
end

# `.OUTNAME` sugar + display -- not part of the Tables.jl interface
# (the generic `::AbstractTable` methods in tables/interface.jl cover
# `istable`/`columns`/`columnnames`/`getcolumn`/`schema`/`rows`).
Base.getproperty(x::GroupedTable, s::Symbol) =
    s === :names || s === :cols ? getfield(x, s) : column(x, String(s))
Base.propertynames(x::GroupedTable) = Tuple(getfield(x, :names))

function Base.show(io::IO, ::MIME"text/plain", x::GroupedTable)
    nr = nrow(x)
    println(io, "GroupedTable: $nr row", nr == 1 ? "" : "s", " × ",
            length(getfield(x, :names)), " column",
            length(getfield(x, :names)) == 1 ? "" : "s")
    print(io, "  ", join(getfield(x, :names), ", "))
end

# --- query on an already-in-memory result -----------------------------
# `query` on a `GroupedTable` (from `groupby` / `join` / a prior
# `query`) returns a *materialised* `GroupedTable` -- "in-memory in,
# in-memory out" -- rather than the lazy `RefTable` the generic
# `query(::AbstractTable, ...)` produces (which would need a disk-backed
# parent for `write_reftable`).

"""
    query(gt::GroupedTable, wherestr; select=identity) -> GroupedTable

Filter / project / sort an in-memory columnar result. `wherestr` is a
TaQL-lite WHERE expression (+ optional trailing `ORDER BY`) over the
result's column names; `select` is `outname => source_name` pairs.
"""
function query(gt::GroupedTable, wherestr::AbstractString;
               select::AbstractVector{<:Pair}=[n => n for n in columnnames(gt)])
    ast, orderby = _taqllite_parse_query(wherestr, Set(columnnames(gt)))
    cd = Dict{String,AbstractVector}(n => column(gt, n) for n in columnnames(gt))
    nr = nrow(gt)
    keep = ast === nothing ? collect(1:nr) : [i for i in 1:nr if _tqleval(ast, cd, i)]
    keep = _apply_orderby(keep, orderby, cd)
    cls = _select_classify(select, Set(columnnames(gt)))
    ps = _select_materialize(cls, gt, keep)
    return GroupedTable(first.(ps), AbstractVector[last(x) for x in ps])
end

"""
    query(f, gt::GroupedTable; cols=nothing, orderby=nothing, select=identity) -> GroupedTable

Closure form: keep the rows for which `f(row) -> Bool` (`row.OUTNAME`
property access). See the string form above.
"""
function query(f::Function, gt::GroupedTable;
               cols::Union{Nothing,AbstractVector}=nothing,
               orderby::Union{Nothing,AbstractVector}=nothing,
               select::AbstractVector{<:Pair}=[n => n for n in columnnames(gt)])
    names = cols === nothing ? columnnames(gt) : String.(cols)
    orderkeys = orderby === nothing ? TQLOrderKey[] : [_normalize_orderkey(gt, o) for o in orderby]
    allnames = unique(vcat(collect(names), [k.name for k in orderkeys]))
    cd = Dict{String,AbstractVector}(n => column(gt, n) for n in allnames)
    rws = CTDSRows(AbstractVector[cd[n] for n in allnames], Symbol.(allnames), nrow(gt))
    keep = [i for (i, row) in enumerate(rws) if f(row)]
    keep = _apply_orderby(keep, orderkeys, cd)
    cls = _select_classify(select, Set(columnnames(gt)))
    ps = _select_materialize(cls, gt, keep)
    return GroupedTable(first.(ps), AbstractVector[last(x) for x in ps])
end

_gb_names(c::Union{AbstractString,Symbol}) = String[String(c)]
_gb_names(cs) = String[String(c) for c in cs]

function _gb_keys(t::AbstractTable, groupcols)
    ks = _gb_names(groupcols)
    vn = Set(columnnames(t))
    for k in ks
        k in vn || throw(ArgumentError("groupby: no column \"$k\""))
    end
    return ks
end

function _group_rows(keys::Vector{String}, loaded, rows)
    groups = Dict{Any,Vector{Int}}()
    seen = Any[]
    for i in rows
        key = ntuple(j -> loaded[keys[j]][i], length(keys))
        g = get(groups, key, nothing)
        if g === nothing
            groups[key] = Int[i]
            push!(seen, key)
        else
            push!(g, i)
        end
    end
    return groups, seen
end

# column names a WHERE string references (for the caller to pre-load)
function _tql_where_refs(wherestr::AbstractString, t::AbstractTable)
    ast = _taqllite_parse(String(wherestr), Set(columnnames(t)))
    !_has_aggr(ast) ||
        throw(ArgumentError("WHERE must not contain aggregate functions"))
    s = Set{String}()
    _tqlrefs!(s, ast)
    return s
end

# `where` (nothing / WHERE string / row->Bool closure) -> Vector{Int}.
# `cols` must already hold every column the predicate touches (the
# WHERE-string columns, or -- for a closure -- every column).
function _where_rows(t::AbstractTable, where, cols::AbstractDict)
    where === nothing && return collect(1:nrow(t))
    if where isa Function
        nms = collect(keys(cols))
        rws = CTDSRows(AbstractVector[cols[n] for n in nms], Symbol.(nms), nrow(t))
        return [i for (i, r) in enumerate(rws) if where(r)]
    end
    ast = _taqllite_parse(String(where), Set(columnnames(t)))
    !_has_aggr(ast) ||
        throw(ArgumentError("WHERE must not contain aggregate functions"))
    return [i for i in 1:nrow(t) if _tqleval(ast, cols, i)]
end

# Shared preparation for both `groupby` methods: validate keys, parse
# any string `where`/`having`, decide which columns to load (referenced
# names ∪ keys ∪ -- when a closure is involved -- `cols` or every
# column), load them, filter rows, group, and build a per-group HAVING
# predicate.  `extrarefs` = the parsed string/symbol select ASTs (empty
# for the do-block form).  `anyclosure` forces loading `cols`/all.
function _gb_prepare(t::AbstractTable, groupcols, wherearg, havingarg,
                     extrarefs::Vector{TQLExpr}, cols, anyclosure::Bool)
    vn = Set(columnnames(t))
    keys = _gb_keys(t, groupcols)
    whereast = wherearg isa AbstractString ? _taqllite_parse(wherearg, vn) : nothing
    whereast === nothing || !_has_aggr(whereast) ||
        throw(ArgumentError("groupby: `where` must not contain aggregate functions"))
    havingast = havingarg isa AbstractString ? _taqllite_parse(havingarg, vn) : nothing

    needed = Set{String}(keys)
    for e in extrarefs
        _tqlrefs!(needed, e)
    end
    whereast === nothing || _tqlrefs!(needed, whereast)
    havingast === nothing || _tqlrefs!(needed, havingast)
    if cols !== nothing
        union!(needed, String.(cols))
    elseif anyclosure
        union!(needed, columnnames(t))
    end
    loaded = _tql_cols(t, needed, whereast, havingast, extrarefs)

    rows =
        wherearg === nothing ? collect(1:nrow(t)) :
        wherearg isa Function ? begin
            nms = collect(Base.keys(loaded))
            rws = CTDSRows(AbstractVector[loaded[n] for n in nms], Symbol.(nms), nrow(t))
            [i for (i, r) in enumerate(rws) if wherearg(r)]
        end :
        [i for i in 1:nrow(t) if _tqleval(whereast, loaded, i)]

    havingfn =
        havingarg === nothing ? ((g, kn, act) -> true) :
        havingarg isa Function ? ((g, kn, act) -> havingarg(GroupSlice(loaded, g, kn, act))) :
        ((g, kn, act) -> _geval(_sg(havingast, _gb_rolled(kn, act)), loaded, g))
    return loaded, rows, havingfn, keys
end

# The grouping sets to compute: each a sorted `Vector{Int}` of active
# key indices. Plain groupby -> one set (all keys); ROLLUP -> key
# prefixes n, n-1, ..., 0; CUBE -> every subset; `grouping_sets` -> the
# explicit list. At most one of rollup/cube/grouping_sets may be given.
function _gb_one_set(gs, kidx::AbstractDict)
    names = gs isa Union{AbstractString,Symbol} ? String[String(gs)] :
            String[String(x) for x in gs]
    for nm in names
        haskey(kidx, nm) || throw(ArgumentError(
            "groupby: grouping set names a non-grouping column \"$nm\""))
    end
    return sort!(unique(Int[kidx[nm] for nm in names]))
end

function _gb_sets(keys::Vector{String}, rollup::Bool, cube::Bool, gsets)
    n = length(keys)
    count(!=(false), (rollup, cube, gsets !== nothing)) <= 1 || throw(ArgumentError(
        "groupby: give at most one of `rollup`, `cube`, `grouping_sets`"))
    if gsets !== nothing
        kidx = Dict(k => j for (j, k) in enumerate(keys))
        return Vector{Int}[_gb_one_set(gs, kidx) for gs in gsets]
    end
    rollup && return [collect(1:p) for p in n:-1:0]
    cube && return sort!(
        [Int[j for j in 1:n if (m >> (j - 1)) & 1 == 1] for m in 0:(2^n - 1)];
        by = s -> (-length(s), s))
    return [collect(1:n)]
end

"""
    groupby(t, groupcols; select, cols=nothing, where=nothing, having=nothing, orderby=nothing) -> GroupedTable

Group the rows of `t` by `groupcols` (a column name / `Symbol`, or a
vector of them; an empty vector = one group over the whole table) and
compute one result row per group. `t` is any `AbstractTable` — a
`Table`, a `RefTable`, or another `groupby` / `join` / `query` result,
so the verbs chain.

`select` is `outname => rhs` pairs, where `rhs` is one of:

* a **string** — a TaQL-lite expression that may use `g`-prefixed
  aggregate functions over the group: `gcount()` / `gcount(x)` (row
  count), `gsum(x)`, `gproduct(x)`, `gmean(x)` / `gavg(x)`,
  `gmedian(x)`, `gmin(x)`, `gmax(x)`, `gvariance(x)` /
  `gsamplevariance(x)`, `gstddev(x)` / `gsamplestddev(x)`, `grms(x)`,
  `gany(x)`, `gall(x)`, `gntrue(x)`, `gnfalse(x)`, `gfirst(x)`,
  `glast(x)` — plus the group-key columns and scalar expressions of
  them. An aggregate's argument is normally a scalar per row (wrap an
  array cell in `mean(...)` / `sum(...)`), OR a masked array
  (`gmean(V[!FLAG])` pools every row's unmasked elements). The
  `s`-suffixed per-element variants (`gsums`, `gproducts`, `gmeans` /
  `gavgs`, `gvariances` / `gsamplevariances`, `gstddevs` /
  `gsamplestddevs`, `grmss`, `gmins`, `gmaxs`, `ganys`, `galls`,
  `gntrues`, `gnfalses`) reduce the group's array cells per position —
  over the rows where that cell is unmasked (all cells if unmasked),
  giving one array.
* a **`Symbol`** — shorthand for a bare column name (`:K` ≡ `"K"`).
* a **function** `g -> value` — called with a [`GroupSlice`](@ref) (see
  the do-block form below); use for aggregates the `g*` set can't
  express.

`where` pre-filters rows (a WHERE string, or a `row -> Bool` closure).
`having` filters groups (a HAVING string over aggregates/keys, or a
`g -> Bool` closure). `cols` restricts which columns are loaded onto a
`GroupSlice` — only relevant when `select`/`where`/`having` use a
closure (default: every column of `t`). `orderby` sorts the result rows
by output column name(s): `"N"` (ascending) or `"N" => :desc`.

`rollup = true` / `cube = true` / `grouping_sets = [...]` compute
multiple SQL grouping sets and stack the result rows. `rollup` groups by
each key prefix (`keys`, `keys[1:end-1]`, …, `()`); `cube` by every
subset; `grouping_sets` by exactly the sets you list — each an iterable
of key names, `()` for the grand total (`grouping_sets = [("K1","K2"),
("K1",), ()]`). At most one of the three. In a row where a key is
aggregated away, that key column is `missing` — a bare `:K` / `"K"`
select entry emits `missing`; a closure should build its key fields
from `g.keys` (`(; g.keys..., N = length(g))`).

`GROUPING(K)` — usable in a `select` or `having` **string**, and as
`g.grouping.K` in a closure — is `true` when key `K` is rolled up in
that row (SQL's `GROUPING()`), e.g.
`select = ["label" => "iif(GROUPING(K2), 'ALL', K2)", …]` or
`having = "GROUPING(K1) == 0"`.

(casacore parses `ROLLUP`/`CUBE`/`GROUPING SETS` but does not implement
them, so this is plain SQL semantics with no real-TaQL cross-check.)

Returns a [`GroupedTable`](@ref).
"""
function groupby(t::AbstractTable, groupcols;
                 select::AbstractVector{<:Pair}, cols=nothing,
                 where=nothing, having=nothing,
                 rollup::Bool=false, cube::Bool=false, grouping_sets=nothing,
                 orderby::Union{Nothing,AbstractVector}=nothing)
    isempty(select) && throw(ArgumentError("groupby: `select` must not be empty"))
    outnames = String[String(first(p)) for p in select]
    allunique(outnames) || throw(ArgumentError("groupby: duplicate output column name"))
    vn = Set(columnnames(t))

    # classify each select RHS: (:fn, closure) or (:ast, TQLExpr)
    kinds = Tuple{Symbol,Any}[
        last(p) isa Function ? (:fn, last(p)) :
        (:ast, _taqllite_parse(String(last(p)), vn)) for p in select]
    strasts = TQLExpr[a for (k, a) in kinds if k === :ast]
    anyclosure = any(k === :fn for (k, _) in kinds) ||
                 where isa Function || having isa Function

    loaded, rows, havingfn, keys =
        _gb_prepare(t, groupcols, where, having, strasts, cols, anyclosure)
    kidx = Dict(k => j for (j, k) in enumerate(keys))

    acc = [Any[] for _ in outnames]
    for active in _gb_sets(keys, rollup, cube, grouping_sets)
        aset = Set(active)
        rolled = _gb_rolled(keys, active)
        # resolve GROUPING(k) in each string select expr for this set
        lvl = Tuple{Symbol,Any}[k === :ast ? (:ast, _sg(v, rolled)) : (k, v) for (k, v) in kinds]
        groups, seen = _group_rows(keys[active], loaded, rows)
        for key in seen
            g = groups[key]
            havingfn(g, keys, active) || continue
            for (j, (k, v)) in enumerate(lvl)
                push!(acc[j],
                    k === :fn ? v(GroupSlice(loaded, g, keys, active)) :
                    (v isa TQLCol && haskey(kidx, v.name) && !(kidx[v.name] in aset)) ? missing :
                    _geval(v, loaded, g))
            end
        end
    end

    gt = GroupedTable(Symbol.(outnames), AbstractVector[identity.(a) for a in acc])
    orderby === nothing ? gt : _gt_sort(gt, orderby)
end

"""
    groupby(f, t, groupcols; cols=nothing, where=nothing, having=nothing, orderby=nothing) -> GroupedTable

Closure form (do-block friendly). `f(g)` receives a [`GroupSlice`](@ref)
for each group and returns a `NamedTuple` — that group's output row.
Every group must return the same field names; they become the result's
columns, in that order.

```julia
groupby(t, [:ANTENNA1]; cols=["ANTENNA1", "DATA"]) do g
    (; ANT = first(g.ANTENNA1), N = length(g), AMP = mean(abs.(g.DATA)))
end
```

`cols` restricts which columns are loaded onto `g` (default: every
column of `t` — `f` is opaque). `where` / `having` — a string or a
predicate closure (`row -> Bool` / `g -> Bool`). `orderby` — see the
string form. `rollup` / `cube` / `grouping_sets` — see the string form;
a multi-set closure should use `g.keys` for its key fields (`(; g.keys...,
N = length(g))`) so aggregated-away keys come back as `missing`, and
may test `g.grouping.K`.
"""
function groupby(f::Function, t::AbstractTable, groupcols; cols=nothing,
                 where=nothing, having=nothing,
                 rollup::Bool=false, cube::Bool=false, grouping_sets=nothing,
                 orderby::Union{Nothing,AbstractVector}=nothing)
    loaded, rows, havingfn, keys =
        _gb_prepare(t, groupcols, where, having, TQLExpr[], cols, true)

    nts = NamedTuple[]
    for active in _gb_sets(keys, rollup, cube, grouping_sets)
        groups, seen = _group_rows(keys[active], loaded, rows)
        for key in seen
            g = groups[key]
            havingfn(g, keys, active) || continue
            nt = f(GroupSlice(loaded, g, keys, active))
            nt isa NamedTuple ||
                throw(ArgumentError("groupby(f, ...): the closure must return a NamedTuple"))
            isempty(nts) || Base.keys(nt) == Base.keys(nts[1]) ||
                throw(ArgumentError(
                    "groupby(f, ...): every group must return the same NamedTuple field names"))
            push!(nts, nt)
        end
    end

    onames = isempty(nts) ? Symbol[] : collect(Base.keys(nts[1]))
    gt = GroupedTable(onames,
        AbstractVector[identity.([nt[n] for nt in nts]) for n in onames])
    orderby === nothing ? gt : _gt_sort(gt, orderby)
end

function _gt_sort(gt::GroupedTable, orderby::AbstractVector)
    keys = TQLOrderKey[]
    for o in orderby
        if o isa Pair
            d = last(o)
            d isa Symbol && d in (:asc, :desc) ||
                throw(ArgumentError("groupby orderby: direction must be :asc or :desc"))
            push!(keys, TQLOrderKey(String(first(o)), d === :desc))
        else
            push!(keys, TQLOrderKey(String(o), false))
        end
    end
    for k in keys
        k.name in String.(gt.names) ||
            throw(ArgumentError("groupby orderby: no output column \"$(k.name)\""))
    end
    bycol = Dict(String(n) => c for (n, c) in zip(gt.names, gt.cols))
    n = isempty(gt.cols) ? 0 : length(gt.cols[1])
    perm = sort(collect(1:n); alg=Base.Sort.MergeSort, lt=function (i, j)
        for k in keys
            vi, vj = bycol[k.name][i], bycol[k.name][j]
            vi == vj && continue
            return k.desc ? isless(vj, vi) : isless(vi, vj)
        end
        return false
    end)
    return GroupedTable(copy(gt.names), AbstractVector[c[perm] for c in gt.cols])
end

