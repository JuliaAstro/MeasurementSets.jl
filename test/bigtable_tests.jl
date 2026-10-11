# Very large tables (Phase 398): row numbers beyond 2^31 / 2^32, tile files and hypercube offsets beyond
# 2 GiB, and the guards that keep an oversized table from taking the machine down.
#
# The 64-bit forms are casacore's: `Table` version 3 and the ColumnSet nrow beyond Int max, `ISMIndex`
# version 2 and a 64-bit row-number flag in each ISM bucket, 64-bit row blocks in the SSM index,
# `TSMFile` / `TSMCube` version 2 records beyond 2 GiB.  An IncrementalStMan table stores only the
# changes, so a casacore-written table of 5e9 rows is a 33 KB file -- test/data/ism64.tbl is one
# (column A Int32, B Float64 = A/2; the rows listed below hold the only non-zero values).

import Tables

const _ISM64 = joinpath(@__DIR__, "data", "ism64.tbl")
const _ISM64_N = 5_000_000_000
const _ISM64_SET = Dict(10 => 3, 2^31 + 10 => 7, 2^32 + 5 => 9, _ISM64_N - 1 => 12, _ISM64_N => 11)

@testset "5e9-row casacore IncrementalStMan table (Phase 398)" begin
    r = readtable(_ISM64)
    @test nrow(r) == _ISM64_N
    ca = column(r, "A")
    cb = column(r, "B")
    @test length(ca) == _ISM64_N
    # every row around each place the stored value changes -- below and above 2^31 and 2^32
    expect(i) = (v = 0; for k in sort(collect(keys(_ISM64_SET))); k <= i && (v = _ISM64_SET[k]); end; v)
    for edge in keys(_ISM64_SET), i in (edge - 1, edge, edge + 1)
        1 <= i <= _ISM64_N || continue
        @test ca[i] == expect(i)
        @test getcell(r, "A", i) == expect(i)
        @test cb[i] == expect(i) / 2
    end
    for i in (1, 2^31 - 1, 2^31, 2^31 + 1, 2^32 - 1, 2^32, 2^32 + 1)
        @test ca[i] == expect(i)
    end
    @test_throws BoundsError ca[_ISM64_N + 1]
    @test eltype(ca) == Int32
    # row iteration reads the first rows without touching the rest
    rows = collect(Iterators.take(Tables.rows(r), 3))
    @test length(rows) == 3 && rows[1].A == 0
end

# casacore-authored TiledColumnStMan table of 4.5e9 Bool cells: the TiledStMan header is its version-3 form
# (64-bit row count, file count and cube count; the persistent cache size stays 32-bit -- a misread of that
# field once made every such table fail with "corrupt hypercube dimensionality").  test/data/tcm64.tbl holds
# only the three small files; the 563 MB tile file is created sparse here with the four set bits.
const _TCM64 = joinpath(@__DIR__, "data", "tcm64.tbl")

@testset "4.5e9-row casacore TiledColumnStMan table (Phase 398)" begin
    d = joinpath(mktempdir(), "tcm64.tbl")
    cp(_TCM64, d)
    n = 4_500_000_000
    tile = joinpath(d, "table.f0_TSM0")
    # tile [1, 65536] of bit-packed Bool = 8192 bytes; row r is tile (r-1)÷65536, bit (r-1)%65536
    setbits = [10, 2^31 + 5, 2^32 + 7, n]
    open(tile, "w") do io
        truncate(io, 562_503_680)
        for r in setbits
            q, b = divrem(r - 1, 65536)
            seek(io, q * 8192 + b ÷ 8)
            write(io, UInt8(1) << (b % 8))
        end
    end
    if stat(tile).blocks * 512 > 64 * 2^20
        @info "skipping the 4.5e9-row tiled test: this filesystem does not support sparse files"
    else
        r = readtable(d)
        @test nrow(r) == n
        c = column(r, "A")
        for i in (1, 9, 10, 11, 2^31 + 4, 2^31 + 5, 2^31 + 6, 2^32 + 6, 2^32 + 7, 2^32 + 8, n - 1, n)
            @test c[i] == [i in setbits]
        end
        if _HAVE_CASACORE
            ct = CCT.Table(d)
            for i in (10, 2^31 + 5, 2^32 + 7, n, n - 1)
                @test ct[:A][:, i] == [i in setbits]
            end
        end
    end
end

@testset "an oversized table is refused, not run to exhaustion (Phase 398)" begin
    d = joinpath(mktempdir(), "ism64.tbl")
    cp(_ISM64, d)
    r = readtable(d)
    # edit keeps a row map and rewrites whole columns: 5e9 rows cannot be held
    e = try edit(d); nothing catch ex; ex end
    @test e isa ArgumentError
    @test occursin("rows would need", sprint(showerror, e))
    @test isempty(MSv2._HELD_LOCKS)                            # the refused session released its lock
    # a whole-column read of a column larger than half the machine's memory
    if Sys.total_memory() < 80 * 2^30                          # 5e9 Float64 = 40 GB
        err = try column(r, "B")[:]; nothing catch ex; ex end
        @test err isa ArgumentError && occursin("read it in row ranges", sprint(showerror, err))
    end
    # copytable reads every column: refused before anything is created
    dst = joinpath(dirname(d), "copy")
    err = try copytable(dst, r); nothing catch ex; ex end
    @test err isa ArgumentError && occursin("exceed", sprint(showerror, err))
    @test !ispath(dst)
    # writers store 32-bit row counts: beyond 2^32-1 a clear error, no stray directory
    w = joinpath(dirname(d), "w")
    err = try write_table(w, "T", Pair{String,Any}["A" => Int32[1]]; nrow=2^32); nothing catch ex; ex end
    @test err isa ArgumentError
    @test !ispath(w)
    @test_throws ArgumentError MSv2._check_nrow_limit(2^32, "x")
    @test MSv2._check_nrow_limit(2^32 - 1, "x") === nothing
    # the budget helpers themselves
    @test_throws ArgumentError MSv2._check_row_budget(2^40, 8, "x")
    @test MSv2._check_row_budget(1000, 8, "x") === nothing
    d1 = columndesc(r, "A")
    @test_throws ArgumentError MSv2._check_read_budget(d1, 2^45)
    @test MSv2._check_read_budget(d1, 1000) === nothing
end

@testset "edit materialisation: bulk path for scalar columns (Phase 398)" begin
    d = joinpath(mktempdir(), "t")
    n = 2000
    write_table(d, "T", Pair{String,Any}["X" => Float64.(1:n) ./ 3, "Y" => Int32.(div.(1:n, 50)), "S" => ["s$i" for i in 1:n]];
                nrow=n, ism=["X", "Y"])
    # untouched row map: bulk read; reordered row map (removerows!): per-cell read -- same values
    edit(d) do t
        t[:X][7] = -1.5
        t[:Y][1000] = Int32(-3)
    end
    r = readtable(d)
    @test column(r, "X")[7] == -1.5 && column(r, "X")[8] == 8 / 3
    @test column(r, "Y")[1000] == -3 && column(r, "Y")[999] == div(999, 50)
    edit(d) do t
        removerows!(t, [1, 2, 3])
        t[:X][1] = 0.25                                       # row 4 of the original
    end
    r = readtable(d)
    @test nrow(r) == n - 3
    @test column(r, "X")[1] == 0.25 && column(r, "X")[2] == 5 / 3
    @test column(r, "S")[1] == "s4"
    @test column(r, "Y")[end] == div(n, 50)
end

@testset "tile files and hypercube offsets beyond 2 GiB (Phase 398)" begin
    # A TiledCellStMan table whose last cell sits at byte offset ~3 GB of a SPARSE tile file: the
    # cube record then needs the 64-bit offset form and the file record the 64-bit length (version 2).
    d = joinpath(mktempdir(), "t")
    cells = [Float32.(reshape(1:(4 * (3 + i)), 4, 3 + i)) .+ 100i for i in 1:3]     # 4x4, 4x5, 4x6 -- per-row shapes
    write_table(d, "T", Pair{String,Any}["A" => cells]; nrow=3, tcell=[["A"]])
    tile = joinpath(d, "table.f0_TSM0")
    low = read(tile)
    @test length(low) == 320                                  # tile (4,4): 1 + 2 + 2 tiles of 64 bytes
    big = 3_000_000_000
    open(tile, "w") do io
        write(io, low[1:192])                                 # rows 1 and 2 where they were
        truncate(io, big + 128)                                # sparse: nothing is stored for the gap
        seek(io, big)
        write(io, low[193:320])                               # row 3 moved past 2 GiB
    end
    sparse_ok = stat(tile).blocks * 512 < 64 * 2^20          # the filesystem really made it sparse
    sparse_ok || @info "skipping the >2 GiB tile-file test: this filesystem does not support sparse files"
    if sparse_ok
    # new headers: cube 3 at the large offset, the file record with the large length
    types = [MSv2.TpFloat]
    w = MSv2.AipsWriter(; endian=:big)
    MSv2.putstart(w, "TiledCellStMan", MSv2.TSM_WRAPPER_VER)
    MSv2.wr_iposition(w, (4, 4))                              # defaultTileShape
    cubes = [MSv2._TSMCubeSpec((4, 4), (4, 4), 0, 0), MSv2._TSMCubeSpec((4, 5), (4, 4), 0, 64),
             MSv2._TSMCubeSpec((4, 6), (4, 4), 0, big)]
    MSv2._tsm_headerfileput!(w, 0, types, "TSMA", 2, [MSv2._TSMFileSpec(true, 0, big + 128)], cubes, 3, :little;
                             cube_extensible=false)
    MSv2.putend(w)
    write(joinpath(d, "table.f0"), MSv2.bytes(w))
    r = readtable(d; precision=:full)
    @test column(r, "A")[1] == cells[1]
    @test column(r, "A")[2] == cells[2]
    @test column(r, "A")[3] == cells[3]                       # read through the 64-bit offset
    @test getcell(r, "A", 3) == cells[3]
    inst = MSv2._dm_instance(r, columndesc(r, "A").sequ)
    @test inst.cubes[3].offset == big
    # in-place edit of the far cell through the writable mmap
    edit(d) do t
        t[:A][3] = fill(-2f0, 4, 6)
    end
    r2 = readtable(d; precision=:full)
    @test column(r2, "A")[3] == fill(-2f0, 4, 6)
    @test column(r2, "A")[1] == cells[1]
    if _HAVE_CASACORE
        ct = CCT.Table(d)
        @test ct[:A][3] == fill(-2f0, 4, 6)
        @test ct[:A][1] == cells[1]
    end
    end
end
