# TaQL-lite query engine -- entry point.  This file only `include`s the
# pieces below in dependency order; `MeasurementSets.jl` includes it.
#
# A small, self-contained query facility -- a deliberate subset of
# casacore's Table Query Language.  The pieces:
#
#   ast.jl        AST node types + the `_tqleval` / `_tqlrefs!` /
#                 `_has_aggr` / `_sg` visitors, `_bcast`, masked arrays
#                 (`TQLMArray`), and array-cell indexing / slice helpers
#   parse.jl      tokenizer, recursive-descent parser, operator tables,
#                 `~=` near-equality, and SQL/glob pattern -> Regex
#   functions.jl  the `NAME(args...)` function library + `g*` aggregate
#                 registry + `_make_func`
#   query.jl      ORDER BY, `_taqllite_parse_query`, `select` classify /
#                 materialise, and `query(::AbstractTable, ...)`
#   groupby.jl    `GroupSlice`, `GroupedTable`, `groupby`, the `_geval`
#                 (per-group) visitors, and `query(::GroupedTable, ...)`
#   join.jl       `join` -- index-lookup / equi / M:N / predicate /
#                 `L.`-`R.`-qualified string condition
#
# The row-level write commands (`update!` / `delete!` / `insert!` /
# `taql`) live in `taql/commands.jl`, included later (after `tables/edit.jl` /
# `tables/create.jl` / `tables/resync.jl`, which they build on).

include("ast.jl")
include("parse.jl")
include("functions.jl")
include("query.jl")
include("groupby.jl")
include("join.jl")
