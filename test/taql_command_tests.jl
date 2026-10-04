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

    # Phase 149: SET items apply in order, each seeing the PRECEDING
    # item's already-written value for that row -- NOT a swap. Live-
    # verified against real casacore: `SET A=B, B=A` leaves both columns
    # equal to the OLD B (A takes B's old value; B then reads that
    # already-updated A). A prior version of this test asserted a true
    # swap, matching this package's old (incorrect) semantics rather
    # than real casacore's.
    p2 = mk("t2")
    update!(p2; set=["A" => "B", "B" => "A"])
    t2 = readtable(p2)
    @test column(t2, "A")[:] == B && column(t2, "B")[:] == B
    # a later item CAN see an earlier item's write on a DIFFERENT column
    p2b = mk("t2b")
    update!(p2b; set=["A" => "1000", "B" => "A"])   # B ends up 1000, not old A
    t2b = readtable(p2b)
    @test all(==(1000), column(t2b, "A")[:]) && all(==(1000), column(t2b, "B")[:])

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

# Phase 111: UPDATE/DELETE ORDER BY + LIMIT ("update/delete the N
# oldest/newest rows matching a condition").
@testset "update!/delete! -- ORDER BY + LIMIT" begin
    dir = mktempdir()
    A = collect(Int32, 1:10)
    T = Float64.(10:-1:1)                          # descending: row i has TIME = 11-i
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["A" => copy(A), "T" => copy(T)];
                    nrow=10); p)

    # update! -- the 3 matched rows with the smallest T ("oldest")
    p1 = mk("u1")
    @test update!(p1; set=["A" => "A + 100"], where="A > 3", orderby=["T"], limit=3) == 3
    a1 = column(readtable(p1), "A")[:]
    # A>3 candidates are A=4..10 (T=7,6,5,4,3,2,1); smallest-T 3 are A=8,9,10
    @test a1 == Int32[1, 2, 3, 4, 5, 6, 7, 108, 109, 110]

    # orderby entry as a `name => :desc` pair (largest T first == "newest");
    # among A>3 (rows 4..10), T decreases as A increases, so the 2 largest-T
    # rows are A=4 (T=7) and A=5 (T=6)
    p2 = mk("u2")
    @test update!(p2; set=["A" => "A + 100"], where="A > 3", orderby=["T" => :desc], limit=2) == 2
    a2 = column(readtable(p2), "A")[:]
    @test a2 == Int32[1, 2, 3, 104, 105, 6, 7, 8, 9, 10]

    # negative limit -> the LAST |limit| of the ordered set; with no WHERE,
    # ascending-T order is rows [10,9,...,1] (T is the exact row-reverse
    # here), so the last 3 of that order are rows 3,2,1 (A=3,2,1)
    p3 = mk("u3")
    @test update!(p3; set=["A" => "A + 100"], orderby=["T"], limit=-3) == 3
    @test column(readtable(p3), "A")[:] == Int32[101, 102, 103, 4, 5, 6, 7, 8, 9, 10]

    # delete! -- the 2 matched rows with the largest T ("newest"); same
    # A>3 / T-decreasing-with-A geometry as p2 above -> A=4,5 removed
    p4 = mk("d1")
    @test delete!(p4; where="A > 3", orderby=["T" => :desc], limit=2) == 2
    @test column(readtable(p4), "A")[:] == Int32[1, 2, 3, 6, 7, 8, 9, 10]

    # taql string form: ORDER BY / LIMIT parsed out of the command string
    p5 = mk("t1")
    @test taql(p5, "UPDATE t SET A = A + 100 WHERE A > 3 ORDER BY T LIMIT 3") == 3
    @test column(readtable(p5), "A")[:] == a1
    p6 = mk("t2")
    @test taql(p6, "DELETE FROM t WHERE A > 3 ORDER BY T DESC LIMIT 2") == 2
    @test column(readtable(p6), "A")[:] == column(readtable(p4), "A")[:]
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

    # SELECT expr AS (val, mask)
    dm = mktempdir()
    V = [Float64[i i+1; i+2 i+3] for i in 1:4]
    F = [Bool[false true; true false] for _ in 1:4]
    write_table(joinpath(dm, "mt"), "mt", Pair{String,Any}["V" => V, "F" => F];
        nrow=4, tsm=[["V"], ["F"]])
    mt = readtable(joinpath(dm, "mt"))
    r = taql(mt, "SELECT V[V > 2.0] AS (D, M)")
    @test columnnames(r) == ["D", "M"]
    @test collect(r.D)[1] == V[1]
    @test collect(r.M)[1] == (V[1] .> 2.0)   # mask = the selector itself (live-verified vs real casacore)

    # malformed
    @test_throws ArgumentError taql(p3, "FROBNICATE x")
    @test_throws ArgumentError taql(p3, "UPDATE t A = 1")
end

@testset "insert! -- Julia form" begin
    dir = mktempdir()
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["A" => Int32[10, 20, 30],
                    "B" => [1.0, 2.0, 3.0], "S" => ["x", "y", "z"],
                    "V" => [Float64[i, i + 1] for i in 1:3]]; nrow=3, tsm=[["V"]]); p)

    # one row, explicit
    p1 = mk("t1")
    @test insert!(p1; values=["A" => 40, "B" => 4.5]) == 1
    t = readtable(p1)
    @test nrow(t) == 4
    @test column(t, "A")[:] == Int32[10, 20, 30, 40]
    @test column(t, "B")[:] == [1.0, 2.0, 3.0, 4.5]
    @test column(t, "S")[4] == ""              # default
    @test column(t, "V")[4] == Float64[0, 0]   # default same-shape zero array
    @test eltype(column(t, "A")[:]) == Int32   # Int64 40 coerced to Int32

    # NamedTuple row
    p2 = mk("t2")
    @test insert!(p2; values=(; A=Int32(41), B=4.1)) == 1
    @test column(readtable(p2), "A")[:] == Int32[10, 20, 30, 41]

    # multi-row, mixed shapes, partial
    p3 = mk("t3")
    @test insert!(p3; values=[["A" => 50], (; A=60, B=6.5)]) == 2
    t3 = readtable(p3)
    @test nrow(t3) == 5
    @test column(t3, "A")[:] == Int32[10, 20, 30, 50, 60]
    @test column(t3, "B")[:] == [1.0, 2.0, 3.0, 0.0, 6.5]

    # from another table (INSERT ... SELECT)
    p4 = mk("t4")
    s = joinpath(dir, "s")
    write_table(s, "s", Pair{String,Any}["A" => Int32[100, 200], "B" => [10.0, 20.0],
        "S" => ["p", "q"], "V" => [Float64[9, 9] for _ in 1:2]]; nrow=2, tsm=[["V"]])
    @test insert!(p4, readtable(s)) == 2
    t4 = readtable(p4)
    @test column(t4, "A")[:] == Int32[10, 20, 30, 100, 200]
    @test column(t4, "V")[5] == Float64[9, 9]

    # from a query result
    p5 = mk("t5")
    @test insert!(p5, query(readtable(s), "A > 150")) == 1
    @test column(readtable(p5), "A")[:] == Int32[10, 20, 30, 200]

    # errors
    @test_throws ArgumentError insert!(p5; values=["NOPE" => 1])
    @test_throws ArgumentError insert!(p5; values=42)
    @test insert!(p5; values=Pair{String,Any}[]) == 0

    # target may be an open Table
    p6 = mk("t6")
    @test insert!(readtable(p6); values=["A" => 44]) == 1
end

@testset "insert! -- taql string commands" begin
    dir = mktempdir()
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["A" => Int32[1, 2], "B" => [1.0, 2.0]];
                    nrow=2); p)

    p1 = mk("u1")
    @test taql(p1, "INSERT INTO t (A, B) VALUES (3, 3.5)") == 1
    @test column(readtable(p1), "A")[:] == Int32[1, 2, 3]

    p2 = mk("u2")
    @test taql(p2, "INSERT INTO t (A, B) VALUES (3, 3.5), (4, 4.5)") == 2
    t2 = readtable(p2)
    @test column(t2, "A")[:] == Int32[1, 2, 3, 4]
    @test column(t2, "B")[:] == [1.0, 2.0, 3.5, 4.5]

    p3 = mk("u3")                          # no column list -> positional
    @test taql(p3, "INSERT INTO t VALUES (9, 9.9)") == 1
    t3 = readtable(p3)
    @test column(t3, "A")[end] == 9
    @test column(t3, "B")[end] == 9.9

    p4 = mk("u4")
    @test taql(p4, "INSERT INTO t SET A = 7, B = 8.8") == 1
    @test column(readtable(p4), "A")[end] == 7

    p5 = mk("u5")                          # constant expression is fine
    @test taql(p5, "INSERT INTO t (A, B) VALUES (2 + 3, sqrt(16.0))") == 1
    t5 = readtable(p5)
    @test column(t5, "A")[end] == 5
    @test column(t5, "B")[end] == 4.0

    # errors
    @test_throws ArgumentError taql(p5, "INSERT INTO t (A, B) VALUES (A + 1, 2)")
    @test_throws ArgumentError taql(p5, "INSERT INTO t (A, B) VALUES (1, 2, 3)")
    @test_throws ArgumentError taql(p5, "INSERT INTO t FROBNICATE")
end

# Phase 114: array-cell values in the `taql` INSERT VALUES string form.
@testset "insert! -- taql INSERT VALUES array-cell literals" begin
    mkarr(dir, name) = (p = joinpath(dir, name);
        write_table(p, name, Pair{String,Any}["A" => Int32[1, 2],
            "V" => [rand(2, 2) for _ in 1:2], "L" => [rand(3) for _ in 1:2]];
            nrow=2, tsm=[["V"], ["L"]]); p)

    dir = mktempdir()
    p1 = mkarr(dir, "a1")                  # flat + nested array literals
    @test taql(p1, "INSERT INTO t (A, V, L) VALUES (9, [[1.0,2.0],[3.0,4.0]], [7.0,8.0,9.0])") == 1
    t1 = readtable(p1)
    @test column(t1, "A")[:] == Int32[1, 2, 9]
    @test column(t1, "V")[end] == [1.0 3.0; 2.0 4.0]   # column-major nesting, see _nest_to_array
    @test column(t1, "L")[end] == [7.0, 8.0, 9.0]

    p2 = mkarr(dir, "a2")                  # multi-row VALUES, each with an array literal
    @test taql(p2, "INSERT INTO t (A, V, L) VALUES " *
                   "(10, [[1.0,0.0],[0.0,1.0]], [1.0,1.0,1.0]), " *
                   "(11, [[2.0,0.0],[0.0,2.0]], [2.0,2.0,2.0])") == 2
    t2 = readtable(p2)
    @test column(t2, "A")[end-1:end] == Int32[10, 11]
    @test column(t2, "V")[end-1] == [1.0 0.0; 0.0 1.0]
    @test column(t2, "V")[end] == [2.0 0.0; 0.0 2.0]

    # a ragged nested literal isn't rectangular -> left as nested vectors,
    # not silently reshaped; writing that into an array-shaped column errors
    p3 = mkarr(dir, "a3")
    @test_throws Exception taql(p3,
        "INSERT INTO t (A, V, L) VALUES (1, [[1.0,2.0],[3.0]], [1.0,2.0,3.0])")

    # `_nest_to_array` directly: flat/scalar values pass through unchanged,
    # a rectangular nesting becomes a real Array, a ragged one doesn't
    @test MSv2._taql_const("[1,2,3]") == [1, 2, 3]
    @test MSv2._taql_const("[[1,2],[3,4]]") == [1 3; 2 4]
    @test MSv2._taql_const("[[1,2],[3]]") == [[1, 2], [3]]
    @test MSv2._taql_const("3.5") === 3.5
end

# Phase 113: `INSERT INTO t SELECT ... FROM 'path' [WHERE cond]`.
@testset "insert! -- taql INSERT ... SELECT ... FROM 'path'" begin
    dir = mktempdir()
    srcp = joinpath(dir, "src")
    write_table(srcp, "src", Pair{String,Any}["A" => collect(Int32, 1:10), "B" => Float64.(1:10)];
               nrow=10)
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["A" => Int32[100], "B" => [99.0]]; nrow=1); p)

    # SELECT * -- every source row, source column names unchanged
    p1 = mk("s1")
    @test taql(p1, "INSERT INTO t SELECT * FROM '$srcp'") == 10
    @test column(readtable(p1), "A")[:] == Int32[100, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    # explicit column list with an AS rename, and WHERE
    p2 = joinpath(dir, "s2")
    write_table(p2, "s2", Pair{String,Any}["X" => Int32[], "B" => Float64[]]; nrow=0)
    @test taql(p2, "INSERT INTO t SELECT A AS X, B FROM '$srcp' WHERE A > 7") == 3
    t2 = readtable(p2)
    @test column(t2, "X")[:] == Int32[8, 9, 10]
    @test column(t2, "B")[:] == [8.0, 9.0, 10.0]

    # LIMIT -- cycles/truncates the SELECT result the same way insert!'s
    # own `values=` LIMIT does
    p3 = joinpath(dir, "s3")
    write_table(p3, "s3", Pair{String,Any}["A" => Int32[], "B" => Float64[]]; nrow=0)
    @test taql(p3, "INSERT INTO t SELECT * FROM '$srcp' LIMIT 3") == 3
    @test column(readtable(p3), "A")[:] == Int32[1, 2, 3]

    # matches the Julia insert!(target, query(src, ...)) form exactly
    p4 = joinpath(dir, "s4"); p4j = joinpath(dir, "s4j")
    write_table(p4, "s4", Pair{String,Any}["A" => Int32[], "B" => Float64[]]; nrow=0)
    write_table(p4j, "s4j", Pair{String,Any}["A" => Int32[], "B" => Float64[]]; nrow=0)
    taql(p4, "INSERT INTO t SELECT * FROM '$srcp' WHERE A > 5")
    insert!(readtable(p4j), query(readtable(srcp), "A > 5"))
    @test column(readtable(p4), "A")[:] == column(readtable(p4j), "A")[:]

    # errors
    @test_throws Exception taql(p1, "INSERT INTO t SELECT A FROM '$(joinpath(dir,"nope"))'")
end

@testset "update! -- array-slice assignment" begin
    dir = mktempdir()
    K = Int32[0, 1, 0, 1]
    V = [Float64[i i+1 i+2 i+3; i+4 i+5 i+6 i+7; i+8 i+9 i+10 i+11] for i in 1:4]
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["K" => copy(K), "V" => deepcopy(V)];
                    nrow=4, tsm=[["V"]]); p)

    # scalar element, WHERE-filtered
    p1 = mk("s1")
    @test update!(p1; set=["V[1,1]" => "0.0"], where="K == 1") == 2
    v1 = column(readtable(p1), "V")
    @test v1[2][1, 1] == 0.0 && v1[4][1, 1] == 0.0
    @test v1[1][1, 1] == 1.0 && v1[3][1, 1] == 3.0     # unmatched rows untouched
    @test v1[2][1, 2] == V[2][1, 2]                    # rest of the cell untouched

    # range subscript, scalar RHS broadcast; all rows
    p2 = mk("s2")
    @test update!(p2; set=["V[1:2,3]" => "9.0"]) == 4
    v2 = column(readtable(p2), "V")
    @test v2[1][:, 3] == [9.0, 9.0, V[1][3, 3]]

    # end-relative
    p3 = mk("s3")
    update!(p3; set=["V[end,1]" => "-1.0"])
    @test column(readtable(p3), "V")[1][3, 1] == -1.0

    # RHS references another slice of the same column (pre-update value)
    p4 = mk("s4")
    update!(p4; set=["V[1,1]" => "V[2,2] + 1.0"])
    v4 = column(readtable(p4), "V")
    @test v4[1][1, 1] == V[1][2, 2] + 1.0

    # sequential SET on one cell: the second does not clobber the first
    p5 = mk("s5")
    update!(p5; set=["V[1,1]" => "1.0", "V[2,2]" => "2.0"])
    v5 = column(readtable(p5), "V")[1]
    @test v5[1, 1] == 1.0 && v5[2, 2] == 2.0 && v5[2, 1] == V[1][2, 1]

    # whole-column then slice on the same column
    p6 = mk("s6")
    update!(p6; set=["V" => "V * 0.0", "V[1,1]" => "5.0"])
    v6 = column(readtable(p6), "V")[2]
    @test v6[1, 1] == 5.0 && all(v6[2:end, :] .== 0.0)

    # errors
    p7 = mk("s7")
    @test_throws ArgumentError update!(p7; set=["V[1,1,1]" => "0.0"])
    @test_throws ArgumentError update!(p7; set=["5" => "0.0"])

    # taql string form
    p8 = mk("s8")
    @test taql(p8, "UPDATE t SET V[1,1] = 0.0 WHERE K == 1") == 2
    @test column(readtable(p8), "V")[2][1, 1] == 0.0
    p9 = mk("s9")
    @test taql(p9, "UPDATE t SET V[1:2,3] = 9.0, K = 5") == 4
    t9 = readtable(p9)
    @test column(t9, "V")[1][:, 3] == [9.0, 9.0, V[1][3, 3]]
    @test all(column(t9, "K")[:] .== 5)
end

@testset "update! -- boolean-mask assignment" begin
    dir = mktempdir()
    V0 = [Float64[i i+1 i+2; i+3 i+4 i+5] for i in 1:3]
    M0 = [Bool[isodd(i + j) for i in 1:2, j in 1:3] for _ in 1:3]
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["V" => deepcopy(V0), "MK" => deepcopy(M0)];
                    nrow=3, tsm=[["V"], ["MK"]]); p)

    # mask from a Bool column
    p1 = mk("m1")
    @test update!(p1; set=["V[MK]" => "0.0"]) == 3
    v1 = column(readtable(p1), "V")
    for r in 1:3
        @test all(v1[r][M0[r]] .== 0.0)
        @test v1[r][.!M0[r]] == V0[r][.!M0[r]]
    end

    # inline mask expression
    p2 = mk("m2")
    update!(p2; set=["V[V > 5.0]" => "-1.0"])
    v2 = column(readtable(p2), "V")[1]
    @test v2 == [1.0 2.0 3.0; 4.0 5.0 -1.0]

    # slice then mask (mask conforms to the section)
    p3 = mk("m3")
    update!(p3; set=["V[1:2,1:2][MK[1:2,1:2]]" => "9.0"])
    v3 = column(readtable(p3), "V")[1]
    @test v3 == [1.0 9.0 3.0; 9.0 5.0 6.0]

    # mask then slice (mask conforms to the cell, then sliced)
    p4 = mk("m4")
    update!(p4; set=["V[MK][1:2,1:2]" => "7.0"])
    @test column(readtable(p4), "V")[1] == [1.0 7.0 3.0; 7.0 5.0 6.0]

    # taql string form
    p6 = mk("m6")
    @test taql(p6, "UPDATE t SET V[MK] = 0.0") == 3
    @test all(column(readtable(p6), "V")[1][M0[1]] .== 0.0)
end

@testset "update! -- (col, maskcol) pair form" begin
    dir = mktempdir()
    V0 = [Float64[i i+1 i+2; i+3 i+4 i+5] for i in 1:3]
    M0 = [falses(2, 3) for _ in 1:3]
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["V" => deepcopy(V0), "M" => deepcopy(M0)];
                    nrow=3, tsm=[["V"], ["M"]]); p)

    # default mask = where the data expr goes non-finite
    p1 = mk("d1")
    @test update!(p1; set=[("V", "M") => "1.0 / (V - 4.0)"]) == 3
    v1 = column(readtable(p1), "V"); m1 = column(readtable(p1), "M")
    for r in 1:3
        want = 1.0 ./ (V0[r] .- 4.0)
        @test isequal(v1[r], want)
        @test m1[r] == .!isfinite.(want)
    end

    # explicit (dexpr, mexpr)
    p2 = mk("d2")
    update!(p2; set=[("V", "M") => ("V * 2.0", "V > 4.0")])
    @test column(readtable(p2), "V")[1] == 2 .* V0[1]
    @test column(readtable(p2), "M")[1] == (V0[1] .> 4.0)

    # slice targets inside the pair
    p3 = mk("d3")
    update!(p3; set=[("V[1,1]", "M[1,1]") => ("0.0", "true")])
    @test column(readtable(p3), "V")[1][1, 1] == 0.0
    @test column(readtable(p3), "M")[1][1, 1] == true
    @test column(readtable(p3), "M")[1][2, 2] == false

    # taql string forms
    p4 = mk("d4")
    @test taql(p4, "UPDATE t SET (V, M) = V * 2.0") == 3
    @test column(readtable(p4), "V")[1] == 2 .* V0[1]
    p5 = mk("d5")
    taql(p5, "UPDATE t SET (V, M) = (V * 2.0, V > 4.0), M = M")   # composes with a plain entry
    @test column(readtable(p5), "V")[1] == 2 .* V0[1]

    # errors
    p6 = mk("d6")
    @test_throws ArgumentError update!(p6; set=[("V", "M", "X") => "0.0"])
    @test_throws ArgumentError update!(p6; set=[("V", "NOPE") => "0.0"])
    @test_throws ArgumentError update!(p6; set=["V" => ("a", "b")])

    # faithful MArray form: (D, M) = V[boolexpr] writes the array's mask
    p7 = mk("d7")
    update!(p7; set=[("V", "M") => "V[V > 5.0]"])
    v7 = column(readtable(p7), "V"); m7 = column(readtable(p7), "M")
    for r in 1:3
        @test v7[r] == V0[r]                       # data unchanged (V[cond] keeps the cell)
        @test m7[r] == (V0[r] .> 5.0)               # mask = the selector itself
    end
end

if _HAVE_TAQL
    @testset "update! -- boolean-mask real TaQL cross-check" begin
        for slice_cmd in ("V[MK] = 0.0",
                          "V[V > 5.0] = -1.0",
                          "V[1:2,1:2][MK[1:2,1:2]] = 9.0")
            d = mktempdir()
            V0 = [Float64[i i+1 i+2; i+3 i+4 i+5] for i in 1:5]
            M0 = [Bool[isodd(i + j) for i in 1:2, j in 1:3] for _ in 1:5]
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                    Pair{String,Any}["V" => deepcopy(V0), "MK" => deepcopy(M0)];
                    nrow=5, tsm=[["V"], ["MK"]])
            end
            lhs, rhs = split(slice_cmd, " = "; limit=2)
            update!(joinpath(d, "ours"); set=[String(lhs) => String(strip(rhs))])
            _taqlcmd("UPDATE \$1 SET $slice_cmd", joinpath(d, "ref"))
            vo = column(readtable(joinpath(d, "ours")), "V")
            vr = column(readtable(joinpath(d, "ref")), "V")
            @test all(vo[i] ≈ vr[i] for i in 1:5)
        end
    end

    @testset "update! -- array-slice real TaQL cross-check" begin
        for slice_cmd in ("V[1,1] = 0.0",
                          "V[1:2,3] = 9.0",
                          "V[2,2] = V[1,1] + 1.0",
                          "V[-1,1] = -5.0")
            d = mktempdir()
            V = [Float64[i i+1 i+2 i+3; i+4 i+5 i+6 i+7; i+8 i+9 i+10 i+11] for i in 1:5]
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm, Pair{String,Any}["V" => deepcopy(V)];
                    nrow=5, tsm=[["V"]])
            end
            lhs, rhs = split(slice_cmd, " = "; limit=2)
            update!(joinpath(d, "ours"); set=[String(lhs) => String(strip(rhs))])
            _taqlcmd("UPDATE \$1 SET $slice_cmd", joinpath(d, "ref"))
            vo = column(readtable(joinpath(d, "ours")), "V")
            vr = column(readtable(joinpath(d, "ref")), "V")
            @test all(vo[i] ≈ vr[i] for i in 1:5)
        end
    end

    # NOTE (Phase 111, found by spiking against real Casacore.jl): real
    # TaQL's own UPDATE/DELETE `ORDER BY ... LIMIT n` does **not** sort
    # the WHERE-matched rows by the ORDER BY key and then take the first
    # `n` of that sorted set -- e.g. `UPDATE $1 SET A=A+100 WHERE A>3
    # ORDER BY T LIMIT 3` gives byte-identical results to the same
    # command with `ORDER BY T` removed entirely (confirmed live); `T`'s
    # actual values play no role. `orderby`/`limit` here are a
    # deliberate MeasurementSets extension implementing the genuinely
    # useful "update/delete the N oldest/newest rows" semantics the
    # Phase 30 non-goal text described -- a real sort-then-limit, not a
    # port of whatever real TaQL's own (surprising, direction-only,
    # LIMIT-sign-dependent) row-selection turns out to do. No live
    # cross-check for this reason; verified by hand-computed row
    # selections above instead (and against a direct spike of real
    # TaQL's behaviour, kept as the note above, not as a running test).
end

@testset "insert! -- LIMIT" begin
    dir = mktempdir()
    mk(name) = (p = joinpath(dir, name);
                write_table(p, name, Pair{String,Any}["A" => Int32[1, 2], "B" => [1.0, 2.0]];
                    nrow=2); p)

    # positive limit -> exactly that many rows, one value row repeated
    p1 = mk("l1")
    @test insert!(p1; values=["A" => 9, "B" => 9.5], limit=4) == 4
    @test column(readtable(p1), "A")[:] == Int32[1, 2, 9, 9, 9, 9]

    # positive limit cycles through multiple value rows
    p2 = mk("l2")
    @test insert!(p2; values=[["A" => 3], (; A=4, B=4.0)], limit=5) == 5
    @test column(readtable(p2), "A")[:] == Int32[1, 2, 3, 4, 3, 4, 3]

    # negative limit -> nrow(target) + limit rows
    p3 = mk("l3")                                  # 2 rows
    @test insert!(p3; values=["A" => 7], limit=-1) == 1     # 2 + (-1)
    @test nrow(readtable(p3)) == 3
    p3b = mk("l3b")
    @test insert!(p3b; values=["A" => 7], limit=-5) == 0    # clamped at 0
    @test nrow(readtable(p3b)) == 2

    # limit == 0 / nothing -> one row per value row
    p4 = mk("l4")
    @test insert!(p4; values=[["A" => 1], ["A" => 2]], limit=0) == 2

    # taql: trailing LIMIT (VALUES) and prefix LIMIT (SET, lite-only)
    p5 = mk("l5")
    @test taql(p5, "INSERT INTO t (A, B) VALUES (1, 1.0), (2, 2.0) LIMIT 5") == 5
    @test column(readtable(p5), "A")[:] == Int32[1, 2, 1, 2, 1, 2, 1]
    p6 = mk("l6")
    @test taql(p6, "INSERT LIMIT 3 INTO t SET A = 8, B = 8.0") == 3
    @test column(readtable(p6), "A")[:] == Int32[1, 2, 8, 8, 8]
    p7 = mk("l7")
    @test taql(p7, "INSERT INTO t SET A = 8 LIMIT 1 + 1") == 2
    @test_throws ArgumentError taql(p7, "INSERT LIMIT 2 INTO t (A) VALUES (1) LIMIT 3")
end

if _HAVE_TAQL
    @testset "write commands -- real TaQL cross-check" begin
        _run(path, cmd) = _taqlcmd(cmd, path)

        for (jl_cmd, taql_cmd, wherestr) in (
            (["A" => "A * 2"], "SET A = A * 2", "K == 0"),
            (["A" => "A + B"], "SET A = A + B", "K != 1"),
            (["B" => "B - 1", "A" => "A * 10"], "SET B = B - 1, A = A * 10", nothing),
            # Phase 149: the classic "swap" -- real casacore does NOT
            # swap (each SET item is applied immediately, so B=A reads
            # A's value AFTER the A=B item already wrote it); pins the
            # fix live against real TaQL, not just a hand-computed value.
            (["A" => "B", "B" => "A"], "SET A = B, B = A", nothing),
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

        for taql_cmd in ("INSERT INTO \$1 (A, B) VALUES (30.0, 3.5)",
                         "INSERT INTO \$1 (A, B) VALUES (40.0, 4.5), (50.0, 5.5)",
                         "INSERT INTO \$1 SET A = 60.0, B = 6.5")
            d = mktempdir()
            A = collect(Float64, 1:6)
            B = collect(Float64, 6:-1:1)
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                            Pair{String,Any}["A" => copy(A), "B" => copy(B)]; nrow=6)
            end
            taql(joinpath(d, "ours"), replace(taql_cmd, "\$1" => "t"))
            _run(joinpath(d, "ref"), taql_cmd)
            ours = readtable(joinpath(d, "ours"))
            ref = readtable(joinpath(d, "ref"))
            @test nrow(ours) == nrow(ref)
            @test column(ours, "A")[:] ≈ column(ref, "A")[:]
            @test column(ours, "B")[:] ≈ column(ref, "B")[:]
        end

        # Phase 114: array-cell VALUES literals -- cross-checks the
        # column-major nested-array-literal reshape convention itself
        for taql_cmd in (
            "INSERT INTO \$1 (A, V) VALUES (9.0, [[1.0,2.0],[3.0,4.0]])",
        )
            d = mktempdir()
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                            Pair{String,Any}["A" => collect(Float64, 1:3),
                                             "V" => [reshape(collect(Float64, 4i-3:4i), 2, 2)
                                                     for i in 1:3]];
                            nrow=3, tsm=[["V"]])
            end
            taql(joinpath(d, "ours"), replace(taql_cmd, "\$1" => "t"))
            _run(joinpath(d, "ref"), taql_cmd)
            ours = readtable(joinpath(d, "ours"))
            ref = readtable(joinpath(d, "ref"))
            @test nrow(ours) == nrow(ref)
            @test column(ours, "A")[:] ≈ column(ref, "A")[:]
            @test column(ours, "V")[end] ≈ column(ref, "V")[end]
        end

        for taql_cmd in ("INSERT INTO \$1 (A, B) VALUES (7.0, 0.5) LIMIT 4",
                         "INSERT INTO \$1 (A, B) VALUES (1.0, 1.0), (2.0, 2.0) LIMIT 5",
                         "INSERT LIMIT 3 INTO \$1 (A, B) VALUES (9.0, 9.0)",
                         "INSERT INTO \$1 (A, B) VALUES (3.0, 3.0) LIMIT -2")
            d = mktempdir()
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm,
                            Pair{String,Any}["A" => collect(Float64, 1:6),
                                             "B" => collect(Float64, 6:-1:1)]; nrow=6)
            end
            taql(joinpath(d, "ours"), replace(taql_cmd, "\$1" => "t"))
            _run(joinpath(d, "ref"), taql_cmd)
            ours = readtable(joinpath(d, "ours"))
            ref = readtable(joinpath(d, "ref"))
            @test nrow(ours) == nrow(ref)
            @test column(ours, "A")[:] ≈ column(ref, "A")[:]
            @test column(ours, "B")[:] ≈ column(ref, "B")[:]
        end

        # Phase 113: INSERT INTO t SELECT ... FROM 'path' [WHERE cond]
        for (collist, wherestr) in (("*", nothing), ("A, B", "A > 3.0"),
                                    ("A AS X, B", nothing))
            d = mktempdir()
            sp = joinpath(d, "src")
            write_table(sp, "src", Pair{String,Any}["A" => collect(Float64, 1:6),
                                                     "B" => collect(Float64, 6:-1:1)]; nrow=6)
            targetcols = occursin("AS X", collist) ?
                         Pair{String,Any}["X" => Float64[], "B" => Float64[]] :
                         Pair{String,Any}["A" => Float64[], "B" => Float64[]]
            for nm in ("ours", "ref")
                write_table(joinpath(d, nm), nm, targetcols; nrow=0)
            end
            w = wherestr === nothing ? "" : " WHERE $wherestr"
            taql(joinpath(d, "ours"), "INSERT INTO t SELECT $collist FROM '$sp'$w")
            _run(joinpath(d, "ref"), "INSERT INTO \$1 SELECT $collist FROM '$sp'$w")
            ours = readtable(joinpath(d, "ours"))
            ref = readtable(joinpath(d, "ref"))
            @test nrow(ours) == nrow(ref)
            @test column(ours, "B")[:] ≈ column(ref, "B")[:]
        end
    end
end

# Phase 242: `taql()`'s SELECT parser only understood `cols [WHERE c]`: an
# `ORDER BY` / `LIMIT` with no WHERE was swallowed into the column list
# (error), and `FROM t` / `DISTINCT` / `LIMIT` were unsupported. Now
# `SELECT [DISTINCT] cols [FROM t] [WHERE c] [ORDER BY k] [LIMIT n]`, with
# real-TaQL SELECT LIMIT semantics (live-verified): `LIMIT 0` = no limit,
# `LIMIT -k` = all but the last k rows (first nrow-k), applied after
# ORDER BY / DISTINCT.
@testset "taql SELECT — ORDER BY / LIMIT / DISTINCT / FROM (Phase 242)" begin
    dir = joinpath(mktempdir(), "t")
    A = Int32[5, 3, 9, 1, 7, 3]
    write_table(dir, "T", ["A" => A, "B" => [1.5, 2.5, 0.5, 4.5, 3.5, 2.0]]; nrow=6)
    t = readtable(dir)
    col(q) = collect(column(taql(t, q), "A")[:])

    @test col("SELECT A ORDER BY A") == sort(A)
    @test col("SELECT A ORDER BY A DESC") == sort(A; rev=true)
    @test col("SELECT A WHERE A > 2 ORDER BY A") == sort(filter(>(2), A))
    @test col("SELECT A LIMIT 3") == A[1:3]
    @test col("SELECT A WHERE A > 2 LIMIT 2") == filter(>(2), A)[1:2]
    @test col("SELECT A ORDER BY A LIMIT 3") == sort(A)[1:3]
    @test col("SELECT A LIMIT -2") == A[1:4]
    @test col("SELECT A ORDER BY A LIMIT -2") == sort(A)[1:4]
    @test col("SELECT A LIMIT 0") == A
    @test col("SELECT A LIMIT 99") == A
    @test col("SELECT DISTINCT A") == unique(A)
    @test col("SELECT DISTINCT A ORDER BY A DESC LIMIT 2") == sort(unique(A); rev=true)[1:2]
    @test col("SELECT A FROM t WHERE A > 2") == filter(>(2), A)
    @test length(column(taql(t, "SELECT DISTINCT A, B WHERE A = 3"), "A")) == 2   # (3,2.5),(3,2.0)

    # INTO persists the limited result
    out = joinpath(mktempdir(), "o")
    taql(t, "SELECT A ORDER BY A LIMIT 2 INTO '$out'")
    @test collect(column(readtable(out), "A")[:]) == sort(A)[1:2]

    if _HAVE_TAQL
        for (rq, mq) in [("SELECT A FROM \$1 ORDER BY A", "SELECT A ORDER BY A"),
                         ("SELECT A FROM \$1 LIMIT 3", "SELECT A LIMIT 3"),
                         ("SELECT A FROM \$1 LIMIT -2", "SELECT A LIMIT -2"),
                         ("SELECT A FROM \$1 ORDER BY A LIMIT -2", "SELECT A ORDER BY A LIMIT -2"),
                         ("SELECT A FROM \$1 LIMIT 0", "SELECT A LIMIT 0"),
                         ("SELECT DISTINCT A FROM \$1", "SELECT DISTINCT A"),
                         ("SELECT DISTINCT A FROM \$1 ORDER BY A DESC LIMIT 2",
                          "SELECT DISTINCT A ORDER BY A DESC LIMIT 2"),
                         ("SELECT A FROM \$1 WHERE A>2 LIMIT 2", "SELECT A WHERE A>2 LIMIT 2")]
            ref = collect(_taqlcmd(rq, dir)[:A][:])
            @test Float64.(col(mq)) == Float64.(ref)
        end
    end
end

# Phase 247: 110 UPDATE / DELETE / INSERT forms applied to twin copies of a
# table (real TaQL vs `taql()`), every column compared. Found + fixed:
# writing a FLOAT into an INTEGER column errored (real TaQL truncates toward
# zero; out-of-range values saturate and NaN -> 0 by OUR convention -- real
# casacore's cast there is architecture-dependent UB, so not cross-checked), for both UPDATE ... SET and INSERT; and
# `INSERT INTO t [(cols)] SELECT ... FROM <name|'path'>` -- a column list
# was rejected and a bare `FROM name` (the target itself) unsupported.
# (Not copied: real TaQL's adjacent-literal `'it''s'` -> "its" and its
# `VALUES (A)` -> default; it also rejects Bool <-> numeric writes we allow.)
@testset "taql writes — float→int coercion, INSERT [(cols)] SELECT ... FROM name (Phase 247)" begin
    mk() = (d = joinpath(mktempdir(), "t");
            write_table(d, "T", Pair{String,Any}["A" => Int32[5, 3, 9, 1, 7, 3], "B" => [1.5, 2.5, 0.5, 4.5, 3.5, 2.0],
                       "S" => ["ab", "cd", "", "x y", "Q", "zz"], "G" => Bool[1, 0, 1, 0, 1, 0]]; nrow=6); d)
    col(d, n) = collect(column(readtable(d), n)[:])

    d = mk(); taql(d, "UPDATE t SET A = B")
    @test col(d, "A") == Int32[1, 2, 0, 4, 3, 2]                 # trunc toward zero
    d = mk(); taql(d, "UPDATE t SET A = B * -1")
    @test col(d, "A") == Int32[-1, -2, 0, -4, -3, -2]
    d = mk(); taql(d, "UPDATE t SET A = B * 1e12")
    @test all(==(typemax(Int32)), col(d, "A"))                     # saturates
    d = mk(); taql(d, "UPDATE t SET A = 0.0/0")
    @test all(==(0), col(d, "A"))                                  # NaN -> 0
    d = mk(); taql(d, "UPDATE t SET A = 1.0/0")
    @test all(==(typemax(Int32)), col(d, "A"))
    d = mk(); taql(d, "UPDATE t SET A = B, B = A")                 # chained: A trunc'd first
    @test col(d, "A") == Int32[1, 2, 0, 4, 3, 2] && col(d, "B") == [1.0, 2.0, 0.0, 4.0, 3.0, 2.0]
    d = mk(); taql(d, "UPDATE t SET A = A / 2 WHERE A > 4")
    @test col(d, "A") == Int32[2, 3, 4, 1, 3, 3]
    d = mk(); taql(d, "INSERT INTO t (A) VALUES (2.9),(-1.5)")
    @test col(d, "A")[7:8] == Int32[2, -1]
    d = mk(); taql(d, "INSERT INTO t SET A = 7.9")
    @test col(d, "A")[7] == 7
    d = mk(); taql(d, "INSERT INTO t (A) VALUES (1e12)")
    @test col(d, "A")[7] == typemax(Int32)
    d = mk(); taql(d, "UPDATE t SET B = A")                        # int -> float unchanged
    @test col(d, "B") == Float64.(Int32[5, 3, 9, 1, 7, 3])

    # INSERT ... SELECT: optional target column list, bare `FROM name` = the target
    d = mk(); @test taql(d, "INSERT INTO t SELECT A,B,S,G FROM t WHERE A > 4") == 3
    @test col(d, "A")[7:9] == Int32[5, 9, 7] && col(d, "S")[7:9] == ["ab", "", "Q"]
    d = mk(); @test taql(d, "INSERT INTO t (A,B) SELECT A,B FROM t WHERE A < 4") == 3
    @test col(d, "A")[7:9] == Int32[3, 1, 3] && col(d, "S")[7:9] == ["", "", ""]
    d = mk(); @test taql(d, "INSERT INTO t SELECT * FROM t") == 6
    @test col(d, "A") == vcat(Int32[5, 3, 9, 1, 7, 3], Int32[5, 3, 9, 1, 7, 3])
    d = mk(); @test_throws ArgumentError taql(d, "INSERT INTO t (A) SELECT A,B FROM t")

    if _HAVE_TAQL
        # Only IN-RANGE conversions are cross-checked: casacore's out-of-range /
        # NaN / Inf float->int cast is C++ undefined behaviour that differs by
        # architecture (ARM64 saturates piecewise; x86-64 gives typemin for all of
        # them -- CI caught this), so our saturating/NaN->0 convention is checked
        # above against fixed expectations instead, not against a live oracle.
        for cmd in ("UPDATE \$1 SET A = B", "UPDATE \$1 SET A = B * -1", "UPDATE \$1 SET A = B, B = A",
                    "UPDATE \$1 SET A = A / 2 WHERE A > 4", "INSERT INTO \$1 (A) VALUES (2.9),(-1.5)",
                    "INSERT INTO \$1 SET A = 7.9",
                    "INSERT INTO \$1 SELECT A,B,S,G FROM \$1 WHERE A > 4",
                    "INSERT INTO \$1 (A,B) SELECT A,B FROM \$1 WHERE A < 4", "INSERT INTO \$1 SELECT * FROM \$1")
            dr = mk(); dm = mk()
            _taqlcmd(cmd, dr)
            taql(dm, replace(cmd, "\$1" => "t"))
            for n in ("A", "B", "S", "G")
                @test col(dr, n) == col(dm, n)
            end
        end
    end
end

# Phase 255: SELECT `LIMIT n OFFSET m`, `OFFSET m [LIMIT n]` and the 0-based
# half-open range `LIMIT a:b[:s]` (each part optional), live-probed vs real TaQL
# (48 forms, all match): n == 0 no limit, n < 0 = `nr + n` rows from the start
# row, negative offset / range bounds count from the end, b == 0 = end, an offset
# or start beyond the end / an empty range / step <= 0 error, a range cannot be
# combined with OFFSET; applies after ORDER BY.
@testset "taql() SELECT LIMIT/OFFSET/range (Phase 255)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["K" => Int32.(1:10)]; nrow=10)
    t = readtable(dir)
    ks(q) = Int.(collect(column(taql(t, "SELECT K " * q), "K")[:]))
    @test ks("LIMIT 3 OFFSET 2") == [3, 4, 5] && ks("OFFSET 2 LIMIT 3") == [3, 4, 5]
    @test ks("LIMIT 2:5") == [3, 4, 5] && ks("LIMIT 2:8:2") == [3, 5, 7] && ks("LIMIT 1:10:3") == [2, 5, 8]
    @test ks("LIMIT :4") == 1:4 && ks("LIMIT 3:") == 4:10 && ks("LIMIT ::2") == [1, 3, 5, 7, 9] && ks("LIMIT 2::3") == [3, 6, 9]
    @test ks("LIMIT 2:20") == 3:10 && ks("LIMIT 0:0") == 1:10 && ks("LIMIT -3:") == [8, 9, 10]
    @test ks("LIMIT :-2") == 1:8 && ks("LIMIT 3:-1") == 4:9 && ks("LIMIT -5:-2") == [6, 7, 8]
    @test ks("LIMIT 3 OFFSET -1") == [10] && ks("OFFSET -3") == [8, 9, 10] && ks("LIMIT 3 OFFSET -20") == [1, 2, 3]
    @test ks("OFFSET 3") == 4:10 && ks("LIMIT 0 OFFSET 4") == 5:10 && ks("LIMIT 20 OFFSET 8") == [9, 10]
    @test ks("LIMIT -3 OFFSET 2") == 3:9 && ks("LIMIT -1 OFFSET 2") == 3:10 && ks("LIMIT -2") == 1:8
    @test ks("WHERE K>2 LIMIT 2 OFFSET 1") == [4, 5] && ks("WHERE K>3 LIMIT 1:3") == [5, 6]
    @test ks("ORDER BY K DESC LIMIT 3 OFFSET 2") == [8, 7, 6] && ks("ORDER BY K DESC LIMIT 2:5") == [8, 7, 6]
    for bad in ("LIMIT 3:3", "LIMIT 5:2", "LIMIT 20:30", "OFFSET 10", "OFFSET 20", "LIMIT 3 OFFSET 20", "LIMIT 2:8:0",
                "LIMIT 2:8:-1", "LIMIT 1:2 OFFSET 1", "LIMIT 3 OFFSET 2 OFFSET 1", "LIMIT 2, 3")
        @test_throws ArgumentError ks(bad)
    end
    if _HAVE_TAQL
        for q in ("LIMIT 3 OFFSET 2", "LIMIT 2:5", "LIMIT 2:8:2", "LIMIT 1:10:3", "OFFSET 3", "LIMIT 3 OFFSET -1", "LIMIT :4", "LIMIT 3:",
                  "LIMIT ::2", "LIMIT -3:", "LIMIT :-2", "LIMIT -5:-2", "LIMIT -3 OFFSET 2", "LIMIT 0 OFFSET 4", "WHERE K>3 LIMIT 1:3",
                  "ORDER BY K DESC LIMIT 2:5", "OFFSET -3", "LIMIT 20 OFFSET 8", "LIMIT 2::3")
            @test Int.(collect(_taqlcmd("SELECT K FROM \$1 " * q, dir)[:K][:])) == ks(q)
        end
    end
end

# Phase 256: `taql()` SELECT with aggregates / GROUP BY / HAVING (routed through
# `groupby`), live-probed vs real TaQL (26 forms; group order is unspecified so
# results are compared sorted).  Aggregates without GROUP BY = ONE group over the
# whole table; a non-aggregate, non-key select expression takes the group's LAST
# row (real TaQL -- was the first row before); `GROUP BY expr` groups on a computed
# key; ORDER BY / LIMIT / OFFSET apply to the grouped result.  Divergence: an empty
# single-group aggregate (`WHERE K>100`) is a 0-row result here, an (odd) error in
# real TaQL.
@testset "taql() SELECT aggregates / GROUP BY / HAVING (Phase 256)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["G" => Int32[1, 2, 1, 3, 2, 1, 3, 3], "K" => Int32.(1:8),
                "D" => collect(0.5:1:7.5), "H" => Int32[1, 1, 2, 2, 1, 2, 1, 2]]; nrow=8)
    t = readtable(dir)
    cols(q, cs) = (r = taql(t, q); [collect(column(r, c)[:]) for c in cs])
    srt(a) = (p = sortperm(collect(zip(a...))); [x[p] for x in a])
    @test cols("SELECT gsum(K) AS X FROM t", ["X"]) == [[36]]
    @test cols("SELECT gsum(K)+1 AS X, gcount() AS Y FROM t", ["X", "Y"]) == [[37], [8]]
    @test cols("SELECT gsum(K) AS X FROM t WHERE K>2 HAVING gsum(K)>5", ["X"]) == [[33]]
    @test srt(cols("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G", ["X", "Y"])) == [[1, 2, 3], [10, 7, 19]]
    gm = srt(cols("SELECT G AS X, gcount() AS Y, gmean(D) AS Z FROM t GROUP BY G", ["X", "Y", "Z"]))
    @test gm[1] == [1, 2, 3] && gm[2] == [3, 2, 3] && gm[3] ≈ [17/6, 3.0, 35/6]
    @test srt(cols("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G HAVING gsum(K)>8", ["X", "Y"])) == [[1, 3], [10, 19]]
    @test cols("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY Y DESC", ["X", "Y"]) == [[3, 1, 2], [19, 10, 7]]
    @test cols("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY X DESC LIMIT 2", ["X", "Y"]) == [[3, 2], [19, 7]]
    @test cols("SELECT G AS X, gcount() AS Y FROM t GROUP BY G ORDER BY X LIMIT 1 OFFSET 1", ["X", "Y"]) == [[2], [2]]
    @test srt(cols("SELECT G AS X, H AS Y, gsum(K) AS Z FROM t GROUP BY G, H", ["X", "Y", "Z"])) ==
          [[1, 1, 2, 3, 3], [1, 2, 1, 1, 2], [1, 9, 7, 7, 12]]
    # LAST row of the group for a non-key, non-aggregate select expression
    @test srt(cols("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY H", ["X", "Y"])) == [[3, 3], [15, 21]]
    # an expression group key
    @test srt(cols("SELECT G+H AS X, gsum(K) AS Y FROM t GROUP BY G+H", ["X", "Y"])) == [[2, 3, 4, 5], [1, 16, 7, 12]]
    @test_throws ArgumentError taql(t, "SELECT G AS X, gsum(K) AS Y FROM t GROUP BY NOPE")
    if _HAVE_TAQL
        real(q, cs) = (r = _taqlcmd(q, dir); [collect(r[Symbol(c)][:]) for c in cs])
        for (q, cs) in [("SELECT gsum(K) AS X FROM \$1", ["X"]), ("SELECT gsum(K)+1 AS X, gcount() AS Y FROM \$1", ["X", "Y"]),
                        ("SELECT gsum(K) AS X FROM \$1 HAVING gsum(K)>5", ["X"]), ("SELECT G AS X, gsum(K) AS Y FROM \$1 GROUP BY G", ["X", "Y"]),
                        ("SELECT G AS X, gcount() AS Y, gmean(D) AS Z FROM \$1 GROUP BY G", ["X", "Y", "Z"]),
                        ("SELECT G AS X, gsum(K) AS Y FROM \$1 WHERE K>2 GROUP BY G HAVING gcount()>1", ["X", "Y"]),
                        ("SELECT G AS X, H AS Y, gsum(K) AS Z FROM \$1 GROUP BY G, H", ["X", "Y", "Z"]),
                        ("SELECT G AS X, gsum(K) AS Y FROM \$1 GROUP BY H", ["X", "Y"]), ("SELECT G+H AS X, gsum(K) AS Y FROM \$1 GROUP BY G+H", ["X", "Y"]),
                        ("SELECT G AS X, gfirst(K) AS Y, glast(K) AS Z FROM \$1 GROUP BY G", ["X", "Y", "Z"])]
            @test srt(real(q, cs)) == srt(cols(replace(q, "\$1" => "t"), cs))
        end
    end
end

# Phase 257: `taql()` SELECT sub-queries and table aliases, live-probed vs real
# TaQL (34 forms): `FROM (SELECT ...)` (nested ok), `x [NOT] IN (SELECT col ...)`
# (with WHERE / ORDER BY / LIMIT / DISTINCT / computed columns inside),
# `[NOT] EXISTS (SELECT ...)`, `SELECT FROM t` (no column list), and `FROM t [AS] a`
# with `a.COL` qualifiers.  Divergence: a POSITIVE `EXISTS` / `IN` of an EMPTY
# sub-query errors in real TaQL; here it simply matches no rows.
@testset "taql() SELECT sub-queries + aliases (Phase 257)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["G" => Int32[1, 2, 1, 3, 2, 1, 3, 3], "K" => Int32.(1:8), "D" => collect(0.5:1:7.5)]; nrow=8)
    t = readtable(dir)
    xs(q) = collect(column(taql(t, q), "X")[:])
    @test xs("SELECT K AS X FROM t a") == 1:8 && xs("SELECT a.K AS X FROM t AS a WHERE a.K>3") == 4:8
    @test xs("SELECT K AS X FROM t q WHERE q.G==1 AND K>1") == [3, 6] && xs("SELECT q.K AS X FROM t q ORDER BY q.K DESC") == 8:-1:1
    @test xs("SELECT K AS X FROM (SELECT FROM t WHERE K>3)") == 4:8
    @test xs("SELECT K AS X FROM (SELECT FROM t WHERE K>3) WHERE K<7") == [4, 5, 6]
    @test xs("SELECT K AS X FROM (SELECT FROM (SELECT FROM t WHERE K>2) WHERE K<7)") == 3:6
    @test xs("SELECT K AS X FROM (SELECT K FROM t WHERE G==1) ORDER BY K DESC") == [6, 3, 1]
    @test xs("SELECT gsum(K) AS X FROM (SELECT FROM t WHERE G==1)") == [10]
    @test xs("SELECT K AS X FROM t WHERE K IN (SELECT K FROM t WHERE G==1)") == [1, 3, 6]
    @test xs("SELECT K AS X FROM t WHERE K NOT IN (SELECT K FROM t WHERE G==1)") == [2, 4, 5, 7, 8]
    @test xs("SELECT K AS X FROM t WHERE G IN (SELECT G FROM t WHERE K>6)") == [4, 7, 8]
    @test xs("SELECT K AS X FROM t WHERE K IN (SELECT K FROM t WHERE G==1 ORDER BY K DESC LIMIT 2)") == [3, 6]
    @test xs("SELECT K AS X FROM t WHERE D IN (SELECT D FROM t WHERE G==2)") == [2, 5]
    @test xs("SELECT K AS X FROM t WHERE K IN (SELECT K+1 AS K FROM t WHERE G==2)") == [3, 6]
    @test xs("SELECT K AS X FROM t WHERE K IN (SELECT DISTINCT G FROM t)") == [1, 2, 3]
    @test xs("SELECT K AS X FROM t WHERE EXISTS (SELECT FROM t WHERE K>7)") == 1:8
    @test xs("SELECT K AS X FROM t WHERE NOT EXISTS (SELECT FROM t WHERE K>100)") == 1:8
    @test isempty(xs("SELECT K AS X FROM t WHERE EXISTS (SELECT FROM t WHERE K>100)"))
    @test isempty(xs("SELECT K AS X FROM t WHERE K IN (SELECT K FROM t WHERE G==9)"))
    @test_throws ArgumentError taql(t, "SELECT K AS X FROM (K>3)")
    if _HAVE_TAQL
        for q in ("SELECT K AS X FROM \$1 a", "SELECT a.K AS X FROM \$1 AS a WHERE a.K>3", "SELECT K AS X FROM (SELECT FROM \$1 WHERE K>3) WHERE K<7",
                  "SELECT K AS X FROM (SELECT FROM (SELECT FROM \$1 WHERE K>2) WHERE K<7)", "SELECT gsum(K) AS X FROM (SELECT FROM \$1 WHERE G==1)",
                  "SELECT K AS X FROM \$1 WHERE K IN (SELECT K FROM \$1 WHERE G==1)", "SELECT K AS X FROM \$1 WHERE K NOT IN (SELECT K FROM \$1 WHERE G==1)",
                  "SELECT K AS X FROM \$1 WHERE K IN (SELECT K FROM \$1 WHERE G==1 ORDER BY K DESC LIMIT 2)",
                  "SELECT K AS X FROM \$1 WHERE K IN (SELECT K+1 AS K FROM \$1 WHERE G==2)", "SELECT K AS X FROM \$1 WHERE EXISTS (SELECT FROM \$1 WHERE K>7)",
                  "SELECT K AS X FROM \$1 WHERE NOT EXISTS (SELECT FROM \$1 WHERE K>100)", "SELECT K AS X FROM \$1 t WHERE t.G==1 AND K>1")
            @test collect(_taqlcmd(q, dir)[:X][:]) == xs(replace(q, "\$1" => "t"))
        end
    end
end

# Phase 258: sub-queries (`x [NOT] IN (SELECT ..)`, `[NOT] EXISTS (SELECT ..)`) in
# the WHERE of UPDATE / DELETE, and `UPDATE t [AS] a SET` / `DELETE FROM t [AS] a`
# aliases, applied to twin copies vs real TaQL (9 forms, all match).  The inner
# query sees the table BEFORE the write.
@testset "taql UPDATE/DELETE sub-queries + aliases (Phase 258)" begin
    mk() = (d = joinpath(mktempdir(), "t");
            write_table(d, "T", Pair{String,Any}["G" => Int32[1, 2, 1, 3, 2, 1, 3, 3], "K" => Int32.(1:8), "D" => collect(0.5:1:7.5)]; nrow=8); d)
    col(d, n) = collect(column(readtable(d), n)[:])
    d = mk(); taql(d, "DELETE FROM t WHERE K IN (SELECT K FROM t WHERE G==1)")
    @test col(d, "K") == [2, 4, 5, 7, 8]
    d = mk(); taql(d, "UPDATE t SET D=0 WHERE K IN (SELECT K FROM t WHERE G==1)")
    @test col(d, "D") == [0.0, 1.5, 0.0, 3.5, 4.5, 0.0, 6.5, 7.5]
    d = mk(); taql(d, "UPDATE t SET D=-1 WHERE G IN (SELECT G FROM t WHERE K>6)")
    @test col(d, "D") == [0.5, 1.5, 2.5, -1.0, 4.5, 5.5, -1.0, -1.0]
    d = mk(); taql(d, "DELETE FROM t WHERE NOT EXISTS (SELECT FROM t WHERE K>100)")
    @test nrow(readtable(d)) == 0
    d = mk(); taql(d, "UPDATE t a SET D=0 WHERE a.K>6"); @test col(d, "D")[7:8] == [0.0, 0.0] && col(d, "D")[1] == 0.5
    d = mk(); taql(d, "DELETE FROM t a WHERE a.K>6"); @test col(d, "K") == 1:6
    d = mk(); taql(d, "UPDATE t AS a SET D=a.K*2 WHERE a.G==1"); @test col(d, "D")[[1, 3, 6]] == [2.0, 6.0, 12.0]
    if _HAVE_TAQL
        for q in ("DELETE FROM \$1 WHERE K IN (SELECT K FROM \$1 WHERE G==1)", "UPDATE \$1 SET D=0 WHERE K IN (SELECT K FROM \$1 WHERE G==1)",
                  "UPDATE \$1 SET D=0 WHERE EXISTS (SELECT FROM \$1 WHERE K>7)", "DELETE FROM \$1 WHERE NOT EXISTS (SELECT FROM \$1 WHERE K>100)",
                  "UPDATE \$1 SET D=-1 WHERE G IN (SELECT G FROM \$1 WHERE K>6)", "UPDATE \$1 a SET D=0 WHERE a.K>6",
                  "DELETE FROM \$1 a WHERE a.K>6", "UPDATE \$1 AS a SET D=a.K*2 WHERE a.G==1",
                  "UPDATE \$1 SET D=K*2 WHERE K IN (SELECT DISTINCT G FROM \$1)")
            dr = mk(); dm = mk()
            _taqlcmd(q, dr); taql(dm, replace(q, "\$1" => "t"))
            @test col(dr, "K") == col(dm, "K") && col(dr, "D") == col(dm, "D")
        end
    end
end

# Phase 259: `taql(target, cmd, others...)` SELECT ... FROM $1 a JOIN $2 b ON
# a.K == b.K, live-probed vs real TaQL (11 forms + per-type sentinels).  Real TaQL's
# JOIN is a LEFT join filling unmatched left rows with type sentinels: Int ->
# typemax(Int64), Float / Float32 -> NaN, Complex -> NaN+NaN·im, Bool -> false,
# String -> "none".  `$1` is the target, `$2`... the extra arguments; columns are
# `a.COL` / `b.COL`.  One `==` (or `IN`) condition, either order; the right key must
# be unique.  (Real TaQL rejects `AND` conditions and comma joins; so do we.)
@testset "taql SELECT ... JOIN (Phase 259)" begin
    d1 = joinpath(mktempdir(), "a"); d2 = joinpath(mktempdir(), "b")
    write_table(d1, "A", Pair{String,Any}["K" => Int32[1, 2, 3, 4, 5, 2], "V" => [10.0, 20, 30, 40, 50, 60], "Z" => Int32[0, 1, 2, 0, 1, 2]]; nrow=6)
    write_table(d2, "B", Pair{String,Any}["K" => Int32[2, 3, 5, 9], "N" => ["two", "three", "five", "nine"], "W" => [0.2, 0.3, 0.5, 0.9],
                "I" => Int32[7, 8, 9, 10], "F" => Bool[1, 1, 1, 1], "C" => ComplexF32[1, 2, 3, 4], "R" => Float32[1, 2, 3, 4]]; nrow=4)
    t1 = readtable(d1); t2 = readtable(d2)
    xy(q) = (r = taql(t1, q, t2); (collect(column(r, "X")[:]), collect(column(r, "Y")[:])))
    j = "FROM \$1 a JOIN \$2 b ON a.K == b.K"
    @test xy("SELECT a.V AS X, b.N AS Y $j") == ([10.0, 20, 30, 40, 50, 60], ["none", "two", "three", "none", "five", "two"])
    x, y = xy("SELECT a.V AS X, b.W AS Y $j"); @test x == [10.0, 20, 30, 40, 50, 60] && isequal(y, [NaN, 0.2, 0.3, NaN, 0.5, 0.2])
    @test xy("SELECT a.V AS X, b.I AS Y $j")[2] == [typemax(Int64), 7, 8, typemax(Int64), 9, 7]
    @test xy("SELECT a.V AS X, b.F AS Y $j")[2] == Bool[0, 1, 1, 0, 1, 1]
    y = xy("SELECT a.V AS X, b.C AS Y $j")[2]; @test isnan(real(y[1])) && isnan(imag(y[1])) && y[2] == 1 && y[5] == 3
    @test isequal(xy("SELECT a.V AS X, b.R AS Y $j")[2], Float32[NaN, 1, 2, NaN, 3, 1])
    @test xy("SELECT a.V AS X, b.N AS Y $j WHERE a.V>20")[1] == [30.0, 40, 50, 60]
    @test xy("SELECT a.K AS X, b.N AS Y $j ORDER BY a.V DESC") == (Int32[2, 5, 4, 3, 2, 1], ["two", "five", "none", "three", "two", "none"])
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.Z == b.K")[2] == ["none", "none", "two", "none", "none", "two"]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON b.K == a.K")[2] == ["none", "two", "three", "none", "five", "two"]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K IN b.K")[2] == ["none", "two", "three", "none", "five", "two"]
    @test xy("SELECT a.V AS X, b.N AS Y $j LIMIT 2") == ([10.0, 20.0], ["none", "two"])
    x, y = xy("SELECT gsum(a.V) AS X, gcount() AS Y $j"); @test x == [210.0] && y == [6]
    x, y = xy("SELECT a.V*b.W AS X, b.N AS Y $j"); @test isequal(x, [NaN, 4.0, 9.0, NaN, 25.0, 12.0])
    @test_throws ArgumentError xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K AND a.Z == 2")
    @test_throws ArgumentError taql(t1, "SELECT a.V AS X, b.N AS Y $j")            # no \$2 supplied
    if _HAVE_TAQL
        for q in ("SELECT a.V AS X, b.N AS Y $j", "SELECT a.V AS X, b.W AS Y $j WHERE a.V>20", "SELECT a.K AS X, b.N AS Y $j ORDER BY a.V DESC",
                  "SELECT a.V AS X, b.I AS Y $j", "SELECT a.V AS X, b.F AS Y $j", "SELECT a.V AS X, b.R AS Y $j",
                  "SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.Z == b.K", "SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON b.K == a.K",
                  "SELECT a.V AS X, b.W AS Y FROM \$1 a JOIN \$2 b ON a.K IN b.K", "SELECT gsum(a.V) AS X, gcount() AS Y $j", "SELECT a.V*b.W AS X, b.N AS Y $j")
            r = _taqlcmd(q, d1, d2); m = xy(q)
            @test isequal(collect(r[:X][:]), m[1]) && isequal(collect(r[:Y][:]), m[2])
        end
    end
end

# Phase 260: more JOIN forms (live-probed vs real TaQL, 20 forms): chained joins
# (`JOIN $2 b ON .. JOIN $3 c ON b.N == c.N`, matched against the joined table so
# far), an INDEX lookup `ON a.K == b.rowid()` (the left value is the 0-based right
# row), `a.rowid()` / `b.rowid()` as columns, `=` as well as `==`, and a duplicate
# right key matching its FIRST row (was an error).  Divergence: real TaQL returns
# NaN for the reversed index form `ON b.rowid() == a.K`; here it is the same lookup.
@testset "taql SELECT ... JOIN: chained, rowid(), duplicate keys (Phase 260)" begin
    d1 = joinpath(mktempdir(), "a"); d2 = joinpath(mktempdir(), "b"); d3 = joinpath(mktempdir(), "c")
    write_table(d1, "A", Pair{String,Any}["K" => Int32[1, 2, 3, 4, 5, 2], "V" => [10.0, 20, 30, 40, 50, 60], "Z" => Int32[0, 1, 2, 0, 1, 2]]; nrow=6)
    write_table(d2, "B", Pair{String,Any}["K" => Int32[2, 3, 5, 9], "N" => ["two", "three", "five", "nine"], "W" => [0.2, 0.3, 0.5, 0.9]]; nrow=4)
    write_table(d3, "C", Pair{String,Any}["N" => ["two", "five", "zzz"], "Q" => Int32[100, 200, 300]]; nrow=3)
    t1, t2, t3 = readtable(d1), readtable(d2), readtable(d3)
    xy(q) = (r = taql(t1, q, t2, t3); (collect(column(r, "X")[:]), collect(column(r, "Y")[:])))
    big = typemax(Int64)
    @test xy("SELECT a.V AS X, c.Q AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K JOIN \$3 c ON b.N == c.N")[2] == [big, 100, big, big, 200, 100]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K JOIN \$3 c ON b.N == c.N")[2] == ["none", "two", "three", "none", "five", "two"]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K == b.rowid()")[2] == ["three", "five", "nine", "none", "none", "five"]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.Z == b.rowid()")[2] == ["two", "three", "five", "two", "three", "five"]
    @test xy("SELECT a.V AS X, a.V AS Y FROM \$1 a JOIN \$2 b ON a.K == b.rowid() WHERE b.N == 'five'") == ([20.0, 60.0], [20.0, 60.0])
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K = b.K")[2] == ["none", "two", "three", "none", "five", "two"]
    @test xy("SELECT a.V AS X, b.N AS Y FROM \$1 AS a JOIN \$2 AS b ON a.K == b.K WHERE b.N != 'none'")[2] == ["two", "three", "five", "two"]
    @test xy("SELECT a.V AS X, upper(b.N) AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K")[2] == ["NONE", "TWO", "THREE", "NONE", "FIVE", "TWO"]
    g = taql(t1, "SELECT b.N AS X, gsum(a.V) AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K GROUP BY b.N", t2)
    @test sort(collect(column(g, "X")[:])) == ["five", "none", "three", "two"] && sum(column(g, "Y")[:]) == 210
    # self-join, duplicate right key -> the FIRST matching row; a./b.rowid()
    s(q) = (r = taql(t1, q); (collect(column(r, "X")[:]), collect(column(r, "Y")[:])))
    @test s("SELECT a.V AS X, b.V AS Y FROM \$1 a JOIN \$1 b ON a.K == b.K")[2] == [10.0, 20, 30, 40, 50, 20]
    @test s("SELECT a.V AS X, b.rowid() AS Y FROM \$1 a JOIN \$1 b ON a.K == b.K")[2] == [0, 1, 2, 3, 4, 1]
    @test s("SELECT a.rowid() AS X, b.V AS Y FROM \$1 a JOIN \$1 b ON a.Z == b.rowid()") == ([0, 1, 2, 3, 4, 5], [10.0, 20, 30, 10, 20, 30])
    @test_throws ArgumentError xy("SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K == a.Z")
    if _HAVE_TAQL
        for q in ("SELECT a.V AS X, c.Q AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K JOIN \$3 c ON b.N == c.N",
                  "SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K == b.rowid()", "SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.Z == b.rowid()",
                  "SELECT a.V AS X, b.N AS Y FROM \$1 a JOIN \$2 b ON a.K = b.K", "SELECT a.V AS X, b.N AS Y FROM \$1 AS a JOIN \$2 AS b ON a.K == b.K WHERE b.N != 'none'",
                  "SELECT a.V AS X, upper(b.N) AS Y FROM \$1 a JOIN \$2 b ON a.K == b.K",
                  "SELECT a.V AS X, b.V AS Y FROM \$1 a JOIN \$1 b ON a.K == b.K", "SELECT a.V AS X, b.rowid() AS Y FROM \$1 a JOIN \$1 b ON a.K == b.K",
                  "SELECT a.rowid() AS X, b.V AS Y FROM \$1 a JOIN \$1 b ON a.Z == b.rowid()")
            ps = occursin("\$3", q) ? (d1, d2, d3) : occursin("\$2", q) ? (d1, d2) : (d1,)
            r = _taqlcmd(q, ps...); m = taql(t1, q, t2, t3)
            @test isequal(collect(r[:X][:]), collect(column(m, "X")[:])) && isequal(collect(r[:Y][:]), collect(column(m, "Y")[:]))
        end
    end
end

# Phase 261: SELECT odds and ends, live-probed vs real TaQL (~45 forms): `SELECT
# ALL`, the one-word `ORDERBY`, a grouped SELECT's HAVING naming a select ALIAS
# (`HAVING Y > 10`), and an ORDER BY that is an EXPRESSION over the group
# (`ORDER BY G*-1`).  (Real TaQL rejects `ORDER BY gsum(K)`; that and
# `NOT G==3` are accepted here.)
@testset "taql SELECT: ALL, ORDERBY, HAVING alias, ORDER BY expression (Phase 261)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["G" => Int32[1, 2, 1, 3, 2, 1, 3, 3], "K" => Int32.(1:8), "S" => ["a", "b", "a", "c", "b", "a", "c", "c"]]; nrow=8)
    t = readtable(dir)
    cs(q, c...) = (r = taql(t, q); [collect(column(r, n)[:]) for n in c])
    @test cs("SELECT ALL K AS X FROM t", "X") == [collect(1:8)]
    @test cs("SELECT K AS X FROM t ORDERBY K DESC", "X") == [collect(8:-1:1)]
    @test cs("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G HAVING Y>10", "X", "Y") == [[3], [19]]
    @test sort(cs("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G HAVING Y>5 AND gcount()>2", "X")[1]) == [1, 3]
    @test cs("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY G*-1", "X", "Y") == [[3, 2, 1], [19, 7, 10]]
    @test cs("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY Y DESC", "X", "Y") == [[3, 1, 2], [19, 10, 7]]
    @test cs("SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY gmax(K) DESC", "X") == [[3, 1, 2]]
    @test columnnames(taql(t, "SELECT G AS X, gsum(K) AS Y FROM t GROUP BY G ORDER BY G*-1")) == ["X", "Y"]   # hidden key dropped
    if _HAVE_TAQL
        for q in ("SELECT ALL K AS X FROM \$1", "SELECT K AS X FROM \$1 ORDERBY K DESC",
                  "SELECT G AS X, gsum(K) AS Y FROM \$1 GROUP BY G HAVING Y>10", "SELECT G AS X, gsum(K) AS Y FROM \$1 GROUP BY G ORDER BY G*-1",
                  "SELECT G AS X, gsum(K) AS Y FROM \$1 GROUP BY G ORDER BY Y DESC")
            r = _taqlcmd(q, dir); m = taql(t, replace(q, "\$1" => "t"))
            xs = names -> [collect(column(m, n)[:]) for n in names]
            hasY = occursin("AS Y", q)
            @test collect(r[:X][:]) == xs(["X"])[1] && (!hasY || collect(r[:Y][:]) == xs(["Y"])[1])
        end
    end
end

# Phase 264: a FIXED-SHAPE string array column (`S S [SHAPE=[2]]`).  Casacore stores
# it INDIRECT (option FixedShape, not Direct): each cell is one 12-byte ref to a
# string-bucket blob of just the elements.  `write_table` used to crash with a
# BoundsError on such a column (it declared it Direct) and the reader errored on a
# casacore-written one ("string arrays not yet supported").
@testset "fixed-shape string array columns — read + write (Phase 264)" begin
    cols = ["uniform" => [["u", "v"], ["w", "x"], ["y", "z"], ["p", "q"]],
            "with-empty" => [["u", ""], ["w", "x"], ["", "z"], ["p", "q"]],
            "long" => [["a" ^ 50, "b"], ["c", "d" ^ 300], ["e", "f"], ["g", "h"]],
            "matrix" => [["a" "b"; "c" "d"] for _ in 1:4]]
    for (nm, col) in cols
        dir = joinpath(mktempdir(), "t")
        write_table(dir, "T", Pair{String,Any}["X" => col, "K" => Int32.(1:4)]; nrow=4)
        r = readtable(dir); d = columndesc(r, "X")
        @test d.shape isa Dims && d.shape == size(col[1]) && d.option == MSv2.COLOPT_FIXEDSHAPE     # FixedShape, NOT Direct
        @test column(r, "X")[:] == col && column(r, "X")[3] == col[3]
        if _HAVE_CASACORE
            ct = CCT.Table(dir)
            got = ct[:X]
            arr = got[ntuple(_ -> Colon(), ndims(got))...]
            @test [collect(selectdim(arr, ndims(arr), i)) for i in 1:4] == col
        end
    end
    if _HAVE_TAQL
        dir = joinpath(mktempdir(), "t")
        _taql_create("CREATE TABLE $dir [S S [SHAPE=[2]], K I4] LIMIT 3")
        _taqlcmd("UPDATE \$1 SET S=['u','v'], K=7", dir)
        @test column(readtable(dir), "S")[:] == [["u", "v"] for _ in 1:3]     # casacore-written -> ours
    end
end

# Phase 318: random JOIN fuzz vs real TaQL.  Random left/right/third tables
# (duplicate and unmatched keys), chained joins, rowid() index lookup, WHERE /
# ORDER BY / LIMIT / GROUP BY / HAVING over joined columns.  Every query with a
# non-empty result matches real TaQL exactly (unmatched rows get the type
# sentinels).  Real TaQL throws an unexplained "Slicer error" when a join query
# selects ZERO rows (Phase 253 saw it elsewhere); there ours returns 0 rows.
if _HAVE_TAQL
@testset "taql SELECT ... JOIN random fuzz vs real TaQL (Phase 318)" begin
    rng = MersenneTwister(318)
    same(a, b) = length(a) == length(b) && all(eachindex(a)) do i
        a[i] isa AbstractFloat && b[i] isa AbstractFloat ?
            (isnan(a[i]) && isnan(b[i]) || isapprox(a[i], b[i]; rtol=1e-9)) : isequal(a[i], b[i])
    end
    for case in 1:12
        na = rand(rng, 1:30); nb = rand(rng, 1:12); nc = rand(rng, 1:6)
        kr = Int32.(1:rand(rng, 3:10))
        # typed Pair{String,Any}[...] literals: a bare [...] would promote the Int32 keys (Phase 210)
        A = Pair{String,Any}["K" => Int32.(rand(rng, kr, na)), "V" => round.(randn(rng, na) * 10; digits=2),
                             "Z" => Int32.(rand(rng, 0:max(nb - 1, 0) + 2, na))]
        B = Pair{String,Any}["K" => Int32.(rand(rng, kr, nb)), "N" => [rand(rng, ("x", "y", "z", "w")) for _ in 1:nb],
                             "W" => round.(randn(rng, nb); digits=2), "J" => Int32.(rand(rng, 1:4, nb))]
        C = Pair{String,Any}["J" => Int32.(rand(rng, 1:4, nc)), "Q" => Int32.(rand(rng, 100:105, nc))]
        d = [joinpath(mktempdir(), n) for n in ("a", "b", "c")]
        write_table(d[1], "A", A; nrow=na); write_table(d[2], "B", B; nrow=nb); write_table(d[3], "C", C; nrow=nc)
        t = readtable.(d)
        j2 = "FROM \$1 a JOIN \$2 b ON a.K == b.K"
        j3 = j2 * " JOIN \$3 c ON b.J == c.J"
        qs = [("SELECT a.V AS X, b.N AS Y $j2", 2),
              ("SELECT a.V*b.W AS X, a.K AS Y $j2 WHERE b.W > 0", 2),
              ("SELECT a.V AS X, b.N AS Y $j2 ORDER BY a.V DESC", 2),
              ("SELECT a.V AS X, c.Q AS Y $j3", 3),
              ("SELECT b.N AS X, gcount() AS Y $j2 GROUP BY b.N", 2),
              ("SELECT b.N AS X, gsum(a.V) AS Y $j2 GROUP BY b.N HAVING gcount() > 1", 2),
              ("SELECT a.V AS X, b.W AS Y FROM \$1 a JOIN \$2 b ON a.Z == b.rowid()", 2),
              ("SELECT a.V AS X, b.N AS Y $j2 WHERE b.N == 'x' OR a.V < 0 ORDER BY a.V LIMIT 7", 2)]
        for (q, np) in qs
            ours = taql(t[1], q, t[2:np]...)
            real = try
                rt = _taqlcmd(q, d[1:np]...)
                Dict(c => collect(rt[Symbol(c)][:]) for c in ("X", "Y"))   # the error can surface lazily here
            catch e
                e
            end
            if real isa Exception
                @test occursin("Slicer error", sprint(showerror, real))
                @test length(column(ours, "X")[:]) == 0
            else
                for c in ("X", "Y")
                    @test same(real[c], collect(column(ours, c)[:]))
                end
            end
        end
    end
end
end

# Phase 319: random ORDER BY / DISTINCT / LIMIT / OFFSET fuzz vs real TaQL, on
# low-cardinality columns (lots of ties).  Plain SELECTs match real TaQL
# EXACTLY (stable multi-key sort, DESC / leading-DESC, LIMIT / negative LIMIT /
# OFFSET).  `SELECT DISTINCT ... ORDER BY` returns the same SET of rows, but
# real TaQL keeps an arbitrary representative row per distinct tuple (its
# dedup is a no-duplicates heap sort), so the order among tied rows -- and an
# ORDER BY on an unselected column -- can differ; there only the multiset is
# compared (no LIMIT).  A window that is empty / past the end makes real TaQL
# throw a lazy "Slicer error"; ours returns 0 rows or an ArgumentError.
if _HAVE_TAQL
@testset "taql SELECT ORDER BY / DISTINCT / LIMIT random fuzz vs real TaQL (Phase 319)" begin
    rng = MersenneTwister(319)
    same(a, b) = length(a) == length(b) && all(eachindex(a)) do i
        a[i] isa AbstractFloat && b[i] isa AbstractFloat ?
            (isnan(a[i]) && isnan(b[i]) || isapprox(a[i], b[i]; rtol=1e-9)) : isequal(a[i], b[i])
    end
    for case in 1:12
        n = rand(rng, (1, 2, 8, 25, 60))
        cols = Pair{String,Any}["I" => Int32.(rand(rng, 0:3, n)), "D" => Float64.(rand(rng, -2:2, n)),
                                "S" => [rand(rng, ("a", "b", "c")) for _ in 1:n], "R" => Int32.(1:n),
                                "B" => rand(rng, Bool, n)]
        d = joinpath(mktempdir(), "t"); write_table(d, "T", cols; nrow=n)
        t = readtable(d)
        for _ in 1:8
            ks = shuffle(rng, ["I", "D", "S", "B", "R"])[1:rand(rng, 1:3)]
            ob = join([k * rand(rng, ("", " ASC", " DESC")) for k in ks], ", ")
            lead = rand(rng) < 0.15 ? "DESC " : ""
            distinct = rand(rng) < 0.25
            lim = distinct ? "" : rand(rng, ("", "", " LIMIT $(rand(rng, 1:n + 2))", " LIMIT -$(rand(rng, 1:n))",
                                             " LIMIT $(rand(rng, 1:5)) OFFSET $(rand(rng, 0:4))", " OFFSET $(rand(rng, 0:n))"))
            wh = rand(rng) < 0.3 ? " WHERE I > 0" : ""
            sel, scols = distinct ? ("DISTINCT I, S", ["I", "S"]) : ("R, I, D, S", ["R", "I", "D", "S"])
            q = "SELECT $sel FROM \$1$wh ORDER BY $lead$ob$lim"
            real = try
                rt = _taqlcmd(q, d)
                Dict(c => collect(rt[Symbol(c)][:]) for c in scols)
            catch e
                e
            end
            ours = try taql(t, q) catch e; e end
            if real isa Exception
                @test occursin("Slicer error", sprint(showerror, real))
                @test ours isa ArgumentError || length(column(ours, scols[1])[:]) == 0
            elseif distinct
                rp = sort(collect(zip(real["I"], real["S"])))
                op = sort(collect(zip(collect(column(ours, "I")[:]), collect(column(ours, "S")[:]))))
                @test rp == op
            else
                for c in scols
                    @test same(real[c], collect(column(ours, c)[:]))
                end
            end
        end
    end
end
end

# Phase 346: `ALTER TABLE` -- ADD / DROP / RENAME COLUMN and SET / DROP / RENAME KEYWORD (table and `COL::kw` column keywords).
# 32 commands compared against real TaQL on twin tables (columns, types, shapes, keyword order and types, data): all agree.
# Real quirks reproduced: an existing keyword is replaced IN PLACE (Phase 349 correction: the earlier "moves to the end" was a misread of Dict order); integers are stored as Int64 and a mixed
# `[1.5, 2]` array as Float64; several clauses may follow one `ALTER TABLE`; failures (unknown column, rename onto an existing
# one) leave the table unchanged.
@testset "taql ALTER TABLE vs real TaQL (Phase 346)" begin
    mk() = (d = joinpath(mktempdir(), "t");
            write_table(d, "T", Pair{String,Any}["A" => Int32.(1:4), "B" => Float64.(1:4), "S" => ["a", "b", "c", "d"], "K" => Int32.(1:4)];
                        nrow=4, keywords=Dict("KW1" => 5, "KW2" => "x")); d)
    kwlist(t) = [(t.desc.public.names[i] => t.desc.public.values[i]) for i in eachindex(t.desc.public.names)]
    colnames(t) = [c.name for c in t.desc.columns]
    d = mk()
    taql(d, "ALTER TABLE \$1 SET KEYWORD KW1=7, KW3='z'")
    @test kwlist(readtable(d)) == ["KW2" => "x", "KW1" => 7, "KW3" => "z"]         # KW1 replaced in place
    @test readtable(d).desc.public.values[2] isa Int64
    taql(d, "ALTER TABLE \$1 SET KEYWORD KW4=[1.5,2], KW5=(1+2)*3, KW6=true")
    kw = Dict(kwlist(readtable(d)))
    @test kw["KW4"] == [1.5, 2.0] && kw["KW5"] == 9 && kw["KW6"] === true
    taql(d, "ALTER TABLE \$1 DROP KEYWORD KW3")
    @test !haskey(Dict(kwlist(readtable(d))), "KW3")
    taql(d, "ALTER TABLE \$1 RENAME KEYWORD KW1 TO KWX")
    @test Dict(kwlist(readtable(d)))["KWX"] == 7 && !haskey(Dict(kwlist(readtable(d))), "KW1")      # renamed in place (Phase 349)
    taql(d, "ALTER TABLE \$1 SET KEYWORD A::QuantumUnits=['m'], B::MyKw=3")
    @test columndesc(readtable(d), "A").keywords.values == [["m"]]
    @test_throws KeyError taql(d, "ALTER TABLE \$1 DROP KEYWORD NOSUCH")
    # columns
    d = mk()
    taql(d, "ALTER TABLE \$1 RENAME COLUMN A TO AA, B TO BB")
    @test colnames(readtable(d)) == ["AA", "BB", "S", "K"] && collect(column(readtable(d), "AA")) == Int32.(1:4)
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 RENAME COLUMN AA TO BB")      # already exists
    @test_throws KeyError taql(d, "ALTER TABLE \$1 DROP COLUMN NOSUCH")
    @test colnames(readtable(d)) == ["AA", "BB", "S", "K"]                             # unchanged by the failures
    taql(d, "ALTER TABLE \$1 DROP COLUMN BB RENAME COLUMN AA TO A")                   # several clauses
    @test colnames(readtable(d)) == ["A", "S", "K"]
    taql(d, "ALTER TABLE \$1 ADD COLUMN N1 R8, N2 I4, N3 S DMINFO [TYPE=\"StandardStMan\", NAME=\"SSM2\"]")
    t = readtable(d)
    @test colnames(t) == ["A", "S", "K", "N1", "N2", "N3"]
    @test eltype(column(t, "N1")) == Float64 && eltype(column(t, "N2")) == Int32 && eltype(column(t, "N3")) == String
    @test collect(column(t, "N1")) == zeros(4) && collect(column(t, "N3")) == fill("", 4)
    taql(d, "ALTER TABLE \$1 ADD COLUMN V R8 [NDIM=1], W B DMINFO [TYPE=\"StandardStMan\", NAME=\"SSM3\"]")
    t = readtable(d)
    @test columndesc(t, "V").shape == MSv2.VariableShape(1) && columndesc(t, "W").type == MSv2.TpBool
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 ADD COLUMN Q ZZ")             # unknown type
    # a renamed column keeps its data, units and the engine links that name it
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["F" => Float64.(1:4)]; nrow=4, units=Dict("F" => "Hz"))
    renamecolumn!(d, "F", "FREQ")
    @test get(columndesc(readtable(d), "FREQ").keywords, "QuantumUnits", nothing) == ["Hz"]
    d2 = joinpath(mktempdir(), "t")
    write_table(d2, "T", Pair{String,Any}["V" => [Float32.(i .* ones(2, 2)) for i in 1:3]]; nrow=3,
                engines=Dict("V" => (; kind=MSv2.CompressFloat(), scale=0.01, offset=0.0)))
    renamecolumn!(d2, "V_COMPRESSED", "VC")
    @test collect(column(readtable(d2), "V"))[2] ≈ Float32.(2 .* ones(2, 2)) atol = 0.01    # the engine follows its stored column
    if _HAVE_TAQL
        function state(dd)
            t = readtable(dd)
            (colnames(t), [(c.name, c.type, c.shape isa Tuple ? c.shape : typeof(c.shape)) for c in t.desc.columns], kwlist(t),
             [collect(column(t, c.name)[:])[1:2] for c in t.desc.columns if !(c.name in ("N4",))])
        end
        dm = " DMINFO [TYPE=\"StandardStMan\", NAME=\"SSM2\"]"
        for c in ["SET KEYWORD KW1=7, KW3=2", "DROP KEYWORD KW1", "RENAME KEYWORD KW1 TO KW9", "RENAME COLUMN A TO AA, B TO BB",
                  "DROP COLUMN A, B", "RENAME COLUMN A TO AA DROP COLUMN B", "SET KEYWORD KW6=(1+2)*3", "SET KEYWORD KW8=[1.5,2]",
                  "SET KEYWORD KW8=true", "SET KEYWORD KW8=['a','b']", "ADD COLUMN N1 R8, N2 I4" * dm, "ADD COLUMN N1 S" * dm,
                  "ADD COLUMN N1 R8 [NDIM=1]" * dm, "ADD COLUMN N1 B" * dm, "ADD COLUMN N1 C8" * dm, "ADD COLUMN N1 U1" * dm,
                  "ADD COLUMN N1 R8 [NDIM=0]" * dm, "ADD COLUMN N1 R8 [NDIM=2]" * dm]
            d1 = mk(); d2 = mk()
            before = state(d1)
            x = _taqlcmd("ALTER TABLE \$1 $c", d1); x = nothing      # drop the handle so casacore flushes the table
            taql(d2, "ALTER TABLE \$1 $c")
            for _ in 1:50                          # casacore flushes the altered table when its handle is finalised
                GC.gc(); GC.gc(); sleep(0.1)
                state(d1) != before && break
            end
            @test state(d1) == state(d2)
        end
        for c in ["DROP COLUMN NOSUCH", "RENAME COLUMN A TO B", "DROP KEYWORD NOSUCH", "ADD COLUMN K R8" * dm]
            d1 = mk(); d2 = mk()
            @test_throws Exception _taqlcmd("ALTER TABLE \$1 $c", d1)
            @test_throws Exception taql(d2, "ALTER TABLE \$1 $c")
        end
    end
end

# Phase 347: `CREATE TABLE` and `DROP TABLE` as target-less commands, `taql("CREATE TABLE ...")`.  24 CREATE forms compared against
# real TaQL (column names / types / shapes / units / comments / data managers / default rows).  Real casacore leaves the cells of a
# fixed-shape array column uninitialised (garbage) and lists the DMINFO data manager first; neither is copied.  (Real
# `CREATE TABLE ... LIMIT -1` crashes casacore, so it can't be an oracle; here a negative LIMIT is an error.)
@testset "taql CREATE TABLE / DROP TABLE vs real TaQL (Phase 347)" begin
    newpath() = joinpath(mktempdir(), "n")
    cols(t) = [(c.name, c.type, c.shape isa Tuple ? c.shape : typeof(c.shape), c.comment, c.keywords.names, c.keywords.values) for c in t.desc.columns]
    p = newpath()
    taql("CREATE TABLE '$p' [A I4, B R8, S S, F B, C C8, V R8 [NDIM=1], M R4 [NDIM=2, SHAPE=[2,3]], Q U1] LIMIT 3")
    t = readtable(p)
    @test nrow(t) == 3 && columnnames(t) == ["A", "B", "S", "F", "C", "V", "M", "Q"]
    @test collect(column(t, "A")) == Int32[0, 0, 0] && collect(column(t, "S")) == fill("", 3) && collect(column(t, "F")) == falses(3)
    @test eltype(column(t, "C")) == ComplexF64 && eltype(column(t, "Q")) == UInt8
    @test columndesc(t, "V").shape == MSv2.VariableShape(1) && columndesc(t, "M").shape == (2, 3)
    @test all(isempty, column(t, "V")[:]) && all(==(zeros(Float32, 2, 3)), column(t, "M")[:])
    p = newpath(); taql("CREATE TABLE '$p' [A I4 [UNIT=\"m\", COMMENT=\"c\"], a r8] LIMIT 2+1")    # types are case-insensitive, names keep case
    t = readtable(p)
    @test nrow(t) == 3 && columnnames(t) == ["A", "a"] && columndesc(t, "A").comment == "c"
    @test columndesc(t, "A").keywords["QuantumUnits"] == ["m"]
    p = newpath(); taql("CREATE TABLE '$p' [] LIMIT 2"); @test nrow(readtable(p)) == 2 && isempty(columnnames(readtable(p)))
    p = newpath(); taql("CREATE TABLE '$p' [A I4]"); @test nrow(readtable(p)) == 0
    p = newpath(); taql("CREATE TABLE '$p' [A I4, B R8] LIMIT 4 DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"A\"]]")
    @test sort([m.name for m in readtable(p).managers]) == ["IncrementalStMan", "StandardStMan"]
    p = newpath(); taql("CREATE TABLE '$p' AS [storage=\"multifile\", blocksize=1024] [A I4] LIMIT 2")
    @test readtable(p).container isa MSv2.MultiFileContainer
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A I4, A R8] LIMIT 1")             # duplicate column
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A ZZ] LIMIT 1")                   # unknown type
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A I4 [NDIM=1, SHAPE=[2,3]]] LIMIT 1")
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A I4] LIMIT -1")
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A I4 [DEFAULT=7]] LIMIT 1")
    @test_throws ArgumentError taql("CREATE TABLE '$(newpath())' [A,B] LIMIT 1")
    @test_throws ArgumentError taql("CREATE TABLE '$p' [A I4] LIMIT 1")                              # exists
    # DROP TABLE
    p = newpath(); taql("CREATE TABLE '$p' [A I4] LIMIT 2")
    @test isdir(p)
    taql("DROP TABLE '$p'")
    @test !ispath(p)
    p = newpath(); taql("CREATE TABLE '$p' [A I4] LIMIT 2")
    taql(p, "DROP TABLE \$1"); @test !ispath(p)
    @test_throws ArgumentError taql("DROP TABLE '$(mktempdir())'")                                 # not a table: nothing is deleted
    if _HAVE_TAQL
        function state(pp)
            t = readtable(pp)
            (nrow(t), [(c.name, c.type, c.shape isa Tuple ? c.shape : typeof(c.shape), c.comment, c.keywords.names, c.keywords.values) for c in t.desc.columns],
             sort([m.name for m in t.managers]),
             # real leaves a fixed-shape array column's cells uninitialised, so compare the other columns' first rows only
             [map(v -> v isa AbstractArray ? Array(v) : v, collect(column(t, c.name)[:])[1:min(end, 2)])
              for c in t.desc.columns if !(c.shape isa Tuple && !isempty(c.shape))])
        end
        for c in ["[A I4, B R8] LIMIT 5", "[A I4, B R8, S S] LIMIT 3", "[A I4 [NDIM=1]] LIMIT 3", "[A I4 [SHAPE=[2,3]]] LIMIT 3", "[A I4, B R8]",
                  "[A I4] LIMIT 0", "[A I4, B R8] LIMIT 4 DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"A\"]]",
                  "[A C8, B B, C U1] LIMIT 2", "[A I4 [UNIT=\"m\"]] LIMIT 2", "[A I4 [COMMENT=\"hi\"]] LIMIT 2", "[A I4 [UNIT=\"m\", COMMENT=\"c\"]] LIMIT 1",
                  "[A I4 [UNIT=[\"m\"]]] LIMIT 1", "[] LIMIT 2", "[A I4] LIMIT 2+1", "[a i4] LIMIT 1", "[A R8 [NDIM=0]] LIMIT 2", "[A R8 [NDIM=2]] LIMIT 2"]
            p1 = newpath(); p2 = newpath()
            x = _taqlcmd("CREATE TABLE '$p1' $c"); x = nothing
            taql("CREATE TABLE '$p2' $c")
            for _ in 1:50                                  # casacore finalises (flushes) the new table when its handle is collected
                GC.gc(); GC.gc(); sleep(0.1)
                isfile(joinpath(p1, "table.dat")) && break
            end
            @test state(p1) == state(p2)
        end
    end
end

# Phase 348: random CREATE TABLE specs vs real TaQL (types, NDIM/SHAPE, UNIT, COMMENT, LIMIT incl. 0 / absent, DMINFO).  Found: a column with
# no rows and a variable / fixed array shape (NDIM, or LIMIT 0 + SHAPE) had no element type and could not be written.
@testset "taql CREATE TABLE random specs vs real TaQL (Phase 348)" begin
    newpath() = joinpath(mktempdir(), "n")
    for ty in ("R4", "U1"), spec in ("[NDIM=2]", "[SHAPE=[3,1,2]]", "[NDIM=0]")      # zero rows keep their element type
        p = newpath(); taql("CREATE TABLE '$p' [A $ty $spec] LIMIT 0")
        @test nrow(readtable(p)) == 0 && columndesc(readtable(p), "A").type == (ty == "R4" ? MSv2.TpFloat : MSv2.TpUChar)
    end
    if _HAVE_TAQL
        function state(pp)
            t = readtable(pp)
            (nrow(t), [(c.name, c.type, c.shape isa Tuple ? c.shape : typeof(c.shape), c.comment, c.keywords.names, c.keywords.values) for c in t.desc.columns],
             sort([m.name for m in t.managers]),
             [map(v -> v isa AbstractArray ? Array(v) : v, collect(column(t, c.name)[:])[1:min(end, 2)])
              for c in t.desc.columns if !(c.shape isa Tuple && !isempty(c.shape))])
        end
        rng = MersenneTwister(348)
        types = ["I2", "I4", "R4", "R8", "S", "B", "C8", "C16", "U1", "U2", "U4", "I8"]
        function gen()
            nc = rand(rng, 0:4); names = ["C$i" for i in 1:nc]; specs = String[]
            for nm in names
                opts = String[]; r = rand(rng)
                r < .25 ? push!(opts, "NDIM=$(rand(rng, 0:3))") : r < .4 && push!(opts, "SHAPE=[" * join(rand(rng, 1:4, rand(rng, 1:3)), ",") * "]")
                rand(rng) < .25 && push!(opts, "UNIT=\"" * rand(rng, ["m", "Hz", "s", "Jy"]) * "\"")
                rand(rng) < .25 && push!(opts, "COMMENT=\"c$(rand(rng, 1:99))\"")
                push!(specs, nm * " " * rand(rng, types) * (isempty(opts) ? "" : " [" * join(opts, ", ") * "]"))
            end
            s = "[" * join(specs, ", ") * "]"
            rand(rng) < .8 && (s *= " LIMIT $(rand(rng, 0:6))")
            nc >= 2 && rand(rng) < .3 && (s *= " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"$(names[1])\"]]")
            s
        end
        for _ in 1:25
            c = gen(); p1 = newpath(); p2 = newpath()
            ok1 = try x = _taqlcmd("CREATE TABLE '$p1' $c"); x = nothing; true catch; false end   # real rejects e.g. C16
            ok2 = try taql("CREATE TABLE '$p2' $c"); true catch; false end
            @test ok1 == ok2
            (ok1 && ok2) || continue
            for _ in 1:50
                GC.gc(); GC.gc(); sleep(0.1)
                isfile(joinpath(p1, "table.dat")) && break
            end
            @test state(p1) == state(p2)
        end
    end
end

# Phase 349: random ALTER TABLE clauses vs real TaQL (1-2 clauses, ADD/DROP/RENAME COLUMN, SET/DROP/RENAME KEYWORD, `COL::kw`).
# Found: SET KEYWORD on an existing keyword must keep its data type (Int stays Int, scalar stays scalar; a one-element array
# literal is a scalar) or real errors; RENAME KEYWORD keeps the keyword's position; RENAME COLUMN X TO X errors.
@testset "taql ALTER TABLE random clauses vs real TaQL (Phase 349)" begin
    mk() = (d = joinpath(mktempdir(), "t");
            write_table(d, "T", Pair{String,Any}["A" => Int32.(1:4), "B" => Float64.(1:4), "S" => ["a", "b", "c", "d"], "K" => Int32.(1:4)];
                        nrow=4, keywords=Dict("KW1" => 5, "KW2" => "x")); d)
    kwlist(t) = [(t.desc.public.names[i] => t.desc.public.values[i]) for i in eachindex(t.desc.public.names)]
    d = mk()
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 SET KEYWORD KW1=1.5")             # Int -> Double
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 SET KEYWORD KW2=7")               # String -> Int
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 SET KEYWORD KW1=[1,2]")           # scalar -> array
    taql(d, "ALTER TABLE \$1 SET KEYWORD KW2=['q']")                                       # one-element array literal = scalar
    @test Dict(kwlist(readtable(d)))["KW2"] == "q"
    d = mk(); names0 = first.(kwlist(readtable(d)))
    taql(d, "ALTER TABLE \$1 SET KEYWORD KW4=1, $(names0[1])=" * (names0[1] == "KW1" ? "9" : "'w'"))   # replaced in place, KW4 appended
    @test first.(kwlist(readtable(d))) == [names0; "KW4"]
    d = mk()
    taql(d, "ALTER TABLE \$1 RENAME KEYWORD KW1 TO KWX")
    @test first.(kwlist(readtable(d))) == replace(names0, "KW1" => "KWX")                   # renamed in place
    taql(d, "ALTER TABLE \$1 RENAME KEYWORD KWX TO KWX"); @test first.(kwlist(readtable(d))) == replace(names0, "KW1" => "KWX")
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 ADD COLUMN N R8")                  # real TaQL needs the DMINFO
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 RENAME KEYWORD KWX TO KW2")
    @test_throws ArgumentError taql(d, "ALTER TABLE \$1 RENAME COLUMN A TO A")
    if _HAVE_TAQL
        colnames(t) = [c.name for c in t.desc.columns]
        function state(dd)
            t = readtable(dd)
            (colnames(t), [(c.name, c.type, c.shape isa Tuple ? c.shape : typeof(c.shape)) for c in t.desc.columns], kwlist(t),
             [collect(column(t, c.name)[:])[1:2] for c in t.desc.columns], [c.keywords.names for c in t.desc.columns])
        end
        rng = MersenneTwister(349)
        cn = ["A", "B", "S", "K", "N1", "N2", "ZZ"]; kn = ["KW1", "KW2", "KW3", "KW4"]
        vals = ["7", "'z'", "1.5", "[1,2]", "[1.5,2]", "true", "(1+2)*3", "['a','b']", "-3", "2.5e3"]
        ty = ["I4", "R8", "S", "B", "C8", "U1", "I2", "R4"]
        dm = " DMINFO [TYPE=\"StandardStMan\", NAME=\"SSM2\"]"
        function clause()
            r = rand(rng, 1:8)
            r == 1 && return "SET KEYWORD " * join(["$(rand(rng, kn))=$(rand(rng, vals))" for _ in 1:rand(rng, 1:2)], ", ")
            r == 2 && return "DROP KEYWORD " * rand(rng, kn)
            r == 3 && return "RENAME KEYWORD $(rand(rng, kn)) TO KWR$(rand(rng, 1:10^6))"   # a fresh name: real writes a duplicate key onto an existing one
            r == 4 && return "RENAME COLUMN $(rand(rng, cn)) TO $(rand(rng, cn))"
            r == 5 && return "DROP COLUMN " * join(unique([rand(rng, cn) for _ in 1:rand(rng, 1:2)]), ", ")
            r == 6 && return "SET KEYWORD $(rand(rng, cn))::$(rand(rng, ["QuantumUnits", "MyKw"]))=$(rand(rng, vals))"
            r == 7 && return "ADD COLUMN $(rand(rng, cn)) $(rand(rng, ty))" * (rand(rng) < .3 ? " [NDIM=$(rand(rng, 0:2))]" : "") * dm
            return "ADD COLUMN N9 $(rand(rng, ty))" * dm
        end
        for _ in 1:30
            c = join([clause() for _ in 1:rand(rng, 1:2)], " ")
            d1 = mk(); d2 = mk(); before = state(d1)
            ok1 = try x = _taqlcmd("ALTER TABLE \$1 $c", d1); x = nothing; true catch; false end
            ok2 = try taql(d2, "ALTER TABLE \$1 $c"); true catch; false end
            @test ok1 == ok2
            ok1 && (for _ in 1:50; GC.gc(); GC.gc(); sleep(0.1); state(d1) != before && break; end)
            @test state(d1) == state(d2)
        end
    end
end

# Phase 350: random sub-query SELECTs vs real TaQL (IN / NOT IN / EXISTS / NOT EXISTS with WHERE, DISTINCT, ORDER BY, LIMIT, computed columns,
# FROM (SELECT ..)).  Found: sub-queries in the WHERE of `FROM (SELECT ..)` still name the ORIGINAL table (`$1`), not the inner selection;
# and `EXISTS (... LIMIT n)` is empty when fewer than n rows match (real errors for the positive form).  Where real errors (a positive
# EXISTS / IN of an empty sub-query) ours returns no rows.
@testset "taql SELECT sub-queries random fuzz vs real TaQL (Phase 350)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["G" => Int32[1, 2, 1, 3, 2, 1, 3, 3], "K" => Int32.(1:8), "D" => collect(0.5:1:7.5)]; nrow=8)
    t = readtable(dir)
    xs(q) = collect(column(taql(t, q), "X")[:])
    @test xs("SELECT K AS X FROM (SELECT FROM t WHERE G==1) WHERE EXISTS (SELECT FROM t WHERE G==2)") == [1, 3, 6]
    @test xs("SELECT K AS X FROM (SELECT FROM t WHERE K<4) WHERE K IN (SELECT K FROM t WHERE K>2)") == [3]
    @test isempty(xs("SELECT K AS X FROM t WHERE EXISTS (SELECT FROM t WHERE K<2 LIMIT 3)"))
    @test xs("SELECT K AS X FROM t WHERE NOT EXISTS (SELECT FROM t WHERE K<2 LIMIT 3)") == 1:8
    @test xs("SELECT K AS X FROM t WHERE EXISTS (SELECT FROM t WHERE K<5 LIMIT 3)") == 1:8
    if _HAVE_TAQL
        rng = MersenneTwister(350)
        cond() = rand(rng, ["K>$(rand(rng, 0:8))", "K<$(rand(rng, 1:9))", "G==$(rand(rng, 1:3))", "G!=$(rand(rng, 1:3))", "D>$(rand(rng, 0:7)).5",
                            "K%2==$(rand(rng, 0:1))", "G+K>$(rand(rng, 2:10))", "K BETWEEN $(rand(rng, 1:4)) AND $(rand(rng, 4:8))"])
        function inner(col)
            s = "SELECT " * (rand(rng) < .2 ? "DISTINCT " : "") * rand(rng, [col, col, "$col+1 AS $col"]) * " FROM \$1"
            rand(rng) < .8 && (s *= " WHERE " * cond())
            rand(rng) < .3 && (s *= " ORDER BY K" * rand(rng, ["", " DESC"]))
            rand(rng) < .2 && (s *= " LIMIT $(rand(rng, 1:4))")
            s
        end
        noproj(q) = replace(q, r"SELECT (DISTINCT )?\S+( AS \w+)? FROM" => "SELECT FROM")
        function wh()
            r = rand(rng); r < .35 && return cond()
            c = rand(rng, ["K", "G"])
            r < .6 && return "$c IN ($(inner(c)))"
            r < .75 && return "$c NOT IN ($(inner(c)))"
            r < .85 && return "EXISTS ($(noproj(inner("K"))))"
            r < .92 && return "NOT EXISTS ($(noproj(inner("K"))))"
            return cond() * rand(rng, [" AND ", " OR "]) * "$c IN ($(inner(c)))"
        end
        for _ in 1:60
            q = "SELECT K AS X FROM " * (rand(rng) < .25 ? "(SELECT FROM \$1 WHERE $(cond()))" : "\$1")
            rand(rng) < .9 && (q *= " WHERE " * wh())
            rand(rng) < .4 && (q *= " ORDER BY K" * rand(rng, ["", " DESC"]))
            r1 = try collect(_taqlcmd(q, dir)[:X][:]) catch; :err end
            r2 = xs(replace(q, "\$1" => "t"))
            @test r1 === :err ? isempty(r2) : r1 == r2
        end
    end
end

# Phase 355: random GROUP BY with expression keys (K+1, K%2, upper(S), strlength(S), (I>0), floor(D/2), ...), aggregate expressions, WHERE,
# HAVING (also by alias), ORDER BY (alias / key / DESC) and LIMIT vs real TaQL, compared IN ORDER (550 queries; `gmax` left out: upstream bug,
# Phase 284).  Found: an all-DESC ORDER BY of a grouped result is the reversed ascending sort (fully-tied groups come out reversed), like a
# row ORDER BY (Phase 246); mixed directions keep ties in first-seen group order.
@testset "taql GROUP BY expression keys + ORDER BY / LIMIT vs real TaQL (Phase 355)" begin
    dir = joinpath(mktempdir(), "t")
    write_table(dir, "T", Pair{String,Any}["K" => Int32[3, 1, 2, 0, 3, 1, 2, 0], "D" => [2.5, -1.0, 0.5, 3.0, -2.0, 1.0, 0.0, 4.0]]; nrow=8)
    t = readtable(dir)
    col(q, n) = collect(column(taql(t, q), n)[:])
    @test col("SELECT K, gcount() AS N FROM t GROUP BY K", "K") == [3, 1, 2, 0]                      # first-seen group order
    @test col("SELECT K, gcount() AS N FROM t GROUP BY K ORDER BY N DESC", "K") == [0, 2, 1, 3]     # all tied, DESC = reversed
    @test col("SELECT K, gcount() AS N FROM t GROUP BY K ORDER BY K DESC", "K") == [3, 2, 1, 0]
    @test col("SELECT K%2 AS P, K, gcount() AS N FROM t GROUP BY K%2, K ORDER BY P DESC, K", "K") == [1, 3, 0, 2]   # mixed: ties keep order
    if _HAVE_TAQL
        N = 40; r0 = MersenneTwister(3)
        d2 = joinpath(mktempdir(), "t")
        write_table(d2, "T", Pair{String,Any}["K" => Int32.(rand(r0, 0:3, N)), "I" => Int32.(rand(r0, -5:5, N)), "D" => round.(randn(r0, N) .* 3; digits=1),
                    "S" => rand(r0, ["ab", "abc", "b", "z"], N)]; nrow=N)
        t2 = readtable(d2)
        rng = MersenneTwister(355)
        pick(xs) = xs[rand(rng, 1:length(xs))]
        keyexprs = ["K", "K+1", "K%2", "I%3", "S", "upper(S)", "strlength(S)", "(I>0)", "floor(D/2)", "K*2+I%2"]
        aggs = ["gcount()", "gsum(I)", "gmean(D)", "gmin(I)", "gfirst(D)", "glast(S)", "gsum(I)+gcount()", "gmean(I)*2"]
        for _ in 1:60
            ks = unique([pick(keyexprs) for _ in 1:rand(rng, 1:2)])
            ags = ["$(pick(aggs)) AS A$i" for i in 1:rand(rng, 1:2)]
            q = "SELECT " * join(vcat(["$k AS G$i" for (i, k) in enumerate(ks)], ags), ", ") * " FROM \$1" * (rand(rng) < .3 ? " WHERE I > $(rand(rng, -3:3))" : "") *
                " GROUP BY " * join(ks, ", ")
            rand(rng) < .3 && (q *= " HAVING " * pick(["gcount() > 2", "A1 > 0", "gsum(I) <= 5", "gcount() < 8"]))
            rand(rng) < .6 && (q *= " ORDER BY " * pick(["G1", "A1", "G1 DESC", "A1 DESC, G1"]))
            rand(rng) < .2 && (q *= " LIMIT $(rand(rng, 1:4))")
            names = ["G$i" for i in 1:length(ks)]; append!(names, ["A$i" for i in 1:length(ags)])
            r1 = try (rt = _taqlcmd(q, d2); [collect(rt[Symbol(n)][:]) for n in names]) catch ex; occursin("Slicer", sprint(showerror, ex)) ? :empty : :err end    # a lazy "Slicer error" = an empty result
            r2 = try (g = taql(t2, replace(q, "\$1" => "t")); [collect(column(g, n)[:]) for n in names]) catch; :err end
            @test (r1 === :err && r2 === :err) || (r1 === :empty && r2 !== :err && all(isempty, r2)) || (r1 !== :err && r1 !== :empty && r2 !== :err && all(j -> length(r1[j]) == length(r2[j]) &&
                  all(i -> r1[j][i] == r2[j][i] || (r1[j][i] isa Real && isapprox(r1[j][i], r2[j][i]; rtol=1e-9, atol=1e-12)), eachindex(r1[j])), eachindex(r1)))
        end
    end
end

# Phase 357: GROUP BY aggregate RESULT columns (type, scalar/array, values) vs real TaQL's `GIVING` table: 1300 random `g*(col)` / `gs*(arraycol)`
# (gsum gmean gmin gfirst glast gvariance gstddev grms gmedian gproduct gany gall gntrue gnfalse gsums gmeans gmins gaggr gstack gvariances ...; not gmax/gmaxs:
# real casacore returns DBL_MIN for an all-negative group, Phase 284 -- found on Linux CI)
# over Int/UInt/Short/Float/Double/Complex/Bool/String and array columns: no bug found.  Not copied: real rejects Bool / String aggregates
# (`gsum(B)`, `gmin(S)`, `grms(C)`) and `gfirst` / `glast` of an ARRAY column; TaQL-lite accepts them.
@testset "taql GROUP BY aggregate result columns vs real TaQL GIVING (Phase 357)" begin
    if _HAVE_TAQL
        rng = MersenneTwister(357)
        pick(xs) = xs[rand(rng, 1:length(xs))]
        n = 12
        dir = joinpath(mktempdir(), "t")
        write_table(dir, "T", Pair{String,Any}["G" => Int32.(rand(rng, 1:3, n)), "I" => Int32.(rand(rng, -3:5, n)), "U" => UInt8.(rand(rng, 0:9, n)),
            "H" => Int16.(rand(rng, -3:5, n)), "FL" => Float32.(rand(rng, -3:5, n)) ./ 2, "D" => Float64.(rand(rng, -3:5, n)) ./ 3,
            "C" => ComplexF32.(rand(rng, -3:3, n)) .+ 1im, "AF" => [Float32.(rand(rng, -3:5, 2)) for _ in 1:n], "AI" => [Int32.(rand(rng, -3:5, 3)) for _ in 1:n],
            "AC" => [ComplexF32.(rand(rng, -3:3, 2)) for _ in 1:n]]; nrow=n)
        t = readtable(dir)
        close(a, b) = a isa AbstractArray ? (size(a) == size(b) && all(close.(a, b))) :
                      (a == b || (a isa Number && b isa Number && (isapprox(a, b; rtol=1e-8, atol=1e-10) || (isnan(a) && isnan(b)))))
        for _ in 1:70
            e = rand(rng) < .5 ? "$(pick(["gsum", "gmean", "gmin", "gfirst", "glast", "gvariance", "gstddev", "gmedian", "gproduct", "gntrue"]))($(pick(["I", "U", "H", "FL", "D"])))" :
                "$(pick(["gsums", "gmeans", "gmins", "gaggr", "gstack", "gvariances", "gmedians", "gproducts"]))($(pick(["AF", "AI"])))"
            q = "SELECT G, $e AS X FROM \$1 GROUP BY G"; p1 = joinpath(mktempdir(), "r")
            ok1 = try x = _taqlcmd(q * " GIVING '$p1'", dir); x = nothing; true catch; false end
            ok1 || continue
            g = taql(t, replace(q, "\$1" => "t"))
            for _ in 1:40; GC.gc(); GC.gc(); sleep(0.05); isfile(joinpath(p1, "table.dat")) && break; end
            r1 = readtable(p1)
            k1 = collect(column(r1, "G")[:]); v1 = collect(column(r1, "X")[:]); k2 = collect(column(g, "G")[:]); v2 = collect(column(g, "X")[:])
            o1 = sortperm(k1); o2 = sortperm(k2)
            @test k1[o1] == k2[o2] && all(i -> close(v1[o1[i]], v2[o2[i]]), eachindex(v1))
            @test (MSv2.columndesc(r1, "X").type == MSv2._casatype_of(eltype(first(v2) isa AbstractArray ? eltype(first(v2)) : typeof(first(v2)))))
        end
    end
end

# Phase 358: random `SELECT .. FROM $1 a JOIN $2 b ON a.LK == b.RK` over Int32/Int64 keys, right columns of every type (Int/Float/Double/Complex/Bool/
# String and Float / Int ARRAY columns), WHERE / ORDER BY, values compared in order vs real TaQL (540 queries).  Found: an unmatched row of a right
# ARRAY column is an EMPTY array (any array column in the right table made the whole JOIN fail), and right-table Float32 / ComplexF32 columns are
# widened to Double / ComplexF64 like real TaQL's result columns.  Not copied: real rejects Double join keys; TaQL-lite matches them.
@testset "taql SELECT ... JOIN: array columns, widening, random fuzz vs real TaQL (Phase 358)" begin
    dl = joinpath(mktempdir(), "l"); dr = joinpath(mktempdir(), "r")
    write_table(dl, "L", Pair{String,Any}["LK" => Int32[1, 2, 9, 3], "LV" => [1.0, 2, 3, 4]]; nrow=4)
    write_table(dr, "R", Pair{String,Any}["RK" => Int32[1, 2, 3], "RA" => [Float32.(i .* ones(2)) for i in 1:3], "RAI" => [Int32.(i .* ones(3)) for i in 1:3],
                "RF" => Float32[0.5, 1, 1.5], "RC" => ComplexF32[1, 2, 3]]; nrow=3)
    tl = readtable(dl); tr = readtable(dr)
    col(c) = collect(column(taql(tl, "SELECT a.LK AS LK, $c AS X FROM \$1 a JOIN \$2 b ON a.LK == b.RK", tr), "X")[:])
    @test col("b.RA") == [[1.0, 1.0], [2.0, 2.0], Float64[], [3.0, 3.0]] && col("b.RAI")[3] == Int64[] && eltype(col("b.RAI")[1]) == Int64
    @test eltype(col("b.RF")) == Float64 && eltype(col("b.RC")) == ComplexF64 && isnan(col("b.RF")[3]) && isnan(real(col("b.RC")[3]))
    if _HAVE_TAQL
        rng = MersenneTwister(358)
        pick(xs) = xs[rand(rng, 1:length(xs))]
        for _ in 1:6
            nl = rand(rng, 4:10); nr = rand(rng, 3:7); kt = pick([Int32, Int64])
            d1 = joinpath(mktempdir(), "l"); d2 = joinpath(mktempdir(), "r")
            write_table(d1, "L", Pair{String,Any}["LK" => kt.(rand(rng, 1:6, nl)), "LV" => Float64.(1:nl), "LS" => rand(rng, ["p", "q", "rr"], nl)]; nrow=nl)
            write_table(d2, "R", Pair{String,Any}["RK" => kt.(shuffle(rng, 1:7)[1:nr]), "RI" => Int32.(10 .* (1:nr)), "RF" => Float32.(1:nr) ./ 4, "RD" => Float64.(1:nr) ./ 3,
                        "RS" => ["s$i" for i in 1:nr], "RB" => rand(rng, Bool, nr), "RC" => ComplexF32.(1:nr) .+ 1im,
                        "RA" => [Float32.(i .* ones(2)) for i in 1:nr], "RAI" => [Int32.(i .* ones(3)) for i in 1:nr]]; nrow=nr)
            a = readtable(d1); b = readtable(d2)
            for _ in 1:8
                cols = unique([pick(["RI", "RF", "RD", "RS", "RB", "RC", "RA", "RAI"]) for _ in 1:rand(rng, 1:3)])
                lcols = unique([pick(["LK", "LV", "LS"]) for _ in 1:rand(rng, 1:2)])
                q = "SELECT " * join(vcat(["a.$c AS $c" for c in lcols], ["b.$c AS $c" for c in cols]), ", ") * " FROM \$1 a JOIN \$2 b ON a.LK == b.RK" *
                    (rand(rng) < .3 ? " WHERE a.LV > $(rand(rng, 1:4))" : "") * (rand(rng) < .3 ? " ORDER BY a.LV DESC" : "")
                names = vcat(lcols, cols)
                r1 = try (rt = _taqlcmd(q, d1, d2); [collect(rt[Symbol(n)][:]) for n in names]) catch ex; occursin("Slicer", sprint(showerror, ex)) ? :empty : :err end
                r1 === :err && continue
                g = taql(a, q, b)
                r2 = [collect(column(g, n)[:]) for n in names]
                close(x, y) = x isa AbstractArray ? (size(x) == size(y) && all(close.(x, y))) : (x == y || (x isa Number && y isa Number && (isapprox(x, y; rtol=1e-6) || (isnan(x) && isnan(y)))))
                @test r1 === :empty ? all(isempty, r2) : all(j -> length(r1[j]) == length(r2[j]) && all(i -> close(r1[j][i], r2[j][i]), eachindex(r1[j])), eachindex(r1))
            end
        end
    end
end
