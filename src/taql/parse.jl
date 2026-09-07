# ======================================================================
# tokenizer
# ======================================================================

struct TQLToken
    kind::Symbol     # :ident | :num | :qty | :str | :op | :arithop | :patlit |
                      # :lparen | :rparen | :lbracket | :rbracket | :comma | :colon | :eof
    text::String
    value::Any        # :num/:str -> the literal value; :qty -> (num, unit::String);
                      # :patlit -> (; flavor::Symbol, pattern::String, icase::Bool); else nothing
end

# comparison / logical / match / bitwise operator chars -- grouped into
# one token (`==`, `!=`, `<>`, `<=`, `>=`, `&&`, `||`, `&`, `|`, `~`,
# `!~`, ...). Bare `&`/`|` are bitwise; `~` is bitwise-not or (before a
# `p/m/f` pattern literal) the glob/regex match operator.
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
        elseif c == ':'
            push!(toks, TQLToken(:colon, ":", nothing)); i += 1
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
            # scientific notation: `1.4e9`, `1e-9`, `2E+3`
            isexp = false
            if j + 1 <= n && (cs[j] == 'e' || cs[j] == 'E') &&
               (isdigit(cs[j+1]) || ((cs[j+1] == '+' || cs[j+1] == '-') &&
                                     j + 2 <= n && isdigit(cs[j+2])))
                isexp = true
                j += (cs[j+1] == '+' || cs[j+1] == '-') ? 2 : 1
                while j <= n && isdigit(cs[j])
                    j += 1
                end
            end
            text = join(cs[i:j-1])
            val = (sawdot || isexp) ? parse(Float64, text) : parse(Int64, text)
            # a unit run immediately adjacent (no space) -> a quantity
            # literal (`1.4GHz`, `10arcsec`, `30deg`); casacore's
            # FLINTUNIT. First char must be a letter or `°`; the run is
            # letters / digits / `°` / `µ` (a single unit token -- a
            # compound like `km/s` is not a literal, compare a column).
            if j <= n && (isletter(cs[j]) || cs[j] == '°')
                u0 = j
                while j <= n && (isletter(cs[j]) || isdigit(cs[j]) || cs[j] == '°' || cs[j] == 'µ')
                    j += 1
                end
                unit = join(cs[u0:j-1])
                sx = _sexagesimal_unit(unit)          # :ra | :dec | nothing
                if sx !== nothing                     # `10h30m`, `45d51m16s`, `12h`, `45d`
                    full = string(text, unit)
                    push!(toks, TQLToken(:num, full, _parse_sexagesimal(full, sx)))
                else
                    push!(toks, TQLToken(:qty, string(text, unit), (val, unit)))
                end
            else
                push!(toks, TQLToken(:num, text, val))
            end
            i = j
        elseif isletter(c) || c == '_'
            j = i
            while j <= n && (isletter(cs[j]) || isdigit(cs[j]) || cs[j] == '_')
                j += 1
            end
            # one optional `.suffix` -> a table-qualified column (`L.TIME`),
            # only when a letter/`_` immediately follows the dot
            if j < n && cs[j] == '.' && (isletter(cs[j+1]) || cs[j+1] == '_')
                j += 1
                while j <= n && (isletter(cs[j]) || isdigit(cs[j]) || cs[j] == '_')
                    j += 1
                end
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
            # `!~` is always a pattern match. Bare `~` is a pattern match
            # only when a `p/…/` `m/…/` `f/…/` literal follows; otherwise it
            # stays a bare `:op` token (unary bitwise NOT, or -- infix with
            # no pattern -- a parse error).
            if optext == "!~" || (optext == "~" && _patlit_ahead(cs, i, n))
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

# does a `p/…/` `m/…/` `f/…/` pattern literal start at `cs[i]` (after
# optional whitespace)? -- distinguishes `A ~ p/x/` from unary `~A`.
function _patlit_ahead(cs, i, n)
    while i <= n && isspace(cs[i]); i += 1; end
    i + 1 <= n && haskey(_TQL_PAT_FLAVORS, cs[i]) && cs[i+1] in _TQL_PAT_DELIMS
end

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

# casacore `near(a, b, tol)` (casa/BasicMath/Math.cc, casa/BasicSL/
# Complex.cc) -- TaQL's `~=` / `!~=` desugar to `NEAR(lhs, rhs, 1e-5)`
# and `NOT NEAR(...)`. Relative tolerance, with the same zero / opposite-
# sign special cases casacore uses.
const _TQL_NEAR_TOL = 1.0e-5

# NB: integer operands use this same relative-tolerance form -- casacore's
# own `near(Int,Int)` compares `|a|-|b|` (not `|a-b|`), which makes e.g.
# `3 ~= 4` true; TaQL-lite deliberately does not reproduce that.
function _tql_near(a::Real, b::Real, tol::Real = _TQL_NEAR_TOL)
    tol <= 0 && return a == b
    a == b && return true
    a == 0 && return abs(b) <= (1 + tol) * floatmin(Float64)
    b == 0 && return abs(a) <= (1 + tol) * floatmin(Float64)
    (a > 0) != (b > 0) && return false
    return abs(a - b) <= tol * max(abs(a), abs(b))
end
function _tql_near(a::Complex, b::Complex, tol::Real = _TQL_NEAR_TOL)
    tol <= 0 && return a == b
    a == b && return true
    (_tql_near(real(a), real(b), tol) && _tql_near(imag(a), imag(b), tol)) && return true
    aa, ab = abs(a), abs(b)
    aa == 0 && return ab <= (1 + tol) * floatmin(Float64)
    ab == 0 && return aa <= (1 + tol) * floatmin(Float64)
    return abs(a - b) <= tol * max(aa, ab)
end
_tql_near(a::Complex, b::Real, tol::Real = _TQL_NEAR_TOL) = _tql_near(a, complex(b), tol)
_tql_near(a::Real, b::Complex, tol::Real = _TQL_NEAR_TOL) = _tql_near(complex(a), b, tol)
_tql_nnear(a, b, tol::Real = _TQL_NEAR_TOL) = !_tql_near(a, b, tol)

const _TQL_CMPOPS = Dict{String,Function}(
    "==" => (==), "=" => (==), "!=" => (!=), "<>" => (!=),
    "<" => (<), "<=" => (<=), ">" => (>), ">=" => (>=),
    "~=" => _tql_near, "!~=" => _tql_nnear)

# `/` is Julia's `/` (always Float); `%` -> `rem`; `//` -> `div`
# (truncating, matching TaQL DIVIDETRUNC); `**` -> `^`.
const _TQL_ARITHOPS = Dict{String,Function}(
    "+" => (+), "-" => (-), "*" => (*), "/" => (/), "%" => rem, "//" => div)

# operator tokens this subset deliberately rejects, with a clear message
const _TQL_REJECTED_OPS = Dict{String,String}()

function _parse_comparison!(p::TQLParser)
    lhs = _parse_bitor!(p)
    t = _peek(p)
    if t.kind === :op && haskey(_TQL_CMPOPS, t.text)
        _advance!(p)
        return TQLCmp(_TQL_CMPOPS[t.text], lhs, _parse_bitor!(p))
    elseif t.kind === :op && haskey(_TQL_REJECTED_OPS, t.text)
        throw(ArgumentError("TaQL-lite: $(_TQL_REJECTED_OPS[t.text]) in \"$(p.src)\""))
    elseif _iskw(t, "IN")
        _advance!(p)
        return _parse_in_list!(p, lhs, false)
    elseif _iskw(t, "BETWEEN")
        _advance!(p)
        return _parse_between!(p, lhs, false)
    elseif _iskw(t, "LIKE") || _iskw(t, "ILIKE")
        _advance!(p)
        return _parse_like!(p, lhs, _iskw(t, "ILIKE"), false)
    elseif _iskw(t, "NOT") && (_iskw(p.toks[p.pos+1], "IN") ||
                               _iskw(p.toks[p.pos+1], "BETWEEN") ||
                               _iskw(p.toks[p.pos+1], "LIKE") ||
                               _iskw(p.toks[p.pos+1], "ILIKE"))
        _advance!(p)
        kw = _advance!(p)
        return _iskw(kw, "IN") ? _parse_in_list!(p, lhs, true) :
               _iskw(kw, "BETWEEN") ? _parse_between!(p, lhs, true) :
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

# `lhs BETWEEN lo AND hi` -- the `AND` here is BETWEEN syntax, consumed
# before control returns to `_parse_and!`. `lo`/`hi` are arithexpr-level
# (casacore `arithexpr BETWEEN arithexpr AND arithexpr`).
function _parse_between!(p::TQLParser, lhs::TQLExpr, negate::Bool)
    lo = _parse_bitor!(p)
    _iskw(_peek(p), "AND") || throw(ArgumentError(
        "TaQL-lite: expected `AND` after `BETWEEN <lo>` in \"$(p.src)\""))
    _advance!(p)
    hi = _parse_bitor!(p)
    return TQLBetween(lhs, lo, hi, negate)
end

function _parse_like!(p::TQLParser, lhs::TQLExpr, icase::Bool, negate::Bool)
    rhs = _parse_bitor!(p)
    rhs isa TQLLit && rhs.value isa AbstractString || throw(ArgumentError(
        "TaQL-lite: LIKE/ILIKE needs a string-literal pattern in \"$(p.src)\""))
    return TQLMatch(lhs, _sqlpattern_regex(rhs.value, icase), negate)
end

# ---- "arithexpr" precedence layers, low to high (casacore order):
#      bitor < bitxor < bitand < addsub < muldiv < unary < power.
#      `_parse_bitor!` is the arithexpr entry point (comparisons, BETWEEN,
#      LIKE, IN, array subscripts all bottom out here).

function _parse_bitor!(p::TQLParser)
    a = _parse_bitxor!(p)
    while (t = _peek(p); t.kind === :op && t.text == "|")   # not "||"
        _advance!(p)
        a = TQLArith((|), a, _parse_bitxor!(p))
    end
    return a
end

function _parse_bitxor!(p::TQLParser)
    a = _parse_bitand!(p)
    while (t = _peek(p); t.kind === :arithop && t.text == "^")
        _advance!(p)
        a = TQLArith(xor, a, _parse_bitand!(p))
    end
    return a
end

function _parse_bitand!(p::TQLParser)
    a = _parse_addsub!(p)
    while (t = _peek(p); t.kind === :op && t.text == "&")   # not "&&"
        _advance!(p)
        a = TQLArith((&), a, _parse_addsub!(p))
    end
    return a
end

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
    elseif t.kind === :op && t.text == "~"          # unary bitwise NOT
        _advance!(p)
        return TQLBitNot(_parse_unary!(p))
    end
    return _parse_power!(p)
end

function _parse_power!(p::TQLParser)
    base = _parse_atom!(p)
    t = _peek(p)
    if t.kind === :arithop && t.text == "**"
        _advance!(p)
        return TQLArith(^, base, _parse_unary!(p))   # right-assoc
    end
    return base                                       # `^` handled at _parse_bitxor!
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

# atom, then any postfix `[...]` array subscripts (`a[1]`, `a[1,2]`,
# `a[1:4,1]`, chained `a[1][2]`).  Indexing binds tighter than
# arithmetic, matching casacore's `inxexpr LBRACKET subscripts RBRACKET`.
function _parse_atom!(p::TQLParser)
    e = _parse_atom_base!(p)
    while _peek(p).kind === :lbracket
        e = _parse_index!(p, e)
    end
    return e
end

function _parse_index!(p::TQLParser, base::TQLExpr)
    _advance!(p)                                   # consume '['
    _peek(p).kind === :rbracket && throw(ArgumentError(
        "TaQL-lite: empty `[]` subscript in \"$(p.src)\""))
    axes = Any[_parse_axis!(p)]
    while _peek(p).kind === :comma
        _advance!(p)
        push!(axes, _peek(p).kind === :rbracket ?
              (; lo=nothing, hi=nothing, step=nothing) : _parse_axis!(p))
    end
    _expect_kind!(p, :rbracket, "']'")
    return TQLIndex(base, axes)
end

# one axis subscript: a bare axis (full), a scalar index, or a
# `lo:hi:step` range with every part optional (casacore start:end:step).
function _parse_axis!(p::TQLParser)
    t = _peek(p)
    (t.kind === :comma || t.kind === :rbracket) &&
        return (; lo=nothing, hi=nothing, step=nothing)
    # full expression so a single subscript can be a boolean mask
    # (`V[V > 5]`, `FLAG[chan]`); range bounds stay arithmetic
    lo = t.kind === :colon ? nothing : _parse_or!(p)
    _peek(p).kind === :colon || return lo                     # scalar index / mask
    _advance!(p)                                              # first ':'
    hi = _peek(p).kind in (:colon, :comma, :rbracket) ? nothing : _parse_bitor!(p)
    step = nothing
    if _peek(p).kind === :colon
        _advance!(p)
        step = _peek(p).kind in (:comma, :rbracket) ? nothing : _parse_bitor!(p)
    end
    return (; lo, hi, step)
end

function _parse_atom_base!(p::TQLParser)
    if _peek(p).kind === :lparen
        _advance!(p)
        e = _parse_or!(p)
        _expect_kind!(p, :rparen, "')'")
        return e
    end
    if _peek(p).kind === :lbracket           # array literal [a, b, ...]
        _advance!(p)
        elems = TQLExpr[]
        if _peek(p).kind !== :rbracket
            push!(elems, _parse_or!(p))
            while _peek(p).kind === :comma
                _advance!(p)
                push!(elems, _parse_or!(p))
            end
        end
        _expect_kind!(p, :rbracket, "']'")
        return TQLArrayLit(elems)
    end
    t = _advance!(p)
    if t.kind === :num
        return TQLLit(t.value)
    elseif t.kind === :qty
        return TQLQuantityLit(_tql_quantity(t.value[1], t.value[2]))
    elseif t.kind === :str
        return TQLLit(t.value)
    elseif t.kind === :ident
        _peek(p).kind === :lparen && return _parse_funcall!(p, t.text)
        up = uppercase(t.text)
        up == "TRUE" && return TQLLit(true)
        up == "FALSE" && return TQLLit(false)
        # `end` -- only meaningful inside an array subscript; it errors at
        # evaluation if used anywhere else.
        up == "END" && !(t.text in p.validnames) && return TQLEnd()
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

