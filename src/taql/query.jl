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

# `select` ("output_name => parent_name" pairs, in output order) ->
# `(namemap, order)` for building a RefTable -- shared by
# `write_reftable` (tables/table.jl) and the all-projection `query` path.
function _select_spec(parent::AbstractTable, select::AbstractVector{<:Pair})
    order = String[String(first(p)) for p in select]
    allunique(order) || throw(ArgumentError("duplicate output column name"))
    namemap = Dict{String,String}(String(first(p)) => String(last(p)) for p in select)
    pcols = Set(columnnames(parent))
    for s in values(namemap)
        s in pcols || throw(ArgumentError("parent has no column \"$s\""))
    end
    return namemap, order
end

# Load the columns a TaQL-lite expression references. When any parsed AST
# holds a quantity literal (`1.4GHz`), attach each unit-bearing column's
# `QuantumUnits` (via the Unitful ext) so the comparison goes through
# Unitful -- a bare-number column vs a unit literal then raises a
# DimensionError (casacore's "units do not conform"). `asts` entries may
# be `nothing`, a `TQLExpr`, or an iterable of those.
function _tql_cols(t::AbstractTable, names, asts...)
    need = any(asts) do a
        a === nothing ? false :
        a isa TQLExpr ? _has_qty(a) :
        any(x -> x !== nothing && _has_qty(x), a)
    end
    plain, mscal = _mscal_split(names)
    plain, stokes = _stokes_split(plain)
    plain, mssel = _mssel_split(plain)
    d = Dict{String,AbstractVector}(
        n => (c = _load_col(column(t, n)); need ? _tql_unit_attach(c, columnunit(t, n)) : c)
        for n in plain)
    isempty(mscal) || merge!(d, _mscal_columns(t, mscal))
    isempty(stokes) || merge!(d, _stokes_setups(t, stokes))
    isempty(mssel) || merge!(d, _mssel_columns(t, mssel))
    return d
end

# classify `select` pairs against `validnames` into 3-tuples:
# `(outname, :proj, srcname)`, `(outname, :expr, TQLExpr)`, or
# `(valname, :mpair, (maskname, TQLExpr))` -- the last emits TWO output
# columns (data + mask) from a masked-array expression (TaQL's
# `expr AS (v, m)`). A `Symbol` LHS or a `(v, m)` tuple/`"(v, m)"` LHS
# selects the kind; a `String` RHS naming a column is a projection,
# any other `String` a computed expression (aggregates rejected).
function _select_classify(select::AbstractVector{<:Pair}, validnames)
    out = Tuple{String,Symbol,Any}[]
    names = String[]
    for p in select
        lk, rhs = first(p), last(p)
        pn = lk isa Tuple ?
            (length(lk) == 2 ? (String(lk[1]), String(lk[2])) :
             throw(ArgumentError("select: a (val, mask) target takes exactly two names"))) :
            (lk isa AbstractString ? _pair_split_names(lk) : nothing)
        if pn !== nothing
            ast = _taqllite_parse(String(rhs), validnames)
            _has_aggr(ast) && throw(ArgumentError(
                "select: aggregate functions need `groupby`, not `query` (\"$(rhs)\")"))
            push!(out, (pn[1], :mpair, (pn[2], ast)))
            append!(names, pn)
            continue
        end
        nm = String(lk)
        push!(names, nm)
        if rhs isa Symbol || String(rhs) in validnames
            s = String(rhs)
            s in validnames || throw(ArgumentError("select: no column \"$s\""))
            push!(out, (nm, :proj, s))
        else
            ast = _taqllite_parse(String(rhs), validnames)
            if ast isa TQLCol
                push!(out, (nm, :proj, ast.name))
            else
                _has_aggr(ast) && throw(ArgumentError(
                    "select: aggregate functions need `groupby`, not `query` (\"$(rhs)\")"))
                push!(out, (nm, :expr, ast))
            end
        end
    end
    allunique(names) || throw(ArgumentError("duplicate output column name"))
    return out
end

# "(a, b)" -> ("a", "b"); a bare name or any other string -> nothing
function _pair_split_names(s::AbstractString)
    t = strip(s)
    (startswith(t, "(") && endswith(t, ")")) || return nothing
    p = split(chop(t; head=1, tail=1), ',')
    length(p) == 2 || return nothing
    return (String(strip(p[1])), String(strip(p[2])))
end

_select_all_proj(cls) = all(c -> c[2] === :proj, cls)

# materialise the `select` output -> `Symbol => column` pairs in output
# order (a `:mpair` entry contributes two). `src` is the source table;
# `rows` are the surviving 1-based indices (ORDER BY-sorted). A computed
# column whose values come out as a `Unitful.Quantity` (a quantity
# literal was used) is stripped to a plain number -- dimensionless only.
function _select_materialize(cls, src::AbstractTable, rows::Vector{Int})
    exprasts = TQLExpr[]
    refs = Set{String}()
    for (_, kind, v) in cls
        if kind === :expr
            _tqlrefs!(refs, v); push!(exprasts, v)
        elseif kind === :mpair
            _tqlrefs!(refs, v[2]); push!(exprasts, v[2])
        end
    end
    cd = _tql_cols(src, refs, exprasts)
    _strip(x) = _tql_result_strip(_unwrap_marray(x))
    out = Pair{Symbol,AbstractVector}[]
    for (nm, kind, v) in cls
        if kind === :proj
            push!(out, Symbol(nm) => _mapcol(column(src, v), rows))
        elseif kind === :expr
            push!(out, Symbol(nm) => identity.(Any[_strip(_tqleval(v, cd, i)) for i in rows]))
        else                                       # :mpair -> data + mask
            vals = Any[_tqleval(v[2], cd, i) for i in rows]
            push!(out, Symbol(nm) => identity.(Any[_strip(x) for x in vals]))
            push!(out, Symbol(v[1]) => identity.(Any[
                x isa TQLMArray ? x.mask : _bcast(!isfinite, _unwrap_marray(x)) for x in vals]))
        end
    end
    return out
end

# ======================================================================
# public API
# ======================================================================

"""
    query(t::AbstractTable, wherestr::AbstractString;
         select=[n=>n for n in columnnames(t)]) -> RefTable | GroupedTable

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
  `isnan`/`isinf`/`isfinite`/`nonfinite`, masked arrays
  (`marray(d, m)`, `arraydata`, `arraymask`; `V[boolexpr]` yields a
  masked array whose reductions skip the excluded elements),
  `iif(cond, a, b)`, `rownumber()` (1-based),
  `pi`, `e`;
* an optional trailing `ORDER BY col [ASC|DESC], ...` (bare columns).

Column names are case-sensitive and must name a column of `t`; keywords
and function names are case-insensitive. Only the columns actually
referenced (by the WHERE expression or an ORDER BY key) are read.

`select` is `"out" => rhs` pairs. When every `rhs` is a bare column
name (or `Symbol`) the result is a lazy `RefTable` (no data copied;
persist it with `write_reftable(dst, result)`). When any `rhs` is a
**computed expression** (`"X * 2"`, `"sqrt(abs(V))"`, `"iif(K==0, 1,
0)"` — same grammar as WHERE, aggregates excepted) the result is an
in-memory `GroupedTable` with those columns evaluated per matched row.
A computed column that is a masked array (`"V[FLAG]"`) persists as its
plain data. A `("val", "mask") => "expr"` pair entry (TaQL's
`expr AS (v, m)`) instead emits **two** columns — the data and the
mask — so `[("D", "F") => "marray(DATA, FLAG)"]` reads a column
together with its mask column.

A bare `"ORDER BY ..."` (no WHERE) matches every row, sorted.

`mscal.*` derived-MS functions (Phase 77, needs `import SOFA` and an MS
MAIN table with `ANTENNA` / `FIELD` subtables): `mscal.ha1()` /
`ha2()` / `ha()` (hour angle, rad), `mscal.hadec1()` (`[ha, dec]`),
`mscal.azel1()` (`[az, el]`), `mscal.az1()` / `el1()` (scalar),
`mscal.pa1()` (parallactic angle), `mscal.last1()` (local apparent
sidereal time, rad), `mscal.itrf()` (`[lon, lat]` of `PHASE_DIR` in
ITRF), `mscal.uvw_j2000()` (`[u, v, w]` m — the `UVW` column in J2000),
`mscal.delay()` (geometric delay, s). The `1` / `2` suffix
picks `ANTENNA1` / `ANTENNA2`; no suffix uses antenna 0 (array-centre
fallback). The direction functions (`ha` / `hadec` / `azel` / `az` /
`el` / `pa` / `itrf` / `delay`) take an optional direction argument
instead of `FIELD.PHASE_DIR` — a body name (`mscal.el1('SUN')`), a
FIELD direction column (`mscal.az1('DELAY_DIR')`), a `[ra, dec]` J2000
pair in radians (`mscal.hadec1([2.0, 0.5])`), or a sexagesimal
`'RA, DEC'` string (`mscal.el1('10h42m31, 45d51m16')`).

`mscal.stokes(col [, 'types'] [, rescale])` (Phase 78) converts a
`DATA` / `FLAG` / `WEIGHT` array cell between correlation bases. `types`
(default `'IQUV'`) is an alias (`IQUV` / `CIRC` / `LIN`) or a
comma-list (`'I'`, `'I,V'`, `'XX,YY'`); the input basis comes from
`POLARIZATION.CORR_TYPE` row 1. The result is a `(nOut, nchan)` matrix.

`mscal.<sel>('spec')` (Phase 80) — MSSelection-lite row selection,
returning a per-row `Bool`. `<sel>` ∈ `baseline` / `field` / `spw` /
`scan` / `state` / `array` / `obs`. `spec` is a comma-list of terms
(`N`, `N~M`, `>N` / `<N`, an exact / glob / `/regex/` name match
against the type's NAME column); a `!`-term is subtracted.
`mscal.baseline` also takes `L & R` / `L && R` (baseline between two
antenna sets; `&` drops autocorrelations) and a whole-spec `!`.
`mscal.time('t0~t1')` selects a `TIME` range (endpoints are ISO /
`YYYY/MM/DD[/HH:MM:SS]` datetimes or a bare MJD-days number);
`mscal.uvdist('a~b[unit]')` selects a 2-D uv-distance range, `unit` ∈
`m` (default) / `km` / `lambda` / `klambda` / `mlambda` (wavelength
units scale per row by `SPECTRAL_WINDOW.REF_FREQUENCY`).
`mscal.corr('RR,LL')` selects rows whose polarization setup contains
any of the named correlations (Stokes names or integer codes);
`mscal.feed('0 & 1')` is the `mscal.baseline` form on `FEED1` / `FEED2`.

`mscal.spw('0:5~20')` — the spw selection takes an optional `:chanlist`
(a `;`-list of `a~b`, `a~b^step` channel-index ranges, single indices,
or `f1~f2GHz` / `<f` / `>f` `CHAN_FREQ` ranges); a channelled spw
selects the row only if at least one of the row's channels is selected.
`mscal.chan('0:5~20')` returns a per-row `BitVector` (the spw's
channel count) — the selected-channel mask, for use with `any(...)` /
`count(...)` / a masked array.

Deliberately a *subset* of real TaQL's grammar, not a look-alike: no
boolean-mask array subscripts.
Supported: 1-based array element/slice indexing (`DATA[1,1]`,
`V[1:4,1]`, `UVW[-1]`, `V[end-2:end,1]`), array literals `[a, b, ...]`,
`BETWEEN` / `NOT BETWEEN` (inclusive), bitwise `& | ^ ~` (`^` is xor --
use `**` for exponentiation), `~=` / `!~=` approximate equality
(casacore's `near`, relative tolerance `1e-5`), scientific-notation
number literals (`1.4e9`), **quantity literals** (`1.4GHz`, `10arcsec`,
`30deg` -- compared against a column carrying a `QuantumUnits` keyword;
needs the Unitful extension), **sexagesimal literals** (`10h30m`,
`45d51m16s`, `12h`, `45d` -- an `h`-prefix is an hour angle ×15, a
`d`-prefix is degrees; the value is radians), and **date/time + angle
functions**:
`datetime`/`mjd`/`mjdtodate`/`date`/`time` (all MJD-day `Float64`),
`year`/`month`/`day`/`week`/`weekday`, `cdate`/`ctime`/`cmonth`/`cdow`/
`ctod`, `hms`/`dms` (radians → sexagesimal string), `angle('10h30m')`
(sexagesimal string → radians), `normangle`, `angdist`/`angdistx`
(4 scalar radians or two `[lon, lat]` arrays).
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
    cols = _tql_cols(t, needed, ast)
    matched = ast === nothing ? collect(1:nrow(t)) :
              [i for i in 1:nrow(t) if _tqleval(ast, cols, i)]
    matched = _apply_orderby(matched, orderby, cols)
    cls = _select_classify(select, validnames)
    if _select_all_proj(cls)
        namemap, order = _select_spec(t, select)
        parent, rows, namemap = _flatten_query_parent(t, matched, namemap)
        return RefTable("", parent, rows, namemap, order,
                        parent.type, parent.subtype, parent.readme)
    end
    ps = _select_materialize(cls, t, matched)
    return GroupedTable(first.(ps), AbstractVector[last(x) for x in ps])
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
         select=[n=>n for n in columnnames(t)]) -> RefTable | GroupedTable

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
    allcols = AbstractVector[_load_col(column(t, n)) for n in allnames]
    rows = CTDSRows(allcols, Symbol.(allnames), nrow(t))
    matched = [i for (i, row) in enumerate(rows) if f(row)]
    cols_by_name = Dict(n => c for (n, c) in zip(allnames, allcols))
    matched = _apply_orderby(matched, orderkeys, cols_by_name)
    cls = _select_classify(select, Set(columnnames(t)))
    if _select_all_proj(cls)
        namemap, order = _select_spec(t, select)
        parent, rows2, namemap = _flatten_query_parent(t, matched, namemap)
        return RefTable("", parent, rows2, namemap, order,
                        parent.type, parent.subtype, parent.readme)
    end
    ps = _select_materialize(cls, t, matched)
    return GroupedTable(first.(ps), AbstractVector[last(x) for x in ps])
end

