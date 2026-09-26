# Phase 266: empty and undefined -- zero-row tables, never-written cells, empty selections.
#
# Probed against real casacore in both directions (TaQL-created -> ours, ours -> Casacore.jl,
# and a real casacore `INSERT` into our zero-row tables).  Found and fixed:
#   * `write_table` / `copytable` / `copyms` of ZERO rows crashed for every tiled manager
#     (`BoundsError` in `write_tiledshapestman`), engines (`eltype(storeddata[1])`) and Dysco
#     ("rowsPerBlock must be positive") -- e.g. `copyms(ms, dst; rows = 1:0)` or copying an
#     empty `query` result;
#   * a zero-row `IncrementalStMan` file lacked the row-0 entry casacore relies on, so a REAL
#     casacore adding a row to it bus-errored (`ISMBucket::getInterval`, the Phase 161 invariant);
#   * a variable-shape column forgot its number of axes on the way through a zero-row table
#     (`VariableShape` now carries `ndim`);
#   * a never-written (undefined) cell of a variable-shape TILED column raised an error where
#     casacore reads an empty array -- so a whole column of them (`FLAG_CATEGORY` and
#     `WEIGHT_SPECTRUM` in the real ALMA MS) was unreadable; ours now also WRITES empty cells
#     as undefined cells;
#   * `edit` defining an undefined tiled cell (or changing its shape) took the in-place patch
#     path and errored; it now falls back to the regenerating path.

# casacore keeps a table open (and its state) per path for as long as a handle lives, so open
# the table under a fresh path to see what is really on disk now.
_cc_copy(dir) = (d = dir * "_cc" * string(rand(UInt16)); cp(dir, d); d)

@testset "zero-row tables (Phase 266)" begin
    if _HAVE_TAQL
        # real casacore-created zero-row tables read as empty columns
        types = [("B", Bool), ("UC", UInt8), ("I4", Int32), ("R8", Float64), ("C4", ComplexF32), ("S", String)]
        shapes = [("scalar", ""), ("fixed3", " [SHAPE=[3]]"), ("var", " [NDIM=1]")]
        mgrs = [("ssm", ""), ("ism", " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"X\"]]"),
                ("tsm", " DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"TSM\", SPEC=[DEFAULTTILESHAPE=[2,2]], COLUMNS=[\"X\"]]"),
                ("tcm", " DMINFO [TYPE=\"TiledColumnStMan\", NAME=\"TCM\", SPEC=[TILESHAPE=[2,2]], COLUMNS=[\"X\"]]")]
        nfail = 0
        for (tn, T) in types, (sn, sd) in shapes, (mn, md) in mgrs
            (mn in ("tsm", "tcm") && (sn == "scalar" || T === String)) && continue
            (mn == "tcm" && sn == "var") && continue
            dir = joinpath(mktempdir(), "t")
            ok = try
                tc = _taql_create("CREATE TABLE $dir [X $tn$sd] LIMIT 0$md"); CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
                t = readtable(dir)
                MSv2.nrow(t) == 0 && length(column(t, "X")[:]) == 0
            catch
                false
            end
            ok || (nfail += 1; @info "zero-row casacore table" tn sn mn)
        end
        @test nfail == 0
    end

    # a zero-row `write_table`: SSM / ISM / scalar always worked; the tiled managers need the
    # number of axes, which a `Vector{Array{T,N}}` element type knows
    for (kw, col) in [((;), Float64[]), ((; ism=["X"]), Int32[]), ((;), Vector{Float64}[]),
                      ((; ism=["X"]), Vector{Float32}[]), ((; tsm=[["X"]]), Vector{Float64}[]),
                      ((; tsm=[["X"]]), Matrix{ComplexF32}[])]
        dir = joinpath(mktempdir(), "t")
        write_table(dir, "T", Pair{String,Any}["X" => col]; nrow=0, kw...)
        t = readtable(dir)
        @test MSv2.nrow(t) == 0
        @test isempty(column(t, "X")[:])
        _HAVE_CASACORE && @test size(CCT.Table(_cc_copy(dir)), 1) == 0
    end
    let d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => Matrix{Float32}[]]; nrow=0, tsm=[["X"]])
        @test columndesc(readtable(d), "X").shape == MSv2.VariableShape(2)   # the ndim survives the file
    end
    # a TiledColumnStMan needs a declared fixed shape; nothing in an empty column gives one
    @test_throws ErrorException write_table(joinpath(mktempdir(), "t"), "T",
        Pair{String,Any}["X" => Vector{Float64}[]]; nrow=0, tcm=[["X"]])
    # ... a Vector{Array} whose ndim the element type cannot give
    @test_throws ErrorException write_table(joinpath(mktempdir(), "t"), "T",
        Pair{String,Any}["X" => Array{Float64}[]]; nrow=0, tsm=[["X"]])
    # an empty column of unknown element type: a clear error (not the Unitful one)
    @test_throws ErrorException write_table(joinpath(mktempdir(), "t"), "T",
        Pair{String,Any}["X" => Any[]]; nrow=0)
    err = try write_table(joinpath(mktempdir(), "t"), "T", Pair{String,Any}["X" => Any[]]; nrow=0)
          catch e; sprint(showerror, e) end
    @test occursin("no rows", err)
end

@testset "an empty selection copies (Phase 266)" begin
    n = 6
    src = joinpath(mktempdir(), "s")
    write_table(src, "S", Pair{String,Any}[
        "A" => collect(1:n), "B" => Float64.(1:n), "V" => [rand(Float32, 2, 3) for _ in 1:n],
        "U" => [rand(3) for _ in 1:n], "C" => [rand(2, k) for k in [1, 2, 1, 2, 1, 2]],
        "CF" => [rand(Float32, 4) for _ in 1:n], "S" => ["s$i" for i in 1:n], "R" => [rand(i % 3 + 1) for i in 1:n],
        "Q" => zeros(n)];
        nrow=n, ism=["B"], tsm=[["V"]], tcm=[["U"]], tcell=[["C"]],
        engines=Dict("CF" => (; kind=MSv2.CompressFloat(), scale=0.01, offset=0.0)),
        virtualtaql=Dict("Q" => "A * 2.0"))
    t = readtable(src)
    for storage in (:sepfile, :multifile)
        dst = joinpath(mktempdir(), "d")
        copytable(dst, t; rows=1:0, storage)
        t2 = readtable(dst)
        @test MSv2.nrow(t2) == 0
        @test all(c -> isempty(column(t2, c)[:]), MSv2.columnnames(t2))
        # every storage manager / engine of the source is kept
        @test sort([m.name for m in t2.managers]) == sort([m.name for m in t.managers])
        _HAVE_CASACORE && @test size(CCT.Table(_cc_copy(dst)), 1) == 0
    end

    # an empty `query` result and `SELECT ... INTO`
    dst = joinpath(mktempdir(), "q")
    copytable(dst, MSv2.query(t, "A > 99"))
    @test MSv2.nrow(readtable(dst)) == 0
    p = joinpath(mktempdir(), "o")
    MSv2.taql(src, "SELECT A, V WHERE A > 99 INTO '$p'")
    @test MSv2.nrow(readtable(p)) == 0 && MSv2.columnnames(readtable(p)) == ["A", "V"]

    # a Dysco column has no zero-row form: an empty selection copies it as a plain column
    let ds = joinpath(mktempdir(), "ds")
        _dysco_synth_ms(ds)                                   # from dysco_tests.jl
        dsrc = readtable(ds)
        @test "DyscoStMan" in [m.name for m in dsrc.managers]
        dd = joinpath(mktempdir(), "dd"); copytable(dd, dsrc; rows=1:0)
        @test MSv2.nrow(readtable(dd)) == 0
        @test !("DyscoStMan" in [m.name for m in readtable(dd).managers])
        dd3 = joinpath(mktempdir(), "dd3"); copytable(dd3, dsrc; rows=1:3)
        @test "DyscoStMan" in [m.name for m in readtable(dd3).managers]
    end

    # the other engine kinds
    nn = 4
    for (spec, data) in [((; kind=MSv2.CompressComplex(), scale=0.01f0, offset=0f0), [rand(ComplexF32, 2, 3) for _ in 1:nn]),
                         ((; kind=MSv2.CompressComplexSD(), scale=0.01f0, offset=0f0), [rand(ComplexF32, 2, 3) for _ in 1:nn]),
                         ((; kind=MSv2.Mapped()), [rand(ComplexF32, 2, 3) for _ in 1:nn]),
                         ((; kind=MSv2.BitFlags(), stored_type=MSv2.TpInt), [rand(Bool, 2, 3) for _ in 1:nn]),
                         ((; kind=MSv2.ScaledArray(), scale=0.5f0, offset=1f0, stored_type=MSv2.TpInt), [rand(Float32, 3) for _ in 1:nn]),
                         ((; kind=MSv2.ScaledComplex(), scale=ComplexF32(0.01, 0.01), offset=ComplexF32(0), stored_type=MSv2.TpShort),
                          [rand(ComplexF32, 2, 3) for _ in 1:nn]),
                         ((; kind=MSv2.CompressFloat(), autoscale=true), [rand(Float32, 4) for _ in 1:nn])]
        es = joinpath(mktempdir(), "e"); ed = joinpath(mktempdir(), "ed")
        write_table(es, "T", Pair{String,Any}["A" => collect(1:nn), "V" => data]; nrow=nn, engines=Dict("V" => spec))
        copytable(ed, readtable(es); rows=1:0)
        e2 = readtable(ed)
        @test MSv2.nrow(e2) == 0 && isempty(column(e2, "V")[:])
        # (a `Mapped` source names its stored type differently from what a copy writes: not a
        # difference made by a zero-row copy, so only the others are compared by name)
        spec.kind isa MSv2.Mapped ||
            @test sort([m.name for m in e2.managers]) == sort([m.name for m in readtable(es).managers])
    end

    # a forwarded column
    fs = joinpath(mktempdir(), "fs"); write_table(fs, "T", Pair{String,Any}["A" => collect(1:4)]; nrow=4)
    ff = joinpath(mktempdir(), "ff"); MSv2.reference_copy(ff, readtable(fs))
    fd = joinpath(mktempdir(), "fd"); copytable(fd, readtable(ff); rows=1:0)
    @test MSv2.nrow(readtable(fd)) == 0

    # the sample MS: copyms of NO rows keeps the layout, validates, and opens in casacore
    if isdir(SAMPLE_MS)
        d0 = joinpath(mktempdir(), "e.ms")
        copyms(SAMPLE_MS, d0; rows=1:0)
        m0 = MeasurementSet(d0)
        main = readtable(d0)
        @test MSv2.nrow(main) == 0
        @test isempty(MSv2.validate(m0))
        @test all(c -> isempty(column(main, c)[:]), MSv2.columnnames(main))
        @test Set(m.name for m in main.managers) ⊇ Set(["StandardStMan", "IncrementalStMan", "TiledShapeStMan", "TiledColumnStMan"])
        _HAVE_CASACORE && @test size(CCT.Table(_cc_copy(d0)), 1) == 0
        # ... and it can be filled again
        edit(d0) do e
            MSv2.addrows!(e, 2)
            e["TIME"][1] = 1.0; e["TIME"][2] = 2.0
            e["UVW"][1] = [1.0, 2.0, 3.0]; e["UVW"][2] = [4.0, 5.0, 6.0]
        end
        filled = readtable(d0)
        @test MSv2.nrow(filled) == 2 && column(filled, "TIME")[:] == [1.0, 2.0]
        @test column(filled, "UVW")[2] == [4.0, 5.0, 6.0]
    end
end

@testset "growing a zero-row table (Phase 266)" begin
    # our edit: every manager, then read back by ours and by casacore
    n = 6
    src = joinpath(mktempdir(), "s")
    write_table(src, "S", Pair{String,Any}[
        "A" => collect(1:n), "B" => Float64.(1:n), "V" => [rand(Float32, 2, 3) for _ in 1:n],
        "U" => [rand(3) for _ in 1:n], "C" => [rand(2, k) for k in [1, 2, 1, 2, 1, 2]],
        "CF" => [rand(Float32, 4) for _ in 1:n], "S" => ["s$i" for i in 1:n], "R" => [rand(i % 3 + 1) for i in 1:n]];
        nrow=n, ism=["B"], tsm=[["V"]], tcm=[["U"]], tcell=[["C"]],
        engines=Dict("CF" => (; kind=MSv2.CompressFloat(), scale=0.01, offset=0.0)))
    d = joinpath(mktempdir(), "d")
    copytable(d, readtable(src); rows=1:0)
    edit(d) do e
        MSv2.addrows!(e, 2)
        e["A"][1] = 7; e["A"][2] = 8
        e["B"][1] = 1.5; e["B"][2] = 2.5
        e["V"][1] = ones(Float32, 2, 3); e["V"][2] = zeros(Float32, 2, 3)
        e["U"][1] = [1.0, 2, 3]; e["U"][2] = [4.0, 5, 6]
        e["C"][1] = ones(2, 1); e["C"][2] = 2 .* ones(2, 2)
        e["CF"][1] = Float32[1, 2, 3, 4]; e["CF"][2] = Float32[4, 3, 2, 1]
        e["S"][1] = "x"; e["S"][2] = "yy"
        e["R"][1] = [1.0]; e["R"][2] = [1.0, 2.0, 3.0]
    end
    t = readtable(d)
    @test MSv2.nrow(t) == 2
    @test column(t, "A")[:] == [7, 8] && column(t, "B")[:] == [1.5, 2.5]
    @test column(t, "U")[:] == [[1.0, 2, 3], [4.0, 5, 6]]
    @test column(t, "V")[1] == ones(Float32, 2, 3) && column(t, "V")[2] == zeros(Float32, 2, 3)
    @test size.(column(t, "C")[:]) == [(2, 1), (2, 2)]
    @test column(t, "S")[:] == ["x", "yy"] && column(t, "R")[:] == [[1.0], [1.0, 2.0, 3.0]]
    @test all(isapprox.(column(t, "CF")[1], Float32[1, 2, 3, 4]; atol=0.01))
    if _HAVE_CASACORE
        cc = CCT.Table(_cc_copy(d))
        @test size(cc, 1) == 2
        @test cc[:A][:] == [7, 8] && cc[:S][:] == ["x", "yy"]
        @test [cc[:U][:, i] for i in 1:2] == [[1.0, 2, 3], [4.0, 5, 6]]
    end

    # removing every row and growing back
    d2 = joinpath(mktempdir(), "d2"); cp(src, d2)
    edit(d2) do e; MSv2.removerows!(e, 1:n); end
    t2 = readtable(d2)
    @test MSv2.nrow(t2) == 0 && all(c -> isempty(column(t2, c)[:]), MSv2.columnnames(t2))
    MSv2.taql(d2, "INSERT INTO t (A, B) VALUES (1, 2.5)")
    t3 = readtable(d2)
    @test MSv2.nrow(t3) == 1 && column(t3, "A")[:] == [1]
    @test size(column(t3, "V")[1]) == (2, 3)                 # a tiled cell of unknown shape keeps its ndim
    @test ndims(column(t3, "C")[1]) == 2                     # ... an appended empty cell too
    @test isempty(column(t3, "R")[1])
    _HAVE_CASACORE && @test size(CCT.Table(_cc_copy(d2)), 1) == 1

    # a REAL casacore adding a row to a zero-row table of ours: every type x shape x manager.
    # (Before this phase a zero-row IncrementalStMan file bus-errored casacore here.)
    if _HAVE_TAQL
        lit = [(Bool, "true", true), (UInt8, "7", UInt8(7)), (Int32, "7", Int32(7)), (Float64, "1.5", 1.5),
               (ComplexF32, "complex(1,2)", ComplexF32(1, 2)), (String, "'ab'", "ab")]
        shp = [(:scalar, ()), (:fixed3, (3,)), (:fixed23, (2, 3)), (:var, nothing)]
        gen(::Type{String}) = "x"
        gen(::Type{Bool}) = true
        gen(T) = zero(T)
        same(a, b) = a isa AbstractArray ? (size(a) == size(b) && all(isequal.(a, b))) : isequal(a, b)
        nfail = 0
        for (T, expr, val) in lit, (sn, sh) in shp, m in (:ssm, :ism, :tsm, :tcm)
            (m in (:tsm, :tcm) && (sh === () || T === String)) && continue
            (m === :tcm && sh === nothing) && continue
            col = sh === () ? [gen(T) for _ in 1:2] : sh === nothing ? [[gen(T) for _ in 1:k] for k in 1:2] :
                  [reshape([gen(T) for _ in 1:prod(sh)], sh...) for _ in 1:2]
            kw = m === :ism ? (; ism=["X"]) : m === :tsm ? (; tsm=[["X"]]) : m === :tcm ? (; tcm=[["X"]]) : (;)
            s = joinpath(mktempdir(), "s"); dd = joinpath(mktempdir(), "d")
            ok = try
                write_table(s, "T", Pair{String,Any}["X" => col]; nrow=2, kw...)
                copytable(dd, readtable(s); rows=1:0)
                ins = sh === () ? expr : sh === nothing ? "array($expr,[3])" : "array($expr,[" * join(sh, ",") * "])"
                tc = _taqlcmd("INSERT INTO \$1 (X) VALUES ($ins)", dd); CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
                got = column(readtable(dd), "X")[:]
                want = sh === () ? val : sh === nothing ? fill(val, 3) : fill(val, sh...)
                length(got) == 1 && same(got[1], want)
            catch
                false
            end
            ok === true || (nfail += 1; @info "casacore INSERT into our zero-row table" T sn m)
        end
        @test nfail == 0
    end
end

@testset "zero-row IncrementalStMan file matches casacore's (Phase 266)" begin
    if _HAVE_TAQL
        real = joinpath(mktempdir(), "r")
        tc = _taql_create("CREATE TABLE $real [B R8] LIMIT 0 DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"B\"]]")
        CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
        ours = joinpath(mktempdir(), "o")
        write_table(ours, "T", Pair{String,Any}["B" => Float64[]]; nrow=0, ism=["B"])
        a = read(joinpath(real, "table.f0")); b = read(joinpath(ours, "table.f0"))
        @test length(a) == length(b)
        # only persCacheSize (header byte 41) differs; the bucket -- including the row-0 entry
        # casacore's reader assumes -- and the index are byte-identical
        @test [i - 1 for i in eachindex(a) if a[i] != b[i]] == [41]
    end
end

@testset "undefined tiled cells (Phase 266)" begin
    if _HAVE_TAQL
        # real casacore: an unwritten variable-shape tiled cell reads as an empty array
        for md in ("TiledShapeStMan", "TiledCellStMan")
            dir = joinpath(mktempdir(), "t")
            spec = md == "TiledCellStMan" ? "SPEC=[DEFAULTTILESHAPE=[2]]" : "SPEC=[DEFAULTTILESHAPE=[2,2]]"
            tc = _taql_create("CREATE TABLE $dir [X R8 [NDIM=1]] LIMIT 4 DMINFO [TYPE=\"$md\", NAME=\"TSM\", $spec, COLUMNS=[\"X\"]]")
            CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            col = column(readtable(dir), "X")
            @test size.(col[:]) == fill((0,), 4)
            @test size(col[1]) == (0,)
            @test size(CCT.Table(_cc_copy(dir))[:X][1]) == (0,)
            # write two of the four cells; the others stay undefined (a gap in the row map)
            _taqlcmd("UPDATE \$1 SET X = array(rownumber()*1.0,[3]) WHERE rownumber()==2 OR rownumber()==4", dir)
            got = column(readtable(dir), "X")[:]
            @test size.(got) == [(0,), (3,), (0,), (3,)]
            @test got[2] == fill(2.0, 3) && got[4] == fill(4.0, 3)
        end
    end

    # ours writes empty cells as undefined cells; casacore reads them back as empties
    col = [Float64[], [1.0, 2, 3], Float64[], [4.0, 5, 6, 7], [8.0], Float64[]]
    for kw in ((; tsm=[["X"]]), (; tcell=[["X"]]))
        dir = joinpath(mktempdir(), "t")
        write_table(dir, "T", Pair{String,Any}["X" => col]; nrow=6, kw...)
        got = column(readtable(dir), "X")[:]
        @test got == col && size.(got) == size.(col)
        if _HAVE_CASACORE
            cc = CCT.Table(_cc_copy(dir))[:X]
            @test [vec(cc[i]) for i in 1:6] == col
        end
        # define an undefined cell, change a shape, extend past the end: needs the regenerating path
        edit(dir) do e
            e["X"][1] = [9.0, 9.0]; e["X"][2] = [7.0, 7.0, 7.0]; e["X"][6] = [1.0]
        end
        want = [[9.0, 9.0], [7.0, 7.0, 7.0], Float64[], [4.0, 5, 6, 7], [8.0], [1.0]]
        @test column(readtable(dir), "X")[:] == want
        _HAVE_CASACORE && @test [vec(CCT.Table(_cc_copy(dir))[:X][i]) for i in 1:6] == want
    end

    # an ordinary same-shape edit still takes the in-place fast path (the file is patched, not rewritten)
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["X" => [rand(2, 3) for _ in 1:5]]; nrow=5, tsm=[["X"]])
    ino = stat(joinpath(dir, "table.f0")).inode
    edit(dir) do e; e["X"][3] = zeros(2, 3); end
    @test stat(joinpath(dir, "table.f0")).inode == ino
    @test column(readtable(dir), "X")[3] == zeros(2, 3)
end

@testset "VariableShape keeps its ndim (Phase 266)" begin
    @test MSv2.VariableShape() == MSv2.VariableShape(0)
    @test MSv2._cell_ndim(MSv2.columndesc(let d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => [rand(2, k) for k in 1:3]]; nrow=3); readtable(d) end, "X")) == 2
    # a zero-row column's ndim comes from the element type
    @test MSv2._infer_shape(Vector{Float64}[]) == MSv2.VariableShape(1)
    @test MSv2._infer_shape(Matrix{Float64}[]) == MSv2.VariableShape(2)
    @test MSv2._infer_shape(Float64[]) == ()
end
