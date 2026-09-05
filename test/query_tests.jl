# Phase 22: TaQL-lite query engine (WHERE row filtering + SELECT column
# projection/rename, producing a RefTable).

@testset "TaQL-lite parser — unit" begin
    validnames = Set(["A", "B", "C", "D"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    # operator precedence: AND binds tighter than OR
    e = parse("A == 1 OR B == 2 AND C == 3")
    @test e isa MSv2.TQLOr
    @test e.b isa MSv2.TQLAnd

    # parens override precedence
    e2 = parse("(A == 1 OR B == 2) AND C == 3")
    @test e2 isa MSv2.TQLAnd
    @test e2.a isa MSv2.TQLOr

    # both spellings of each connective parse identically in structure
    @test parse("A==1 AND B==2") isa MSv2.TQLAnd
    @test parse("A==1 && B==2") isa MSv2.TQLAnd
    @test parse("A==1 OR B==2") isa MSv2.TQLOr
    @test parse("A==1 || B==2") isa MSv2.TQLOr
    @test parse("NOT A==1") isa MSv2.TQLNot
    @test parse("!A==1") isa MSv2.TQLNot

    # comparison operator spellings
    for (s, op) in [("A == 1", ==), ("A = 1", ==), ("A != 1", !=),
                    ("A <> 1", !=), ("A < 1", <), ("A <= 1", <=),
                    ("A > 1", >), ("A >= 1", >=)]
        e3 = parse(s)
        @test e3 isa MSv2.TQLCmp
        @test e3.op === op
    end

    # literals: int, float, string (both quote styles), bool, unary minus
    litval(s) = parse(s).rhs.value
    @test litval("A == 5") === 5
    @test litval("A == 5.5") === 5.5
    @test litval("A == 'x'") == "x"
    @test litval("A == \"x\"") == "x"
    @test litval("A == true") === true
    @test litval("A == false") === false
    @test litval("A > -5") === -5

    # IN list
    ein = parse("A IN [1, 2, 3]")
    @test ein isa MSv2.TQLIn
    @test ein.vals == Any[1, 2, 3]

    # a bare Bool-column predicate (no trailing comparison) is valid
    @test parse("D") isa MSv2.TQLCol
    @test parse("NOT D") isa MSv2.TQLNot

    # errors: unknown column, malformed expression
    @test_throws ArgumentError parse("ZZZ == 1")
    @test_throws ArgumentError parse("A > ")
    @test_throws ArgumentError parse("(A == 1")
    @test_throws ArgumentError parse("A == 1)")
end

@testset "TaQL-lite query — string form" begin
    dir = joinpath(mktempdir(), "t.tab")
    A = collect(Int32, 1:20)
    B = collect(0.0:1.0:19.0)
    C = [isodd(i) ? "x" : "y" for i in 1:20]
    D = [iseven(i) for i in 1:20]
    write_table(dir, "T", ["A" => A, "B" => B, "C" => C, "D" => D]; nrow=20)
    t = readtable(dir)

    r1 = query(t, "A > 15")
    @test r1 isa RefTable
    @test r1.rows == findall(>(15), A)
    @test column(r1, "A")[:] == A[r1.rows]

    r2 = query(t, "A > 5 AND C == 'x'")
    @test r2.rows == findall(i -> A[i] > 5 && C[i] == "x", 1:20)

    r3 = query(t, "A < 3 OR A > 18")
    @test r3.rows == findall(i -> A[i] < 3 || A[i] > 18, 1:20)

    r4 = query(t, "NOT D")
    @test r4.rows == findall(i -> !D[i], 1:20)

    r5 = query(t, "A IN [1, 5, 10]")
    @test r5.rows == findall(i -> A[i] in (1, 5, 10), 1:20)

    r6 = query(t, "A > -1 AND A <= 3")
    @test r6.rows == findall(i -> A[i] > -1 && A[i] <= 3, 1:20)

    r7 = query(t, "(A > 15 OR A < 3) AND NOT D")
    @test r7.rows == findall(i -> (A[i] > 15 || A[i] < 3) && !D[i], 1:20)

    # only referenced columns are read: a column whose reader always
    # throws (a fabricated ColumnDesc bound to no real data manager)
    # staying untouched proves this, not just an assertion on the result.
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(t.desc.name, t.desc.version, t.desc.comment, t.desc.public,
                    t.desc.private, [t.desc.columns; bogus])
    t2 = Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows, t.endian,
              td2, t.managers, t.syncmod, t.lockpath, t.container)
    r8 = query(t2, "A > 15")   # BOGUS is never resolved -> never errors
    @test r8.rows == r1.rows
end

@testset "TaQL-lite query — select= projection/rename" begin
    dir = joinpath(mktempdir(), "t2.tab")
    A = collect(Int32, 1:10)
    C = ["s$i" for i in 1:10]
    write_table(dir, "T", ["A" => A, "C" => C]; nrow=10)
    t = readtable(dir)

    r = query(t, "A > 5"; select=["AA" => "A", "CC" => "C"])
    @test columnnames(r) == ["AA", "CC"]
    @test column(r, "AA")[:] == A[r.rows]
    @test column(r, "CC")[:] == C[r.rows]

    @test_throws ArgumentError query(t, "A > 5"; select=["X" => "A", "X" => "C"])
    @test_throws ArgumentError query(t, "A > 5"; select=["X" => "NOPE"])
end

@testset "TaQL-lite query — closure form" begin
    dir = joinpath(mktempdir(), "t3.tab")
    A = collect(Int32, 1:20)
    C = [isodd(i) ? "x" : "y" for i in 1:20]
    write_table(dir, "T", ["A" => A, "C" => C]; nrow=20)
    t = readtable(dir)

    r1 = query(t; cols=["A"]) do row
        row.A > 15
    end
    @test r1.rows == findall(>(15), A)

    r2 = query(t) do row
        row.A > 5 && row.C == "x"
    end
    @test r2.rows == findall(i -> A[i] > 5 && C[i] == "x", 1:20)

    r3 = query(t; cols=["A"], select=["AA" => "A"]) do row
        row.A <= 3
    end
    @test columnnames(r3) == ["AA"]
    @test column(r3, "AA")[:] == A[r3.rows]
end

@testset "TaQL-lite query — composability (query of a RefTable)" begin
    dir = joinpath(mktempdir(), "t4.tab")
    A = collect(Int32, 1:30)
    write_table(dir, "T", ["A" => A]; nrow=30)
    t = readtable(dir)

    r1 = query(t, "A > 10")                    # rows 11:30
    r2 = query(r1, "A < 20")                    # further filter, through the MappedColumn
    @test r2.rows == findall(i -> A[i] > 10 && A[i] < 20, 1:30)
    @test column(r2, "A")[:] == A[r2.rows]

    # persist and reopen
    dst = joinpath(mktempdir(), "sel.tab")
    write_reftable(dst, r2)
    r2b = readtable(dst)
    @test r2b isa RefTable
    @test column(r2b, "A")[:] == A[r2.rows]
    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test [ct[:A][i] for i in 1:length(r2.rows)] == A[r2.rows]
    end
end

@testset "TaQL-lite parser — ORDER BY unit" begin
    validnames = Set(["A", "B", "C"])
    parseq(s) = MSv2._taqllite_parse_query(s, validnames)

    ast, ob = parseq("A > 5 ORDER BY B")
    @test ast isa MSv2.TQLCmp
    @test ob == [MSv2.TQLOrderKey("B", false)]

    ast2, ob2 = parseq("A > 5 ORDER BY B DESC")
    @test ob2 == [MSv2.TQLOrderKey("B", true)]

    ast3, ob3 = parseq("ORDER BY B, C DESC")
    @test ast3 === nothing
    @test ob3 == [MSv2.TQLOrderKey("B", false), MSv2.TQLOrderKey("C", true)]

    ast4, ob4 = parseq("ORDER BY A")
    @test ast4 === nothing
    @test ob4 == [MSv2.TQLOrderKey("A", false)]

    # ASC/DESC case-insensitivity
    _, ob5 = parseq("ORDER BY A asc")
    @test ob5 == [MSv2.TQLOrderKey("A", false)]
    _, ob6 = parseq("ORDER BY A desc")
    @test ob6 == [MSv2.TQLOrderKey("A", true)]

    @test_throws ArgumentError parseq("ORDER BY ZZZ")
    @test_throws ArgumentError parseq("A > 5 ORDER BY B garbage")
end

@testset "TaQL-lite query — ORDER BY string form" begin
    dir = joinpath(mktempdir(), "ob1.tab")
    A = Int32[5, 3, 1, 3, 2]
    B = ["e", "c", "a", "d", "b"]
    write_table(dir, "T", ["A" => A, "B" => B]; nrow=5)
    t = readtable(dir)

    r1 = query(t, "A >= 1 ORDER BY A")
    expected1 = sort(collect(1:5); lt=(i, j) -> A[i] < A[j], alg=Base.Sort.MergeSort)
    @test r1.rows == expected1
    @test issorted(A[r1.rows])

    r2 = query(t, "A >= 1 ORDER BY A DESC")
    @test issorted(A[r2.rows]; rev=true)
    # stable tie-break: A has a tie at value 3 (original rows 2 and 4) —
    # descending order must keep row 2 before row 4 among the ties.
    tiepos = findall(==(3), A[r2.rows])
    @test r2.rows[tiepos] == [2, 4]

    # multi-key
    dir2 = joinpath(mktempdir(), "ob2.tab")
    A2 = Int32[1, 1, 1, 2, 2, 2]
    C2 = Int32[5, 3, 9, 1, 1, 2]
    write_table(dir2, "T2", ["A" => A2, "C" => C2]; nrow=6)
    t2 = readtable(dir2)
    r3 = query(t2, "A >= 1 ORDER BY A, C DESC")
    @test A2[r3.rows] == [1, 1, 1, 2, 2, 2]
    @test C2[r3.rows] == [9, 5, 3, 2, 1, 1]
    @test r3.rows[end-1:end] == [4, 5]   # stable tie-break within the A=2,C=1 group

    # bare "ORDER BY" (no WHERE) matches every row, sorted
    r4 = query(t, "ORDER BY B")
    @test B[r4.rows] == sort(B)

    # only referenced-or-sorted-by columns are read
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(t.desc.name, t.desc.version, t.desc.comment, t.desc.public,
                    t.desc.private, [t.desc.columns; bogus])
    t3 = Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows, t.endian,
              td2, t.managers, t.syncmod, t.lockpath, t.container)
    r5 = query(t3, "A >= 1 ORDER BY A")   # BOGUS never resolved -> never errors
    @test r5.rows == r1.rows
end

@testset "TaQL-lite query — ORDER BY closure form" begin
    dir = joinpath(mktempdir(), "ob3.tab")
    A = Int32[5, 3, 1, 3, 2]
    write_table(dir, "T", ["A" => A]; nrow=5)
    t = readtable(dir)

    r1 = query(t; orderby=["A" => :desc]) do row
        row.A >= 1
    end
    @test issorted(A[r1.rows]; rev=true)

    r2 = query(t; orderby=["A"]) do row   # bare name = ascending
        row.A >= 1
    end
    @test issorted(A[r2.rows])

    # matches the equivalent string-form order
    rstr = query(t, "A >= 1 ORDER BY A DESC")
    @test r1.rows == rstr.rows

    @test_throws ArgumentError query(t; orderby=["NOPE"]) do row
        true
    end
    @test_throws ArgumentError query(t; orderby=["A" => :bogus]) do row
        true
    end
end

@testset "TaQL-lite query — ORDER BY composability" begin
    dir = joinpath(mktempdir(), "ob4.tab")
    A = collect(Int32, 1:30)
    write_table(dir, "T", ["A" => A]; nrow=30)
    t = readtable(dir)

    r1 = query(t, "A > 10")                          # rows 11:30, in order
    r2 = query(r1, "A < 25 ORDER BY A DESC")          # flattens through r1's parent
    expected = filter(i -> A[i] > 10 && A[i] < 25, 1:30)
    @test A[r2.rows] == sort(A[expected]; rev=true)
end

if _HAVE_TAQL
    @testset "TaQL-lite query — real TaQL cross-check" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        A = collect(Int32, 1:20)
        B = collect(0.0:1.0:19.0)
        C = [isodd(i) ? "x" : "y" for i in 1:20]
        write_table(pdir, "T", Pair{String,Any}["A" => A, "B" => B, "C" => C]; nrow=20)

        function _taql_rows(wherestr)
            rdir = joinpath(mktempdir(), "sel")
            v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
            parent = CCT.Table(pdir)
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(parent.tableref)))
            GC.@preserve parent CCT.Table(Casacore.LibCasacore.tableCommand(
                "SELECT FROM \$1 WHERE $wherestr GIVING '$rdir'", v))
            GC.gc(); GC.gc()
            rows = readtable(rdir).rows
            return rows
        end

        t = readtable(pdir)
        for wherestr in ("A > 5", "A >= 15 OR A <= 2", "A > 3 AND A < 10",
                         "C == 'x'", "NOT (A > 10)", "A IN [1,5,10,20]")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end

        # ORDER BY -- row ORDER matters here (unlike the WHERE-only cross-
        # check above, which only needs set equality since it never sorts).
        for wherestr in ("A > 5 ORDER BY A DESC", "A > 3 AND A < 15 ORDER BY B",
                         "A > 0 ORDER BY B DESC, A")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end
    end
end
