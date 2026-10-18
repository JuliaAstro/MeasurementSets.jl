# Performance

Everything here is measured on an Apple-silicon laptop with a 1M-row synthetic table (four columns) or a 20 000-row
Measurement Set; the figures are there to show *what matters*, not to promise exact numbers. The examples run against the
sample Measurement Set in the test suite.

```julia
using MeasurementSets
t = readtable("/path/to/my.ms")
```

## Reading cells and columns

A [`Column`](@ref) is lazy. Read it in bulk when you want all of it, and keep the lazy column when you index into it
repeatedly:

```julia
times = column(t, "TIME")[:]                  # one bulk read: ~1 ms for a million rows

function total(col)                            # pass the lazy column in; `col[i]` is 20-50 ns for a numeric cell
    s = 0.0
    for i in 1:length(col)
        s += col[i]
    end
    return s
end
total(column(t, "TIME"))
```

| Read | Cost |
|---|---|
| `column(t, "TIME")[:]` | ~1 ms per million rows (faster than casacore C++) |
| `col[i]` on a kept numeric `Column` | 17–50 ns, no allocation |
| `getcell(t, "TIME", i)` on a `Table` | ~40 ns (the `Column` is kept with the table) |
| `getcell(rt, "TIME", i)` on a query result | ~150 ns |
| a tiled `DATA` cell, `precision = :full` | ~0.5 µs |
| `DataFrame(t)` of 1M rows × 4 columns | ~40 ms |

A column of array cells (`UVW`, `DATA`, `FLAG`, ...) comes back from `[:]` as a lazy [`BlockColumn`](@ref) over one buffer, and
[`rawblock`](@ref) gives you that buffer as a single dense array with the cell axes first — the cheapest way to hand a column to
numerical code:

```julia
uvw = rawblock(t, "UVW")                       # a 3 × nrow matrix, no per-row objects
```

Selecting many rows at once reads the column once when the selection is dense (at least 4096 rows covering an eighth of the
column) and cell by cell otherwise, so both `column(t, "TIME")[rows]` for a large `rows` and `column(query_result, "TIME")[:]`
are cheap:

```julia
rows = findall(>(0), column(t, "ANTENNA1")[:])
sel  = column(t, "TIME")[rows]
```

### Precision

A MAIN table reads its `ComplexF32` columns (`DATA`, `MODEL_DATA`, `CORRECTED_DATA`) as `ComplexF16` by default, which halves
the memory of a visibility cube, and decodes straight into the narrow type. Ask for the on-disk precision when you need it:

```julia
full = column(t, "DATA"; precision = :full)    # ComplexF32; about twice as fast per cell as the narrowed read
```

## Queries

`query`, `groupby`, `join`, `update!`, `delete!` and `taql` evaluate their conditions and expressions as compiled closures over
the loaded columns once the table has at least 2000 rows, so a `WHERE` over a million rows is milliseconds
(`A == 3`: 1 ms; `sqrt(B) + C > 1`: 18 ms; `ORDER BY` a numeric key: ~50 ms; an equi-`join` of 1M rows to 100: 9 ms;
`groupby ... gsum(B*C)`: ~65 ms). Prefer the string forms to the closure forms: a closure is opaque, so every column is loaded
unless you pass `cols=`.

```julia
r = query(t, "ANTENNA1 == 3 AND sqrt(TIME) > 0 ORDER BY TIME")
g = groupby(t, "ANTENNA1"; select = ["ANTENNA1" => "ANTENNA1", "n" => "gcount()", "m" => "gmean(TIME)"])
```

## Editing and writing

An [`edit`](@ref) session rewrites the storage-manager file of every column it touches (and the columns that share the file),
so do all your changes in **one** session rather than one session per cell:

```julia
update!("/path/to/my.ms"; set = ["INTERVAL" => "INTERVAL * 1.0"])    # a whole column: ~1 s per million rows
```

Removing or appending rows regenerates the table's files (`removerows!` of 1000 of 1M rows: ~0.35 s); a tiled visibility
cube is rewritten completely. [`copyms`](@ref) / [`create_ms`](@ref) of a 20 000 × 64 × 4 MS take about 0.2 s.

## Reference-frame conversions

[`measconvert`](@ref) to `AZEL`, `AZELGEO`, `HADEC`, `APP` or `ITRF` builds SOFA's astrometry context for the frame once and
caches it, so converting many directions under one [`MeasFrame`](@ref) costs ~7 µs each; create the frame once and reuse it:

```julia
fr   = MeasFrame(epoch = MEpoch{UTC}(60454.42), position = observatory("VLA"))
dirs = [MDirection{J2000}(0.1i, 0.5) for i in 1:1000]
azel = [measconvert(d, AZEL; frame = fr) for d in dirs]
```

## Threads

The caches (the per-table `Column` objects, the data managers, the compiled expressions, the astrometry context) are safe to
use from several tasks at once; concurrent reads, queries and conversions are tested under `julia -t 8`.
