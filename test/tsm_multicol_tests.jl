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
