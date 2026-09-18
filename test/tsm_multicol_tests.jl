# Phase 11: multi-column tiled storage managers
# (TiledShapeStMan shared hypercubes, TiledColumnStMan + TiledCellStMan writers).

# `_HAVE_TAQL` / `_taql_create` (casacore-authored table via TaQL
# CREATE TABLE) come from test/taql_helpers.jl.

# ragged per-row cells (VariableShape) so Casacore.jl gives proper array columns
_ragged(J, shapes) = [J.(reshape(1:prod(s), s)) .+ J(10i) for (i, s) in enumerate(shapes)]

# manager type bound to a column (mirrors create.jl `_source_dm`)
function _source_dm_name(t, name)
    c = columndesc(t, name)
    i = findfirst(m -> m.sequ == c.sequ, t.managers)
    i === nothing ? c.manager : t.managers[i].name
end

@testset "multi-column TiledShapeStMan — our writer <-> our reader" begin
    dir = joinpath(mktempdir(), "g.tab")
    shp = [(2, 3), (2, 3), (2, 4), (2, 4), (2, 3)]        # 2 distinct shapes -> 2 cubes
    A = _ragged(ComplexF32, shp)
    B = [isodd(i) .* trues(shp[i]) for i in 1:5]
    W = _ragged(Float32, shp)
    write_table(dir, "T", ["A" => A, "B" => B, "W" => W]; nrow=5, tsm=[["A", "B", "W"]])

    r = readtable(dir)
    @test Set(m.name for m in r.managers) == Set(["TiledShapeStMan"])
    @test columndesc(r, "A").sequ == columndesc(r, "B").sequ == columndesc(r, "W").sequ
    @test count(f -> startswith(f, "table.f0_TSM"), readdir(dir)) == 2   # one _TSM per shape

    @test [column(r, "A")[i] for i in 1:5] == A
    @test [column(r, "B")[i] for i in 1:5] == B
    @test [column(r, "W")[i] for i in 1:5] == W

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test [ct[:A][i] for i in 1:5] == A
        @test [Bool.(ct[:B][i]) for i in 1:5] == B
        @test [ct[:W][i] for i in 1:5] == W
    end
end

if _HAVE_TAQL
    @testset "multi-column TiledShapeStMan — casacore writer -> our reader" begin
        dir = joinpath(mktempdir(), "cc.tab")
        t = _taql_create("CREATE TABLE $dir " *
            "[A C4 [NDIM=2], B B [NDIM=2], W R4 [NDIM=2]] LIMIT 4 " *
            "DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"TSMd\", " *
            "SPEC=[DEFAULTTILESHAPE=[2,3,2]], COLUMNS=[\"A\",\"B\",\"W\"]]")
        A = [ComplexF32.(fill(r, 2, 3)) .+ ComplexF32(0, r) for r in 1:4]
        B = [(iseven(r) ? trues(2, 3) : falses(2, 3)) for r in 1:4]
        W = [Float32.(fill(10r, 2, 3)) for r in 1:4]
        for r in 1:4
            t[:A][r] = A[r]; t[:B][r] = B[r]; t[:W][r] = W[r]
        end
        CCT.flush(t); t = nothing; GC.gc()

        r = readtable(dir)
        @test length(r.managers) == 1 && r.managers[1].name == "TiledShapeStMan"
        @test [column(r, "A")[i] for i in 1:4] == A
        @test [column(r, "B")[i] for i in 1:4] == B
        @test [column(r, "W")[i] for i in 1:4] == W
    end

    @testset "tile-block order — equal-size types (casacore tie-break)" begin
        dir = joinpath(mktempdir(), "tie.tab")
        # Int32 and Float32 both have canonical size 4; casacore orders equal
        # sizes by *descending* binding index, so the tile holds FF before IX.
        t = _taql_create("CREATE TABLE $dir [IX I4 [NDIM=2], FF R4 [NDIM=2]] LIMIT 3 " *
            "DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"TSMt\", " *
            "SPEC=[DEFAULTTILESHAPE=[2,2,3]], COLUMNS=[\"IX\",\"FF\"]]")
        IX = [Int32.(reshape(1:4, 2, 2)) .+ Int32(r) for r in 1:3]
        FF = [Float32.(reshape(1:4, 2, 2)) .* Float32(r) for r in 1:3]
        for r in 1:3; t[:IX][r] = IX[r]; t[:FF][r] = FF[r]; end
        CCT.flush(t); t = nothing; GC.gc()

        r = readtable(dir)
        @test [column(r, "IX")[i] for i in 1:3] == IX
        @test [column(r, "FF")[i] for i in 1:3] == FF

        # our own writer must reproduce the same layout casacore reads back
        dir2 = joinpath(mktempdir(), "tie2.tab")
        Iv = [Int32.(reshape(1:(2 * s), 2, s)) for s in (2, 3, 2)]
        Fv = [Float32.(reshape(1:(2 * s), 2, s)) for s in (2, 3, 2)]
        write_table(dir2, "T", ["IX" => Iv, "FF" => Fv]; nrow=3, tsm=[["IX", "FF"]])
        ct = CCT.Table(dir2)
        @test [ct[:IX][i] for i in 1:3] == Iv
        @test [ct[:FF][i] for i in 1:3] == Fv
    end
end

@testset "TiledColumnStMan writer (single + multi column)" begin
    dir = joinpath(mktempdir(), "tcm.tab")
    U = [Float64[r, 2r, 3r] for r in 1:6]
    P = [Float64[r, r, r] for r in 1:6]
    Q = [ComplexF32[r, 0, -r] for r in 1:6]
    write_table(dir, "T", ["U" => U, "P" => P, "Q" => Q]; nrow=6, tcm=[["U"], ["P", "Q"]])

    r = readtable(dir)
    @test [m.name for m in r.managers] == ["TiledColumnStMan", "TiledColumnStMan"]
    @test columndesc(r, "U").sequ != columndesc(r, "P").sequ
    @test columndesc(r, "P").sequ == columndesc(r, "Q").sequ
    @test "table.f$(columndesc(r,"P").sequ)_TSM0" in readdir(dir)

    @test [column(r, "U")[i] for i in 1:6] == U
    @test [column(r, "P")[i] for i in 1:6] == P
    @test [column(r, "Q")[i] for i in 1:6] == Q

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test [ct[:U][:, i] for i in 1:6] == U
        @test [ct[:P][:, i] for i in 1:6] == P
        @test [ct[:Q][:, i] for i in 1:6] == Q
    end
end

@testset "TiledCellStMan writer + reader (per-row hypercube)" begin
    dir = joinpath(mktempdir(), "tcell.tab")
    C = [Float32.(reshape(1:(2 * (k + 1)), 2, k + 1)) for k in 1:5]   # (2,2)..(2,6)
    write_table(dir, "T", ["C" => C]; nrow=5, tcell=["C"])

    r = readtable(dir)
    @test r.managers[1].name == "TiledCellStMan"
    @test [column(r, "C")[i] for i in 1:5] == C
    @test getcolumn(r, "C") == C

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test [ct[:C][i] for i in 1:5] == C
    end

    if _HAVE_TAQL
        cdir = joinpath(mktempdir(), "cccell.tab")
        t = _taql_create("CREATE TABLE $cdir [C R4 [NDIM=2]] LIMIT 4 " *
            "DMINFO [TYPE=\"TiledCellStMan\", NAME=\"TSMc\", SPEC=[DEFAULTTILESHAPE=[2,3]], " *
            "COLUMNS=[\"C\"]]")
        CC = [Float32.(fill(r, 2, r + 1)) for r in 1:4]
        for r in 1:4; t[:C][r] = CC[r]; end
        CCT.flush(t); t = nothing; GC.gc()
        rr = readtable(cdir)
        @test [column(rr, "C")[i] for i in 1:4] == CC
    end
end

# Phase 213 (src/datamanagers sweep, continued): a `TiledCellStMan` row can
# genuinely have an UNDEFINED cell -- real casacore's own
# `TiledCellStMan::addRow64` (TiledCellStMan.cc:178-200) creates a null
# `TSMCube` (empty cubeshape, no file) for any row added before its cell
# shape is ever `setShape`'d.  `getcell` already raised a clear error for
# that row; `getcolumn`'s bulk `:cell` path skipped the same check and
# crashed instead with a raw, unhelpful `MethodError: no method matching
# _tsmbytes(..., ::Nothing)` -- live-reproduced by hand-inserting a null
# cube into a real, on-disk-round-tripped instance (exactly the state a
# genuine casacore-authored table can be in), confirming the crash before
# the fix and the matching clear error after.
@testset "TiledCellStMan — an undefined (never setShape'd) row (Phase 213)" begin
    dir = joinpath(mktempdir(), "tcellundef.tab")
    C = [Float32.(reshape((r * 10) .+ (1:(2 * (r + 1))), 2, r + 1)) for r in 1:3]
    write_table(dir, "T", ["C" => C]; nrow=3, tcell=[["C"]])

    r = readtable(dir)
    seq = only(m.sequ for m in r.managers if m.name == "TiledCellStMan")
    inst = MSv2._dm_instance(r, seq)
    @test !MSv2.isnull(inst.cubes[2])
    inst.cubes[2] = MSv2.TSMCube((), (), nothing, 0)   # simulate addRow64-before-setShape

    cdesc = columndesc(r, "C")
    @test_throws ErrorException MSv2.getcell(inst, 1, cdesc, 2, 1)
    @test_throws ErrorException MSv2.getcolumn(inst, 1, cdesc, 3, 1)
    # the other (defined) rows are unaffected by the one undefined row
    @test MSv2.getcell(inst, 1, cdesc, 1, 1) == C[1]
    @test MSv2.getcell(inst, 1, cdesc, 3, 1) == C[3]
    # and the same error message either way, matching `getcell`'s
    try
        MSv2.getcolumn(inst, 1, cdesc, 3, 1)
    catch e
        try
            MSv2.getcell(inst, 1, cdesc, 2, 1)
        catch e2
            @test sprint(showerror, e) == sprint(showerror, e2)
        end
    end
end

# Phase 211 (src/datamanagers sweep): `tsm_setcell!`'s `:cell`-kind branch
# (a `TiledCellStMan` in-place cell edit) had ZERO test coverage anywhere
# in the suite -- a coverage-instrumented run confirmed not one line of it
# had ever executed. Live-verified correct (no code change needed) before
# adding this as a permanent regression test, matching this project's own
# "close a genuine coverage gap with a real test" precedent (Phases
# 158/173/209) rather than leaving a confirmed-working-but-silently-
# unguarded corner to bit-rot.
#
# NOTE: the row shapes below deliberately VARY per row (2x2, 2x3, 2x4),
# matching the pre-existing "TiledCellStMan writer + reader" testset
# above, rather than all sharing one uniform shape. Found live: a
# TiledCellStMan column whose every row happens to share the SAME cell
# shape trips a pre-existing bug in the `Casacore.jl` cross-check
# library itself (not this package -- our own reader already reads such
# a table back correctly) -- its `Tables.Column.size()` gets a raw
# `(Int64, Int64, UInt64)` tuple from real casacore for that case and
# fails to `convert` it to the `Tuple{Int64}` its own `N=1` type
# parameter expects; the varying-shape case (real TiledCellStMan usage)
# does not hit it.
@testset "TiledCellStMan — in-place cell edit (Phase 211)" begin
    dir = joinpath(mktempdir(), "tcelledit.tab")
    C = [Float32.(reshape((r * 10) .+ (1:(2 * (r + 1))), 2, r + 1)) for r in 1:3]
    write_table(dir, "T", ["C" => C]; nrow=3, tcell=[["C"]])

    newcell = Float32.(fill(99, 2, 3))   # matches row 2's own shape, (2,3)
    edit(dir) do t
        t[:C][2] = newcell
    end
    r = readtable(dir)
    d = [column(r, "C")[i] for i in 1:3]
    @test d[2] == newcell
    @test d[1] == C[1] && d[3] == C[3]   # siblings untouched

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:C][2] == newcell
        @test ct[:C][1] == C[1] && ct[:C][3] == C[3]
    end

    # the Bool bit-packed path through the same `:cell` branch, also
    # completely uncovered before this phase
    dirb = joinpath(mktempdir(), "tcelleditbool.tab")
    F = [rand(Bool, 2, r + 1) for r in 1:3]
    write_table(dirb, "T", ["F" => F]; nrow=3, tcell=[["F"]])
    newbool = falses(2, 3)               # matches row 2's own shape, (2,3)
    edit(dirb) do t
        t[:F][2] = newbool
    end
    rb = readtable(dirb)
    db = [column(rb, "F")[i] for i in 1:3]
    @test db[2] == newbool
    @test db[1] == F[1] && db[3] == F[3]
    if _HAVE_CASACORE
        ctb = CCT.Table(dirb)
        @test ctb[:F][2] == newbool
    end
end

@testset "create_ms — DATA/FLAG/WEIGHT_SPECTRUM share one hypercube" begin
    dst = joinpath(mktempdir(), "m.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)
    r = readtable(dst)
    s = columndesc(r, "DATA").sequ
    @test columndesc(r, "FLAG").sequ == s
    @test columndesc(r, "WEIGHT_SPECTRUM").sequ == s
    @test count(f -> startswith(f, "table.f$(s)_TSM"), readdir(dst)) == 1
    ms = MeasurementSet(dst)
    @test isempty(validate(ms))
    @test size(ms[:WEIGHT_SPECTRUM][1]) == (2, 4)

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test all(iszero, ct[:DATA][1])
        @test all(iszero, ct[:WEIGHT_SPECTRUM][1])
        @test !any(ct[:FLAG][1])
    end
end

@testset "edit — one column of a shared cube, in place" begin
    dst = joinpath(mktempdir(), "e.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)
    s = columndesc(readtable(dst), "DATA").sequ
    tsmfile = joinpath(dst, "table.f$(s)_TSM1")
    before = read(tsmfile)

    ms0 = MeasurementSet(dst)
    data0 = [copy(ms0[:DATA][i]) for i in 1:6]
    ws0 = [copy(ms0[:WEIGHT_SPECTRUM][i]) for i in 1:6]

    edit(dst) do t
        t[:FLAG][3] = trues(2, 4)
        t[:FLAG][5] = trues(2, 4)
    end

    @test filesize(tsmfile) == length(before)          # no reallocation
    ms = MeasurementSet(dst)
    @test all(ms[:FLAG][3]) && all(ms[:FLAG][5])
    @test !any(ms[:FLAG][1])
    @test [ms[:DATA][i] for i in 1:6] == data0         # sibling columns untouched
    @test [ms[:WEIGHT_SPECTRUM][i] for i in 1:6] == ws0
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test all(ct[:FLAG][3])
        @test all(iszero, ct[:DATA][2])
    end
end

@testset "edit — addrows! / removerows! on a shared cube" begin
    dst = joinpath(mktempdir(), "e2.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)

    edit(dst) do t
        addrows!(t, 3)
        for r in 7:9
            t[:DATA][r] = fill(ComplexF32(r), 2, 4)
            t[:FLAG][r] = trues(2, 4)
            t[:WEIGHT_SPECTRUM][r] = fill(Float32(r), 2, 4)
        end
    end
    ms = MeasurementSet(dst)
    @test getfield(ms, :data).rows == 9
    @test ms[:DATA][8] == fill(ComplexF32(8), 2, 4)
    @test all(iszero, ms[:DATA][1])
    @test ms[:WEIGHT_SPECTRUM][9] == fill(9f0, 2, 4)

    edit(dst) do t
        removerows!(t, [2, 4])
    end
    ms2 = MeasurementSet(dst)
    @test getfield(ms2, :data).rows == 7
    @test ms2[:DATA][6] == fill(ComplexF32(8), 2, 4)   # old row 8 -> new row 6
    @test isempty(validate(ms2))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test size(ct, 1) == 7
        @test ct[:DATA][6] == fill(ComplexF32(8), 2, 4)
    end
end

@testset "copyms preserves hypercube grouping + TiledColumnStMan" begin
    src = joinpath(mktempdir(), "src.tab")
    A = _ragged(ComplexF32, [(2, 3), (2, 3), (2, 4)])
    B = [trues(size(A[i])) for i in 1:3]
    U = [Float64[i, i, i] for i in 1:3]
    write_table(src, "T", ["A" => A, "B" => B, "U" => U]; nrow=3,
                tsm=[["A", "B"]], tcm=[["U"]])

    dst = joinpath(mktempdir(), "dst.tab")
    copyms(src, dst)
    r = readtable(dst)
    @test columndesc(r, "A").sequ == columndesc(r, "B").sequ
    da = _source_dm_name(r, "U")
    @test da == "TiledColumnStMan"
    @test [column(r, "A")[i] for i in 1:3] == A
    @test [column(r, "U")[i] for i in 1:3] == U
end

# Phase 213 (src/datamanagers sweep, continued): a `TiledShapeStMan`
# column can genuinely have rows *beyond* its own row map's last defined
# interval -- e.g. a column whose tile coverage never got extended to the
# table's full row count. `_cube_for_row`'s `rownr > tsm.row[end]` branch
# (returning the dummy "undefined cells" cube 0) already handles this
# correctly, but no test ever actually put a real, opened `TiledStMan`
# instance into that state -- live-reproduced by hand-truncating a real
# instance's own row map (the same technique used for the null-cube
# `TiledCellStMan` case above), confirming `getcell` *and* `getcolumn`
# (the astype-narrowed AND plain per-cell fallback paths) all give the
# same clear error, and that the still-defined rows are unaffected.
@testset "TiledShapeStMan — rows beyond the row map's last interval (Phase 213)" begin
    dir = joinpath(mktempdir(), "tsmpartial.tab")
    D = [Float32.(reshape(1:6, 2, 3)) .+ 10i for i in 1:5]
    write_table(dir, "T", ["D" => D]; nrow=5, tsm=[["D"]])

    r = readtable(dir)
    seq = columndesc(r, "D").sequ
    inst = MSv2._dm_instance(r, seq)
    @test inst.kind === :shape
    @test inst.row == [5]                              # one interval, covers every row

    # simulate: this column's tile coverage only extends through row 3 --
    # rows 4-5 are genuinely undefined (row/pos must stay in sync: the
    # position at the new last row is 3, not the original 5).
    inst.row = [3]; inst.pos = [3]
    cdesc = columndesc(r, "D")
    @test MSv2.getcell(inst, 1, cdesc, 1, 1) == D[1]
    @test MSv2.getcell(inst, 1, cdesc, 3, 1) == D[3]
    @test_throws ErrorException MSv2.getcell(inst, 1, cdesc, 4, 1)
    @test_throws ErrorException MSv2.getcolumn(inst, 1, cdesc, 5, 1)
    @test_throws ErrorException MSv2.getcolumn(inst, 1, cdesc, 5, 1; astype=Float16)
end

# Phase 213: `getcolumn`'s astype-narrowed per-cell fallback (used when the
# whole-column bulk-read fast path doesn't apply -- e.g. more than one real
# hypercube for the column, as here) had zero coverage: every existing
# precision-narrowing test happened to hit the single-real-cube fast path
# instead. Two distinct cell shapes force two real cubes.
@testset "TiledShapeStMan — narrowed getcolumn via the per-cell fallback (Phase 213)" begin
    dir = joinpath(mktempdir(), "tsmnarrow.tab")
    A = [ComplexF32.(reshape(1:6, 2, 3)) .+ 10i for i in 1:3]
    B = [ComplexF32.(reshape(1:8, 2, 4)) .+ 10i for i in 1:2]
    D = vcat(A, B)
    write_table(dir, "T", ["D" => D]; nrow=5, tsm=[["D"]])

    r = readtable(dir)
    seq = columndesc(r, "D").sequ
    inst = MSv2._dm_instance(r, seq)
    @test count(!MSv2.isnull, inst.cubes) == 2          # confirms the fast path is skipped

    out = column(r, "D"; precision=Float16)[:]
    @test eltype(out[1]) == ComplexF16
    @test out == [Complex{Float16}.(d) for d in D]
end

# Phase 213: an unrecognized / not-yet-supported tiled wrapper name inside
# `table.f<seq>` gives a clear error naming it (rather than a raw parse
# failure) -- hand-patch a real file's private header to a bogus / the
# genuinely-unimplemented "TiledDataStMan" wrapper (`table.dat`'s own DM
# entry is untouched, so `_dm_instance` still routes the open call here).
@testset "TiledStMan — unrecognized / TiledDataStMan wrapper name (Phase 213)" begin
    @test MSv2._dmtype("TiledDataStMan") === MSv2.TiledStMan   # routed, not silently "nothing"

    dir = joinpath(mktempdir(), "tsmwrap.tab")
    D = [Float32.(reshape(1:6, 2, 3)) .+ 10i for i in 1:3]
    write_table(dir, "T", ["D" => D]; nrow=3, tsm=[["D"]])
    r = readtable(dir)
    seq = columndesc(r, "D").sequ
    path = joinpath(dir, "table.f$seq")

    w = MSv2.AipsWriter(; endian=:big)
    MSv2.putstart(w, "TiledDataStMan", 1)
    MSv2.putend(w)
    write(path, MSv2.bytes(w))
    err = try column(readtable(dir), "D")[1]; nothing catch e; e end
    @test err isa ErrorException && occursin("TiledDataStMan", err.msg)

    w2 = MSv2.AipsWriter(; endian=:big)
    MSv2.putstart(w2, "SomeBogusWrapper", 1)
    MSv2.putend(w2)
    write(path, MSv2.bytes(w2))
    err2 = try column(readtable(dir), "D")[1]; nothing catch e; e end
    @test err2 isa ErrorException && occursin("SomeBogusWrapper", err2.msg)

    # a totally unregistered data-manager NAME (never reaching this file's
    # own wrapper dispatch at all -- caught earlier, in `_dm_instance`
    # itself, `tables/column.jl`) -- `_dmtype`'s own final fallback
    # (`datamanager.jl:28`, `return nothing`) had no test at all.
    @test MSv2._dmtype("TotallyUnknownDataManager") === nothing
end

if _HAVE_TAQL
    # Phase 213: casacore allows a tile shape that also chunks the CELL's
    # own (non-row) axes, not just the row axis -- `read_plane`'s "leading
    # axes tiled (rare)" branch handles this, but nothing our own writer
    # produces ever exercises it (`write_tiledshapestman` always tiles
    # only the row axis). A real, casacore-authored fixture with an
    # explicit small `DEFAULTTILESHAPE` is both the only way to construct
    # one and a genuine interop cross-check.
    @testset "TiledShapeStMan — leading axes tiled too (Phase 213)" begin
        dir = joinpath(mktempdir(), "leadtile.tab")
        t = _taql_create("CREATE TABLE $dir [A C4 [NDIM=2]] LIMIT 4 " *
            "DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"TSMd\", " *
            "SPEC=[DEFAULTTILESHAPE=[1,2,2]], COLUMNS=[\"A\"]]")
        CC = [ComplexF32.(reshape(1:6, 2, 3)) .+ 10i for i in 1:4]
        for r in 1:4; t[:A][r] = CC[r]; end
        CCT.flush(t); t = nothing; GC.gc()

        r = readtable(dir)
        seq = columndesc(r, "A").sequ
        inst = MSv2._dm_instance(r, seq)
        cube = inst.cubes[findfirst(!MSv2.isnull, inst.cubes)]
        @test cube.tileshape[1] < cube.cubeshape[1]     # a leading axis really is tiled
        @test [column(r, "A")[i] for i in 1:4] == CC    # per-cell (read_plane)
        @test column(r, "A")[:] == CC                   # bulk (falls through to read_plane too)
    end
end
