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
    @test collect(r.M)[1] == .!(V[1] .> 2.0)

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
        @test m7[r] == .!(V0[r] .> 5.0)            # mask = where the selector is false
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

    @testset "update!/delete! -- ORDER BY + LIMIT real TaQL cross-check" begin
        d = mktempdir()
        A = collect(Int32, 1:10)
        T = Float64.(10:-1:1)
        for nm in ("ours", "ref")
            write_table(joinpath(d, nm), nm, Pair{String,Any}["A" => copy(A), "T" => copy(T)];
                       nrow = 10)
        end
        update!(joinpath(d, "ours"); set = ["A" => "A + 100"], where = "A > 3",
               orderby = ["T"], limit = 3)
        _taqlcmd("UPDATE \$1 SET A = A + 100 WHERE A > 3 ORDER BY T LIMIT 3", joinpath(d, "ref"))
        @test column(readtable(joinpath(d, "ours")), "A")[:] ==
              column(readtable(joinpath(d, "ref")), "A")[:]

        d2 = mktempdir()
        for nm in ("ours", "ref")
            write_table(joinpath(d2, nm), nm, Pair{String,Any}["A" => copy(A), "T" => copy(T)];
                       nrow = 10)
        end
        delete!(joinpath(d2, "ours"); where = "A > 3", orderby = ["T" => :desc], limit = 2)
        _taqlcmd("DELETE FROM \$1 WHERE A > 3 ORDER BY T DESC LIMIT 2", joinpath(d2, "ref"))
        @test column(readtable(joinpath(d2, "ours")), "A")[:] ==
              column(readtable(joinpath(d2, "ref")), "A")[:]
    end
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
    end
end
