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
# accepted by real TaQL (verified against `tables/TaQL/TableGram.{ll,yy}`'s
# lexer + grammar -- `==`/`=`/`!=`/`<>`/`<`/`<=`/`>`/`>=`, `AND`/`&&`,
# `OR`/`||`, `NOT`/`!`, `IN [...]`, arithmetic `+ - * / % // **`,
# `LIKE`/`ILIKE`, the `~`/`!~` glob/regex operator, and a trailing
# `ORDER BY`, all case-insensitive keyword forms). Not supported (see
# the Phase 22/24 plan non-goals): bitwise operators (`& | ^ ~`),
# `BETWEEN`, `~=` approximate equality, array indexing, units,
# functions, GROUP BY, joins, computed output columns.
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
# (rownumber(), pi, e, iif). Not supported: date/time, measures/cones,
# sliding-window (`running*`/`boxed*`) ops, rand, array reshaping,
# rowid(), substr, type conversions, UDFs, aggregates over row groups.

import Statistics
import Tables

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
    fn::Base.Callable               # Vector-of-per-row-values -> scalar
    arg::Union{Nothing,TQLExpr}     # nothing only for gcount()
end

# Arithmetic and comparison broadcast over an array-cell operand (TaQL
# semantics: `DATA * 2`, `FLAG == True` are elementwise). A top-level
# WHERE that produces an array (e.g. `DATA > 0`) then errors on the
# `if` -- correct, exactly as real TaQL requires `any(...)`/`all(...)`
# there. `AND`/`OR`/`NOT` stay scalar (short-circuit).
_bcast(f, x) = x isa AbstractArray ? f.(x) : f(x)
_bcast(f, x, y) = (x isa AbstractArray || y isa AbstractArray) ? f.(x, y) : f(x, y)

_tqleval(e::TQLCol, cols, i) = cols[e.name][i]
_tqleval(e::TQLLit, cols, i) = e.value
_tqleval(e::TQLCmp, cols, i) = _bcast(e.op, _tqleval(e.lhs, cols, i), _tqleval(e.rhs, cols, i))
_tqleval(e::TQLAnd, cols, i) = _tqleval(e.a, cols, i) && _tqleval(e.b, cols, i)
_tqleval(e::TQLOr, cols, i) = _tqleval(e.a, cols, i) || _tqleval(e.b, cols, i)
_tqleval(e::TQLNot, cols, i) = !_tqleval(e.a, cols, i)
_tqleval(e::TQLIn, cols, i) = _tqleval(e.lhs, cols, i) in e.vals
_tqleval(e::TQLArith, cols, i) = _bcast(e.op, _tqleval(e.lhs, cols, i), _tqleval(e.rhs, cols, i))
_tqleval(e::TQLNeg, cols, i) = _bcast(-, _tqleval(e.a, cols, i))
_tqleval(e::TQLMatch, cols, i) =
    xor(occursin(e.regex, _tqleval(e.lhs, cols, i)::AbstractString), e.negate)
_tqleval(e::TQLFunc, cols, i) =
    e.fn(ntuple(k -> _tqleval(e.args[k], cols, i), length(e.args))...)
_tqleval(::TQLRowNum, cols, i) = i
_tqleval(::TQLAggr, cols, i) = throw(ArgumentError(
    "TaQL-lite: aggregate functions (g*) are only valid in groupby(...), not query(...)"))

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
_tqlrefs!(seen, e::TQLArith) = (_tqlrefs!(seen, e.lhs); _tqlrefs!(seen, e.rhs))
_tqlrefs!(seen, e::TQLNeg) = _tqlrefs!(seen, e.a)
_tqlrefs!(seen, e::TQLMatch) = _tqlrefs!(seen, e.lhs)
_tqlrefs!(seen, e::TQLFunc) = foreach(a -> _tqlrefs!(seen, a), e.args)
_tqlrefs!(seen, ::TQLRowNum) = nothing
_tqlrefs!(seen, e::TQLAggr) = e.arg === nothing ? nothing : _tqlrefs!(seen, e.arg)

# true if any TQLAggr node appears anywhere in the expression tree
_has_aggr(e::TQLAggr) = true
_has_aggr(e::TQLCol) = false
_has_aggr(e::TQLLit) = false
_has_aggr(::TQLRowNum) = false
_has_aggr(e::TQLCmp) = _has_aggr(e.lhs) || _has_aggr(e.rhs)
_has_aggr(e::TQLArith) = _has_aggr(e.lhs) || _has_aggr(e.rhs)
_has_aggr(e::TQLAnd) = _has_aggr(e.a) || _has_aggr(e.b)
_has_aggr(e::TQLOr) = _has_aggr(e.a) || _has_aggr(e.b)
_has_aggr(e::TQLNot) = _has_aggr(e.a)
_has_aggr(e::TQLNeg) = _has_aggr(e.a)
_has_aggr(e::TQLIn) = _has_aggr(e.lhs)
_has_aggr(e::TQLMatch) = _has_aggr(e.lhs)
_has_aggr(e::TQLFunc) = any(_has_aggr, e.args)

# ======================================================================
# tokenizer
# ======================================================================

struct TQLToken
    kind::Symbol     # :ident | :num | :str | :op | :arithop | :patlit |
                      # :lparen | :rparen | :lbracket | :rbracket | :comma | :eof
    text::String
    value::Any        # :num/:str -> the literal value; :patlit ->
                      # (; flavor::Symbol, pattern::String, icase::Bool); else nothing
end

# comparison/logical/match operator chars -- grouped into one token
# (`==`, `!=`, `<>`, `<=`, `>=`, `&&`, `||`, `~`, `!~`, ...).  `~` is
# here (not a bitwise op in this subset) so `!~` lexes as one token.
const _TQL_OPCHARS = "=!<>&|~"
# `~ <flavor><delim>pattern<delim>[i]` literal delimiters / flavors.
const _TQL_PAT_DELIMS = "/%@"
const _TQL_PAT_FLAVORS = Dict{Char,Symbol}('p' => :glob, 'm' => :partial, 'f' => :full)

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
        elseif c == '+' || c == '-' || c == '%' || c == '^'
            push!(toks, TQLToken(:arithop, string(c), nothing)); i += 1
        elseif c == '*'
            twochar = i < n && cs[i+1] == '*'
            push!(toks, TQLToken(:arithop, twochar ? "**" : "*", nothing))
            i += twochar ? 2 : 1
        elseif c == '/'
            twochar = i < n && cs[i+1] == '/'
            push!(toks, TQLToken(:arithop, twochar ? "//" : "/", nothing))
            i += twochar ? 2 : 1
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
            optext = join(cs[i:j-1])
            push!(toks, TQLToken(:op, optext, nothing))
            i = j
            if optext == "~" || optext == "!~"
                i = _read_patlit!(toks, cs, i, n, s)
            end
        else
            throw(ArgumentError("TaQL-lite: unexpected character '$c' in \"$s\""))
        end
    end
    push!(toks, TQLToken(:eof, "", nothing))
    return toks
end

_isdigit_at(cs, j, n) = j <= n && isdigit(cs[j])

# Consume a `~`/`!~` pattern literal: optional space, a flavor char
# (`p` glob / `m` partial regex / `f` full regex), a delimiter (`/ % @`),
# the pattern text up to the matching delimiter, an optional trailing
# `i` (case-insensitive). Pushes one :patlit token; returns the new
# cursor index.
function _read_patlit!(toks, cs, i, n, s)
    while i <= n && isspace(cs[i])
        i += 1
    end
    i <= n && haskey(_TQL_PAT_FLAVORS, cs[i]) || throw(ArgumentError(
        "TaQL-lite: expected a pattern literal (p/.../, m/.../, f/.../) after `~` in \"$s\""))
    flavor = _TQL_PAT_FLAVORS[cs[i]]
    i += 1
    (i <= n && cs[i] in _TQL_PAT_DELIMS) || throw(ArgumentError(
        "TaQL-lite: expected a pattern delimiter (one of / % @) in \"$s\""))
    delim = cs[i]
    i += 1
    j = i
    while j <= n && cs[j] != delim
        j += 1
    end
    j > n && throw(ArgumentError("TaQL-lite: unterminated pattern literal in \"$s\""))
    pat = join(cs[i:j-1])
    i = j + 1
    icase = i <= n && (cs[i] == 'i' || cs[i] == 'I')
    icase && (i += 1)
    push!(toks, TQLToken(:patlit, pat, (; flavor, pattern=pat, icase)))
    return i
end

# ======================================================================
# recursive-descent parser
# ======================================================================
#
# expr    := orExpr
# orExpr  := andExpr ( (OR|'||') andExpr )*
# andExpr := notExpr ( (AND|'&&') notExpr )*
# notExpr := (NOT|'!') notExpr | comparison
# comparison := addsub ( cmpop addsub
#                      | [NOT] IN '[' litval (',' litval)* ']'
#                      | [NOT] (LIKE|ILIKE) addsub
#                      | ('~'|'!~') patlit )?
# addsub  := muldiv ( ('+'|'-') muldiv )*
# muldiv  := unary ( ('*'|'/'|'%'|'//') unary )*
# unary   := ('-'|'+') unary | power
# power   := atom ( '**' unary )?          # right-assoc
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

# `/` is Julia's `/` (always Float); `%` -> `rem`; `//` -> `div`
# (truncating, matching TaQL DIVIDETRUNC); `**` -> `^`.
const _TQL_ARITHOPS = Dict{String,Function}(
    "+" => (+), "-" => (-), "*" => (*), "/" => (/), "%" => rem, "//" => div)

# operator tokens this subset deliberately rejects, with a clear message
const _TQL_REJECTED_OPS = Dict{String,String}(
    "~=" => "approximate equality (`~=`) is not supported",
    "!~=" => "approximate inequality (`!~=`) is not supported",
    "&" => "bitwise operators (`& | ^ ~`) are not supported",
    "|" => "bitwise operators (`& | ^ ~`) are not supported")

function _parse_comparison!(p::TQLParser)
    lhs = _parse_addsub!(p)
    t = _peek(p)
    if t.kind === :op && haskey(_TQL_CMPOPS, t.text)
        _advance!(p)
        return TQLCmp(_TQL_CMPOPS[t.text], lhs, _parse_addsub!(p))
    elseif t.kind === :op && haskey(_TQL_REJECTED_OPS, t.text)
        throw(ArgumentError("TaQL-lite: $(_TQL_REJECTED_OPS[t.text]) in \"$(p.src)\""))
    elseif _iskw(t, "IN")
        _advance!(p)
        return _parse_in_list!(p, lhs, false)
    elseif _iskw(t, "LIKE") || _iskw(t, "ILIKE")
        _advance!(p)
        return _parse_like!(p, lhs, _iskw(t, "ILIKE"), false)
    elseif _iskw(t, "NOT") && (_iskw(p.toks[p.pos+1], "IN") ||
                               _iskw(p.toks[p.pos+1], "LIKE") ||
                               _iskw(p.toks[p.pos+1], "ILIKE"))
        _advance!(p)
        kw = _advance!(p)
        return _iskw(kw, "IN") ? _parse_in_list!(p, lhs, true) :
               _parse_like!(p, lhs, _iskw(kw, "ILIKE"), true)
    elseif t.kind === :op && (t.text == "~" || t.text == "!~")
        _advance!(p)
        pl = _expect_kind!(p, :patlit, "a pattern literal")
        return TQLMatch(lhs, _patlit_regex(pl.value), t.text == "!~")
    else
        # No comparison/IN/LIKE/~ follows -- treat the bare expression
        # itself as the boolean result (e.g. `WHERE D` / `WHERE NOT D`
        # for a Bool column `D`, exactly as real TaQL allows). Not
        # statically checked: a bare non-Bool expression here surfaces
        # as an ordinary Julia `TypeError`/`MethodError` at
        # query-evaluation time, not a parse error.
        return lhs
    end
end

function _parse_in_list!(p::TQLParser, lhs::TQLExpr, negate::Bool)
    _expect_kind!(p, :lbracket, "'['")
    vals = Any[_parse_literal_value!(p)]
    while _peek(p).kind === :comma
        _advance!(p)
        push!(vals, _parse_literal_value!(p))
    end
    _expect_kind!(p, :rbracket, "']'")
    e = TQLIn(lhs, vals)
    return negate ? TQLNot(e) : e
end

function _parse_like!(p::TQLParser, lhs::TQLExpr, icase::Bool, negate::Bool)
    rhs = _parse_addsub!(p)
    rhs isa TQLLit && rhs.value isa AbstractString || throw(ArgumentError(
        "TaQL-lite: LIKE/ILIKE needs a string-literal pattern in \"$(p.src)\""))
    return TQLMatch(lhs, _sqlpattern_regex(rhs.value, icase), negate)
end

# ---- arithmetic precedence layers (addsub < muldiv < unary < power) ----

function _parse_addsub!(p::TQLParser)
    a = _parse_muldiv!(p)
    while (t = _peek(p); t.kind === :arithop && (t.text == "+" || t.text == "-"))
        _advance!(p)
        a = TQLArith(_TQL_ARITHOPS[t.text], a, _parse_muldiv!(p))
    end
    return a
end

function _parse_muldiv!(p::TQLParser)
    a = _parse_unary!(p)
    while (t = _peek(p); t.kind === :arithop && t.text in ("*", "/", "%", "//"))
        _advance!(p)
        a = TQLArith(_TQL_ARITHOPS[t.text], a, _parse_unary!(p))
    end
    return a
end

function _parse_unary!(p::TQLParser)
    t = _peek(p)
    if t.kind === :arithop && t.text == "-"
        _advance!(p)
        inner = _parse_unary!(p)
        # constant-fold `-<number literal>` so `A > -5` keeps a plain
        # `TQLLit(-5)` rhs (matches pre-Phase-24 AST shape, and lets a
        # negative literal appear anywhere an atom can).
        return inner isa TQLLit && inner.value isa Number ? TQLLit(-inner.value) : TQLNeg(inner)
    elseif t.kind === :arithop && t.text == "+"
        _advance!(p)
        return _parse_unary!(p)
    end
    return _parse_power!(p)
end

function _parse_power!(p::TQLParser)
    base = _parse_atom!(p)
    t = _peek(p)
    if t.kind === :arithop && t.text == "**"
        _advance!(p)
        return TQLArith(^, base, _parse_unary!(p))   # right-assoc
    elseif t.kind === :arithop && t.text == "^"
        throw(ArgumentError("TaQL-lite: `^` (bitwise xor) is not supported; " *
                            "use `**` for exponentiation in \"$(p.src)\""))
    end
    return base
end

# accepts an optional leading unary minus so `IN [-1, 2]` works
function _parse_literal_value!(p::TQLParser)
    neg = false
    if (t = _peek(p); t.kind === :arithop && t.text == "-")
        _advance!(p)
        neg = true
    end
    e = _parse_atom!(p)
    e isa TQLLit || throw(ArgumentError(
        "TaQL-lite: expected a literal value in an IN list in \"$(p.src)\""))
    return neg ? -e.value : e.value
end

function _parse_atom!(p::TQLParser)
    if _peek(p).kind === :lparen
        _advance!(p)
        e = _parse_or!(p)
        _expect_kind!(p, :rparen, "')'")
        return e
    end
    t = _advance!(p)
    if t.kind === :num
        return TQLLit(t.value)
    elseif t.kind === :str
        return TQLLit(t.value)
    elseif t.kind === :ident
        _peek(p).kind === :lparen && return _parse_funcall!(p, t.text)
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

function _parse_funcall!(p::TQLParser, name::AbstractString)
    _advance!(p)                                   # consume '('
    args = TQLExpr[]
    if _peek(p).kind !== :rparen
        push!(args, _parse_or!(p))
        while _peek(p).kind === :comma
            _advance!(p)
            push!(args, _parse_or!(p))
        end
    end
    _expect_kind!(p, :rparen, "')'")
    return _make_func(lowercase(name), args, p.src)
end

# ======================================================================
# pattern -> Regex  (mirrors casacore Regex::fromSQLPattern / fromPattern)
# ======================================================================

const _TQL_RE_SPECIAL = Set("^\$.|?*+()[]{}\\")

# SQL LIKE glob: `%` = any run, `_` = one char, no escape char (casacore
# `fromSQLPattern`). Anchored (full-string match).
function _sqlpattern_regex(pat::AbstractString, icase::Bool)
    io = IOBuffer()
    print(io, '^')
    for c in pat
        if c == '%'
            print(io, ".*")
        elseif c == '_'
            print(io, '.')
        else
            c in _TQL_RE_SPECIAL && print(io, '\\')
            print(io, c)
        end
    end
    print(io, '$')
    return Regex(String(take!(io)), icase ? "i" : "")
end

# shell glob (casacore `fromPattern`, subset -- no `{a,b}` alternation):
# `*` -> `.*`, `?` -> `.`, `[...]`/`[!...]` char class, `\x` literal.
# Anchored (full-string match).
function _glob_regex(pat::AbstractString, icase::Bool)
    io = IOBuffer()
    print(io, '^')
    cs = collect(pat)
    i = 1
    while i <= length(cs)
        c = cs[i]
        if c == '\\' && i < length(cs)
            nxt = cs[i+1]
            nxt in _TQL_RE_SPECIAL && print(io, '\\')
            print(io, nxt)
            i += 2
            continue
        elseif c == '*'
            print(io, ".*")
        elseif c == '?'
            print(io, '.')
        elseif c == '['
            print(io, '[')
            i += 1
            if i <= length(cs) && (cs[i] == '!' || cs[i] == '^')
                print(io, '^')
                i += 1
            end
            while i <= length(cs) && cs[i] != ']'
                print(io, cs[i])
                i += 1
            end
            print(io, ']')
        else
            c in _TQL_RE_SPECIAL && print(io, '\\')
            print(io, c)
        end
        i += 1
    end
    print(io, '$')
    return Regex(String(take!(io)), icase ? "i" : "")
end

# a `~ <flavor><delim>...<delim>[i]` :patlit token value -> Regex
function _patlit_regex(v)
    flags = v.icase ? "i" : ""
    v.flavor === :glob && return _glob_regex(v.pattern, v.icase)
    v.flavor === :partial && return Regex(v.pattern, flags)          # occursin anywhere
    return Regex("^(?:" * v.pattern * ")\$", flags)                  # :full -> anchored
end

# ======================================================================
# functions -- NAME(args...).  A curated "lite" subset of TaQL's library
# (scalar math, complex parts, array-cell reductions, string ops, a few
# specials).  Function names are case-insensitive; many have aliases,
# matching casacore's own `TableParseFunc::findFunc`.  Not supported:
# date/time, measures/cones, sliding-window (`running*`/`boxed*`) ops,
# `rand`, array reshaping, `rowid()`, `substr`, type conversions, UDFs.
# ======================================================================

# unary / binary elementwise (map over an array cell, apply directly to
# a scalar) -- share the `_bcast` helper used by the arithmetic evaluator
_ew(f) = x -> _bcast(f, x)
_ew2(f) = (x, y) -> _bcast(f, x, y)
# reduction: a scalar arg is wrapped in a 1-tuple so `f` still applies
_red(f) = x -> f(x isa AbstractArray ? x : (x,))

_tql_rms(x) = sqrt(_red(y -> sum(abs2, y) / length(y))(x))
_tql_nelem(x) = x isa AbstractArray ? length(x) : 1
_tql_ndim(x) = x isa AbstractArray ? ndims(x) : 0

# name => (callable-over-arg-values, allowed arg count).  `min`/`max` are
# arity-overloaded and handled in `_make_func`, not here.
const _TQL_FUNCS = Dict{String,Tuple{Base.Callable,UnitRange{Int}}}(
    # --- unary elementwise numeric ---
    "abs" => (_ew(abs), 1:1), "amplitude" => (_ew(abs), 1:1), "ampl" => (_ew(abs), 1:1),
    "sqrt" => (_ew(sqrt), 1:1), "square" => (_ew(abs2), 1:1), "sqr" => (_ew(abs2), 1:1),
    "cube" => (_ew(x -> x^3), 1:1),
    "exp" => (_ew(exp), 1:1), "log" => (_ew(log), 1:1), "ln" => (_ew(log), 1:1),
    "log10" => (_ew(log10), 1:1),
    "sin" => (_ew(sin), 1:1), "cos" => (_ew(cos), 1:1), "tan" => (_ew(tan), 1:1),
    "asin" => (_ew(asin), 1:1), "acos" => (_ew(acos), 1:1), "atan" => (_ew(atan), 1:1),
    "sinh" => (_ew(sinh), 1:1), "cosh" => (_ew(cosh), 1:1), "tanh" => (_ew(tanh), 1:1),
    "sign" => (_ew(sign), 1:1), "floor" => (_ew(floor), 1:1), "ceil" => (_ew(ceil), 1:1),
    "round" => (_ew(round), 1:1), "int" => (_ew(x -> trunc(Int, x)), 1:1),
    "integer" => (_ew(x -> trunc(Int, x)), 1:1),
    "real" => (_ew(real), 1:1), "imag" => (_ew(imag), 1:1),
    "arg" => (_ew(angle), 1:1), "phase" => (_ew(angle), 1:1),
    "conj" => (_ew(conj), 1:1), "norm" => (_ew(abs2), 1:1),
    "isnan" => (_ew(isnan), 1:1), "isinf" => (_ew(isinf), 1:1),
    "isfinite" => (_ew(isfinite), 1:1),
    # --- binary elementwise ---
    "pow" => (_ew2(^), 2:2), "atan2" => (_ew2((y, x) -> atan(y, x)), 2:2),
    "fmod" => (_ew2(rem), 2:2),
    # --- array-cell reductions ---
    "sum" => (_red(sum), 1:1), "product" => (_red(prod), 1:1),
    "mean" => (_red(Statistics.mean), 1:1), "avg" => (_red(Statistics.mean), 1:1),
    "median" => (_red(Statistics.median), 1:1),
    "variance" => (_red(x -> Statistics.var(x; corrected=false)), 1:1),
    "stddev" => (_red(x -> Statistics.std(x; corrected=false)), 1:1),
    "rms" => (_tql_rms, 1:1),
    "any" => (_red(any), 1:1), "all" => (_red(all), 1:1),
    "ntrue" => (_red(x -> count(identity, x)), 1:1),
    "nfalse" => (_red(x -> count(!, x)), 1:1),
    "nelements" => (_tql_nelem, 1:1), "count" => (_tql_nelem, 1:1),
    "ndim" => (_tql_ndim, 1:1),
    # --- string ---
    "strlength" => (length, 1:1), "len" => (length, 1:1),
    "upcase" => (uppercase, 1:1), "upper" => (uppercase, 1:1), "toupper" => (uppercase, 1:1),
    "downcase" => (lowercase, 1:1), "lower" => (lowercase, 1:1), "tolower" => (lowercase, 1:1),
    "trim" => (strip, 1:1), "ltrim" => (lstrip, 1:1), "rtrim" => (rstrip, 1:1),
    # --- misc ---
    "iif" => (ifelse, 3:3),
)

# g-prefixed aggregate functions -- each reduces a Vector of per-row
# values (collected over a group's rows) to a scalar.  Used only by
# `groupby` (via `_geval`); `_tqleval(::TQLAggr, ...)` errors.
# `gvariance`/`gstddev` are population (÷N); `gsample*` are ÷(N-1),
# matching casacore's own `gvariance0`/`gvariance1` split.
const _TQL_AGGRS = Dict{String,Base.Callable}(
    "gcount" => length,
    "gsum" => sum, "gproduct" => prod,
    "gmean" => Statistics.mean, "gavg" => Statistics.mean,
    "gmedian" => Statistics.median,
    "gmin" => minimum, "gmax" => maximum,
    "gvariance" => (v -> Statistics.var(v; corrected=false)),
    "gsamplevariance" => Statistics.var,
    "gstddev" => (v -> Statistics.std(v; corrected=false)),
    "gsamplestddev" => Statistics.std,
    "grms" => (v -> sqrt(sum(abs2, v) / length(v))),
    "gany" => any, "gall" => all,
    "gntrue" => (v -> count(identity, v)), "gnfalse" => (v -> count(!, v)),
    "gfirst" => first, "glast" => last,
)

function _make_func(name::String, args::Vector{TQLExpr}, src::AbstractString)
    n = length(args)
    if haskey(_TQL_AGGRS, name)
        if name == "gcount"
            n in 0:1 || throw(ArgumentError("TaQL-lite: gcount() takes 0 or 1 arguments in \"$src\""))
            return TQLAggr(length, n == 0 ? nothing : args[1])
        end
        n == 1 || throw(ArgumentError("TaQL-lite: $name() takes 1 argument, got $n, in \"$src\""))
        return TQLAggr(_TQL_AGGRS[name], args[1])
    end
    if name in ("rownumber", "rownr")
        n == 0 || throw(ArgumentError("TaQL-lite: $name() takes no arguments in \"$src\""))
        return TQLRowNum()
    elseif name == "pi" && n == 0
        return TQLLit(π)
    elseif name == "e" && n == 0
        return TQLLit(ℯ)
    elseif name == "min" || name == "max"
        n in 1:2 || throw(ArgumentError("TaQL-lite: $name() takes 1 or 2 arguments in \"$src\""))
        base = name == "min" ? min : max
        fn = n == 1 ? _red(x -> (name == "min" ? minimum : maximum)(x)) : _ew2(base)
        return TQLFunc(fn, args)
    end
    haskey(_TQL_FUNCS, name) || throw(ArgumentError(
        "TaQL-lite: unknown function \"$name\" in \"$src\""))
    fn, arity = _TQL_FUNCS[name]
    n in arity || throw(ArgumentError(
        "TaQL-lite: $name() takes $(arity == 1:1 ? "1 argument" :
         length(arity) == 1 ? "$(first(arity)) arguments" :
         "$(first(arity))–$(last(arity)) arguments"), got $n, in \"$src\""))
    return TQLFunc(fn, args)
end

# ======================================================================
# ORDER BY
# ======================================================================
#
# sortlist := sortexpr (',' sortexpr)*
# sortexpr := column ('ASC'|'DESC')?
#
# `ORDER BY` is lexed by real TaQL as a single two-word token; this
# package's tokenizer has no multi-word-token mechanism, so the two
# idents "ORDER"/"BY" are recognised as a literal sequence at the parser
# level instead.

struct TQLOrderKey
    name::String
    desc::Bool
end

_at_orderby(p::TQLParser) =
    _iskw(p.toks[p.pos], "ORDER") && p.pos < length(p.toks) &&
    _iskw(p.toks[p.pos+1], "BY")

# Parses an optional WHERE expression followed by an optional ORDER BY
# clause. `ast === nothing` means "no WHERE" (match every row) -- covers
# a bare `"ORDER BY ..."` string with no filter at all.
function _taqllite_parse_query(s::AbstractString, validnames::AbstractSet{String})
    p = TQLParser(_taqllite_tokenize(s), 1, validnames, String(s))
    ast = _at_orderby(p) ? nothing : _parse_or!(p)
    orderby = TQLOrderKey[]
    if _at_orderby(p)
        _advance!(p)
        _advance!(p)
        push!(orderby, _parse_orderkey!(p))
        while _peek(p).kind === :comma
            _advance!(p)
            push!(orderby, _parse_orderkey!(p))
        end
    end
    _peek(p).kind === :eof || throw(ArgumentError(
        "TaQL-lite: unexpected trailing input near \"$(_peek(p).text)\" in \"$s\""))
    return ast, orderby
end

function _parse_orderkey!(p::TQLParser)
    t = _expect_kind!(p, :ident, "a column name in ORDER BY")
    t.text in p.validnames || throw(ArgumentError(
        "TaQL-lite: unknown column \"$(t.text)\" in \"$(p.src)\""))
    nt = _peek(p)
    desc = if _iskw(nt, "DESC")
        _advance!(p)
        true
    elseif _iskw(nt, "ASC")
        _advance!(p)
        false
    else
        false
    end
    return TQLOrderKey(t.text, desc)
end

# Stable multi-key sort over matched row indices; ties on every key keep
# the original (pre-sort) row order (`alg=MergeSort` -- Julia's default
# algorithm choice is type/size-dependent and not guaranteed stable, and
# a stable tie-break is the intuitive, TaQL-consistent behaviour).
function _apply_orderby(matched::Vector{Int}, orderby::Vector{TQLOrderKey},
                        cols::AbstractDict)
    isempty(orderby) && return matched
    lt = function (i, j)
        for k in orderby
            vi, vj = cols[k.name][i], cols[k.name][j]
            vi == vj && continue
            return k.desc ? isless(vj, vi) : isless(vi, vj)
        end
        return false
    end
    return sort(matched; lt, alg=Base.Sort.MergeSort)
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

Row-filter `t` with a small TaQL-like WHERE expression:

* comparisons `==`/`=`, `!=`/`<>`, `<`, `<=`, `>`, `>=`;
* `AND`/`&&`, `OR`/`||`, `NOT`/`!`, parentheses;
* arithmetic `+ - * / % // **` and unary `-` on numeric operands
  (`A + 1 > B`, `ANTENNA1 % 4 == 0`, `2 ** N`) — Julia numeric
  semantics (`/` yields a float, `//` truncates, `%` is `rem`);
* `col IN [v1, v2, ...]` / `col NOT IN [...]`;
* `col LIKE 'pat'` / `ILIKE` (case-insensitive) / `NOT LIKE` — SQL glob
  (`%` = any run, `_` = one char); and TaQL's `col ~ p/glob/`,
  `~ m/regex/`, `~ f/regex/` (and `!~`), delimiters `/ % @`, optional
  trailing `i`;
* functions `NAME(args...)` (case-insensitive, TaQL's aliases) — scalar
  math (`abs`, `sqrt`, `exp`, `log`/`ln`, `log10`, trig, `floor`/`ceil`/
  `round`, `sign`, `int`, `pow`, `fmod`), complex parts (`real`, `imag`,
  `arg`/`phase`, `conj`, `norm`), array-cell reductions (`mean`/`avg`,
  `sum`, `product`, `median`, `variance`, `stddev`, `rms`, `min`/`max`,
  `any`, `all`, `ntrue`/`nfalse`, `nelements`/`count`, `ndim`), string
  ops (`strlength`/`len`, `upper`/`lower`, `trim`/`ltrim`/`rtrim`),
  `isnan`/`isinf`/`isfinite`, `iif(cond, a, b)`, `rownumber()` (1-based),
  `pi`, `e`;
* an optional trailing `ORDER BY col [ASC|DESC], ...` (bare columns).

Column names are case-sensitive and must name a column of `t`; keywords
and function names are case-insensitive. Only the columns actually
referenced (by the WHERE expression or an ORDER BY key) are read.
`select` projects/renames columns exactly like [`write_reftable`](@ref)'s
own `select=`. Returns a `RefTable` (no data copied); persist it with
`write_reftable(dst, result)`.

A bare `"ORDER BY ..."` (no WHERE) matches every row, sorted.

Deliberately a *subset* of real TaQL's grammar, not a look-alike: no
bitwise operators, `BETWEEN`, `~=` approximate equality, array indexing,
units, date/time or measures functions, `GROUP BY`, or joins.
"""
function query(t::AbstractTable, wherestr::AbstractString;
              select::AbstractVector{<:Pair}=[n => n for n in columnnames(t)])
    validnames = Set(columnnames(t))
    ast, orderby = _taqllite_parse_query(wherestr, validnames)
    needed = Set{String}()
    ast === nothing || _tqlrefs!(needed, ast)
    for k in orderby
        push!(needed, k.name)
    end
    cols = Dict(n => column(t, n) for n in needed)
    matched = ast === nothing ? collect(1:nrow(t)) :
              [i for i in 1:nrow(t) if _tqleval(ast, cols, i)]
    matched = _apply_orderby(matched, orderby, cols)
    namemap, order = _select_spec(t, select)
    parent, rows, namemap = _flatten_query_parent(t, matched, namemap)
    return RefTable("", parent, rows, namemap, order, parent.type, parent.subtype, parent.readme)
end

_normalize_orderkey(t::AbstractTable, s::Union{AbstractString,Symbol}) = begin
    n = String(s)
    n in columnnames(t) || throw(ArgumentError("orderby: no column \"$n\""))
    TQLOrderKey(n, false)
end
function _normalize_orderkey(t::AbstractTable, p::Pair)
    n = String(first(p))
    n in columnnames(t) || throw(ArgumentError("orderby: no column \"$n\""))
    d = last(p)
    d isa Symbol && d in (:asc, :desc) || throw(ArgumentError(
        "orderby: direction must be :asc or :desc, got $(repr(d))"))
    return TQLOrderKey(n, d === :desc)
end

"""
    query(f::Function, t::AbstractTable; cols=nothing, orderby=nothing,
         select=[n=>n for n in columnnames(t)]) -> RefTable

Row-filter `t` with a Julia predicate `f(row) -> Bool` (do-block
friendly: `query(t; cols=[...]) do row ... end`). `row` is a
`Tables.AbstractRow` supporting `row.COLNAME` property access. `cols`
restricts which columns are actually read (default: every column — `f`
is an opaque closure, so unlike the string-based `query` its column use
can't be inferred; pass `cols` explicitly on a wide table to avoid
materialising columns `f` never touches). `orderby` sorts the matched
rows by one or more columns: each entry is a bare column name/`Symbol`
(ascending) or a `name => :asc`/`name => :desc` pair. `select` — see the
string-based `query` above.
"""
function query(f::Function, t::AbstractTable;
              cols::Union{Nothing,AbstractVector}=nothing,
              orderby::Union{Nothing,AbstractVector}=nothing,
              select::AbstractVector{<:Pair}=[n => n for n in columnnames(t)])
    names = cols === nothing ? columnnames(t) : String.(cols)
    orderkeys = orderby === nothing ? TQLOrderKey[] : [_normalize_orderkey(t, o) for o in orderby]
    extra = [k.name for k in orderkeys if !(k.name in names)]
    allnames = vcat(collect(names), extra)
    allcols = AbstractVector[column(t, n) for n in allnames]
    rows = CTDSRows(allcols, Symbol.(allnames), nrow(t))
    matched = [i for (i, row) in enumerate(rows) if f(row)]
    cols_by_name = Dict(n => c for (n, c) in zip(allnames, allcols))
    matched = _apply_orderby(matched, orderkeys, cols_by_name)
    namemap, order = _select_spec(t, select)
    parent, rows2, namemap = _flatten_query_parent(t, matched, namemap)
    return RefTable("", parent, rows2, namemap, order, parent.type, parent.subtype, parent.readme)
end

# ======================================================================
# GROUP BY + aggregation  (Phase 26)
# ======================================================================
#
# `_geval(e, cols, g)` evaluates an expression for one group: `g` is the
# group's `Vector{Int}` of (filtered) row indices.  A `TQLAggr` reduces
# over the whole group; every other node evaluates on the group's FIRST
# row (a non-aggregate select expr is assumed constant across the group
# because you grouped by it -- SQL-lenient, not strictly verified).

_geval(e::TQLAggr, cols, g) =
    e.fn(e.arg === nothing ? g : [_tqleval(e.arg, cols, i) for i in g])
_geval(e::TQLCol, cols, g) = cols[e.name][g[1]]
_geval(e::TQLLit, cols, g) = e.value
_geval(e::TQLCmp, cols, g) = _bcast(e.op, _geval(e.lhs, cols, g), _geval(e.rhs, cols, g))
_geval(e::TQLArith, cols, g) = _bcast(e.op, _geval(e.lhs, cols, g), _geval(e.rhs, cols, g))
_geval(e::TQLNeg, cols, g) = _bcast(-, _geval(e.a, cols, g))
_geval(e::TQLAnd, cols, g) = _geval(e.a, cols, g) && _geval(e.b, cols, g)
_geval(e::TQLOr, cols, g) = _geval(e.a, cols, g) || _geval(e.b, cols, g)
_geval(e::TQLNot, cols, g) = !_geval(e.a, cols, g)
_geval(e::TQLIn, cols, g) = _geval(e.lhs, cols, g) in e.vals
_geval(e::TQLMatch, cols, g) =
    xor(occursin(e.regex, _geval(e.lhs, cols, g)::AbstractString), e.negate)
_geval(e::TQLFunc, cols, g) =
    e.fn(ntuple(k -> _geval(e.args[k], cols, g), length(e.args))...)
_geval(::TQLRowNum, cols, g) =
    throw(ArgumentError("TaQL-lite: rownumber() is not valid in groupby(...)"))

"""
    GroupSlice

The per-group value passed to a closure-form [`groupby`](@ref) (the
do-block argument, and the argument of a `select` / `where` / `having`
closure). `g.COLNAME` is a materialised `Vector` of that column's values
for the group's rows; `length(g)` is the group size; `propertynames(g)`
lists the loaded columns.

Only the columns named in `cols=` (or every column, when `cols` is
omitted) are available — a closure's column use cannot be inferred. The
names `cols` and `rows` are struct fields, so a column with either name
is unreachable as `g.cols` / `g.rows` (a non-issue for MS column names).
"""
struct GroupSlice
    cols::Dict{String,AbstractVector}
    rows::Vector{Int}
end
Base.length(g::GroupSlice) = length(getfield(g, :rows))
Base.propertynames(g::GroupSlice) = Tuple(Symbol.(keys(getfield(g, :cols))))
function Base.getproperty(g::GroupSlice, s::Symbol)
    (s === :cols || s === :rows) && return getfield(g, s)
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
function column(gt::GroupedTable, name::AbstractString)
    j = findfirst(==(Symbol(name)), getfield(gt, :names))
    j === nothing && throw(KeyError(name))
    return getfield(gt, :cols)[j]
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
# (the generic `::AbstractTable` methods in tables_interface.jl cover
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
    namemap, order = _select_spec(gt, select)
    return GroupedTable(Symbol.(order),
        AbstractVector[cd[namemap[o]][keep] for o in order])
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
    fullcd = Dict{String,AbstractVector}(n => column(gt, n) for n in columnnames(gt))
    namemap, order = _select_spec(gt, select)
    return GroupedTable(Symbol.(order),
        AbstractVector[fullcd[namemap[o]][keep] for o in order])
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
    loaded = Dict{String,AbstractVector}(n => column(t, n) for n in needed)

    rows =
        wherearg === nothing ? collect(1:nrow(t)) :
        wherearg isa Function ? begin
            nms = collect(Base.keys(loaded))
            rws = CTDSRows(AbstractVector[loaded[n] for n in nms], Symbol.(nms), nrow(t))
            [i for (i, r) in enumerate(rws) if wherearg(r)]
        end :
        [i for i in 1:nrow(t) if _tqleval(whereast, loaded, i)]

    groups, seen = _group_rows(keys, loaded, rows)
    havingfn =
        havingarg === nothing ? (g -> true) :
        havingarg isa Function ? (g -> havingarg(GroupSlice(loaded, g))) :
        (g -> _geval(havingast, loaded, g))
    return loaded, groups, seen, havingfn
end

"""
    groupby(t, groupcols; select, cols=nothing, where=nothing, having=nothing, orderby=nothing) -> GroupedTable

Group the rows of `t` by `groupcols` (a column name / `Symbol`, or a
vector of them; an empty vector = one group over the whole table) and
compute one result row per group.

`select` is `outname => rhs` pairs, where `rhs` is one of:

* a **string** — a TaQL-lite expression that may use `g`-prefixed
  aggregate functions over the group: `gcount()` / `gcount(x)` (row
  count), `gsum(x)`, `gproduct(x)`, `gmean(x)` / `gavg(x)`,
  `gmedian(x)`, `gmin(x)`, `gmax(x)`, `gvariance(x)` /
  `gsamplevariance(x)`, `gstddev(x)` / `gsamplestddev(x)`, `grms(x)`,
  `gany(x)`, `gall(x)`, `gntrue(x)`, `gnfalse(x)`, `gfirst(x)`,
  `glast(x)` — plus the group-key columns and scalar expressions of
  them. An aggregate's argument must reduce to a scalar per row (wrap
  an array cell in `mean(...)` / `sum(...)`).
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

Returns a [`GroupedTable`](@ref).
"""
function groupby(t::AbstractTable, groupcols;
                 select::AbstractVector{<:Pair}, cols=nothing,
                 where=nothing, having=nothing,
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

    loaded, groups, seen, havingfn =
        _gb_prepare(t, groupcols, where, having, strasts, cols, anyclosure)

    acc = [Any[] for _ in outnames]
    for key in seen
        g = groups[key]
        havingfn(g) || continue
        for (j, (k, v)) in enumerate(kinds)
            push!(acc[j], k === :fn ? v(GroupSlice(loaded, g)) : _geval(v, loaded, g))
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
string form.
"""
function groupby(f::Function, t::AbstractTable, groupcols; cols=nothing,
                 where=nothing, having=nothing,
                 orderby::Union{Nothing,AbstractVector}=nothing)
    loaded, groups, seen, havingfn =
        _gb_prepare(t, groupcols, where, having, TQLExpr[], cols, true)

    nts = NamedTuple[]
    for key in seen
        g = groups[key]
        havingfn(g) || continue
        nt = f(GroupSlice(loaded, g))
        nt isa NamedTuple ||
            throw(ArgumentError("groupby(f, ...): the closure must return a NamedTuple"))
        isempty(nts) || Base.keys(nt) == Base.keys(nts[1]) ||
            throw(ArgumentError(
                "groupby(f, ...): every group must return the same NamedTuple field names"))
        push!(nts, nt)
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

# ======================================================================
# join -- an N:1 lookup join  (Phase 28)
# ======================================================================
#
# Not a general SQL cross-product: each `left` row maps to at most one
# `right` row (via a key), and selected `right` columns are pulled in
# per left row -- exactly what TaQL's own `JOIN ... ON` does.  The result
# is a `GroupedTable` whose columns are lazy `MappedColumn` views
# (zero-copy even joining onto a large left table); `unmatched=:missing`
# forces the affected right columns to materialise.

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
         unmatched=:error, orderby=nothing) -> GroupedTable

N:1 lookup join (extends `Base.join`). Each `left` row is matched to at
most one `right` row and the selected `right` columns are pulled in per
left row — TaQL's `JOIN … ON` semantics, not a general cross product.

`on` is either

* a **column name** (`String` / `Symbol`) — that `left` column holds a
  **0-based row index** into `right` (the MS subtable convention:
  `ANTENNA1` → the `ANTENNA` subtable row);
* a **`Pair`** `"LKEY" => "RKEY"` — equi-join, matching `left.LKEY`
  against `right.RKEY` (which must be unique);
* a **vector of pairs** — a composite key (all must match).

`rightcols` lists the `right` columns to attach — `"NAME"` or
`"NAME" => "ANT_NAME"` to rename. `leftcols` (default: every `left`
column) likewise selects/renames left columns. Output names must be
unique across both. `where` filters the assembled result (a string over
the *output* column names, or a `row -> Bool` closure). `unmatched`:
`:error` (default — throw on a dangling key), `:drop` (exclude that
left row), or `:missing` (keep it; right columns get `missing`).
`orderby` sorts the result by output column name (`"N"` / `"N" => :desc`).

Returns a [`GroupedTable`](@ref) whose columns are lazy views unless
`:missing` forces materialisation.
"""
function Base.join(left::AbstractTable, right::AbstractTable; on,
                   rightcols::AbstractVector, leftcols=nothing,
                   where=nothing, unmatched::Symbol=:error,
                   orderby::Union{Nothing,AbstractVector}=nothing)
    matchrow = _join_matchrow(left, right, on)

    lrows =
        unmatched === :error ? begin
            b = findfirst(iszero, matchrow)
            b === nothing ? collect(1:nrow(left)) :
                throw(ArgumentError("join: left row $b has no match on the right " *
                                    "(pass unmatched=:drop or :missing to allow it)"))
        end :
        unmatched === :drop ? [i for i in eachindex(matchrow) if matchrow[i] != 0] :
        unmatched === :missing ? collect(1:nrow(left)) :
        throw(ArgumentError("join: `unmatched` must be :error, :drop, or :missing"))
    rrows = matchrow[lrows]

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

    cols = AbstractVector[]
    for (_, s) in lpairs
        push!(cols, _mapcol(column(left, s), lrows))
    end
    anymiss = unmatched === :missing && any(iszero, rrows)
    for (_, s) in rpairs
        rc = column(right, s)
        push!(cols, anymiss ? [r == 0 ? missing : rc[r] for r in rrows] : _mapcol(rc, rrows))
    end

    gt = GroupedTable(Symbol.(outnames), cols)
    where === nothing || (gt = _result_filter(gt, where))
    orderby === nothing ? gt : _gt_sort(gt, orderby)
end
