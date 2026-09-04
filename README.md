# MeasurementSetv2

[![Build Status](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Paul Barrett/MeasurementSetv2.jl/actions/workflows/CI.yml?query=branch%3Amain)

A pure-Julia reader and writer for the **Measurement Set version 2** data
format — the casacore Table Data System (CTDS) tables used for
interferometric visibility data by ALMA, the VLA, LOFAR and others.

No dependency on the casacore C++ library.

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
