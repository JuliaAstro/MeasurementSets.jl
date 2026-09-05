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

function _make_func(name::String, args::Vector{TQLExpr}, src::AbstractString)
    n = length(args)
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
