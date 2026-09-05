# Phase 30: TaQL-lite write commands -- update! / delete! / SELECT INTO / taql.

@testset "update! -- Julia form" begin
    dir = mktempdir()
    K = Int32[0, 1, 0, 1, 2, 0, 2, 1]
    A = Int32[10, 20, 30, 40, 50, 60, 70, 80]
    B = Int32[1, 2, 3, 4, 5, 6, 7, 8]
    UVW = [Float64[i, i + 1, i + 2] for i in 1:8]

    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["K" => copy(K), "A" => copy(A),
                    "B" => copy(B), "UVW" => deepcopy(UVW)]; nrow=8, tsm=[["UVW"]]); p)

    p1 = mk("t1")
    @test update!(p1; set=["A" => "A + 100"], where="K == 0") == 3
    t = readtable(p1)
    @test column(t, "A")[:] == Int32[K[i] == 0 ? A[i] + 100 : A[i] for i in 1:8]
    @test column(t, "B")[:] == B                     # untouched

    # swap uses pre-update values
    p2 = mk("t2")
    update!(p2; set=["A" => "B", "B" => "A"])
    t2 = readtable(p2)
    @test column(t2, "A")[:] == B && column(t2, "B")[:] == A

    # array column, elementwise
    p3 = mk("t3")
    update!(p3; set=["UVW" => "UVW * 2.0"], where="K == 1")
    t3 = readtable(p3)
    for i in 1:8
        @test column(t3, "UVW")[i] == (K[i] == 1 ? UVW[i] .* 2.0 : UVW[i])
    end

    # closure where; whole-table (where=nothing)
    p4 = joinpath(dir, "t4")
    write_table(p4, "t4", Pair{String,Any}["A" => copy(A)]; nrow=8)
    @test update!(p4; set=["A" => "0"], where=row -> row.A > 40) ==
          count(>(40), A)
    @test column(readtable(p4), "A")[:] == Int32[a > 40 ? 0 : a for a in A]

    p5 = joinpath(dir, "t5")
    write_table(p5, "t5", Pair{String,Any}["A" => copy(A)]; nrow=8)
    @test update!(p5; set=["A" => "A * 10"]) == 8
    @test column(readtable(p5), "A")[:] == A .* 10

    # errors
    @test_throws ArgumentError update!(p5; set=["NOPE" => "1"])
    @test_throws ArgumentError update!(p5; set=["A" => "gsum(A)"])
    @test_throws ArgumentError update!(p5; set=Pair{String,String}[])

    # target may be an open Table
    p6 = mk("t6")
    @test update!(readtable(p6); set=["A" => "A - 5"], where="K == 2") == 2
end

@testset "delete!" begin
    dir = mktempdir()
    K = Int32[0, 1, 0, 1, 2, 0, 2, 1, 0, 2]
    A = collect(Int32, 1:10)
    V = [Float64[i, 2i] for i in 1:10]

    p1 = joinpath(dir, "d1")
    write_table(p1, "d1", Pair{String,Any}["K" => K, "A" => A, "V" => V]; nrow=10, tsm=[["V"]])
    d = delete!(p1; where="K == 2")
    @test d == count(==(Int32(2)), K)
    t = readtable(p1)
    keep = findall(!=(Int32(2)), K)
    @test nrow(t) == length(keep)
    @test column(t, "A")[:] == A[keep]
    @test column(t, "V")[:] == V[keep]

    # closure where
    p2 = joinpath(dir, "d2")
    write_table(p2, "d2", Pair{String,Any}["A" => copy(A)]; nrow=10)
    @test delete!(p2; where=row -> row.A % 2 == 0) == 5
    @test column(readtable(p2), "A")[:] == filter(isodd, A)

    # delete every row
    p3 = joinpath(dir, "d3")
    write_table(p3, "d3", Pair{String,Any}["A" => copy(A)]; nrow=10)
    @test delete!(p3) == 10
    @test nrow(readtable(p3)) == 0
end

@testset "SELECT INTO -- copytable of a query result" begin
    dir = mktempdir()
    A = collect(Int32, 1:12)
    B = collect(0.0:1.0:11.0)
    write_table(joinpath(dir, "src"), "src", Pair{String,Any}["A" => A, "B" => B]; nrow=12)
    s = readtable(joinpath(dir, "src"))

    d1 = joinpath(dir, "out1")
    @test copytable(d1, query(s, "A > 6")) == d1
    o1 = readtable(d1)
    @test o1 isa Table
    @test column(o1, "A")[:] == A[A .> 6]
    @test column(o1, "B")[:] == B[A .> 6]

    d2 = joinpath(dir, "out2")
    copytable(d2, groupby(s, "A"; select=["A" => :A, "N" => "gcount()"]); name="GRP")
    o2 = readtable(d2)
    @test Set(columnnames(o2)) == Set(["A", "N"])
    @test column(o2, "N")[:] == fill(1, 12)

    # a join result too
    write_table(joinpath(dir, "r"), "r", Pair{String,Any}["V" => ["x", "y"]]; nrow=2)
    r = readtable(joinpath(dir, "r"))
    write_table(joinpath(dir, "l"), "l", Pair{String,Any}["K" => Int32[0, 1, 0], "W" => Float64[1, 2, 3]]; nrow=3)
    l = readtable(joinpath(dir, "l"))
    d3 = joinpath(dir, "out3")
    copytable(d3, join(l, r; on="K", rightcols=["V" => "VV"]))
    @test column(readtable(d3), "VV")[:] == ["x", "y", "x"]
end

@testset "taql -- string commands" begin
    dir = mktempdir()
    K = Int32[0, 1, 0, 1, 2, 0, 2, 1]
    A = Int32[10, 20, 30, 40, 50, 60, 70, 80]
    B = Int32[1, 2, 3, 4, 5, 6, 7, 8]

    p1 = joinpath(dir, "u")
    write_table(p1, "u", Pair{String,Any}["K" => K, "A" => copy(A)]; nrow=8)
    @test taql(p1, "UPDATE u SET A = A + 1 WHERE K == 0") == 3
    @test column(readtable(p1), "A")[:] == Int32[K[i] == 0 ? A[i] + 1 : A[i] for i in 1:8]

    # multi-assign, comma inside iif()
    p2 = joinpath(dir, "u2")
    write_table(p2, "u2", Pair{String,Any}["A" => copy(A), "B" => copy(B)]; nrow=8)
    taql(p2, "UPDATE t SET A = iif(A > 40, 1, 0), B = B * 2")
    t2 = readtable(p2)
    @test column(t2, "A")[:] == Int32[a > 40 ? 1 : 0 for a in A]
    @test column(t2, "B")[:] == B .* 2

    p3 = joinpath(dir, "d")
    write_table(p3, "d", Pair{String,Any}["K" => K, "A" => copy(A)]; nrow=8)
    @test taql(p3, "DELETE FROM d WHERE K == 1") == 3
    @test nrow(readtable(p3)) == 5

    # SELECT ... INTO
    write_table(joinpath(dir, "s"), "s", Pair{String,Any}["A" => A, "B" => B]; nrow=8)
    s = readtable(joinpath(dir, "s"))
    d4 = joinpath(dir, "sout")
    @test taql(s, "SELECT A, B AS BB WHERE A > 30 ORDER BY A INTO '$d4'") == d4
    o = readtable(d4)
    @test Set(columnnames(o)) == Set(["A", "BB"])
    sel = A .> 30
    p = sortperm(A[sel])
    @test column(o, "A")[:] == A[sel][p]
    @test column(o, "BB")[:] == B[sel][p]

    # SELECT with no INTO -> a query result
    res = taql(s, "SELECT * WHERE A > 60")
    @test res isa RefTable
    @test column(res, "A")[:] == A[A .> 60]

    # SELECT * INTO (copy all)
    d5 = joinpath(dir, "allout")
    taql(s, "SELECT * INTO '$d5'")
    @test column(readtable(d5), "A")[:] == A

    # malformed
    @test_throws ArgumentError taql(p3, "FROBNICATE x")
    @test_throws ArgumentError taql(p3, "UPDATE t A = 1")
end

if _HAVE_TAQL
    @testset "write commands -- real TaQL cross-check" begin
        _run(path, cmd) = begin
            v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
            tb = CCT.Table(path)
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(tb.tableref)))
            GC.@preserve tb Casacore.LibCasacore.tableCommand(cmd, v)
            GC.gc(); GC.gc()
        end

        for (jl_cmd, taql_cmd, wherestr) in (
            (["A" => "A * 2"], "SET A = A * 2", "K == 0"),
            (["A" => "A + B"], "SET A = A + B", "K != 1"),
            (["B" => "B - 1", "A" => "A * 10"], "SET B = B - 1, A = A * 10", nothing),
        )
            d = mktempdir()
            K = Int32[(i - 1) % 3 for i in 1:12]
            A = collect(Float64, 1:12)
            B = collect(Float64, 12:-1:1)
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                            Pair{String,Any}["K" => K, "A" => copy(A), "B" => copy(B)]; nrow=12)
            end
            update!(joinpath(d, "ours"); set=jl_cmd, where=wherestr)
            w = wherestr === nothing ? "" : " WHERE $wherestr"
            _run(joinpath(d, "ref"), "UPDATE \$1 $taql_cmd$w")
            ours = readtable(joinpath(d, "ours"))
            ref = readtable(joinpath(d, "ref"))
            @test column(ours, "A")[:] ≈ column(ref, "A")[:]
            @test column(ours, "B")[:] ≈ column(ref, "B")[:]
        end

        for wherestr in ("K == 2", "A > 6.0 OR A < 3.0")
            d = mktempdir()
            K = Int32[(i - 1) % 3 for i in 1:12]
            A = collect(Float64, 1:12)
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                            Pair{String,Any}["K" => K, "A" => copy(A)]; nrow=12)
            end
            delete!(joinpath(d, "ours"); where=wherestr)
            _run(joinpath(d, "ref"), "DELETE FROM \$1 WHERE $wherestr")
            @test column(readtable(joinpath(d, "ours")), "A")[:] ==
                  column(readtable(joinpath(d, "ref")), "A")[:]
        end
    end
end
