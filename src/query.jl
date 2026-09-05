# TaQL-lite: a small, self-contained query facility -- row filtering
# (WHERE) and column projection/rename (SELECT), producing a `RefTable`
# (the same lazy, no-copy view type real TaQL's own `SELECT ... GIVING`
# produces -- see tables.jl's RefTable/`write_reftable`).
#
# Two entry points share one AST/evaluator: a small hand-written parser
# for a TaQL-like WHERE string, and a plain Julia predicate closure over
# a `Tables.AbstractRow` (reusing `CTDSRow`/`CTDSRows` from
# tables_interface.jl -- no new row-wrapper type needed).
#
# This is a deliberate SUBSET of real TaQL's WHERE grammar, not a
# look-alike: every operator/keyword spelling accepted here is also
# accepted by real TaQL (verified against `tables/TaQL/TableGram.ll`'s
# lexer -- `==`/`=`/`!=`/`<>`/`<`/`<=`/`>`/`>=`, `AND`/`&&`, `OR`/`||`,
# `NOT`/`!`, both case-insensitive keyword forms). Not supported (see the
# Phase 22 plan's non-goals): arithmetic expressions, string pattern
# matching, ORDER BY, GROUP BY, joins, computed output columns.

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

_tqleval(e::TQLCol, cols, i) = cols[e.name][i]
_tqleval(e::TQLLit, cols, i) = e.value
_tqleval(e::TQLCmp, cols, i) = e.op(_tqleval(e.lhs, cols, i), _tqleval(e.rhs, cols, i))
_tqleval(e::TQLAnd, cols, i) = _tqleval(e.a, cols, i) && _tqleval(e.b, cols, i)
_tqleval(e::TQLOr, cols, i) = _tqleval(e.a, cols, i) || _tqleval(e.b, cols, i)
_tqleval(e::TQLNot, cols, i) = !_tqleval(e.a, cols, i)
_tqleval(e::TQLIn, cols, i) = _tqleval(e.lhs, cols, i) in e.vals

# Collect every column name an expression actually references, so `query`
# reads only those columns (not the whole table) -- the real point of the
# string-based path over the closure one, which can't be introspected.
_tqlrefs!(seen, e::TQLCol) = push!(seen, e.name)
_tqlrefs!(seen, e::TQLLit) = nothing
_tqlrefs!(seen, e::TQLCmp) = (_tqlrefs!(seen, e.lhs); _tqlrefs!(seen, e.rhs))
_tqlrefs!(seen, e::TQLAnd) = (_tqlrefs!(seen, e.a); _tqlrefs!(seen, e.b))
_tqlrefs!(seen, e::TQLOr) = (_tqlrefs!(seen, e.a); _tqlrefs!(seen, e.b))
_tqlrefs!(seen, e::TQLNot) = _tqlrefs!(seen, e.a)
_tqlrefs!(seen, e::TQLIn) = _tqlrefs!(seen, e.lhs)

# ======================================================================
# tokenizer
# ======================================================================

struct TQLToken
    kind::Symbol     # :ident | :num | :str | :op | :lparen | :rparen |
                      # :lbracket | :rbracket | :comma | :eof
    text::String
    value::Any        # parsed literal value for :num/:str, else nothing
end

const _TQL_OPCHARS = "=!<>&|"

function _taqllite_tokenize(s::AbstractString)
    toks = TQLToken[]
    cs = collect(s)
    n = length(cs)
    i = 1
    while i <= n
        c = cs[i]
        if isspace(c)
            i += 1
        elseif c == '('
            push!(toks, TQLToken(:lparen, "(", nothing)); i += 1
        elseif c == ')'
            push!(toks, TQLToken(:rparen, ")", nothing)); i += 1
        elseif c == '['
            push!(toks, TQLToken(:lbracket, "[", nothing)); i += 1
        elseif c == ']'
            push!(toks, TQLToken(:rbracket, "]", nothing)); i += 1
        elseif c == ','
            push!(toks, TQLToken(:comma, ",", nothing)); i += 1
        elseif c == '-'
            push!(toks, TQLToken(:minus, "-", nothing)); i += 1
        elseif c == '\'' || c == '"'
            q = c
            j = i + 1
            while j <= n && cs[j] != q
                j += 1
            end
            j > n && throw(ArgumentError("TaQL-lite: unterminated string literal in \"$s\""))
            val = join(cs[i+1:j-1])
            push!(toks, TQLToken(:str, join(cs[i:j]), val))
            i = j + 1
        elseif isdigit(c) || (c == '.' && _isdigit_at(cs, i + 1, n))
            j = i
            sawdot = false
            while j <= n && (isdigit(cs[j]) || (cs[j] == '.' && !sawdot))
                sawdot |= cs[j] == '.'
                j += 1
            end
            text = join(cs[i:j-1])
            val = sawdot ? parse(Float64, text) : parse(Int64, text)
            push!(toks, TQLToken(:num, text, val))
            i = j
        elseif isletter(c) || c == '_'
            j = i
            while j <= n && (isletter(cs[j]) || isdigit(cs[j]) || cs[j] == '_')
                j += 1
            end
            push!(toks, TQLToken(:ident, join(cs[i:j-1]), nothing))
            i = j
        elseif c in _TQL_OPCHARS
            j = i
            while j <= n && cs[j] in _TQL_OPCHARS
                j += 1
            end
            push!(toks, TQLToken(:op, join(cs[i:j-1]), nothing))
            i = j
        else
            throw(ArgumentError("TaQL-lite: unexpected character '$c' in \"$s\""))
        end
    end
    push!(toks, TQLToken(:eof, "", nothing))
    return toks
end

_isdigit_at(cs, j, n) = j <= n && isdigit(cs[j])

# ======================================================================
# recursive-descent parser
# ======================================================================
#
# expr    := orExpr
# orExpr  := andExpr ( (OR|'||') andExpr )*
# andExpr := notExpr ( (AND|'&&') notExpr )*
# notExpr := (NOT|'!') notExpr | comparison
# comparison := atom ( cmpop atom | IN '[' atom (',' atom)* ']' )?
# atom    := column | literal | '(' expr ')'

mutable struct TQLParser
    toks::Vector{TQLToken}
    pos::Int
    validnames::AbstractSet{String}
    src::String
end

_peek(p::TQLParser) = p.toks[p.pos]
_advance!(p::TQLParser) = (t = p.toks[p.pos]; p.pos += 1; t)

_iskw(t::TQLToken, kw::String) = t.kind === :ident && uppercase(t.text) == kw

function _expect_kind!(p::TQLParser, kind::Symbol, what::AbstractString)
    t = _peek(p)
    t.kind === kind || throw(ArgumentError(
        "TaQL-lite: expected $what near \"$(t.text)\" in \"$(p.src)\""))
    return _advance!(p)
end

function _taqllite_parse(s::AbstractString, validnames::AbstractSet{String})
    p = TQLParser(_taqllite_tokenize(s), 1, validnames, String(s))
    e = _parse_or!(p)
    _peek(p).kind === :eof || throw(ArgumentError(
        "TaQL-lite: unexpected trailing input near \"$(_peek(p).text)\" in \"$s\""))
    return e
end

function _parse_or!(p::TQLParser)
    a = _parse_and!(p)
    while true
        t = _peek(p)
        if _iskw(t, "OR") || (t.kind === :op && t.text == "||")
            _advance!(p)
            b = _parse_and!(p)
            a = TQLOr(a, b)
        else
            return a
        end
    end
end

function _parse_and!(p::TQLParser)
    a = _parse_not!(p)
    while true
        t = _peek(p)
        if _iskw(t, "AND") || (t.kind === :op && t.text == "&&")
            _advance!(p)
            b = _parse_not!(p)
            a = TQLAnd(a, b)
        else
            return a
        end
    end
end

function _parse_not!(p::TQLParser)
    t = _peek(p)
    if _iskw(t, "NOT") || (t.kind === :op && t.text == "!")
        _advance!(p)
        return TQLNot(_parse_not!(p))
    end
    return _parse_comparison!(p)
end

const _TQL_CMPOPS = Dict{String,Function}(
    "==" => (==), "=" => (==), "!=" => (!=), "<>" => (!=),
    "<" => (<), "<=" => (<=), ">" => (>), ">=" => (>=))

function _parse_comparison!(p::TQLParser)
    if _peek(p).kind === :lparen
        _advance!(p)
        e = _parse_or!(p)
        _expect_kind!(p, :rparen, "')'")
        return e
    end
    lhs = _parse_atom!(p)
    t = _peek(p)
    if t.kind === :op && haskey(_TQL_CMPOPS, t.text)
        _advance!(p)
        rhs = _parse_atom!(p)
        return TQLCmp(_TQL_CMPOPS[t.text], lhs, rhs)
    elseif _iskw(t, "IN")
        _advance!(p)
        _expect_kind!(p, :lbracket, "'['")
        vals = Any[_parse_literal_value!(p)]
        while _peek(p).kind === :comma
            _advance!(p)
            push!(vals, _parse_literal_value!(p))
        end
        _expect_kind!(p, :rbracket, "']'")
        return TQLIn(lhs, vals)
    else
        # No comparison/IN follows -- treat the bare atom itself as the
        # boolean expression (e.g. `WHERE D` / `WHERE NOT D` for a Bool
        # column `D`, exactly as real TaQL allows). Not statically
        # checked: a bare non-Bool column/literal here surfaces as an
        # ordinary Julia `TypeError`/`MethodError` at query-evaluation
        # time, not a parse error.
        return lhs
    end
end

function _parse_literal_value!(p::TQLParser)
    e = _parse_atom!(p)
    e isa TQLLit || throw(ArgumentError(
        "TaQL-lite: expected a literal value in an IN list in \"$(p.src)\""))
    return e.value
end

function _parse_atom!(p::TQLParser)
    if _peek(p).kind === :lparen
        _advance!(p)
        e = _parse_or!(p)
        _expect_kind!(p, :rparen, "')'")
        return e
    end
    if _peek(p).kind === :minus     # unary minus, numeric literals only (no general arithmetic)
        _advance!(p)
        t = _expect_kind!(p, :num, "a number after '-'")
        return TQLLit(-t.value)
    end
    t = _advance!(p)
    if t.kind === :num
        return TQLLit(t.value)
    elseif t.kind === :str
        return TQLLit(t.value)
    elseif t.kind === :ident
        up = uppercase(t.text)
        up == "TRUE" && return TQLLit(true)
        up == "FALSE" && return TQLLit(false)
        t.text in p.validnames || throw(ArgumentError(
            "TaQL-lite: unknown column \"$(t.text)\" in \"$(p.src)\""))
        return TQLCol(t.text)
    else
        throw(ArgumentError(
            "TaQL-lite: expected a column, literal, or '(' near \"$(t.text)\" in \"$(p.src)\""))
    end
end

# A query result's `path` is `""` (in-memory, never persisted on its
# own -- see the module docs). Composing a further `query` on top of one
# would otherwise nest a RefTable whose PARENT has no real path, which
# `write_reftable`'s on-disk RefTable format can't represent (it stores a
# real path string to the parent). So instead of nesting, flatten straight
# through any chain of pathless (query-produced) RefTable ancestors,
# composing `rows`/`select` along the way, bottoming out at a real
# `Table`/`ConcatTable` or an actually-persisted `RefTable` (non-empty
# `path`) -- always a valid, addressable `write_reftable` parent.
function _flatten_query_parent(t::AbstractTable, rows::Vector{Int},
                               namemap::Dict{String,String})
    if t isa RefTable && isempty(t.path)
        rows2 = t.rows[rows]
        namemap2 = Dict(out => t.namemap[srcname] for (out, srcname) in namemap)
        return _flatten_query_parent(t.parent, rows2, namemap2)
    end
    return t, rows, namemap
end

# ======================================================================
# public API
# ======================================================================

"""
    query(t::AbstractTable, wherestr::AbstractString;
         select=[n=>n for n in columnnames(t)]) -> RefTable

Row-filter `t` with a small TaQL-like WHERE expression: comparisons
(`==`/`=`, `!=`/`<>`, `<`, `<=`, `>`, `>=`), `AND`/`&&`, `OR`/`||`,
`NOT`/`!`, parentheses, and `col IN [v1, v2, ...]`. Column names are
case-sensitive and must name a column of `t`; keywords are
case-insensitive. Only the columns the expression actually references
are read. `select` projects/renames columns exactly like
[`write_reftable`](@ref)'s own `select=`. Returns a `RefTable` (no data
copied); persist it with `write_reftable(dst, result)`.

Deliberately a *subset* of real TaQL's WHERE grammar, not a look-alike:
no arithmetic, no string pattern matching, no `ORDER BY`/`GROUP BY`/joins.
"""
function query(t::AbstractTable, wherestr::AbstractString;
              select::AbstractVector{<:Pair}=[n => n for n in columnnames(t)])
    ast = _taqllite_parse(wherestr, Set(columnnames(t)))
    needed = Set{String}()
    _tqlrefs!(needed, ast)
    cols = Dict(n => column(t, n) for n in needed)
    matched = [i for i in 1:nrow(t) if _tqleval(ast, cols, i)]
    namemap, order = _select_spec(t, select)
    parent, rows, namemap = _flatten_query_parent(t, matched, namemap)
    return RefTable("", parent, rows, namemap, order, parent.type, parent.subtype, parent.readme)
end

"""
    query(f::Function, t::AbstractTable; cols=nothing,
         select=[n=>n for n in columnnames(t)]) -> RefTable

Row-filter `t` with a Julia predicate `f(row) -> Bool` (do-block
friendly: `query(t; cols=[...]) do row ... end`). `row` is a
`Tables.AbstractRow` supporting `row.COLNAME` property access. `cols`
restricts which columns are actually read (default: every column — `f`
is an opaque closure, so unlike the string-based `query` its column use
can't be inferred; pass `cols` explicitly on a wide table to avoid
materialising columns `f` never touches). `select` — see the string-based
`query` above.
"""
function query(f::Function, t::AbstractTable;
              cols::Union{Nothing,AbstractVector}=nothing,
              select::AbstractVector{<:Pair}=[n => n for n in columnnames(t)])
    names = cols === nothing ? columnnames(t) : String.(cols)
    rows = CTDSRows(AbstractVector[column(t, n) for n in names], Symbol.(names), nrow(t))
    matched = [i for (i, row) in enumerate(rows) if f(row)]
    namemap, order = _select_spec(t, select)
    parent, rows2, namemap = _flatten_query_parent(t, matched, namemap)
    return RefTable("", parent, rows2, namemap, order, parent.type, parent.subtype, parent.readme)
end
