# TaQL-lite: a small, self-contained query facility -- row filtering
# (WHERE) and column projection/rename (SELECT), producing a `RefTable`
# (the same lazy, no-copy view type real TaQL's own `SELECT ... GIVING`
# produces -- see tables/table.jl's RefTable/`write_reftable`).
#
# Two entry points share one AST/evaluator: a small hand-written parser
# for a TaQL-like WHERE string, and a plain Julia predicate closure over
# a `Tables.AbstractRow` (reusing `CTDSRow`/`CTDSRows` from
# tables/interface.jl -- no new row-wrapper type needed).
#
# This is a deliberate SUBSET of real TaQL's WHERE grammar, not a
# look-alike: every operator/keyword spelling accepted here is also
# accepted by real TaQL (verified against `tables/TaQL/TableGram.{ll,yy}`'s
# lexer + grammar -- `==`/`=`/`!=`/`<>`/`<`/`<=`/`>`/`>=`, `~=`/`!~=`
# (approximate equality), `AND`/`&&`, `OR`/`||`, `NOT`/`!`, `IN [...]`,
# arithmetic `+ - * / % // **`, bitwise `& | ^` + unary `~`,
# `LIKE`/`ILIKE`, the `~`/`!~` glob/regex operator, and a trailing
# `ORDER BY`, all case-insensitive keyword forms). Supports quantity
# literals + date/time/angle functions (Phase 69), computed output
# columns (Phase 57), and -- with `import SOFA` -- `mscal.*` derived-MS
# functions (Phase 77). Not supported: a read of `V[boolmask]` in a
# WHERE/SELECT expression (it is valid only as an `update!` SET
# target -- Phase 55).
# (Array element/slice indexing -- `DATA[1,1]`, `UVW[3]`, `V[1:4,1]`,
# 1-based, with negative-from-end and `end` -- landed in Phase 42/44;
# `BETWEEN` / `NOT BETWEEN` in Phase 43; bitwise ops -- `^` is xor, use
# `**` for power -- in Phase 46; `~=` in Phase 47.)
#
# Phase 23 adds ORDER BY (bare column references only, optional per-key
# ASC/DESC -- verified against the `sortlist`/`sortexpr` grammar; no
# arithmetic sort keys, no leading global default-direction shortcut,
# no NODUPL/DISTINCT).
#
# Phase 24 adds an arithmetic-expression layer (between comparison and
# atom: `+ -` < `* / % //` < unary `-` < `**`, matching TaQL's own
# precedence table) and pattern matching -- `LIKE`/`ILIKE`/`NOT LIKE`
# (SQL glob: `%` `_`) and TaQL's `~`/`!~` operator with `p/glob/`,
# `m/regex/`, `f/regex/` delimited literals (delimiters `/ % @`,
# optional trailing `i` for case-insensitive).
#
# Phase 25 adds a curated function library -- `NAME(args...)`,
# case-insensitive, with TaQL's own aliases: scalar math (abs, sqrt,
# exp, log, trig, floor/ceil/round, sign, ...), complex parts (real,
# imag, arg/phase, conj, norm), array-cell reductions (mean/avg, sum,
# median, stddev, variance, rms, min/max, any, all, ntrue, nelements),
# string ops (strlength/len, upper, lower, trim), and specials
# (rownumber(), pi, e, iif, GROUPING(k) in a groupby select/having).
#
# Phase 69 adds quantity literals (`1.4GHz`, `10arcsec` -- a
# Unitful.Quantity, needs the Unitful ext; a context with one attaches
# each unit-bearing column's QuantumUnits so the comparison goes through
# Unitful), array literals `[a, b, ...]`, scientific-notation number
# literals, and date/time + angle functions (`datetime`, `mjd`, `date`,
# `year`/`month`/`day`, `hms`/`dms`, `normangle`, `angdist` -- dates are
# an MJD `Float64`).
# Not supported: `mscal.*` / measures-frame functions,
# sliding-window (`running*`/`boxed*`) ops, rand, array reshaping,
# rowid(), substr, type conversions, UDFs, aggregates over row groups.

import Statistics
import Tables
import Dates

# ======================================================================
# AST -- dispatch, not branching (see [[julia-dispatch-style]]): a
# comparison node stores the actual Julia comparison FUNCTION, so one
# `_tqleval` method handles every operator with no per-operator branch.
# ======================================================================

abstract type TQLExpr end

struct TQLCol <: TQLExpr
    name::String
end
struct TQLLit <: TQLExpr
    value::Any
end
struct TQLCmp{F} <: TQLExpr        # op ∈ {==, !=, <, <=, >, >=}
    op::F
    lhs::TQLExpr
    rhs::TQLExpr
end
struct TQLAnd <: TQLExpr
    a::TQLExpr
    b::TQLExpr
end
struct TQLOr <: TQLExpr
    a::TQLExpr
    b::TQLExpr
end
struct TQLNot <: TQLExpr
    a::TQLExpr
end
struct TQLIn <: TQLExpr
    lhs::TQLExpr
    vals::Vector{Any}
end
struct TQLArith{F} <: TQLExpr      # op ∈ {+, -, *, /, rem (%), div (//), ^ (**)}
    op::F
    lhs::TQLExpr
    rhs::TQLExpr
end
struct TQLNeg <: TQLExpr           # unary minus on an expression
    a::TQLExpr
end
struct TQLMatch <: TQLExpr         # LIKE / ILIKE / ~ / !~  (regex compiled at parse time)
    lhs::TQLExpr
    regex::Regex
    negate::Bool
end
struct TQLFunc <: TQLExpr           # NAME(args...) -- resolved Julia callable + parsed args
    fn::Base.Callable
    args::Vector{TQLExpr}
end
struct TQLRowNum <: TQLExpr end     # rownumber() / rownr() -- the 1-based row index
struct TQLAggr <: TQLExpr           # g*(arg) -- reduces over a group's rows (groupby only)
    fn::Base.Callable               # a scalar reducer (Vector -> scalar)
    arg::Union{Nothing,TQLExpr}     # nothing only for gcount()
    mode::Symbol                    # :scalar (g*) or :perelem (gs*)
end
struct TQLGrouping <: TQLExpr       # GROUPING(k) -- true if key `k` is rolled up in this group
    name::String
end
struct TQLIndex <: TQLExpr          # base[i], base[i,j], base[a:b:step, k] -- 1-based
    base::TQLExpr
    axes::Vector{Any}               # each: a TQLExpr (scalar index, drops the axis) OR
                                    # (; lo, hi, step) of Union{Nothing,TQLExpr} (a range/colon)
end
struct TQLBetween <: TQLExpr        # x BETWEEN lo AND hi (inclusive both ends); NOT BETWEEN
    lhs::TQLExpr
    lo::TQLExpr
    hi::TQLExpr
    negate::Bool
end
struct TQLEnd <: TQLExpr end         # `end` inside a subscript -> that axis's length
struct TQLBitNot <: TQLExpr          # unary `~` (bitwise NOT)
    a::TQLExpr
end
struct TQLMaskOf <: TQLExpr          # the mask of a (possibly masked) array expr;
    e::TQLExpr                       # `update!`'s `(D, M) = expr` mask side
end
struct TQLQuantityLit <: TQLExpr     # `1.4GHz` / `10arcsec` -- a Unitful.Quantity
    value::Any                       # built at parse time by the Unitful ext
end
struct TQLArrayLit <: TQLExpr        # `[a, b, ...]` -- a plain vector of the elements
    elems::Vector{TQLExpr}
end

# Arithmetic and comparison broadcast over an array-cell operand (TaQL
# semantics: `DATA * 2`, `FLAG == True` are elementwise). A top-level
# WHERE that produces an array (e.g. `DATA > 0`) then errors on the
# `if` -- correct, exactly as real TaQL requires `any(...)`/`all(...)`
# there. `AND`/`OR` stay scalar (short-circuit); `NOT` broadcasts so
# `NOT FLAG` / `V[!FLAG]` negate an array-cell mask elementwise.
_bcast(f, x) = x isa AbstractArray ? f.(x) : f(x)
_bcast(f, x, y) = (x isa AbstractArray || y isa AbstractArray) ? f.(x, y) : f(x, y)

# Materialise a (lazy) *scalar* column once, so a WHERE / group /
# aggregate loop indexes a dense `Vector` per row rather than re-decoding
# a storage-manager cell by cell.  A `GroupedTable` column is already a
# `Vector` (no needless copy); an array-valued column stays lazy so a
# predicate over a huge cube column (`mean(abs(DATA)) > x`) still streams
# rather than trying to hold the whole column in memory.
_load_col(c::Vector) = c
_load_col(c::AbstractVector) = eltype(c) <: AbstractArray ? c : c[:]

# --- masked arrays (TaQL `MArray`): data + a Bool mask, `true` = invalid.
# Produced by `V[boolexpr]`, `marray(d, m)`, and a masked reduction's
# argument; reductions skip masked elements, arithmetic unions the masks.
struct TQLMArray{A<:AbstractArray,M<:AbstractArray{Bool}}
    data::A
    mask::M
    function TQLMArray(d::AbstractArray, m::AbstractArray{Bool})
        size(d) == size(m) || throw(ArgumentError(
            "TaQL-lite: masked-array data $(size(d)) and mask $(size(m)) shapes differ"))
        new{typeof(d),typeof(m)}(d, m)
    end
end
_mvalid(m::TQLMArray) = m.data[.!m.mask]
_unwrap_marray(v) = v isa TQLMArray ? v.data : v

_bcast(f, x::TQLMArray) = TQLMArray(_bcast(f, x.data), copy(x.mask))
_bcast(f, x::TQLMArray, y) = TQLMArray(_bcast(f, x.data, y), copy(x.mask))
_bcast(f, x, y::TQLMArray) = TQLMArray(_bcast(f, x, y.data), copy(y.mask))
_bcast(f, x::TQLMArray, y::TQLMArray) =
    TQLMArray(_bcast(f, x.data, y.data), x.mask .| y.mask)

_tqleval(e::TQLCol, cols, i) = cols[e.name][i]
_tqleval(e::TQLLit, cols, i) = e.value
_tqleval(e::TQLQuantityLit, cols, i) = e.value
_tqleval(e::TQLArrayLit, cols, i) = [_tqleval(x, cols, i) for x in e.elems]
_tqleval(e::TQLCmp, cols, i) = _bcast(e.op, _tqleval(e.lhs, cols, i), _tqleval(e.rhs, cols, i))
_tqleval(e::TQLAnd, cols, i) = _tqleval(e.a, cols, i) && _tqleval(e.b, cols, i)
_tqleval(e::TQLOr, cols, i) = _tqleval(e.a, cols, i) || _tqleval(e.b, cols, i)
_tqleval(e::TQLNot, cols, i) = _bcast(!, _tqleval(e.a, cols, i))
_tqleval(e::TQLIn, cols, i) = _tqleval(e.lhs, cols, i) in e.vals
_tqleval(e::TQLArith, cols, i) = _bcast(e.op, _tqleval(e.lhs, cols, i), _tqleval(e.rhs, cols, i))
_tqleval(e::TQLNeg, cols, i) = _bcast(-, _tqleval(e.a, cols, i))
_tqleval(e::TQLBitNot, cols, i) = _bcast((~), _tqleval(e.a, cols, i))
_tqleval(e::TQLMaskOf, cols, i) = (v = _tqleval(e.e, cols, i);
    v isa TQLMArray ? v.mask : _bcast(!isfinite, _unwrap_marray(v)))
_tqleval(e::TQLMatch, cols, i) =
    xor(occursin(e.regex, _tqleval(e.lhs, cols, i)::AbstractString), e.negate)
_tqleval(e::TQLFunc, cols, i) =
    e.fn(ntuple(k -> _tqleval(e.args[k], cols, i), length(e.args))...)
_tqleval(::TQLRowNum, cols, i) = i
_tqleval(::TQLEnd, cols, i) = throw(ArgumentError(
    "TaQL-lite: `end` is only valid inside an array subscript `[...]`"))
_tqleval(::TQLGrouping, cols, i) = throw(ArgumentError(
    "TaQL-lite: GROUPING() is only valid in a groupby select / having"))
_tqleval(::TQLAggr, cols, i) = throw(ArgumentError(
    "TaQL-lite: aggregate functions (g*) are only valid in groupby(...), not query(...)"))
_tqleval(e::TQLIndex, cols, i) = _tql_do_index(_tqleval(e.base, cols, i), e.axes,
                                               (x -> _tqleval(x, cols, i)))
_tqleval(e::TQLBetween, cols, i) = _tql_between(
    _tqleval(e.lhs, cols, i), _tqleval(e.lo, cols, i), _tqleval(e.hi, cols, i), e.negate)

# x BETWEEN lo AND hi -- inclusive both ends (casacore left/right-closed);
# elementwise when `x` is an array cell.
function _tql_between(x, lo, hi, negate::Bool)
    both = _bcast(&, _bcast(>=, x, lo), _bcast(<=, x, hi))
    return negate ? _bcast(!, both) : both
end

# 1-based array-cell indexing: a scalar axis drops that dimension, a
# range axis `lo:hi:step` (casacore's start:end:step) maps to Julia's
# `lo:step:hi`; a missing lo/hi/step defaults to 1 / size(arr,k) / 1;
# fewer subscripts than ndims => trailing axes taken whole.
function _tql_index_tuple(arr, axes, ev)
    arr isa AbstractArray || throw(ArgumentError(
        "TaQL-lite: cannot index a scalar value with `[...]`"))
    nd = ndims(arr)
    length(axes) <= nd || throw(ArgumentError(
        "TaQL-lite: $(length(axes)) subscripts for a $(nd)-D array cell"))
    return ntuple(k -> k <= length(axes) ? _tql_axis(axes[k], arr, k, ev) : Colon(), nd)
end

function _tql_do_index(arr, axes, ev)
    # a single Bool-array subscript is a masked selection, not an index:
    # `V[boolexpr]` -> the whole cell with `!boolexpr` masked out.
    if length(axes) == 1
        m = _as_mask(axes, ev)
        m !== nothing && return TQLMArray(collect(arr), BitArray(.!m))
    end
    return arr[_tql_index_tuple(arr, axes, ev)...]
end

# write `rhs` into `arr` at the resolved index tuple (used by `update!`
# for `SET col[subscripts] = expr`): a plain assign when every axis is a
# scalar index, otherwise a broadcast (a scalar RHS fills the slice, a
# conforming array RHS is assigned elementwise).
function _slice_assign!(arr, idx::Tuple, rhs)
    if all(i -> i isa Integer, idx)
        arr[idx...] = rhs
    else
        arr[idx...] .= rhs
    end
    return arr
end

# unwrap a chain of `TQLIndex` down to a `TQLCol` base, collecting each
# bracket's axes in column-outward order (`V[a][b]` -> `("V", [[a],[b]])`).
# Returns `nothing` if the base is not a plain column.
_flatten_lhs(e::TQLCol) = (e.name, Vector{Any}[])
function _flatten_lhs(e::TQLIndex)
    if e.base isa TQLCol
        return (e.base.name, Vector{Any}[collect(Any, e.axes)])
    elseif e.base isa TQLIndex
        r = _flatten_lhs(e.base)
        r === nothing && return nothing
        return (r[1], push!(r[2], collect(Any, e.axes)))
    end
    return nothing
end
_flatten_lhs(::TQLExpr) = nothing

# a single subscript that evaluates to a Bool array is a mask, not an index
function _as_mask(axes, ev)
    length(axes) == 1 && !(axes[1] isa NamedTuple) || return nothing
    # `ev` may throw for an `end`-relative or out-of-context subscript --
    # that just means "not a mask", fall through to ordinary indexing.
    v = try
        ev(axes[1])
    catch
        return nothing
    end
    (v isa AbstractArray && eltype(v) <: Bool) ? v : nothing
end

# apply an `update!` LHS subscript chain to `cur`, assigning `rhs`; each
# level is either an integer/range slice or a boolean mask (at most one
# mask in the chain). Mask-before-slice conforms the mask to the whole
# cell then slices it; mask-after-slice conforms it to the section.
function _apply_index_chain!(cur, levels, ev, rhs)
    target = cur
    pending = nothing
    for axes in levels
        m = _as_mask(axes, ev)
        if m !== nothing
            pending === nothing ||
                throw(ArgumentError("update!: two masks in one subscript chain"))
            pending = m
        else
            idx = _tql_index_tuple(target, axes, ev)
            target = view(target, idx...)
            pending === nothing || (pending = pending[idx...])
        end
    end
    pending === nothing ? (target .= rhs) : (target[pending] .= rhs)
    return cur
end

function _tql_axis(ax, arr, k::Int, ev)
    n = size(arr, k)
    # `end` inside this axis's subscript -> `n`; a negative resolved
    # index counts from the end (casacore Slicer: -1 == last).
    e(x) = _tql_fromend(Int(ev(_subst_end(x, n))), n)
    ax isa NamedTuple || return e(ax)                             # scalar index
    lo = ax.lo === nothing ? 1 : e(ax.lo)
    hi = ax.hi === nothing ? n : e(ax.hi)
    st = ax.step === nothing ? 1 : Int(ev(_subst_end(ax.step, n)))
    st > 0 || throw(ArgumentError("TaQL-lite: array subscript step must be positive"))
    return lo:st:hi
end

_tql_fromend(v::Int, n::Int) = v < 0 ? n + v + 1 : v

# rewrite `end` -> TQLLit(n) in one axis subscript expression; a nested
# `V[W[end], k]` keeps its inner index untouched (it self-resolves via
# its own `_tql_do_index`).
_subst_end(e::TQLEnd, n) = TQLLit(n)
_subst_end(e::TQLArith, n) = TQLArith(e.op, _subst_end(e.lhs, n), _subst_end(e.rhs, n))
_subst_end(e::TQLNeg, n) = TQLNeg(_subst_end(e.a, n))
_subst_end(e::TQLFunc, n) = TQLFunc(e.fn, TQLExpr[_subst_end(a, n) for a in e.args])
_subst_end(e::TQLExpr, n) = e

# rewrite `GROUPING(k)` -> `TQLLit(k in rolled)` throughout a groupby
# select / having expression -- it is a per-grouping-set constant.
_sg(e::TQLGrouping, r) = TQLLit(e.name in r)
_sg(e::TQLArith, r) = TQLArith(e.op, _sg(e.lhs, r), _sg(e.rhs, r))
_sg(e::TQLCmp, r) = TQLCmp(e.op, _sg(e.lhs, r), _sg(e.rhs, r))
_sg(e::TQLAnd, r) = TQLAnd(_sg(e.a, r), _sg(e.b, r))
_sg(e::TQLOr, r) = TQLOr(_sg(e.a, r), _sg(e.b, r))
_sg(e::TQLNot, r) = TQLNot(_sg(e.a, r))
_sg(e::TQLNeg, r) = TQLNeg(_sg(e.a, r))
_sg(e::TQLBitNot, r) = TQLBitNot(_sg(e.a, r))
_sg(e::TQLBetween, r) = TQLBetween(_sg(e.lhs, r), _sg(e.lo, r), _sg(e.hi, r), e.negate)
_sg(e::TQLIn, r) = TQLIn(_sg(e.lhs, r), e.vals)
_sg(e::TQLMatch, r) = TQLMatch(_sg(e.lhs, r), e.regex, e.negate)
_sg(e::TQLFunc, r) = TQLFunc(e.fn, TQLExpr[_sg(a, r) for a in e.args])
_sg(e::TQLAggr, r) = e.arg === nothing ? e : TQLAggr(e.fn, _sg(e.arg, r), e.mode)
_sg(e::TQLIndex, r) = TQLIndex(_sg(e.base, r),
    Any[ax isa NamedTuple ?
        (; lo = ax.lo === nothing ? nothing : _sg(ax.lo, r),
           hi = ax.hi === nothing ? nothing : _sg(ax.hi, r),
           step = ax.step === nothing ? nothing : _sg(ax.step, r)) :
        _sg(ax, r) for ax in e.axes])
_sg(e::TQLExpr, r) = e     # TQLCol, TQLLit, TQLRowNum, TQLEnd

# the set of grouping-key names rolled up (not in `active`) for a set
_gb_rolled(keys::Vector{String}, active) =
    Set(keys[j] for j in eachindex(keys) if !(j in active))

# Collect every column name an expression actually references, so `query`
# reads only those columns (not the whole table) -- the real point of the
# string-based path over the closure one, which can't be introspected.
_tqlrefs!(seen, e::TQLCol) = push!(seen, e.name)
_tqlrefs!(seen, e::TQLLit) = nothing
_tqlrefs!(seen, e::TQLQuantityLit) = nothing
_tqlrefs!(seen, e::TQLArrayLit) = foreach(x -> _tqlrefs!(seen, x), e.elems)
_tqlrefs!(seen, e::TQLCmp) = (_tqlrefs!(seen, e.lhs); _tqlrefs!(seen, e.rhs))
_tqlrefs!(seen, e::TQLAnd) = (_tqlrefs!(seen, e.a); _tqlrefs!(seen, e.b))
_tqlrefs!(seen, e::TQLOr) = (_tqlrefs!(seen, e.a); _tqlrefs!(seen, e.b))
_tqlrefs!(seen, e::TQLNot) = _tqlrefs!(seen, e.a)
_tqlrefs!(seen, e::TQLIn) = _tqlrefs!(seen, e.lhs)
_tqlrefs!(seen, e::TQLArith) = (_tqlrefs!(seen, e.lhs); _tqlrefs!(seen, e.rhs))
_tqlrefs!(seen, e::TQLNeg) = _tqlrefs!(seen, e.a)
_tqlrefs!(seen, e::TQLBitNot) = _tqlrefs!(seen, e.a)
_tqlrefs!(seen, e::TQLMaskOf) = _tqlrefs!(seen, e.e)
_tqlrefs!(seen, e::TQLMatch) = _tqlrefs!(seen, e.lhs)
_tqlrefs!(seen, e::TQLFunc) = foreach(a -> _tqlrefs!(seen, a), e.args)
_tqlrefs!(seen, ::TQLRowNum) = nothing
_tqlrefs!(seen, ::TQLEnd) = nothing
_tqlrefs!(seen, e::TQLAggr) = e.arg === nothing ? nothing : _tqlrefs!(seen, e.arg)
_tqlrefs!(seen, e::TQLGrouping) = push!(seen, e.name)
function _tqlrefs!(seen, e::TQLIndex)
    _tqlrefs!(seen, e.base)
    for ax in e.axes
        if ax isa NamedTuple
            for v in (ax.lo, ax.hi, ax.step)
                v === nothing || _tqlrefs!(seen, v)
            end
        else
            _tqlrefs!(seen, ax)
        end
    end
end
_tqlrefs!(seen, e::TQLBetween) =
    (_tqlrefs!(seen, e.lhs); _tqlrefs!(seen, e.lo); _tqlrefs!(seen, e.hi))

# true if any TQLAggr node appears anywhere in the expression tree
_has_aggr(e::TQLAggr) = true
_has_aggr(e::TQLGrouping) = true   # group-context only (rejected in a plain WHERE)
_has_aggr(e::TQLCol) = false
_has_aggr(e::TQLLit) = false
_has_aggr(::TQLRowNum) = false
_has_aggr(::TQLEnd) = false
_has_aggr(e::TQLCmp) = _has_aggr(e.lhs) || _has_aggr(e.rhs)
_has_aggr(e::TQLArith) = _has_aggr(e.lhs) || _has_aggr(e.rhs)
_has_aggr(e::TQLAnd) = _has_aggr(e.a) || _has_aggr(e.b)
_has_aggr(e::TQLOr) = _has_aggr(e.a) || _has_aggr(e.b)
_has_aggr(e::TQLNot) = _has_aggr(e.a)
_has_aggr(e::TQLNeg) = _has_aggr(e.a)
_has_aggr(e::TQLBitNot) = _has_aggr(e.a)
_has_aggr(e::TQLMaskOf) = _has_aggr(e.e)
_has_aggr(e::TQLIn) = _has_aggr(e.lhs)
_has_aggr(e::TQLMatch) = _has_aggr(e.lhs)
_has_aggr(e::TQLFunc) = any(_has_aggr, e.args)
_has_aggr(e::TQLIndex) = _has_aggr(e.base) || any(e.axes) do ax
    ax isa NamedTuple ? any(v -> v !== nothing && _has_aggr(v), (ax.lo, ax.hi, ax.step)) :
    _has_aggr(ax)
end
_has_aggr(e::TQLBetween) = _has_aggr(e.lhs) || _has_aggr(e.lo) || _has_aggr(e.hi)
_has_aggr(::TQLQuantityLit) = false
_has_aggr(e::TQLArrayLit) = any(_has_aggr, e.elems)

# true if a quantity literal (`1.4GHz`) appears anywhere in the tree --
# the signal for an expression context to unit-attach its columns
# (structural, no Unitful needed). A generic `false` fallback covers the
# leaf/no-subexpr nodes; the recursive nodes are listed explicitly.
_has_qty(::TQLExpr) = false
_has_qty(::TQLQuantityLit) = true
_has_qty(e::TQLArrayLit) = any(_has_qty, e.elems)
_has_qty(e::TQLCmp) = _has_qty(e.lhs) || _has_qty(e.rhs)
_has_qty(e::TQLArith) = _has_qty(e.lhs) || _has_qty(e.rhs)
_has_qty(e::TQLAnd) = _has_qty(e.a) || _has_qty(e.b)
_has_qty(e::TQLOr) = _has_qty(e.a) || _has_qty(e.b)
_has_qty(e::TQLNot) = _has_qty(e.a)
_has_qty(e::TQLNeg) = _has_qty(e.a)
_has_qty(e::TQLBitNot) = _has_qty(e.a)
_has_qty(e::TQLMaskOf) = _has_qty(e.e)
_has_qty(e::TQLIn) = _has_qty(e.lhs)
_has_qty(e::TQLMatch) = _has_qty(e.lhs)
_has_qty(e::TQLFunc) = any(_has_qty, e.args)
_has_qty(e::TQLAggr) = e.arg !== nothing && _has_qty(e.arg)
_has_qty(e::TQLBetween) = _has_qty(e.lhs) || _has_qty(e.lo) || _has_qty(e.hi)
_has_qty(e::TQLIndex) = _has_qty(e.base) || any(e.axes) do ax
    ax isa NamedTuple ? any(v -> v !== nothing && _has_qty(v), (ax.lo, ax.hi, ax.step)) :
    _has_qty(ax)
end

