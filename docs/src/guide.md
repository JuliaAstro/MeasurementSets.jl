# Guide

The examples below assume `using MeasurementSets` and a Measurement Set
at `/path/to/my.ms`. They are illustrative, not doctested.

## Opening a Measurement Set

```julia
ms = MeasurementSet("/path/to/my.ms")
subtablenames(ms)                        # ["ANTENNA", "SPECTRAL_WINDOW", …]

t = readtable("/path/to/my.ms")          # the MAIN table on its own
nrow(t)
columnnames(t)
```

`readtable` also opens a single subtable directory
(`readtable("/path/to/my.ms/ANTENNA")`) or any casacore table.

## Reading columns

[`column`](@ref) returns a lazy [`Column`](@ref) (`<: AbstractVector`):

```julia
ms[:DATA][42]                            # one cell: a 4×64 ComplexF32
ms[:UVW][1:100]                          # first 100 baselines' UVW
column(ms.data, "TIME")[:]               # the whole column (fast path)
```

Column and table metadata:

```julia
columndesc(t, "DATA")                    # a ColumnDesc (type, shape, keywords, DM binding)
keywords(t)["MS_VERSION"]                # 2.0f0
columndesc(t, "UVW").keywords            # per-column keywords (units, MEASINFO)
```

### Precision

A MAIN table's `TpComplex` visibility columns — `DATA`, `MODEL_DATA`,
`CORRECTED_DATA` — read back as `ComplexF16` **by default**. The on-disk
bytes are `ComplexF32`; the visibilities derive from 8-bit samples, so
nothing real is lost and the working set halves.

```julia
eltype(column(t, "DATA"))                     # Matrix{ComplexF16}
eltype(column(t, "DATA"; precision=:full))    # Matrix{ComplexF32}
readtable("my.ms"; precision=:full)           # every column wide
readtable("my.ms"; precision=BFloat16)        # DATA + WEIGHT + SIGMA all 16-bit
MeasurementSet("my.ms"; precision=:full)
```

`TpFloat` columns (`WEIGHT`, `SIGMA`, `WEIGHT_SPECTRUM`) stay `Float32`
under the default and under `precision=Float16` (real weights exceed
`Float16`'s 65504 range). Pass **`precision=BFloat16`** to narrow them
too — `BFloat16` has `Float32`'s exponent range (overflow-safe) and a
7-bit mantissa that matches 8-bit-derived data; `DATA` then comes back
as `Complex{BFloat16}` and `WEIGHT` as `BFloat16`.

`Float64` (`TIME`, `UVW`), `ComplexF64` and `Bool` are never narrowed.
Non-MAIN tables default to `:full`. `copyms` / `copytable` / `edit`
always read at full precision, so copies and in-place edits stay
byte-exact; a narrowed column written back upcasts to `Float32` on disk.

## Tables.jl interop

Every table is a `Tables.jl` source — column *and* row access — so
subtables drop straight into the data ecosystem:

```julia
using DataFrames
DataFrame(subtable(ms, "ANTENNA"))
Tables.schema(subtable(ms, "SPECTRAL_WINDOW"))
Tables.rowtable(subtable(ms, "FIELD"))
```

## Validating against the standard schema

The MS v2 standard schema (NRAO Memo 229) is available as data:

```julia
validate(ms)                             # String[] when conformant; never throws
stdtable("SPECTRAL_WINDOW").columns
stdcolumns("ANTENNA")
```

## Reference frames

`measure(t, col[, row])` reads a measure-valued column as a typed value
with its reference frame; `import SOFA` (+ optionally `EarthOrientation`)
converts between frames.

```julia
import SOFA, EarthOrientation

e = measure(main, "TIME", 1)                       # MEpoch{UTC}
measconvert(e, TT)                                 # → MEpoch{TT}

fr = MeasFrame(epoch = e,
               position = measure(subtable(ms, "ANTENNA"), "POSITION", 1),
               direction = measure(subtable(ms, "FIELD"), "PHASE_DIR", 1))
measconvert(MDirection{J2000}(2.0, 0.5), AZEL; frame = fr)
measconvert(measure(subtable(ms, "SPECTRAL_WINDOW"), "CHAN_FREQ", 1)[1],
            LSRK; frame = fr)
```

See [Concepts](concepts.md#Reference-frames-(measures)) for the full
frame list, accuracy notes, and the `measures =` write keyword.

## Writing and copying

```julia
copyms("/path/to/my.ms", "/tmp/copy.ms"; rows = 1:2000)
create_ms("/tmp/synth.ms"; nrow = 100, nchan = 64, ncorr = 4, nant = 6)

write_table("/tmp/spw", "SPECTRAL_WINDOW",
            ["NUM_CHAN"  => [64, 32],
             "CHAN_FREQ" => [collect(1.0:64.0), collect(1.0:32.0)]];  # ragged
            nrow = 2)
```

`copyms` / `copytable` preserve each column's storage-manager, virtual
engine and Dysco compression. `write_table` / `create_ms` pick
`StandardStMan` by default; `tsm=` / `ism=` / `engines=` / `dysco=`
choose a different layout, and `storage=:multifile` / `:multihdf5` packs
the result into one container file.

[`copytable`](@ref) is also `SELECT … INTO` — it materialises any query
result:

```julia
copytable("/tmp/cal.tab", query(ms.MAIN, "FIELD_ID == 3"))
```

## Editing in place

```julia
edit("/tmp/copy.ms") do t
    t[:FLAG][5] = trues(4, 64)           # a tiled cell -- patched in the tile file
    t[:SCAN_NUMBER][10] = 7
    addrows!(t, 10)                      # every storage manager's row count grows
    for r in 91:100
        t[:TIME][r] = 4.6e9 + r
    end
end
```

Row and schema mutation take a whole-file regeneration path:

```julia
edit("/tmp/copy.ms") do t
    removerows!(t, [2, 5, 9])
    addcolumn!(t, "WEIGHT_SPECTRUM")
    removecolumn!(t, "FLAG_CATEGORY")
end
```

The flush runs under an exclusive `table.lock` and updates the sync blob,
so a concurrent casacore reader re-syncs. [`is_stale`](@ref) /
[`resync`](@ref) let a long-lived reader notice an external write.

## Querying

[`query`](@ref) row-filters a table and returns a [`RefTable`](@ref):

```julia
sel = query(ms.MAIN, "ANTENNA1 != ANTENNA2 AND mean(abs(DATA)) > 3 ORDER BY TIME")
```

The WHERE string supports comparisons, `AND`/`OR`/`NOT` (or
`&&`/`||`/`!`), parentheses, `IN [...]`, arithmetic (`+ - * / % // **`),
`LIKE` / `~ p/glob/` / `~ m/regex/` pattern matching, a function library
(`abs`, `sqrt`, `mean`, `any`, `rownumber()`, …), and a trailing
`ORDER BY`. There is also a closure form:

```julia
query(ms.MAIN; cols = ["ANTENNA1", "ANTENNA2", "UVW"]) do row
    hypot(row.UVW...) > 500.0
end
```

[`groupby`](@ref) computes one row per group:

```julia
groupby(ms.MAIN, "FIELD_ID";
        select = ["FIELD_ID" => :FIELD_ID,
                  "N"        => "gcount()",
                  "AMP"      => "gmean(mean(abs(DATA)))"],
        having = "gcount() > 100",
        orderby = ["AMP" => :desc])
```

or, for aggregates the `g*` set can't express, a do-block returning a
`NamedTuple`:

```julia
groupby(ms.MAIN, [:ANTENNA1]; cols = ["ANTENNA1", "DATA", "WEIGHT"]) do g
    (; ANT  = first(g.ANTENNA1),
       N    = length(g),
       WAMP = sum(mean.(abs, g.DATA) .* g.WEIGHT) / sum(g.WEIGHT))
end
```

`join` (a method added to `Base.join`) attaches a subtable's columns to
each MAIN row — an **N:1 lookup join**, TaQL's own `JOIN … ON` semantics:

```julia
join(ms.MAIN, subtable(ms, "ANTENNA");
     on        = "ANTENNA1",                    # 0-based row index into ANTENNA
     rightcols = ["NAME" => "ANT_NAME"],
     where     = "ANT_NAME ~ p/DA*/")
```

`on` is a column name (that left column is a 0-based row index into the
right table), a `"LKEY" => "RKEY"` pair (equi-join), or a vector of pairs
(composite key). `unmatched` is `:error` (default), `:drop` or
`:missing`.

Every result is an [`AbstractTable`](@ref), so the verbs chain, and any
result persists with `write_table(dst, "T", result; nrow = nrow(result))`
or [`copytable`](@ref).

## Row-level write commands

[`update!`](@ref), `delete!` (extends `Base.delete!`) and `insert!`
(extends `Base.insert!`) change a table in place:

```julia
update!("/tmp/copy.ms/ANTENNA";
        set = ["MOUNT" => "'ALT-AZ'"], where = "STATION ~ p/PM*/")

delete!("/tmp/copy.ms/FLAG_CMD"; where = "APPLIED")

insert!("/tmp/copy.ms/STATE"; values = (; OBS_MODE = "CALIBRATE_PHASE", SIG = true))
insert!("/tmp/dst.ms/STATE", query(other, "OBS_MODE == 'CALIBRATE_PHASE'"))
```

`update!`'s `set` RHS are TaQL-lite expressions evaluated against the
*pre-update* row (so `["A" => "B", "B" => "A"]` swaps). `where` is a WHERE
string, a `row -> Bool` closure, or `nothing` (every row).

[`taql`](@ref) wraps all four as one string dispatcher:

```julia
taql("/tmp/copy.ms", "UPDATE t SET UVW = UVW * 2 WHERE ANTENNA1 == 0")
taql("/tmp/copy.ms", "DELETE FROM t WHERE FLAG_ROW")
taql("/tmp/copy.ms", "INSERT INTO t (A, B) VALUES (1, 2.5), (3, 4.5)")
taql(ms.MAIN,        "SELECT A, B AS BB WHERE A > 5 INTO '/tmp/out'")
```
