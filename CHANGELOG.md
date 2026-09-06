# Changelog

`MeasurementSets.jl` is pre-1.0 (`1.0.0-DEV`). It has been built in
numbered **phases** — each a self-contained slice of functionality,
verified against `Casacore.jl` / real TaQL / a real CASA install before
merging. These are development milestones, not tagged releases; the
public API has been additive throughout. Newest phases are at the
bottom.

For a task-oriented overview of what the package does today, see the
[README](README.md).

---

### Phase 1 — CTDS metadata (read)

`AipsIO` primitive decoder; `table.dat` / `table.info` parsing (table &
column descriptions, keyword sets incl. nested `Record`s / `QuantumUnits`
/ `MEASINFO`, data-manager bindings, row counts, endianness); the MS
subtable tree.

### Phase 2 — StandardStMan (SSM) column data (read)

`getcolumn` / `getcell` for SSM-backed columns: scalar numerics, `Bool`
(bit-unpacked), variable-length `String` (incl. multi-bucket string
buckets), and direct fixed-shape numeric/`Bool` arrays.

### Phase 3 — TiledStMan column data (read)

`getcolumn` / `getcell` for `TiledShapeStMan` and `TiledColumnStMan`
columns — the visibility cubes (`DATA`, `FLAG`, `WEIGHT`, `SIGMA`,
`UVW`, …).  Header parsing, `row → hypercube` mapping, and tile
de-interleaving from the `table.f<n>_TSM<m>` files (mmapped).  Detects
never-written columns.  (Multi-column hypercubes: Phase 11.)

### Phase 4 — IncrementalStMan column data (read)

The "store-on-change" manager behind most MAIN metadata columns (`TIME`,
`INTERVAL`, `EXPOSURE`, `FIELD_ID`, …).  With this every column of a
typical MAIN table is readable except ones that were never written.

### Phase 5 — high-level API, `Tables.jl`, standard schema

Lazy `Column <: AbstractVector` (`t[:DATA]`, `col[i]`, `col[1:5]`,
`col[:]`), `Tables.jl` column *and* row access (subtables drop straight
into `DataFrame`, `Tables.rowtable`, …), and a machine-readable encoding of
the MS v2 standard schema (`SCHEMAVER2`, `stdtable`, `validate`).

### Phase 6 — writers

Pure-Julia `table.dat` + StandardStMan + TiledShapeStMan writers, little-
endian storage-manager files, verified against `Casacore.jl`.

* `write_table(dir, name, cols; nrow, tsm=…, ism=…)` — one CTDS table from
  `name => vector` pairs or a `Tables` source; `tsm` / `ism` name the
  columns to bind to TiledShapeStMan / IncrementalStMan (default:
  StandardStMan).
* `copyms(src, dst; rows=Colon(), subtables=Colon())` — copy an MS,
  preserving each column's storage-manager kind.
* `create_ms(dir; nrow, nchan, ncorr, nant)` — synthesise a minimal,
  `validate`-clean MS.

### Phase 7 — StandardStMan indirect / string arrays (read + write)

The `StIndArray` / `table.f<n>i` mechanism and the string-handler array
format behind every variable-shape subtable column (`CHAN_FREQ`,
`CORR_TYPE`, `POLARIZATION_TYPE`, `POL_RESPONSE`, `PHASE_DIR`, `LOG`, …).
`copyms` now reproduces every column of a standard MS; `create_ms` writes
these as real ragged arrays.

### Phase 8 — IncrementalStMan writer + ISM indirect arrays

A byte-exact writer for the "store on change" run-length format (header,
multi-bucket data + index parts, `ISMIndex`), plus ISM indirect-array
read + write. `copyms` keeps a source's ISM columns as ISM;
`create_ms` writes MAIN's per-integration scalars (`TIME`, `FIELD_ID`,
…) through ISM.

### Phase 9 — in-place edits

`edit(path) do t … end` opens an existing table for update: overwrite
cells / whole columns (`t[:X][i] = v`, `t[:X][:] = vals`) and append rows
(`addrows!(t, n)`).  Hybrid persist — a touched `TiledShapeStMan` column
is patched in the tile file in place (editing one cell of a multi-GB cube
touches a few bytes); a touched StandardStMan / IncrementalStMan file is
regenerated from its in-memory column data.

### Phase 10 — row deletion + `addColumn` / `removeColumn`

`edit` sessions can now change the row set and the schema:

```julia
edit("/tmp/copy.ms") do t
    removerows!(t, [3, 8, 12])            # drop rows
    addrows!(t, 5)                        # append rows
    addcolumn!(t, "WEIGHT_SPECTRUM")      # from the standard schema
    addcolumn!(t, "FOO", rand(nrow(t)))   # explicit data
    removecolumn!(t, "FLAG_CATEGORY")
end
```

`removerows!` / `addcolumn!` / `removecolumn!` take the *regen* persist
path: every affected storage-manager file is rebuilt from the resolved
in-memory column data (a tiled column's tile file included — so, unlike
casacore, rows can be deleted even from a table with a `TiledStMan`
column) and `table.dat` is rewritten in full.  Untouched managers keep
their files and header bytes.  Plain cell/column overwrite and pure row
appends still take the Phase-9 in-place fast path.

### Phase 11 — multi-column tiled storage managers

`TiledShapeStMan` hypercubes shared by several data columns of one cell
shape (the `DATA` + `FLAG` + `WEIGHT_SPECTRUM` layout of a CASA-filled
MS): concatenated per-column tile blocks in casacore's size-sorted order,
read and write.  New `TiledColumnStMan` and `TiledCellStMan` writers.
`write_table` takes `tsm` / `tcm` / `tcell` column-name *groups*;
`copyms` reproduces a source's hypercube grouping (and keeps a
`TiledColumnStMan` `UVW` as such instead of moving it to StandardStMan);
`create_ms` shares one cube between `DATA`, `FLAG` and `WEIGHT_SPECTRUM`.

### Phase 12 — virtual column engines

The other kind of casacore data manager: one that stores nothing itself
but maps a column the user sees onto a hidden column of scaled integers,
`virtual = stored·scale + offset`.  Read + write for `ScaledArrayEngine`,
`ScaledComplexData`, `CompressFloat`, `CompressComplex`,
`CompressComplexSD` (and `MappedArrayEngine`), including auto-scale
(per-row `scale` / `offset` companion columns computed from each row's
range).

```julia
write_table("/tmp/t", "T", ["DATA" => cubes]; nrow=n,
            engines = Dict("DATA" => (; kind = :compresscomplex, autoscale = true)))
```

`copyms` re-encodes and keeps an engine column compressed; `edit` sessions
re-encode a touched engine column on flush.  Verified byte-for-byte
against casacore's own decoder for the auto-registered engines
(`Compress*`, `MappedArrayEngine`).

### Phase 13 — concurrent access + locking

Cooperative `fcntl` locking + row-count synchronisation via `table.lock`,
so a table is safe to share with another Julia session or a real
`casa` / python-casacore process.  `readtable` holds a shared lock while
it slurps `table.dat` and trusts the `table.lock` `TableSyncData` sync
blob's row count over `table.dat`'s (as casacore does); every writer runs
under an exclusive lock, writes storage-manager files through an atomic
rename, and updates the sync blob (new row count, bumped modify counter)
on the way out.

```julia
t = readtable("/data/my.ms")
# ... another process appends rows ...
is_stale(t)          # true
t = resync(t)        # re-opens; is_stale(t) now false
is_multiused("/data/my.ms")   # is anyone else holding it open?
```

Locking is automatic and degrades to a silent no-op wherever it is
unavailable (NFS without a lock daemon, a read-only directory,
unsupported OS).  macOS + Linux.

A contended acquire also announces itself in `table.lock`'s cooperative
request-id list (and removes itself again once done), the same way a
real casacore process would — so a real `casa` / python-casacore peer
holding the table in its default `AutoLocking` mode can see us waiting
and voluntarily release early, rather than us sitting out the full poll
timeout (Phase 17).

### Phase 14 — reference & concatenation tables (read)

`readtable` now recognises the other two first-class casacore table
kinds and returns a matching view:

* **`RefTable`** — a persistent row-number reference into a parent table,
  what a TaQL `SELECT ... GIVING '<path>'` row selection or
  `table.query` writes.  Column reads delegate to the parent through the
  selected row list; a `SELECT a, b AS c` rename is honoured.
* **`ConcatTable`** — a virtual row-wise concatenation of same-schema
  tables (the MAIN table of a MultiMS).  Row offsets are recomputed from
  each part's row count on open.

Both present the same `column` / `nrow` / `columndesc` / `keywords` /
`subtables` / `Tables.jl` surface as a plain `Table` and share the new
`AbstractTable` supertype; `is_stale` / `resync` follow through to the
parent(s).

```julia
rt = readtable("/tmp/selection.tab")     # a TaQL RefTable
nrow(rt); rt[:DATA][1:10]                # reads the parent's rows
```

### Phase 15 — persist a selection: write RefTable / ConcatTable, and a data-manager-preserving materialise

```julia
# a lightweight reference -- no data copied, openable by casa/python-casacore
write_reftable("/tmp/ref.tab", readtable("/tmp/t.tab"), [5, 1, 3];
               select = ["A" => "A", "BR" => "B"])   # optional rename/projection
write_concattable("/tmp/cc.tab", [readtable("/tmp/p0"), readtable("/tmp/p1")])

# a real independent table, storage-manager / engine layout kept
copytable("/tmp/plain.tab", rt)          # rt :: RefTable or ConcatTable
```

`copytable` (and, through it, `copyms`/`write_ms` when MAIN or a subtable
turns out to be a RefTable/ConcatTable) derives each output column's
storage-manager or virtual-engine kind from the source exactly as
`copyms` already did for a plain table — from the *parent* for a
`RefTable`, from the *first part* for a `ConcatTable` — mirroring
casacore's own `GIVING ... AS PLAIN` (`dataManagerInfo()`).

Not yet implemented: editing a persisted RefTable/ConcatTable in place;
concatenating keyword subtables on write; hypercube coordinate / id
columns; `TiledDataStMan` (`ForwardColumnEngine` and `BitFlagsEngine`
landed in Phase 40, `VirtualTaQLColumn` in Phase 41); adding a column (or engine) to an existing table in an
edit session; in-place per-data-manager `resync`. (Free-list bucket
reuse doesn't apply here — every edit fully regenerates any touched
storage-manager file from resolved data, so nothing accumulates across
edits the way casacore's own in-place bucket model can.)

### Phase 16 — `copyms` performance

A full, in-order table/subtable copy
(every subtable copy, and the default `copyms`/`copytable` with no `rows=`
override) now reads each source column via its own whole-column fast
path instead of cell by cell — roughly halves the time on a large,
mostly-indirect-array subtable (925,645-row `POINTING`: 68 s → 35 s on
the reference MS) and more on a scalar/fixed-shape/tiled-heavy one. A
`RefTable` selection or an explicit partial row range is unaffected.

### Phase 17 — cooperative lock hand-off

Closes the one documented gap
in Phase 13's locking: a contended acquire announces this process in
`table.lock`'s request-id list and removes itself again once done
(casacore `LockFile::addReqId`/`removeReqId`), so a real casacore peer
holding the table in its default `AutoLocking` mode can see us waiting
and release early. See the Phase 13 section above for the usage example
— this is automatic, no API change.

### Phase 18 — `DyscoStMan` column data (read)

`DyscoStMan` (the
third-party `aroffringa/dysco` lossy-compression storage manager many
large modern MSes use for `DATA`/`WEIGHT_SPECTRUM`) is no longer in the
"data manager not yet supported" set — `getcolumn`/`getcell`/`column`
transparently decode it. Scope: **AF normalization + TruncatedGaussian
quantization only** (the real-world default combo), **read-only**.
Verified against a genuine `DyscoStMan`-compressed table written by a
real CASA install's `casatools` (`table.create(...; dminfo=...)`) —
decoded `DATA` matches CASA's own `getcol()` to float32 rounding
precision, `WEIGHT_SPECTRUM` (a plain linear quantizer, no dictionary)
matches exactly. `copyms`/`write_ms`/`copytable` of a Dysco-bound column
falls back to a plain `StandardStMan` copy (decode-then-re-encode
uncompressed) — writing Dysco is out of scope. Not yet implemented: RF/
Row normalization; Gaussian/Uniform/StudentsT distributions (a clear
`error`, not a silent misdecode); writing/compressing.

### Phase 19 — `DyscoStMan` full read + write

Completes Phase 18: all
three normalizations (`AF`/`RF`/`Row`) and all four quantization
distributions (`Gaussian`/`Uniform`/`StudentsT`/`TruncatedGaussian`), read
*and* write. `write_table`/`create_ms` take `dysco=`/`dysco_spec=` kwargs
to compress one or more columns (a Dysco group works like a `tsm` group —
one or more column names sharing one instance); `copyms`/`write_ms`/
`copytable` now **preserve** a source's Dysco compression (reading the
live instance's own parameters) instead of downgrading to plain
`StandardStMan`; `edit()` supports `setcell!`/`addrows!`/`removerows!` on
a Dysco-bound column (always via the regen path — a touched cell needs
its whole block re-decoded and re-encoded, like a virtual engine, not
like a tiled cube's byte-addressable in-place patch). Verified against
the real CASA install used in Phase 18: all 24 (normalization ×
distribution × dither) write combinations produce files real CASA opens
and decodes to float32 rounding precision of our own decoder — genuine
write-direction interop. `dither=true` (the default, matching casacore's
own always-dither write path) uses Julia's own `Random`, not casacore's
`std::mt19937` bit-for-bit — a deliberate departure with no effect on
decodability (dithering only affects which of two adjacent quantization
symbols an in-between value rounds to). StudentsT's CDF comes from
`Distributions.jl`'s `TDist` (unlike the other three distributions, which
use `SpecialFunctions.jl`'s `erf`/`erfinv` matching casacore's own math);
its inverse CDF is still our own bisection over that CDF (no direct
`Distributions.jl` quantile call), self-consistent rather than
GSL-bit-exact.

### Phase 20 — `MultiFile`/`MultiHDF5` container read support

casacore
can pack every small per-storage-manager private file of a table
(`table.f<seq>`, `table.f<seq>i`, `table.f<seq>_TSM<k>`) into one real
file on disk (`table.mf` or `table.mfh5`), to cut open-file-descriptor
counts and help filesystems like Lustre. Both formats are now
transparently readable — `readtable` detects `table.mf`/`table.mfh5`
alongside `table.dat` and every `StandardStMan`/`IncrementalStMan`/
`TiledStMan` opener resolves its private file through the container
instead of a real path (Dysco and the virtual engines are never
container-packed, matching real casacore). **Read-only**; `edit()`
refuses a container-backed table, and `copytable`/`copyms` transparently
un-pack one into an ordinary plain table. `MultiFile` is a from-scratch
byte-exact port (header, packed/run-length-compressed block index,
casacore's own nonstandard CRC32) verified against a real
casacore-authored `table.mf` (TaQL `storage="multifile"`) — genuine
interop, cross-checked with Casacore.jl. `MultiHDF5` needed adding
**`HDF5.jl`** as a dependency — the project's first non-pure-Julia
dependency, a deliberate, explicit user decision — but has **no real
casacore oracle on this machine**: neither Casacore.jl's bundled
`casacorecxx_jll` nor the CASA.app install used for the Dysco oracle has
HDF5 support compiled in, so it is verified only against a self-authored
fixture built directly with HDF5.jl following the documented format — a
known, standing verification gap. A container-backed virtual file's
bytes are `mmap`'d zero-copy when its blocks are physically contiguous
(the common case for a freshly-written, never-edited container; matches
this package's existing non-container `mmap` performance exactly) and
materialized otherwise; `MultiHDF5` always materializes (no `mmap`
equivalent for HDF5).

### Phase 21 — `MultiFile`/`MultiHDF5` container write support

Completes
Phase 20: `write_table`/`create_ms`/`copytable`/`copyms`/`write_ms` all
take `storage=:sepfile|:multifile|:multihdf5` and `blocksize=` (default
4 MiB, matching casacore's own default) to pack every `StandardStMan`/
`IncrementalStMan`/`TiledStMan` private file into one `table.mf`/
`table.mfh5` — Dysco and virtual-engine files stay separate, matching
real casacore. `write_ms`/`copyms`'s `storage=` packs **every** table
(MAIN and each subtable), each into its own container, mirroring what a
real casacore MS created under a global `StorageOption` looks like. The
writer only ever creates a *fresh* container in one shot — `edit()`
still refuses a container-backed table (Phase 20's guard). A real find
along the way: a container file on disk isn't sufficient by itself for a
genuine casacore reopen to use it — casacore's `ColumnSet::getFile`
reads the storage option back out of `table.dat`'s own ColumnSet block
(a version-gated field our writer wasn't emitting), not from probing
`table.mf`'s presence, so `table.dat`'s ColumnSet block now carries that
field too when `storage != :sepfile`. Verified with genuine
write-direction interop for `MultiFile` (our own writer's output opened
and read correctly by real Casacore.jl, mirroring the Dysco Phase 19
write-interop pattern); `MultiHDF5` write output has no real-casacore
oracle available on this machine (same gap as Phase 20's read side).

### Phase 22 — TaQL-lite query engine

`query(t, wherestr)` row-filters
a `Table`/`RefTable`/`ConcatTable` with a small TaQL-like WHERE string
(comparisons, `AND`/`&&`, `OR`/`||`, `NOT`/`!`, parentheses, `col IN
[v1,v2,...]`), reading only the columns the expression references, and
returns a `RefTable` — the same lazy, no-copy view real TaQL's own
`SELECT ... GIVING` produces, persistable unchanged via the existing
`write_reftable`. `query(f, t)` is the Julia-native counterpart: a
predicate closure over a `Tables.AbstractRow` (`query(t; cols=[...]) do
row; row.ANTENNA1 > 0; end`). Both take a `select=` for column
projection/rename, matching `write_reftable`'s own convention exactly.
Every operator/keyword spelling accepted is a genuine subset of real
TaQL's own (verified against its lexer, and against a live TaQL
cross-check test that runs the *same* WHERE string through both engines
and compares the row selections).

### Phase 23 — TaQL-lite `ORDER BY`

Both `query` entry points now sort
their matched rows before building the result `RefTable`. In the
string form, an optional trailing `ORDER BY col [ASC|DESC], ...` (bare
column references only, verified against TaQL's own `sortlist`/
`sortexpr` grammar) — `query(t, "A > 5 ORDER BY B DESC")`, or a bare
`query(t, "ORDER BY B")` to sort every row with no filter. In the
closure form, a new `orderby=` keyword takes bare names (ascending) or
`name => :asc`/`name => :desc` pairs. The sort is a stable multi-key
sort (`Base.Sort.MergeSort`, explicit — ties keep original row order),
so a sort key list with several columns tie-breaks left to right. Sort
keys are read (and de-duplicated against `WHERE`-referenced columns)
through the same only-what's-needed column resolution Phase 22
established. Cross-checked against real TaQL for row *order*, not just
row-set membership. No arithmetic sort keys, no leading global
default-direction shortcut, no `NODUPL`/`DISTINCT`.

### Phase 24 — TaQL-lite arithmetic + pattern matching

The string
parser gains an arithmetic-expression layer between comparison and atom
— `+ - * / % // **` and unary `-`, at TaQL's own precedence (`+ -` <
`* / % //` < unary < `**`, right-assoc) — so a WHERE comparison operand
can now be a computed expression: `query(t, "ANTENNA1 % 4 == 0")`,
`query(t, "TIME - 4.6e9 > 0 AND (A + B) * 2 <= LIM")`. Arithmetic uses
Julia numeric semantics (`/` yields a float, `//` truncates, `%` is
`rem`). And pattern matching: `col LIKE 'pat'` / `ILIKE` / `NOT LIKE`
(SQL glob — `%` any run, `_` one char) and TaQL's `col ~ p/glob/`,
`~ m/regex/`, `~ f/regex/` operator (and `!~`), with `/ % @` delimiters
and an optional trailing `i` for case-insensitive — each compiled to a
Julia `Regex` mirroring casacore's `Regex::fromSQLPattern` /
`fromPattern`. The **closure form (`query(f, t)`) is unchanged** —
arithmetic and matching there are already plain Julia. Cross-checked
against real TaQL for a spread of arithmetic and pattern strings.

### Phase 25 — TaQL-lite functions

The string parser gains a curated
subset of TaQL's function library — `NAME(args...)`, case-insensitive,
with TaQL's own aliases: scalar math (`abs`, `sqrt`, `exp`, `log`/`ln`,
`log10`, trig, `floor`/`ceil`/`round`, `sign`, `int`, `pow`, `fmod`),
complex parts (`real`, `imag`, `arg`/`phase`, `conj`, `norm`),
array-cell reductions (`mean`/`avg`, `sum`, `product`, `median`,
`variance`, `stddev`, `rms`, `min`/`max`, `any`, `all`, `ntrue`/
`nfalse`, `nelements`/`count`, `ndim`), string ops (`strlength`/`len`,
`upper`/`lower`, `trim`/`ltrim`/`rtrim`), `isnan`/`isinf`/`isfinite`,
`iif(cond, a, b)`, `rownumber()` (1-based, matching TaQL's default
style), `pi()`, `e()`. Arithmetic and comparison now also broadcast
over an array-cell operand (`mean(abs(DATA - MODEL_DATA)) > 3`,
`ntrue(FLAG == True)`) — a top-level WHERE that yields an array still
errors, exactly as TaQL requires `any(...)`/`all(...)` there. New
stdlib dependency `Statistics`. The **closure form is unchanged**.
Cross-checked against real TaQL.

### Phase 26 — GROUP BY + aggregation

A new `groupby(t, groupcols;
select, where, having, orderby)` function — distinct from `query`
because the result shape (one row per group, computed aggregate
columns) is not a `RefTable`. `select` takes `outname => expr_string`
pairs where each expression may use `g`-prefixed aggregate functions
over the group — `gcount()`, `gsum(x)`, `gmean(x)`/`gavg(x)`,
`gmedian(x)`, `gmin`/`gmax`, `gvariance`/`gsamplevariance`,
`gstddev`/`gsamplestddev`, `grms`, `gany`/`gall`, `gntrue`/`gnfalse`,
`gfirst`/`glast` — plus the group-key columns and any scalar
expression of them (`gsum(X) / gcount()`). An aggregate's argument
must reduce to a scalar per row, so array cells compose through the
Phase-25 reductions: `"AMP" => "gmean(mean(abs(DATA)))"`. `where`
pre-filters rows; `having` filters groups; `orderby` sorts the result.
An empty `groupcols` gives one whole-table row.

The result is a `GroupedTable` — an in-memory `Tables.jl` source:
`result.OUTNAME` column access, `DataFrame(result)`, and persistence
via the existing `write_table(dst, "T", result; nrow=…)` with no new
machinery. Cross-checked against real TaQL's own `SELECT … GROUP BY …`.

### Phase 27 — closure-form `groupby`

For aggregates the `g*` set
can't express, `groupby` also takes Julia closures — the analog of
`query(f, t) do row … end`. A whole-group do-block returning a
`NamedTuple` (the output row):

```julia
groupby(ms.MAIN, [:ANTENNA1]; cols=["ANTENNA1", "DATA", "WEIGHT"]) do g
    (; ANT = first(g.ANTENNA1), N = length(g),
       WAMP = sum(mean.(abs, g.DATA) .* g.WEIGHT) / sum(g.WEIGHT))
end
```

`f(g)` receives a `GroupSlice` — `g.COLNAME` is a materialised vector of
that column's values for the group, `length(g)` the group size. A
closure can also appear as a `select=` RHS alongside strings/symbols
(`select = [:K => :K, "N" => "gcount()", "W" => g -> sum(g.X.^2)]`), and
`where` / `having` each accept a string **or** a predicate closure
(`row -> Bool` / `g -> Bool`). `cols=` restricts which columns are
loaded onto `g` (default: all of `t`). Same `GroupedTable` output.

### Phase 28 — joins

`join(left, right; on, rightcols, …)` (a method
added to `Base.join`) does an **N:1 lookup join** — each `left` row is
matched to at most one `right` row and the chosen `right` columns are
pulled in per left row. This is TaQL's own `JOIN … ON` semantics, not a
general cross product, and it's exactly what an MS needs: `ANTENNA1` /
`FIELD_ID` / `DATA_DESC_ID` in `MAIN` are keys into the subtables.

```julia
join(ms.MAIN, subtable(ms, "ANTENNA");
     on = "ANTENNA1",                       # 0-based row index into ANTENNA
     rightcols = ["NAME" => "ANT_NAME", "POSITION" => "ANT_POS"],
     where = "ANT_NAME ~ p/DA*/")
```

`on` is a column name (that left column is a 0-based row index into
`right` — the MS convention), a `"LKEY" => "RKEY"` pair (equi-join on a
unique right key), or a vector of pairs (composite key). `rightcols` /
`leftcols` pick and rename columns (`"src" => "out"`, DataFrames-style;
`leftcols` defaults to every left column). `where` filters the
assembled result (a string over the *output* names, or a `row -> Bool`
closure); `orderby` sorts it; `unmatched` is `:error` (default — throw
on a dangling key), `:drop`, or `:missing`. The result is a
`GroupedTable` whose columns are lazy `MappedColumn` views (zero-copy
even joining onto MAIN), cross-checked against real TaQL's `JOIN`.

### Phase 29 — chainable results

`GroupedTable` (the result of
`groupby`, `join`, or `query` on one of those) is itself an
`AbstractTable`, so every query verb feeds the next — a full pipeline:

```julia
join(ms.MAIN, subtable(ms, "ANTENNA"); on="ANTENNA1",
     rightcols=["NAME" => "ANT"]) |>
  r -> groupby(r, "ANT"; select=["ANT" => :ANT, "N" => "gcount()",
                                 "AMP" => "gmean(mean(abs(DATA)))"]) |>
  r -> query(r, "N > 100 ORDER BY AMP DESC")
```

`query` on a `GroupedTable` returns a materialised `GroupedTable`
("in-memory in, in-memory out"); `groupby` / `join` on one behave
exactly as on a disk table. Persist any result with
`write_table(dst, "T", r; nrow=nrow(r))`.

### Phase 30 — the write commands

`UPDATE` / `DELETE` / `SELECT INTO`,
over the Phase 9-11 `edit` primitives:

```julia
update!("/path/to.ms/ANTENNA"; set=["MOUNT" => "'ALT-AZ'"], where="STATION ~ p/PM*/")
delete!(subtable(ms, "FLAG_CMD"); where="APPLIED")
copytable("/tmp/cal.tab", query(ms.MAIN, "FIELD_ID == 3"))          # SELECT ... INTO
```

`update!(target; set, where)` — `target` is a path or an open `Table` /
`subtable(…)`; `set` is `"COL" => "expr"` pairs (TaQL-lite expressions
over the row's columns, evaluated against the *pre-update* values, so
`["A" => "B", "B" => "A"]` swaps); `where` is a WHERE string, a
`row -> Bool` closure, or `nothing` (every row). Returns the row count
changed. `delete!(target; where)` extends `Base.delete!`; `where=nothing`
empties the table. `copytable(dst, result)` persists any query /
`groupby` / `join` result (DM-preserving for a `RefTable`, materialised
for a `GroupedTable`) — that is `SELECT … INTO`.

### Phase 31 — INSERT

`insert!(target; values)` appends rows, over the
same `edit` / `addrows!` primitives:

```julia
insert!("/path/to.ms/ANTENNA"; values=(; NAME="DA99", DISH_DIAMETER=12.0))
insert!(ms.MAIN, query(other.MAIN, "FIELD_ID == 3"))               # INSERT ... SELECT
```

`values` is one row (`["A" => 1, "B" => 2.5]` or `(; A=1, B=2.5)`), a
vector of those, or any `Tables.jl` source (another table, a `query` /
`groupby` / `join` result, a `Vector{NamedTuple}`). Unsupplied columns
take their default (`0` / `""` / a same-shape zero array); scalars are
coerced to the target column's type. Extends `Base.insert!`. Returns the
row count inserted.

A `taql(target, "…")` string-command dispatcher wraps all four:
`taql(t, "UPDATE t SET UVW = UVW * 2 WHERE ANTENNA1 == 0")`,
`taql(t, "DELETE FROM t WHERE FLAG_ROW")`,
`taql(t, "SELECT A, B AS BB WHERE A > 5 INTO '/tmp/out'")`,
`taql(t, "INSERT INTO t (A, B) VALUES (1, 2.5), (3, 4.5)")` (VALUES must
be constant expressions).

Still, across Phases 22–31 (array indexing landed in Phase 42,
`BETWEEN` in Phase 43): no bitwise operators (`& | ^ ~`), `~=`, units,
date/time or measures functions, `GROUP BY ROLLUP`, the `gs*`
per-element aggregates, a general M:N cross-product join, `INSERT
LIMIT`, or `UPDATE` array-slice assignment.

### Phase 32 — docs / consolidation pass

Documentation, no behaviour change: a docstring on every one of the 53
exported bindings (`?nrow`, `?Table`, `?query`, …); the `README` cut from
a 31-paragraph phase log to a task-oriented "At a glance" + "Concepts" +
"Usage", with the phase-by-phase history moved to this `CHANGELOG`. Light
code consolidation — the two byte-identical `_arrayfile!` bodies now
share one helper; the casacore/TaQL `tableCommand` cross-check
boilerplate (six copies across four test files) collapsed to one
`_taqlcmd` helper.

### Phase 33 — Documenter.jl site (local build)

A `docs/` tree — `make.jl` + `Project.toml` + Home / Concepts / Guide /
API reference / Changelog pages — that builds with
`julia --project=docs docs/make.jl` (output in `docs/build/`, not
deployed). The API page is curated `@docs` blocks covering all 53
exports (`checkdocs = :exported`). No `deploydocs` / CI workflow / badge
yet (the GitHub repo slug is still a placeholder).

### Phase 34 — half-precision (ComplexF16) MAIN reads

MS visibility data is stored on disk as `ComplexF32` (a historical
choice) but derives from 8-bit-integer samples, so `ComplexF16` loses no
real information and halves the working-set size. A MAIN table's
`TpComplex` columns (`DATA`, `MODEL_DATA`, `CORRECTED_DATA`, …) now read
back as `ComplexF16` **by default**; the on-disk bytes are unchanged.

```julia
t = readtable("my.ms")
eltype(column(t, "DATA"))                    # Matrix{ComplexF16}
eltype(column(t, "DATA"; precision=:full))   # Matrix{ComplexF32}
readtable("my.ms"; precision=:full)          # every column wide
```

`TpFloat` columns (`WEIGHT`, `SIGMA`, `WEIGHT_SPECTRUM`) stay `Float32` —
real weights routinely exceed `Float16`'s 65504 range; `Float64`
(`TIME`, `UVW`), `ComplexF64` and `Bool` are never narrowed. Non-MAIN
tables default to `:full`. `readtable(...; precision=…)`,
`MeasurementSet(...; precision=…)` and `column(t, name; precision=…)`
override; an explicit `column(...; precision=:half)` narrows a `TpFloat`
column too (the caller's risk). `copyms` / `write_ms` / `copytable` and
`edit` always read the source at full precision, so copies stay
byte-exact.

### Phase 35 — decode straight into the narrow type

A follow-up to Phase 34: the whole-column read (`column(t, "DATA")[:]`)
now threads the target element type through the storage-manager decode
path (a new `astype` keyword on the `getcolumn` family — `TiledStMan`,
`DyscoStMan`, `StandardStMan`, the virtual engines, `IncrementalStMan`),
so a narrowed column decodes straight into a `ComplexF16` buffer instead
of building a `ComplexF32` one and converting. No API or value change;
the `:full` path (`astype === nothing`) is byte-identical to before. The
result buffer is half-size and there is no wide transient. Per-cell
reads (`col[i]`) keep the cheap post-convert.

### Phase 36 — `BFloat16` support

`precision` now accepts a **type**: `Float16` / `BFloat16` / `Float32`
(with `:half` / `:full` the existing default-behaviour aliases). New
dependency: `BFloat16s.jl`.

```julia
readtable("my.ms"; precision=BFloat16)    # DATA -> Complex{BFloat16}, WEIGHT -> BFloat16
```

`BFloat16` has `Float32`'s full exponent range, so it narrows `WEIGHT` /
`SIGMA` / `WEIGHT_SPECTRUM` without the overflow that keeps them at
`Float32` under `:half` / `Float16` — and its 7-bit mantissa matches
8-bit-derived data. `readtable(ms; precision=BFloat16)` (or
`MeasurementSet(...; precision=BFloat16)`, or `column(t, name;
precision=BFloat16)`) narrows **every** `TpFloat`→`BFloat16` and
`TpComplex`→`Complex{BFloat16}` MAIN column. **The default is
unchanged** — `DATA` → `ComplexF16`, `WEIGHT` stays `Float32`. `Float64`
/ `ComplexF64` / `Bool` are never narrowed. Copies and edits still read
the source at full precision; a `BFloat16` column writes back as
`TpFloat` (upcast to `Float32` on disk).

### Phase 37 — `HDF5` is now a weak dependency

`HDF5.jl` (a wrapper over the C `libhdf5`) was a hard dependency since
Phase 20, only ever used for `MultiHDF5` (`table.mfh5`) container tables.
It is now a **weak dependency**: the MultiHDF5 code lives in
`ext/MeasurementSetsHDF5Ext.jl`, a package extension that loads only
when you `import HDF5` yourself. A plain `using MeasurementSets` pulls
in no C libraries. Reading or writing a `table.mfh5` without `HDF5`
loaded raises a clear, actionable error (`... run `import HDF5` first`).
`MultiFile` (`table.mf`, pure Julia) is unaffected.

### Phase 39 — renamed `MeasurementSetv2` → `MeasurementSets`

The package, module and repo are now **`MeasurementSets`** (plural). The
"v2" was version noise. The plural keeps `struct MeasurementSet` (the
`MeasurementSet(path)` MS-directory wrapper) from colliding with the
module — `using MeasurementSets; ms = MeasurementSet("/path")` — the
idiomatic Julia split (`Dates`/`Date`). Pure rename: same UUID, no API
or behaviour change, all tests green. The test-only environment variables
are now `MEASUREMENTSETS_TEST_MS` / `MEASUREMENTSETS_CASA_PYTHON`, and
the HDF5 extension is `MeasurementSetsHDF5Ext`.

### Phase 40 — `BitFlagsEngine` + `ForwardColumnEngine`

The two remaining virtual engines Phase 12 left out.

**`BitFlagsEngine<StoredType>`** — an `Array{Bool}` column (e.g. `FLAG`)
mapped onto a stored integer column, one bit per flag category:
`virtual[i] = (stored[i] & readMask) != 0`. Read + write. The mask is
either the numeric `_BitFlagsEngine_ReadMask` keyword or, when
`ReadMaskKeys` names entries in the stored column's `FLAGSETS` record,
the OR of those. Write stores raw `0`/`1` (matching casacore's actual
`putArray` — the write mask is not applied). Create one with
`write_table(dir, "T", ["FLAG" => cubes]; engines = Dict("FLAG" =>
(; kind = MeasurementSets.BitFlags(), stored_type = MeasurementSets.TpInt)))`;
`copyms` / `copytable` preserve it.

**`ForwardColumnEngine`** — a column that forwards every read to a
same-named column in another table (no data of its own).
`reference_copy(dst, src; writable = [...])` builds a table whose columns
are all forwards to `src`, except those named in `writable` (real
independent copies) — casacore's `MSTableImpl::referenceCopy`. `edit` of
a forward table is refused (edit the source); `copyms` / `copytable`
materialise the forwards into a plain independent table.

`RetypedArrayEngine` and `ForwardColumnIndexedRowEngine` stay
unsupported — a clear error names them; neither occurs in a standard MS.

### Phase 41 — `VirtualTaQLColumn`

casacore's "CALC column": a column whose per-row value is a stored TaQL
expression evaluated against the table's own columns (a constant-valued
MS column, or on-the-fly derived data). Read + write.

Read evaluates the stored `_VirtualTaQLEngine_CalcExpr` keyword with the
Phase 22-25 TaQL-lite engine — a constant expression is computed once,
a column-referencing one per row. An expression using a TaQL feature
TaQL-lite doesn't support (units, date/time or measures functions)
raises a clear `ArgumentError` naming the column and expression **when
that column is read** — the rest of the table opens fine.

Write: `write_table(dir, "T", [..., "CV" => zeros(n)]; nrow = n,
virtualtaql = Dict("CV" => "TIME - 4.6e9"))` declares the column and
stores the expression (the passed values are ignored). `copyms` /
`copytable` preserve a `VirtualTaQLColumn` by re-emitting the
expression. `edit` of such a table is refused (edit the source
columns). `CCT.Table` reads a `VirtualTaQLColumn` our writer produces —
genuine round-trip interop, since casacore auto-registers the engine.

### Phase 42 — TaQL-lite array indexing + slices

Array-cell element and slice indexing in every TaQL-lite expression:
`UVW[3]`, `FLAG[1,1]`, `DATA[1:4,1]`, `V[:,1]`, `V[1:8:2,1]`,
`X[1][2]` (chained), `V[rownumber(),1]` (expression subscripts).
**1-based** — matching casacore's default TaQL style (the `tableCommand`
cross-checks), Julia, and TaQL-lite's 1-based `rownumber()`. A colon
range is casacore's `start:end:step` (end before step), inclusive both
ends; a bare axis / trailing comma / missing trailing axes = whole
axis; a scalar subscript drops that dimension.

This lands in `query` / `groupby` / `join` WHERE and SELECT, the
`update!` SET RHS, and — for free — `VirtualTaQLColumn` CALC
expressions (Phase 41). Verified against real TaQL via `tableCommand`
(1-based, inclusive-range and end-before-step all agree) and, for the
engine path, against `CCT.Table` decoding `virtualtaql=Dict("W" =>
"UVW[3]")`.

Not supported: boolean-mask subscripts (`DATA[FLAG]`), negative /
`end`-relative indices (omit the range end to mean "to the end"), and
assigning *into* an indexed cell.

### Phase 43 — TaQL-lite `BETWEEN`

`x BETWEEN lo AND hi` (inclusive both ends, matching casacore's
left/right-closed range) and `x NOT BETWEEN lo AND hi`, in every
TaQL-lite expression surface. `lo`/`hi` are arithmetic expressions
(`B BETWEEN A - 1 AND A`); `x` may be an array cell (elementwise). Binds
at the comparison level, so `x BETWEEN a AND b OR c` groups as
`(x BETWEEN a AND b) OR c`. Verified against real TaQL via
`tableCommand`.
