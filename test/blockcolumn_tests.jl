# BlockColumn / rawblock (Phase 236) -- the lazy, single-backing-buffer
# whole-column representation for fixed-shape SSM/TiledStMan array
# columns, plus the tile-batched `_read_cube_bulk` rewrite that reduces
# a whole-column read from one `_rd_run!`/`_rd_bits!` call PER ROW to
# one call PER TILE (live-measured to close nearly all of `UVW`'s
# remaining allocation/wall-clock gap against real casacore C++).

using Random        # (Phase 441's ChunkedColumn test; this file runs before any other that loads it)

@testset "BlockColumn — structural (Phase 236)" begin
    t = readtable(SAMPLE_MS; precision=:full)
    n = nrow(t)

    for name in ("UVW", "DATA", "FLAG")
        c = column(t, name)[:]
        @test c isa MSv2.BlockColumn
        @test length(c) == n
        @test c[1] == getcell(t, name, 1)
        @test c[end] == getcell(t, name, n)
        # every row is a VIEW sharing ONE backing buffer -- the whole
        # point of the lazy representation (a fresh per-row `Array`, the
        # pre-Phase-236 behaviour, would give each row its own buffer).
        @test parent(vec(c[1])) === parent(vec(c[end]))
    end

    # a scalar column is unaffected -- still a plain eager `Vector`.
    tm = column(t, "TIME")[:]
    @test tm isa Vector{Float64}
    @test !(tm isa MSv2.BlockColumn)

    # `getindex(bc, ::Colon)` returns the SAME lazy object (no eager copy).
    c = column(t, "FLAG")[:]
    @test c[:] === c

    # `collect` forces genuine materialisation: a real, eager `Vector`,
    # not the lazy wrapper (Julia's own `collect` contract — see also
    # `Base.collect(::Column)`, which now explicitly forces this off).
    cc = collect(c)
    @test cc isa Vector
    @test !(cc isa MSv2.BlockColumn)
    @test cc == [c[i] for i in 1:length(c)]
    @test collect(column(t, "FLAG")) == cc   # Column's own collect, too
end

@testset "rawblock (Phase 236)" begin
    t = readtable(SAMPLE_MS; precision=:full)
    n = nrow(t)

    rb = rawblock(t, "UVW")
    @test size(rb) == (3, n)
    @test eltype(rb) == Float64
    @test rb[:, 1] == getcell(t, "UVW", 1)
    @test rb[:, end] == getcell(t, "UVW", n)

    rf = rawblock(t, "FLAG")
    @test size(rf) == (4, 64, n)
    @test rf[:, :, 1] == getcell(t, "FLAG", 1)

    # a scalar column has no block representation.
    @test_throws ArgumentError rawblock(t, "TIME")
    # neither does a variable-shape/indirect array column.
    fld = subtable(MeasurementSet(SAMPLE_MS), "SPECTRAL_WINDOW")
    @test_throws ArgumentError rawblock(fld, "CHAN_FREQ")

    # zero-copy WITHIN one decode: every row's view, and `rawblock`'s
    # own reshape, both share the SAME `BlockColumn.backing` -- no
    # re-copy on top of the one read. (A SEPARATE `column(...)[:]` /
    # `rawblock(...)` call decodes the column again from scratch --
    # there is no cross-call caching -- so this must be checked against
    # ONE `BlockColumn` object, not two independent calls.)
    c = column(t, "UVW")[:]
    @test c isa MSv2.BlockColumn
    @test parent(vec(c[1])) === c.backing
    # `reshape` of a `Vector` returns a new wrapper (not `===`) but
    # shares the same underlying memory -- confirm via a round-trip
    # mutation instead of object identity.
    rb = reshape(c.backing, c.cellshape..., c.n)
    old = rb[1, 1]
    c.backing[1] += 1.0
    @test rb[1, 1] == old + 1.0
    c.backing[1] -= 1.0   # restore
end

@testset "SSM fixed-array getcolumn — BlockColumn (Phase 236)" begin
    # extends the Phase 235 `parent(...) === parent(...)` structural
    # check: the SSM path now returns a lazy `BlockColumn`, same as the
    # tiled path — one shared representation across every data manager
    # that has a fixed-shape-array bulk read.
    ant = subtable(MeasurementSet(SAMPLE_MS), "ANTENNA")
    @test columndesc(ant, "POSITION").manager == "StandardStMan"
    pos = column(ant, "POSITION")[:]
    @test pos isa MSv2.BlockColumn
    @test length(pos) == nrow(ant)
    @test pos[1] == getcell(ant, "POSITION", 1)
    @test parent(vec(pos[1])) === parent(vec(pos[end]))

    rb = rawblock(ant, "POSITION")
    @test size(rb) == (3, nrow(ant))
    @test rb[:, 1] == pos[1]
end

@testset "BlockColumn — multi-tile boundary correctness (Phase 236)" begin
    # the tile-batched `_read_cube_bulk` rewrite walks whole tiles at a
    # time; force a small `rowspertile` (via a large per-row cell, so
    # the writer's ~1 MiB-per-tile target picks few rows/tile) so this
    # test genuinely crosses several tile boundaries, not just one.
    dir = mktempdir()
    n = 500
    F = [rand(Bool, 100, 100) for _ in 1:n]
    write_table(joinpath(dir, "t.ms"), "T", ["F" => F]; nrow=n, tsm=[["F"]])
    t = readtable(joinpath(dir, "t.ms"))
    c = MSv2._dm_instance(t, columndesc(t, "F").sequ)
    real = findall(!MSv2.isnull, c.cubes)
    rowspertile = c.cubes[real[1]].tileshape[end]
    @test rowspertile < n   # confirms multiple tiles are genuinely exercised

    mine = getcolumn(t, "F")
    @test mine isa MSv2.BlockColumn
    @test all(mine[r] == F[r] for r in 1:n)

    # same for a non-Bool type, at the same forced multi-tile layout.
    D = [rand(Float32, 100, 100) for _ in 1:n]
    write_table(joinpath(dir, "d.ms"), "T", ["D" => D]; nrow=n, tsm=[["D"]])
    td = readtable(joinpath(dir, "d.ms"))
    mineD = getcolumn(td, "D")
    @test mineD isa MSv2.BlockColumn
    @test all(mineD[r] == D[r] for r in 1:n)
end

@testset "BlockColumn — copytable / edit interop (Phase 236)" begin
    # `_read_cells` (create.jl, behind `copytable`/`copyms`) already
    # calls `Array(v)` on every `AbstractArray` cell — confirms a
    # `BlockColumn` source materialises to real, independent, owned
    # arrays on copy (no aliasing survives into the destination).
    t = readtable(SAMPLE_MS; precision=:full)
    dst = joinpath(mktempdir(), "copy.ms")
    copytable(dst, t)
    tc = readtable(dst; precision=:full)
    @test getcolumn(tc, "DATA")[1] == getcolumn(t, "DATA")[1]
    @test getcolumn(tc, "FLAG")[1] == getcolumn(t, "FLAG")[1]
    @test getcolumn(tc, "UVW")[1] == getcolumn(t, "UVW")[1]

    # `edit`'s per-cell materialisation (`getcell`, not the bulk `[:]`
    # path) is untouched by `BlockColumn` -- confirm a cell write still
    # round-trips and doesn't corrupt a neighbouring row (would be the
    # failure mode if a mutation ever escaped into the shared backing).
    dir2 = mktempdir()
    n = 50
    F = [rand(Bool, 4, 8) for _ in 1:n]
    write_table(joinpath(dir2, "e.ms"), "T", ["F" => F]; nrow=n, tsm=[["F"]])
    p = joinpath(dir2, "e.ms")
    newcell = .!F[3]
    edit(p) do et
        et[:F][3] = newcell
    end
    te = readtable(p)
    @test getcell(te, "F", 3) == newcell
    @test getcell(te, "F", 2) == F[2]      # neighbour untouched
    @test getcell(te, "F", 4) == F[4]
end

if _HAVE_CASACORE
    @testset "BlockColumn vs casacore (Phase 236)" begin
        t = readtable(SAMPLE_MS; precision=:full)
        ct = CCT.Table(SAMPLE_MS)
        n = nrow(t)

        uvw = column(t, "UVW")[:]
        ccu = collect(ct[:UVW][:, :])
        @test all(uvw[r] == ccu[:, r] for r in 1:n)
        @test rawblock(t, "UVW") == ccu

        flag = column(t, "FLAG")[:]
        ccf = collect(ct[:FLAG][:])
        @test all(flag[r] == ccf[r] for r in 1:n)

        data = column(t, "DATA")[:]
        ccd = collect(ct[:DATA][:])
        @test all(data[r] == ccd[r] for r in 1:n)
    end
end

@testset "BlockColumn — allocation (Phase 236)" begin
    # the headline result: a whole-column `UVW` read (lazy, no per-row
    # indexing) should cost close to the theoretical minimum -- just the
    # `(cellshape..., nrow)` backing buffer itself -- not the ~5x-larger
    # figure the pre-tile-batching `BlockColumn` (Phase 236 first draft,
    # still one `_rd_run!` call per ROW) or the pre-Phase-234/235 eager
    # per-row-`Array` code both had.
    t = readtable(SAMPLE_MS; precision=:full)
    n = nrow(t)

    column(t, "UVW")[:]                    # warm up (compile)
    GC.gc()
    a_uvw = @allocated column(t, "UVW")[:]
    a_theoretical = n * 3 * sizeof(Float64)
    # generous 2x margin over the exact backing size (BlockColumn's own
    # tiny struct + whatever bookkeeping `_dm_instance`/`_tile_layout`
    # do); the pre-tile-batching figure was ~5.5x on the real MS.
    @test a_uvw < 2 * a_theoretical

    rawblock(t, "UVW")                     # warm up
    GC.gc()
    a_rb = @allocated rawblock(t, "UVW")
    @test a_rb < 2 * a_theoretical
end

# Phase 441: ChunkedColumn streams a tiled array column through blocks for a query loop
@testset "ChunkedColumn — sequential, skipping and random access == per-cell reads (Phase 441)" begin
    rng = MersenneTwister(441)
    for endian in (:little, :big), shape in ((4, 8), (3,))
        n = 9000; d = mktempdir(); p = joinpath(d, "t")
        C = [rand(rng, ComplexF32, shape...) for _ in 1:n]; F = [rand(rng, Bool, shape...) for _ in 1:n]
        write_table(p, "T", Pair{String,Any}["C" => C, "F" => F]; nrow = n, tsm = [["C", "F"]], endian)
        t = readtable(p; precision = :full)
        for nm in ("C", "F")
            col = column(t, nm); cc = MSv2._chunked(col)
            @test cc isa MSv2.ChunkedColumn && length(cc) == n
            ref = nm == "C" ? C : F
            @test all(cc[i] == ref[i] for i in 1:n)                                   # sequential, crosses every block boundary
            cc = MSv2._chunked(col)
            @test all(cc[i] == ref[i] for i in 1:3:n)                                 # forward with small gaps
            cc = MSv2._chunked(col)
            idx = rand(rng, 1:n, 400); @test all(cc[i] == ref[i] for i in idx)        # random order: cell by cell
            cc = MSv2._chunked(col)
            @test all(cc[i] == ref[i] for i in vcat(1:50, 8990:9000 .- 1, 30:-1:20)) # backwards after forwards
            @test cc[:] == ref && eltype(cc[1]) == eltype(ref[1])
            @test_throws BoundsError cc[0]
            @test_throws BoundsError cc[n + 1]
        end
    end
    # a TiledColumnStMan column (the MS `UVW` layout: fixed cell shape, one hypercube, no row map) is chunked too
    n = 9000; p4 = joinpath(mktempdir(), "t"); U = [rand(rng, 3) for _ in 1:n]
    write_table(p4, "T", Pair{String,Any}["U" => U]; nrow = n, tcm = [["U"]])
    t4 = readtable(p4); col4 = column(t4, "U")
    @test only(t4.managers).name == "TiledColumnStMan"
    cc4 = MSv2._chunked(col4)
    @test cc4 isa MSv2.ChunkedColumn && all(cc4[i] == U[i] for i in 1:n)
    cc4 = MSv2._chunked(col4); @test all(cc4[i] == U[i] for i in rand(rng, 1:n, 300))
    # a short column and a column that is not tiled are not chunked
    p2 = joinpath(mktempdir(), "t"); write_table(p2, "T", Pair{String,Any}["A" => [rand(rng, 3) for _ in 1:100]]; nrow = 100)
    @test !(MSv2._chunked(column(readtable(p2), "A")) isa MSv2.ChunkedColumn)
    # a query over a chunked column gives the same rows as one over the materialised column
    n = 5000; p3 = joinpath(mktempdir(), "t")
    write_table(p3, "T", Pair{String,Any}["C" => [rand(rng, ComplexF32, 2, 4) for _ in 1:n], "K" => collect(1:n)]; nrow = n, tsm = [["C"]])
    t3 = readtable(p3)
    @test query(t3, "abs(C[1,2]) > 0.8").rows == [i for i in 1:n if abs(column(t3, "C")[i][1, 2]) > 0.8]
    @test query(t3, "mean(abs(C)) > 0.6 AND K % 3 == 0").rows ==
          [i for i in 1:n if sum(abs.(column(t3, "C")[i])) / 8 > 0.6 && i % 3 == 0]
end
