# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library. One deliberate exception to
"pure Julia": `HDF5.jl` (a thin wrapper over the C `libhdf5`), added in
Phase 20 so `MultiHDF5` containers are readable too.

## Status

**Phase 1 — CTDS metadata (read).**
`AipsIO` primitive decoder; `table.dat` / `table.info` parsing (table &
column descriptions, keyword sets incl. nested `Record`s / `QuantumUnits`
/ `MEASINFO`, data-manager bindings, row counts, endianness); the MS
subtable tree.

**Phase 2 — StandardStMan (SSM) column data (read).**
`getcolumn` / `getcell` for SSM-backed columns: scalar numerics, `Bool`
(bit-unpacked), variable-length `String` (incl. multi-bucket string
buckets), and direct fixed-shape numeric/`Bool` arrays.

**Phase 3 — TiledStMan column data (read).**
`getcolumn` / `getcell` for `TiledShapeStMan` and `TiledColumnStMan`
columns — the visibility cubes (`DATA`, `FLAG`, `WEIGHT`, `SIGMA`,
`UVW`, …).  Header parsing, `row → hypercube` mapping, and tile
de-interleaving from the `table.f<n>_TSM<m>` files (mmapped).  Detects
never-written columns.  (Multi-column hypercubes: Phase 11.)

**Phase 4 — IncrementalStMan column data (read).**
The "store-on-change" manager behind most MAIN metadata columns (`TIME`,
`INTERVAL`, `EXPOSURE`, `FIELD_ID`, …).  With this every column of a
typical MAIN table is readable except ones that were never written.

**Phase 5 — high-level API, `Tables.jl`, standard schema.**
Lazy `Column <: AbstractVector` (`t[:DATA]`, `col[i]`, `col[1:5]`,
`col[:]`), `Tables.jl` column *and* row access (subtables drop straight
into `DataFrame`, `Tables.rowtable`, …), and a machine-readable encoding of
the MS v2 standard schema (`SCHEMAVER2`, `stdtable`, `validate`).

**Phase 6 — writers.**
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

**Phase 7 — StandardStMan indirect / string arrays (read + write).**
The `StIndArray` / `table.f<n>i` mechanism and the string-handler array
format behind every variable-shape subtable column (`CHAN_FREQ`,
`CORR_TYPE`, `POLARIZATION_TYPE`, `POL_RESPONSE`, `PHASE_DIR`, `LOG`, …).
`copyms` now reproduces every column of a standard MS; `create_ms` writes
these as real ragged arrays.

**Phase 8 — IncrementalStMan writer + ISM indirect arrays.**
A byte-exact writer for the "store on change" run-length format (header,
multi-bucket data + index parts, `ISMIndex`), plus ISM indirect-array
read + write. `copyms` keeps a source's ISM columns as ISM;
`create_ms` writes MAIN's per-integration scalars (`TIME`, `FIELD_ID`,
…) through ISM.

**Phase 9 — in-place edits.**
`edit(path) do t … end` opens an existing table for update: overwrite
cells / whole columns (`t[:X][i] = v`, `t[:X][:] = vals`) and append rows
(`addrows!(t, n)`).  Hybrid persist — a touched `TiledShapeStMan` column
is patched in the tile file in place (editing one cell of a multi-GB cube
touches a few bytes); a touched StandardStMan / IncrementalStMan file is
regenerated from its in-memory column data.

**Phase 10 — row deletion + `addColumn` / `removeColumn`.**
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

**Phase 11 — multi-column tiled storage managers.**
`TiledShapeStMan` hypercubes shared by several data columns of one cell
shape (the `DATA` + `FLAG` + `WEIGHT_SPECTRUM` layout of a CASA-filled
MS): concatenated per-column tile blocks in casacore's size-sorted order,
read and write.  New `TiledColumnStMan` and `TiledCellStMan` writers.
`write_table` takes `tsm` / `tcm` / `tcell` column-name *groups*;
`copyms` reproduces a source's hypercube grouping (and keeps a
`TiledColumnStMan` `UVW` as such instead of moving it to StandardStMan);
`create_ms` shares one cube between `DATA`, `FLAG` and `WEIGHT_SPECTRUM`.

**Phase 12 — virtual column engines.**
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

**Phase 13 — concurrent access + locking.**
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

**Phase 14 — reference & concatenation tables (read).**
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

**Phase 15 — persist a selection: write RefTable / ConcatTable, and a
data-manager-preserving materialise.**

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
columns; `TiledDataStMan`; `ForwardColumnEngine` / `VirtualTaQLColumn` /
`BitFlagsEngine`; adding a column (or engine) to an existing table in an
edit session; in-place per-data-manager `resync`. (Free-list bucket
reuse doesn't apply here — every edit fully regenerates any touched
storage-manager file from resolved data, so nothing accumulates across
edits the way casacore's own in-place bucket model can.)

**Phase 16 — `copyms` performance.** A full, in-order table/subtable copy
(every subtable copy, and the default `copyms`/`copytable` with no `rows=`
override) now reads each source column via its own whole-column fast
path instead of cell by cell — roughly halves the time on a large,
mostly-indirect-array subtable (925,645-row `POINTING`: 68 s → 35 s on
the reference MS) and more on a scalar/fixed-shape/tiled-heavy one. A
`RefTable` selection or an explicit partial row range is unaffected.

**Phase 17 — cooperative lock hand-off.** Closes the one documented gap
in Phase 13's locking: a contended acquire announces this process in
`table.lock`'s request-id list and removes itself again once done
(casacore `LockFile::addReqId`/`removeReqId`), so a real casacore peer
holding the table in its default `AutoLocking` mode can see us waiting
and release early. See the Phase 13 section above for the usage example
— this is automatic, no API change.

**Phase 18 — `DyscoStMan` column data (read).** `DyscoStMan` (the
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

**Phase 19 — `DyscoStMan` full read + write.** Completes Phase 18: all
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

**Phase 20 — `MultiFile`/`MultiHDF5` container read support.** casacore
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

**Phase 21 — `MultiFile`/`MultiHDF5` container write support.** Completes
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

**Phase 22 — TaQL-lite query engine.** `query(t, wherestr)` row-filters
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

**Phase 23 — TaQL-lite `ORDER BY`.** Both `query` entry points now sort
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

**Phase 24 — TaQL-lite arithmetic + pattern matching.** The string
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

**Phase 25 — TaQL-lite functions.** The string parser gains a curated
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

**Phase 26 — GROUP BY + aggregation.** A new `groupby(t, groupcols;
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

**Phase 27 — closure-form `groupby`.** For aggregates the `g*` set
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

**Phase 28 — joins.** `join(left, right; on, rightcols, …)` (a method
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

**Phase 29 — chainable results.** `GroupedTable` (the result of
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

**Phase 30 — the write commands.** `UPDATE` / `DELETE` / `SELECT INTO`,
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

A `taql(target, "…")` string-command dispatcher wraps all three:
`taql(t, "UPDATE t SET UVW = UVW * 2 WHERE ANTENNA1 == 0")`,
`taql(t, "DELETE FROM t WHERE FLAG_ROW")`,
`taql(t, "SELECT A, B AS BB WHERE A > 5 INTO '/tmp/out'")`.

Still, across Phases 22–30: no bitwise operators (`& | ^ ~`),
`BETWEEN`, `~=`, array indexing, units, date/time or measures
functions, `GROUP BY ROLLUP`, the `gs*` per-element aggregates, a
general M:N cross-product join, `INSERT`, or `UPDATE` array-slice
assignment.

## Usage

```julia
using MeasurementSetv2

ms = MeasurementSet("/path/to/my.ms")
subtablenames(ms)                        # ["ANTENNA", "SPECTRAL_WINDOW", …]

# lazy columns
ms[:DATA][42]                            # 4×64 ComplexF32   (one cell)
ms[:UVW][1:100]                          # first 100 baselines' UVW
column(ms.data, "TIME")[:]               # whole column (fast path)

t = readtable("/path/to/my.ms")          # the MAIN table directly
nrow(t); columnnames(t)
columndesc(t, "DATA")                    # schema of one column
keywords(t)["MS_VERSION"]                # 2.0f0

# Tables.jl — subtables interoperate with the data ecosystem
using DataFrames
DataFrame(subtable(ms, "ANTENNA"))       # 26×8
Tables.schema(subtable(ms, "SPECTRAL_WINDOW"))

# standard-schema check
validate(ms)                             # String[]  (conformant)
stdtable("SPECTRAL_WINDOW").columns

# writing
copyms("/path/to/my.ms", "/tmp/copy.ms"; rows=1:2000)
create_ms("/tmp/synth.ms"; nrow=100, nchan=64, ncorr=4, nant=6)
write_table("/tmp/spw", "SPECTRAL_WINDOW",
            ["NUM_CHAN" => [64, 32],
             "CHAN_FREQ" => [collect(1.0:64.0), collect(1.0:32.0)]];  # ragged
            nrow=2)

# editing in place
edit("/tmp/copy.ms") do t
    t[:FLAG][5] = trues(4, 64)           # patched in the tile file
    t[:SCAN_NUMBER][10] = 7
    addrows!(t, 10)                      # every storage manager grows
    for r in 91:100; t[:TIME][r] = 4.6e9 + r end
end

# row / schema mutation (regen path)
edit("/tmp/copy.ms") do t
    removerows!(t, [2, 5, 9])
    addcolumn!(t, "WEIGHT_SPECTRUM")
    removecolumn!(t, "FLAG_CATEGORY")
end
```

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

The AipsIO unit tests always run. Metadata tests and a column-by-column
cross-check against [`Casacore.jl`](https://github.com/JuliaAstro/Casacore.jl)
run when a sample MS is available — set `MEASUREMENTSETV2_TEST_MS` to point
at one.
