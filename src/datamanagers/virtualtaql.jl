# VirtualTaQLColumn -- casacore's "CALC column": a column whose per-row
# value is a stored TaQL expression evaluated against the table's own
# columns (a constant-valued MS column, or on-the-fly derived data).
#
# Mirrors casacore/tables/DataMan/VirtualTaQLColumn.{h,cc}.  Stores
# nothing itself (`isWritable()` -> False -> empty per-DM block, like
# every other virtual engine).  Config is two String keywords on the
# virtual column: `_VirtualTaQLEngine_CalcExpr` (the expression) and
# `_VirtualTaQLEngine_Style` (the TaQL style -- 0- vs 1-based indexing,
# a no-op here since TaQL-lite has no array indexing).
#
# The expression is evaluated with the Phase 22-25 TaQL-lite engine
# (`_taqllite_parse` / `_tqleval` in taql/parse.jl / taql/ast.jl).  An expression using a
# TaQL feature TaQL-lite does not support (array indexing, units,
# date/time or measures functions) raises a clear error when the column
# is *read* -- the rest of the table opens fine.  Read-only: casacore
# itself forbids puts; `write_table(...; virtualtaql=Dict("CV"=>expr))`
# only declares the column + stores the expression string.

mutable struct VirtualTaQLColumn
    table::Table
    vdesc::ColumnDesc
    exprstr::String
    style::String
    ast::Any                 # parsed TQLExpr, `nothing` until first access
    cols::Any                # Dict{String,AbstractVector} of referenced columns
    const_value::Any         # cached value when the expression references no column
    prepared::Bool
end

DATAMANAGERS["VirtualTaQLColumn"] = VirtualTaQLColumn

_is_virtualtaql_dm(name::AbstractString) = name == "VirtualTaQLColumn"

function Base.open(::Type{VirtualTaQLColumn}, t::Table, dm::DataManagerInfo)
    vi = findfirst(c -> c.sequ == dm.sequ, t.desc.columns)
    vi === nothing &&
        error("VirtualTaQLColumn (seq $(dm.sequ)) has no bound column")
    vdesc = t.desc.columns[vi]
    expr = String(get(vdesc.keywords, "_VirtualTaQLEngine_CalcExpr", ""))
    isempty(expr) && error("VirtualTaQLColumn column \"$(vdesc.name)\": " *
                           "missing _VirtualTaQLEngine_CalcExpr keyword")
    style = String(get(vdesc.keywords, "_VirtualTaQLEngine_Style", ""))
    return VirtualTaQLColumn(t, vdesc, expr, style, nothing, nothing, nothing, false)
end

function _vtq_prepare!(v::VirtualTaQLColumn)
    v.prepared && return v
    if !(isempty(v.style) || v.style in ("1", "base1"))
        @warn "VirtualTaQLColumn column \"$(v.vdesc.name)\": TaQL style " *
              "\"$(v.style)\" is ignored (TaQL-lite has no array indexing)"
    end
    ast = try
        _taqllite_parse(v.exprstr, Set(columnnames(v.table)))
    catch err
        throw(ArgumentError(
            "VirtualTaQLColumn column \"$(v.vdesc.name)\": cannot evaluate CALC " *
            "expression \"$(v.exprstr)\" — $(sprint(showerror, err)). TaQL-lite " *
            "supports arithmetic, comparisons, LIKE/regex, a function library, IN, " *
            "unit literals (`1.4GHz`) and date/time functions; array indexing and " *
            "measures functions are not."))
    end
    refs = Set{String}()
    _tqlrefs!(refs, ast)
    v.ast = ast
    if isempty(refs)
        v.const_value = _tql_result_strip(_tqleval(ast, Dict{String,AbstractVector}(), 1))
    elseif _has_qty(ast)
        v.cols = Dict{String,AbstractVector}(
            n => _tql_unit_attach(column(v.table, n), columnunit(v.table, n)) for n in refs)
    else
        v.cols = Dict{String,AbstractVector}(n => column(v.table, n) for n in refs)
    end
    v.prepared = true
    return v
end

_vtq_raw(v::VirtualTaQLColumn, row::Integer) =
    v.cols === nothing ? v.const_value :
    _tql_result_strip(_tqleval(v.ast, v.cols, Int(row)))

# cast an evaluated value to the column's declared Julia type
function _vtq_cast(v::VirtualTaQLColumn, raw, J::Type)
    if v.vdesc.shape isa Dims && isempty(v.vdesc.shape)
        return convert(J, raw)                       # scalar column
    end
    return convert(Array{J}, collect(raw))           # array column
end

function _vtq_err(v::VirtualTaQLColumn, err)
    err isa ArgumentError && occursin(v.vdesc.name, err.msg) && rethrow(err)
    throw(ArgumentError(
        "VirtualTaQLColumn column \"$(v.vdesc.name)\": evaluating CALC expression " *
        "\"$(v.exprstr)\" — $(sprint(showerror, err))"))
end

function getcell(v::VirtualTaQLColumn, ::Integer, ::ColumnDesc, row::Integer, ::Integer)
    _vtq_prepare!(v)
    try
        return _vtq_cast(v, _vtq_raw(v, row), juliatype(v.vdesc.type))
    catch err
        _vtq_err(v, err)
    end
end

function getcolumn(v::VirtualTaQLColumn, ::Integer, ::ColumnDesc, nrow::Integer, ::Integer;
                   astype::Union{Nothing,Type}=nothing)
    _vtq_prepare!(v)
    J = astype === nothing ? juliatype(v.vdesc.type) : astype
    try
        return [_vtq_cast(v, _vtq_raw(v, r), J) for r in 1:nrow]
    catch err
        _vtq_err(v, err)
    end
end
