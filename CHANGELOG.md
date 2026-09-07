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
`BETWEEN` in Phase 43, bitwise in Phase 46, `~=` in Phase 47): no
units, date/time or measures functions, the `gs*` per-element
aggregates, `INSERT LIMIT`, or `UPDATE` array-slice assignment.

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
`ext/HDF5Ext.jl`, a package extension that loads only
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
the HDF5 extension is `HDF5Ext`.

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

Not supported: boolean-mask subscripts (`DATA[FLAG]`) and assigning
*into* an indexed cell. (Negative / `end`-relative indices landed in
Phase 44.)

### Phase 43 — TaQL-lite `BETWEEN`

`x BETWEEN lo AND hi` (inclusive both ends, matching casacore's
left/right-closed range) and `x NOT BETWEEN lo AND hi`, in every
TaQL-lite expression surface. `lo`/`hi` are arithmetic expressions
(`B BETWEEN A - 1 AND A`); `x` may be an array cell (elementwise). Binds
at the comparison level, so `x BETWEEN a AND b OR c` groups as
`(x BETWEEN a AND b) OR c`. Verified against real TaQL via
`tableCommand`.

### Phase 44 — TaQL-lite negative / `end`-relative array indices

`V[-1]` / `V[-2,1]` — a negative subscript counts from the end
(`-1` == last), matching casacore's `Slicer` semantics, and
`sum(V[-2:-1,1])` for the last two along an axis. Plus an `end` keyword
(Julia-idiomatic, no casacore equivalent) usable in any subscript
expression: `V[end,1]`, `V[end-2:end,1]` — `end` resolves to that
axis's length. `end` outside a subscript raises a clear error. A
non-positive slice step is rejected (casacore does too).

Negative indices are cross-checked against real TaQL via `tableCommand`;
`end` is exercised only against a hand-computed reference (no TaQL
equivalent).

### Phase 45 — committed small MS test fixture

The data-dependent tests used to run only where a hard-coded 20 GB real
ALMA MS lived. They now run everywhere against a small **committed
fixture** — `test/data/sample.ms` (~4 MB), a 600-row `copyms` slice of a
real MS (POINTING / SYSPOWER capped at 150 rows; every other subtable
kept whole; the SM mix and `(4,64)` cell shape preserved). Regenerate it
with `test/gen_sample_ms.jl`.

`write_ms` / `copyms` gained a `subtable_rows` kwarg (subtable name → row
range) for the slicing. **Bugfix along the way:** `write_ms` / `create_ms`
wrote subtable-keyword paths as `./NAME` (a sibling) instead of casacore's
`././NAME` (inside the table dir) — our own lenient reader coped, but
`CCT.Table(ms).ANTENNA` (real casacore MS subtable access) failed. Now
fixed. `SAMPLE_MS` defaults to the fixture;
`MEASUREMENTSETS_TEST_MS` still points the tests at a full MS when set —
the row/dimension assertions were made relative to `nrow(t)` so both
work. (`FLAG_CATEGORY` / `WEIGHT_SPECTRUM` are defined-but-never-written
in the source and don't survive a `copyms`; the fixture re-adds the
schema-required `FLAG_CATEGORY` as an empty column.)

### Phase 46 — TaQL-lite bitwise operators

Binary `&` `|` `^` and unary `~`, in every TaQL-lite expression surface.
Integer bitwise semantics; elementwise over an array cell. Precedence
matches casacore: above comparisons, below `+`/`-`, with `|` < `^` < `&`.
`^` is **xor** (not exponentiation) — `**` stays for power; the old
"`^` is not supported, use `**`" error is gone. A bare `~` before a
`p/…/` `m/…/` `f/…/` literal is still the glob/regex match operator (the
tokenizer only treats `~` as bitnot when no pattern literal follows).
Verified against real TaQL via `tableCommand` (precedence, `^`=xor,
`~`=bitnot all agree).

### Phase 47 — TaQL-lite approximate equality (`~=` / `!~=`)

`x ~= y` / `x !~= y` — casacore's `near(x, y, 1e-5)` and its negation:
a relative tolerance, with the same zero / opposite-sign special cases
casacore uses (`Math.cc` / `Complex.cc`). Real, complex, and array-cell
operands. Verified against real TaQL via `tableCommand`. One deliberate
divergence: casacore's `near(Int, Int)` compares `|a|-|b|` rather than
`|a-b|` (making `3 ~= 4` true) — TaQL-lite uses the same relative form
for integers as for floats.

### Phase 48 — `groupby` ROLLUP

`groupby(t, cols; select, rollup = true)` (and the closure form) adds
SQL `GROUP BY ROLLUP` subtotal rows: the detailed groups, then one
level per trailing key dropped, ending with the grand total. In a
subtotal row the aggregated-away key columns are `missing` (so those
result columns become `Union{T, Missing}`). A bare key select entry
emits `missing`; a closure builds its key fields from the new `g.keys`
NamedTuple — `(; g.keys..., N = length(g))` — which already carries the
`missing`s. `GroupSlice` also gained `g.level` (active-key count).

casacore parses `GROUP BY ROLLUP` but throws "not supported yet", so
this is plain SQL semantics with no real-TaQL cross-check.

### Phase 50 — `groupby` CUBE / GROUPING SETS

Generalises Phase 48's `rollup`: `groupby(t, cols; select, cube = true)`
computes **every** key subset (not just prefixes); `grouping_sets =
[("K1","K2"), ("K1",), ()]` computes exactly the sets you name (`()` =
grand total). At most one of `rollup` / `cube` / `grouping_sets`.
Aggregated-away keys are `missing` as before. `GroupSlice` now carries
the active-key *set* (not a prefix count): `g.keys` / `g.level` still
work, and a new `g.grouping` NamedTuple gives SQL `GROUPING()` — `true`
for a key rolled up in that row (also a string-grammar function since
Phase 51). casacore parses these but doesn't implement them; plain SQL
semantics, no cross-check.

### Phase 51 — `GROUPING()` in the string grammar

`GROUPING(K)` is now a function usable in a `groupby` `select` or
`having` **string** (not just `g.grouping.K` in a closure) — `true`
when key `K` is rolled up in that row. The classic uses:
`select = ["label" => "iif(GROUPING(K2), 'ALL', K2)", …]` and
`having = "GROUPING(K1) == 0"`. It takes exactly one bare grouping-key
column name, is resolved to a constant per grouping set (an AST
rewrite, like Phase 44's `end`), and is rejected outside a group
context (in a plain `query` / a `where`).

### Phase 49 — M:N joins

`join(left, right; on = "LK" => "RK", ..., multi = true)` is a general
M:N equi-join — one left row can match many right rows. `unmatched`
sets the join type: `:drop` = inner, `:missing` / `:left` = left outer,
`:right` = right outer, `:full` = full outer, `:error` = every left row
must match ≥ 1. Unmatched rows on either side get `missing` in the
other table's columns (those output columns materialise; matched
columns stay lazy `MappedColumn` views). Row order is left-row order,
then right-match order, then the unmatched right rows.

The default (`multi = false`) is unchanged — the Phase-28 N:1 lookup
join, still the only form that takes an index-lookup `on` (a bare
column name) or requires a unique right key.

### Phase 52 — `gs*` per-element aggregates

`groupby` `select` strings gained the `s`-suffixed aggregate variants
(`gsums`, `gproducts`, `gmeans` / `gavgs`, `gvariances` /
`gsamplevariances`, `gstddevs` / `gsamplestddevs`, `grmss`, `gmins`,
`gmaxs`, `ganys`, `galls`, `gntrues`, `gnfalses`). Where `gmean(x)`
reduces one scalar-per-row value over a group, `gmeans(x)` takes the
group's array cells (all the same shape) and reduces them
**elementwise**, giving one array — e.g. `"gmeans(V)"` is the per-cell
mean spectrum over a group. Reuses the existing `TQLAggr` node; no
parser or AST change. Cross-checked against real casacore for
`gsums` / `gmeans` / `gmaxs` / `gstddevs`.

### Phase 53 — `INSERT … LIMIT`

`insert!(target; values, limit = nothing)` gained a `limit` kwarg (TaQL's
`INSERT … LIMIT n`). `nothing` / `0` keeps the old behaviour (one row per
`values` row); a positive `limit` appends exactly that many rows, cycling
through the `values` rows; a negative `limit` appends `nrow(target) +
limit` rows (also cycling), clamped at zero — matching casacore's own
`nrow = table.nrow() + limit_p`. The `taql` string form parses both
`INSERT INTO t … VALUES (…) LIMIT n` (trailing) and `INSERT LIMIT n INTO
t …` (prefix); the lite-only `INSERT … SET` form accepts `LIMIT` in
either position too. Cross-checked against real TaQL for the VALUES
forms (positive, cycling, prefix, and negative limits).

### Phase 54 — `UPDATE` array-slice assignment

`update!`'s `set` key can now be an array-slice target,
`"COL[subscripts]" => "expr"` (TaQL's `UPDATE … SET NAME[i,j] = …`) —
1-based, with `end`-relative and range subscripts as in [`query`](@ref).
It reads the target cell at full precision, writes only the addressed
sub-region, and leaves the rest of the cell (and unmatched rows)
untouched; a scalar RHS fills the slice. Multiple slice assignments to
one column in a single `update!` are applied in order to the same cell
(a later one doesn't clobber an earlier one), and a whole-column
assignment may precede slice assignments to the same column. `taql`'s
`UPDATE … SET` parses the bracketed LHS. Cross-checked against real TaQL
for scalar, range, negative-index, and cross-referencing slice RHS.
Boolean-mask subscripts and the `(col, maskcol) = …` paired form remain
non-goals.

### Phase 55 — `UPDATE` boolean-mask assignment

`update!` / `taql`'s `UPDATE … SET` now also accept a boolean-mask
subscript, `SET col[maskexpr] = expr` — assign only where the mask
(a Bool array conforming to the cell, a column or an inline expression
like `V > 5.0`) is true. The slice + mask two-bracket form works in
either order: `col[slice][mask]` (mask conforms to the section) and
`col[mask][slice]` (mask conforms to the cell, then sliced) — matching
casacore's `maskFirst` semantics. Single array subscripts in the query
grammar are now full expressions (so `V[V > 5]` parses), not just
arithmetic. The `(col, maskcol) = expr` paired form raises a clear
error — it needs masked-array-producing expressions, which TaQL-lite
does not have. Cross-checked against real TaQL for the mask, inline-mask
and slice+mask forms.

### Phase 56 — general non-equi join (predicate closure)

`join`'s `on` may now be a **2-arg predicate** `(lrow, rrow) -> Bool` —
a range / inequality / tolerance join, evaluated by a nested loop over
every `(left, right)` row pair. `lrow` / `rrow` support `row.COLNAME`.
`unmatched` sets the join type (`:drop` inner, `:missing` / `:left`,
`:right`, `:full`, `:error`) exactly as `multi = true`; `oncols =
(leftnames, rightnames)` restricts which columns are loaded onto the
predicate rows. It composes with `where` / `orderby` /
`leftcols` / `rightcols` like the other join forms. This is a
MeasurementSets extension — TaQL's own `JOIN … ON` is `==` / `IN` only,
so there is no cross-check — and it is O(nrow(left) × nrow(right)):
`query` / `select` each side down first for a large table.

### Phase 57 — computed output columns in `query`'s `select`

`query`'s `select` `"out" => rhs` pairs now accept a **computed
expression** as the `rhs` (`"X * 2"`, `"sqrt(abs(V))"`, `"iif(K==0, 1,
0)"` — the WHERE grammar, aggregates excepted). When every `rhs` is a
bare column name the result is still a lazy `RefTable` (unchanged); when
any is computed the result is an in-memory `GroupedTable` with those
columns evaluated per matched row. Works for the closure form and on a
`GroupedTable` input too. `taql`'s `SELECT` parses `expr AS alias`
(a computed column needs the `AS`). An aggregate in a `query` `select`
raises a clear error pointing at `groupby`.

### Phase 58 — `GroupedTable` as a `groupby` / `join` input

Since `GroupedTable <: AbstractTable` (Phase 29) and the query verbs are
generic, a `groupby` / `join` / `query` result already feeds straight
back into `groupby` or `join` — this phase adds a dedicated test set
(both sides `GroupedTable`, index-lookup / equi / `multi` / predicate
`on`, closure `groupby` with `cols=`, a computed-`select` result as
input, 3-verb deep chains, `write_table` round-trip of the final result)
and drops the stale "use `Tables.columntable`" non-goal. No code change.
`edit` / `write_ms` / `copyms`-as-MAIN still need a plain on-disk
`Table`.

### Phase 59 — `UPDATE SET (col, maskcol) = expr`

`update!`'s `set` key can be a `(datacol, maskcol)` tuple (TaQL's
`SET (NAME, MASKNAME) = …`). `("D", "M") => "dexpr"` writes `dexpr` to
`D` and a non-finite flag (`!isfinite`, element-wise) of the result to
`M`; `("D", "M") => ("dexpr", "mexpr")` writes an explicit mask
expression to `M` instead. Either name may be a slice / mask target.
`taql`'s `UPDATE … SET` parses `(D, M) = dexpr` and
`(D, M) = (dexpr, mexpr)`. Since TaQL-lite has no masked-array
expressions the data and mask are given explicitly — a documented
divergence from casacore, which writes `expr`'s own attached mask, so
there is no cross-check. New `nonfinite(x)` / `isnonfinite(x)` function
(element-wise `!isfinite`) is available in expressions generally.

### Phase 60 — masked arrays in the expression engine

A `TQLMArray` value type (data + a `true`-means-masked-out Bool mask,
casacore's `MArray`). `V[boolexpr]` in an expression now yields the
whole cell with `!boolexpr` masked out (not a flat selection);
`marray(d, m)` / `arraydata(m)` / `arraymask(m)` build and unpack one.
Reductions (`sum` / `mean` / `min` / `max` / `median` / `variance` /
`stddev` / `rms` / `any` / `all` / `ntrue` / `nfalse`) skip masked
elements, `nelements` counts the unmasked ones, and arithmetic
propagates the mask (union). So `mean(V[!FLAG])`,
`gmax(mean(V[FLAG]))` (a masked reduction inside a `g*` aggregate), and
`SET (D, M) = V[goodcond]` (writes `V`'s data and the `!goodcond` mask
to the companion column — the faithful form Phase 59 approximated) all
work. A computed `select` column of masked arrays persists as plain
data (`arraymask(expr)` for a separate mask column).

### Phase 61 — `SELECT expr AS (val, mask)`

`query`'s `select` `("valname", "maskname") => "expr"` pair form (and
`taql`'s `SELECT expr AS (v, m)`) emits **two** output columns from a
masked-array expression — the data and the mask. So
`query(t; select = [("D", "F") => "marray(DATA, FLAG)"])` reads a
column together with its mask column, and `taql(t, "SELECT V[V > 0] AS
(D, M)")` splits a masked selection into data + mask. A non-masked RHS
gives a non-finite flag for the mask column (consistent with Phase 59).
casacore has no on-disk column↔mask association — the mask is always
named, so `marray(col, maskcol)` *is* "read a masked column".

### Phase 62 — masked `g*` aggregates (first-class)

A `g*` aggregate with a masked-array argument now reduces over the
group's **unmasked** elements: scalar `g*` (`gmean` / `gsum` / `gmin` /
`gmax` / `gmedian` / `gstddev` / `grms` / `gany` / `gall` / `gproduct`)
pools every row's unmasked elements into one flat reduction —
`gmean(V[!FLAG])` is the mean of every unflagged visibility in the
group — and per-element `gs*` reduces per cell position over the rows
where that cell is unmasked (`gmeans(V[!FLAG])` = the per-cell mean
spectrum, flagged cells ignored; an all-masked cell → NaN/0/false).
The 14 Phase-52 `gs*` closures collapse to one generic
`_perelem_reduce` sharing the non-`s` scalar reducer (so `gproducts` is
a genuine per-cell product, no matmul). `NOT` now broadcasts, so
`V[!FLAG]` and `NOT FLAG` negate an array-cell mask elementwise.
casacore's own masked-`g*` semantics are murky (no reliable
cross-check) — the pooled-unmasked interpretation is the clean one.

### Phase 63 — string `L.` / `R.`-qualified non-equi join condition

`join`'s `on` can now be a **string** — a TaQL-lite expression with
`L.` / `R.` table-qualified column references,
`join(l, r; on = "L.TIME BETWEEN R.T0 AND R.T1")`. It is the
declarative form of the Phase-56 predicate closure: same nested loop,
same O(N×M) cost, same `unmatched` join-type semantics. Must reference
at least one `L.<col>` and one `R.<col>` (aggregates rejected); a
bare-identifier `on` string is still the Phase-28 index-lookup join.
The tokenizer now lexes one optional `.suffix` on an identifier.
TaQL has no cartesian non-equi join, so no cross-check.

### Phase 64 — `src/` restructured into subdirectories

Pure refactor, no behaviour change. `src/` is now organised into
`io/` (the `aips.jl` / `lock.jl` wire-format codecs), `tables/` (the
CTDS type system + table model + I/O: `typeenum.jl`, `record.jl`,
`table.jl`, `column.jl`, `interface.jl`, `writer.jl`, `create.jl`,
`edit.jl`, `resync.jl`), `datamanagers/` (unchanged), and `taql/`
(below); only the module file and the two MS-domain files
`measurementset.jl` / `schema.jl` stay at the top.
`MeasurementSets.jl`'s include list keeps its existing order
(dependencies force table files to interleave with the `datamanagers/`
and `taql/` includes), just gaining directory prefixes.

The ~2300-line `src/query.jl` and `src/write_commands.jl` become the
`src/taql/` directory:
`ast.jl` (nodes + visitors + `_bcast` + masked arrays + indexing),
`parse.jl` (tokenizer + parser + operator tables + pattern→regex),
`functions.jl` (function / aggregate registries + `_make_func`),
`query.jl` (ORDER BY + `select` + `query(::AbstractTable)`),
`groupby.jl` (`GroupSlice` / `GroupedTable` / `groupby` + `_geval`),
`join.jl`, and `commands.jl` (`update!` / `delete!` / `insert!` /
`taql`). `taql/taql.jl` includes the first six; `commands.jl` stays
included last (it builds on `edit` / `create` / `resync`). Test files
renamed to `taql_query_tests.jl` / `taql_command_tests.jl`. The
`_select_spec` helper also moved from `table.jl` to `taql/query.jl`,
so the whole query engine — parser, evaluators, verbs, write commands —
now lives under `src/taql/`; `create.jl` / `resync.jl` / `edit.jl`
keep only thin `GroupedTable` / `VirtualTaQLColumn` dispatch adapters.

### Phase 65 — physical units (Unitful weak-dependency extension)

`import Unitful, UnitfulAngles, UnitfulAstro` loads
`UnitfulExt`, which maps a column's `QuantumUnits`
keyword onto a `Unitful` unit:

```julia
columnunit(t, "CHAN_FREQ")   # u"Hz"
qcolumn(t, "UVW")            # the whole column as `… m` quantities (materialised)
```

`UnitfulAngles` supplies casacore's angle vocabulary (`arcsec`, `mas`,
`°`), `UnitfulAstro` the astronomy units (`Jy`, `pc`, `AU`), and the
extension registers the dimensionless "pseudo-units" casacore uses that
no Julia package provides — `beam`, `pixel`, `channel`, `count`, `adu`,
`lambda`, `klambda` (so `Jy/beam` parses to `Jy beam⁻¹`). The
string-normalisation layer (`_normalize_unit`, always loaded) handles
casacore's `.`-as-multiply, `%`/`%%`, and the FITS/long-form aliases.

`MeasurementSets.UNITS_NO_JULIA_COUNTERPART` documents every casacore
unit without a third-party Julia implementation and how it is handled:

| kind | units | handling |
|---|---|---|
| `:pseudo` | `beam` `pixel` `channel` `count` `adu` `lambda` `klambda` | registered dimensionless by the extension |
| `:nounits` | `_`, `""` | `Unitful.NoUnits` |
| `:unsupported` | `WU` `FU` `fu` `cy` `deg_2` `sq_deg` | clear error + suggested replacement |
| `:dimension` | `rad` `sr` | dimensionless here; base dimensions in casacore |

**Divergence from casacore:** angles are SI-dimensionless
(`dimension(u"rad") == NoDims`) — `UnitfulAngles` gives the unit names
and all angle↔angle / angle↔scalar conversions, but not casacore's
treatment of angle as a base dimension. `DimensionfulAngles.jl` is the
strict alternative.

Read-side only for now. TaQL unit literals (`3km`, `10arcsec`) and
writing `QuantumUnits` from Unitful-typed columns are follow-ups.

### Phase 66 — measures / reference frames (SOFA weak-dependency extension)

A measure-valued column declares its physical quantity and reference
frame in a `MEASINFO` keyword. `src/measures/` (always loaded) parses it
and reads a cell as a typed value:

```julia
measinfo(t, "CHAN_FREQ")           # MeasInfo(:frequency, …, VarRefCol = "MEAS_FREQ_REF", …)
measure(main, "TIME", 1)           # MEpoch{UTC}(60454.4… d)
measure(subtable(ms, "FIELD"), "PHASE_DIR", 1)   # MDirection{J2000}(…, …)
```

`import SOFA` loads `SOFAExt` (pure-Julia
[`SOFA.jl`](https://github.com/JuliaAstro/SOFA.jl) v2, IAU SOFA port),
which converts between frames; `import EarthOrientation` additionally
loads `EarthOrientationExt` for IERS ΔUT1 / polar motion:

```julia
fr = MeasFrame(epoch = measure(main, "TIME", 1),
               position = measure(subtable(ms, "ANTENNA"), "POSITION", 1),
               direction = measure(subtable(ms, "FIELD"), "PHASE_DIR", 1))

measconvert(measure(main, "TIME", 1), TAI)                 # epoch:  UTC → TAI
measconvert(MDirection{J2000}(2.0, 0.5), AZEL; frame = fr) # direction
measconvert(MFrequency{TOPO}(100e9), LSRK; frame = fr)     # frequency (radio/relativistic Doppler)
```

- **Epoch** `UTC`/`TAI`/`TT`/`TDB`/`UT1`; **direction** `J2000`/`ICRS`/
  `B1950`/`APP`/`GALACTIC`/`ECLIPTIC`/`AZEL`/`AZELGEO`/`HADEC`/`ITRF`;
  **frequency** `TOPO`/`GEO`/`BARY`/`LSRK`/`LSRD`/`GALACTO`.
- Velocity-frame constants copied verbatim from casacore
  `MeasTable.cc`; every conversion cross-checked against
  `casatools.measures()` (epoch < 1 µs, direction < 5″, frequency < 1 Hz
  on 100 GHz).
- Without `EarthOrientation.jl`: ΔUT1 = 0, no polar motion (~1″), a
  one-time warning. `J2000` is treated as `ICRS` (~0.02″ frame bias).

Write path: `write_table(dir, name, cols; measures = Dict("D" => (;
kind = :direction, ref = "J2000")))` (or the per-row `(; kind,
varrefcol, tabtypes, tabcodes)` form) stamps a `MEASINFO` keyword;
`copyms` / `copytable` round-trip it verbatim.

Non-goals: solar-system-body direction frames (`SUN`/`MOON`/planets),
`MeasComet` / ephemeris tables, `MBaseline` / `MEarthMagnetic`,
standalone `MDoppler`, `RefOff` application, pulsar-timing-grade
precision, TaQL measures *functions*, in-place `MEASINFO` edit.

### Phase 67 — GitHub / CI wiring for the JuliaAstro repository

The package moved to
[`github.com/JuliaAstro/MeasurementSets.jl`](https://github.com/JuliaAstro/MeasurementSets.jl).
The stale `Paul Barrett` owner in the README CI badge and the `docs/make.jl`
`repo` / edit links were fixed, and the git remote re-pointed.

- **`.github/workflows/CI.yml`** gains a `docs` job
  (`julia-actions/julia-docdeploy`) — builds the Documenter site and
  deploys it (stable + dev + PR previews) via the `DOCUMENTER_KEY`
  secret that `TagBot.yml` already references — plus a coverage upload on
  the `test` job (`julia-actions/julia-processcoverage` +
  `codecov/codecov-action`).
- **`.github/workflows/CompatHelper.yml`** added (the canonical Julia
  `[compat]`-bumping bot, root + `docs/`).
- **`.github/dependabot.yml`** trimmed to the `github-actions` ecosystem
  only — CompatHelper now owns the Julia dependency updates.
- **README** badge rows: `docs-stable` / `docs-dev` on the first,
  CI / codecov / MIT-license on the second.
- `docs/make.jl` `deploydocs` guarded on `CI`, with
  `versions = ["stable" => "v^", "v#.#", "dev" => "dev"]`, matching the
  JuliaAstro convention.

No source or test changes; the suite is unchanged at 2591.

### Performance — bulk column reads in the query engine and `measure`

Two hot paths were re-decoding storage-manager cells one at a time inside
a per-row loop:

- **`measure(t, col)`** (whole-column) re-parsed the `MEASINFO` keyword
  and re-resolved the frame *every row*, and read the value cell by cell.
  Now it parses once and bulk-reads the value column (and the `VarRefCol`
  code column) via the column's own whole-column fast path.
- **`query` / `groupby` / `update!` / `delete!`** loaded the columns a
  `WHERE` / `GROUP BY` / `SET`-RHS touches as lazy `Column`s and indexed
  `col[i]` per row — for an `IncrementalStMan` column (most MAIN
  metadata: `TIME`, `FIELD_ID`, `SCAN_NUMBER`, …) that re-walks the
  bucket index on every access. A new `_load_col` materialises each
  referenced **scalar** column once before the loop (array-valued
  columns stay lazy, so a predicate over a big cube column still
  streams). Orders-of-magnitude faster on a real-sized table; bounded
  extra memory (a `WHERE` usually references 1–3 scalar columns).

No API or behaviour change.

### Performance — tiled reads no longer box every element

`reinterpret(T, ::Vector{UInt8})` followed by per-element indexing is an
allocating slow path in Julia when `sizeof(T) > 1` (each access boxes a
`ReinterpretArray` value). Every `TiledStMan` read went through it:

- `getcell` on a `DATA` cell allocated **~144 KB** (the cell is 2 KB);
  `column(t, "DATA")[:]` allocated ~22 KB/cell.

`read_plane` / `read_cube_whole` / `_read_cube_bulk` now copy each
contiguous on-disk run with `unsafe_load` over a pinned pointer
(`_rd_run!`, handling `Real` and `Complex` endianness). Measured on the
fixture MS: `DATA` `getcell` **144 KB → ~3 KB/cell**, `UVW` 2.0 → 0.9 KB,
`DATA[:]` bulk 22 → 2.2 KB/cell. The `RefTable` / partial-`rows=`
materialise path (always per-cell) benefits directly.

Also: the tile-layout computation (`sortperm` + allocation) is memoised
per tileshape on the `TiledStMan` instead of recomputed on every
`read_plane`; fixed-size index vectors became `NTuple`s; and the
`SOFA` extension uses `StaticArrays` `SVector` for its 3-vector / rotation
math (`StaticArrays` added as a weak dependency — it is already a
transitive dependency of `SOFA.jl`, so `import SOFA` still activates the
extension).

No API, return-type, or behaviour change. 2592 tests.

### Phase 69 — TaQL-lite quantity literals + date/time & angle functions

The string expression grammar (shared by `query` / `groupby` / `join` /
`update!` / `VirtualTaQLColumn` CALC) gains two loosely-coupled features.

**Quantity literals.** `1.4GHz`, `10arcsec`, `30deg` — a number token
immediately followed (no space) by a unit. Compared against a column
that carries a `QuantumUnits` keyword, the comparison goes through
Unitful: `query(spw, "CHAN_FREQ > 1.4GHz")`. When an expression uses a
quantity literal, every referenced unit-bearing column is loaded with
its unit attached, so a bare-number comparison against such a column
then raises a `DimensionError` (casacore's "units do not conform" — a
deliberately stricter reading; only bites when bare and unit literals
are mixed against one column). A computed `select` / CALC expression
whose result is a dimensionless quantity (`"CHAN_FREQ / 1GHz"`) is
stripped to a plain number; a dimensional result errors. An `update!`
SET RHS that evaluates to a quantity is converted to the target
column's unit. Needs the Unitful extension (`import Unitful,
UnitfulAngles, UnitfulAstro`); the parser errors clearly without it.

**Date/time + angle functions** (pure, no weak-dep gating — `Dates`
stdlib + trig). Every date value is an **MJD `Float64`** (days), so
`_bcast` / `isless` / `ORDER BY` all keep working:

- `datetime('2020-02-12')` / `datetime()` / `mjd(x)` / `mjd()` /
  `mjdtodate(x)` / `date(x)` / `time(x)`
- `year` / `month` / `day` / `week` / `weekday` / `dow`
- `cdate` / `ctime` / `cmonth` / `cdow` / `ctod` (formatted strings)
- `hms(rad)` / `dms(rad)` — sexagesimal strings
- `normangle(rad)` — wrap to `(−π, π]`
- `angdist` / `angdistx` — great-circle distance, `angdist(lon1, lat1,
  lon2, lat2)` or `angdist([lon1, lat1], [lon2, lat2])`

**Also:** general array literals `[a, b, c]` in any expression position
(not just `IN`); scientific-notation number literals (`1.4e9`, `1e-9`)
— previously an "unknown column" error.

**Non-goals:** measure literals / a `TQLMeasure` node (casacore core
TaQL has none); `mscal.azel()` / measures-frame functions; the
multi-point (2N-element) `angdist` array form; a `BigFloat` / `Float128`
high-precision MJD variant (considered, deferred); the spaced postfix
`3 km` unit form (no-space `3km` only); input angle literals (`30d15m`
as a value — only the `hms(rad)` *function*).

2638 tests.

### Phase 70 — write `QuantumUnits` / `MEASINFO` from typed columns

The write side of Phases 65-66/69, previously asymmetric: a `write_table`
column could only get a `QuantumUnits` / `MEASINFO` keyword from an
explicit `measures = Dict(...)` kwarg with hand-written unit strings; a
column whose Julia element type was *already* a `Unitful.Quantity` or a
`Measure` hit a bare `MethodError`.

Now such a column is **automatically** stored as plain numbers on disk
with the right keyword stamped, so `write_table` → `readtable` →
`qcolumn` / `measure` round-trips:

- A `Unitful.Quantity` column (scalar or array-cell) is `ustrip`ped to
  its first element's unit and gets `QuantumUnits` stamped. A new
  `_ms_ustring` (in `UnitfulExt`) is the inverse of `_ms_uparse` — a
  curated reverse-alias map + a round-trip check; a unit with no
  casacore spelling **errors** clearly (symmetric with the read side).
- A `Measure` column — `MEpoch{R}` → `mjd*86400` s, `MDirection{R}` →
  `[lon,lat]` rad, `MPosition{R}` → `[x,y,z]` m, `MFrequency{R}` → Hz,
  `MRadialVelocity{R}` → m/s — gets `MEASINFO` (`type` + fixed `Ref` from
  the first row's frame) + `QuantumUnits`.
- New `units = Dict(col => "Hz" | ["rad","rad"])` kwarg on `write_table`
  stamps `QuantumUnits` without a `MEASINFO`. An explicit `measures=` /
  `units=` entry for a column **overrides** the auto-detection (wins
  silently).
- `_casatype_of` gains an `Any` fallback with an actionable message
  (`import Unitful` / check the eltype) instead of a `MethodError`.
- `edit`'s `addcolumn!(t, name, data)` does the same detection.
- `copyms` / `write_ms` unchanged — keyword records are already copied
  verbatim.

**Non-goals:** deriving a per-row `VarRefCol` from a mixed-frame
`Measure` column (fixed `Ref` only); non-canonical stored units for a
`Measure`; `_ms_ustring` for the full casacore unit vocabulary (curated
+ verified, else a clear error); reading a plain column back *as* a
`Quantity` automatically (`column` still returns plain numbers — use
`qcolumn` / `measure`).

2677 tests.

### Phase 71 — `MRadialVelocity` reference-frame conversion

Phase 66 shipped `measconvert` for epoch / direction / frequency and
left `MRadialVelocity` (m/s, `SOURCE.SYSVEL`) as a clear-error stub.
Phase 71 implements it, reusing the frequency path's velocity machinery
in `ext/SOFAExt.jl` (`_v_earth_bary` / `_v_obs_geo` / `_n_hat` / the
`_VEL_LSRK`/`_VEL_LSRD`/`_VEL_LSRGAL` constants):

```julia
measconvert(MRadialVelocity{LSRK}(2e4), BARY; frame = fr)   # needs frame.direction
```

- Frames `LSRK` / `LSRD` / `BARY` / `GEO` / `TOPO` / `GALACTO`, hub =
  BARY, **relativistic velocity addition** (`β_out = (β_in ∓ g)/(1 ∓
  β_in·g)`, `g = V·n̂/c`) — matches casacore `MCRadialVelocity`.
- Verified against `casatools.measures()`: BARY / LSRD / GALACTO to
  < 1 mm/s; GEO / TOPO to ~0.25 m/s (the SOFA `epv00` vs
  casacore-ephemeris residual, the same one the frequency test carries
  as `rtol = 2e-9`). SOFA-only `LSRK → R → LSRK` round-trips to 1e-12.
- `_MEAS_ENUM[:radialvelocity]` added so a bare-code `VarRefCol` column
  decodes.

**Non-goals:** `LGROUP` / `CMB` velocity frames (no singletons — a
`measconvert` targeting one errors clearly; no real MS `SYSVEL` uses
them); a standalone `MDoppler` measure or an `MFrequency` ↔
`MRadialVelocity` bridge given a rest frequency (a distinct feature).

2699 tests.

### Phase 72 — `MDoppler` measure + frequency ↔ velocity bridge

The Phase 71 non-goal: the Doppler-shift *value* — its **convention**
(RADIO / OPTICAL / RATIO / BETA / GAMMA), orthogonal to the reference
*frame*. Pure algebra (`c` is the only constant, exact SI) → **core, no
`import SOFA`**.

```julia
d = MDoppler{RADIO}(0.01)
measconvert(d, OPTICAL)                        # convention -> convention

ν₀ = 1.42040575e9                              # HI rest frequency
doppler(MFrequency{LSRK}(1.4e9), ν₀)           # -> MDoppler{BETA}
frequency(d, ν₀)                               # MDoppler + rest -> MFrequency{LSRK}
restfrequency(MFrequency{LSRK}(1.4e9), d)      # -> MFrequency{REST}
radialvelocity(d)                              # -> MRadialVelocity{LSRK}  (c·β)
doppler(MRadialVelocity{LSRK}(3e5))            # -> MDoppler{BETA}         (β = v/c)
```

- `measconvert(::MDoppler, C2)` uses casacore `MCDoppler`'s hub =
  `RATIO` (`F = ν/ν₀`) route formulas; `BETA` = `RELATIVISTIC` = `v/c`,
  `Z` = `OPTICAL`.
- `doppler` / `frequency` / `radialvelocity` / `restfrequency` mirror
  casacore `MFrequency::to{Doppler,Rest}` / `fromDoppler` /
  `MRadialVelocity::{to,from}Doppler` — the frame of a `fromDoppler`
  result defaults to `LSRK` (casacore's choice).
- `:doppler` MEASINFO read + write (`_MEAS_FRAMES` / `_MEAS_ENUM` /
  `_measure_column_spec`) — completeness; no real MS stores one.
- Verified against `casatools.measures()` to `rtol = 1e-12` (casatools
  reports every doppler `m0` as `value·c` in "m/s" — the fixture
  divides it back out).

**Non-goals:** `MDoppler` reference-*frame* handling (frame-agnostic —
`measconvert` the frequency first); `MDoppler::shiftFrequency` (an
array helper); a `VarRefCol` `:doppler` write path.

2725 tests.
