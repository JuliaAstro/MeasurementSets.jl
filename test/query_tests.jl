# Phase 22: TaQL-lite query engine (WHERE row filtering + SELECT column
# projection/rename, producing a RefTable).
# Phase 26: GROUP BY + aggregation (groupby -> GroupedTable).

import Statistics
import Tables

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
              td2, t.managers, t.syncmod, t.lockpath, t.container, t.precision)
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

@testset "TaQL-lite query — computed select columns" begin
    dir = joinpath(mktempdir(), "csel.tab")
    K = Int32[0, 1, 2, 3, 4, 5]
    X = Float64[1, 4, 9, 16, 25, 36]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=6)
    t = readtable(dir)

    # any computed rhs -> GroupedTable; a bare column stays a projection
    r = query(t, "K >= 1"; select=["K" => "K", "X2" => "X * 2.0", "R" => "sqrt(X)"])
    @test r isa MSv2.GroupedTable
    @test columnnames(r) == ["K", "X2", "R"]
    @test collect(r.K) == Int32[1, 2, 3, 4, 5]
    @test collect(r.X2) == 2 .* X[2:6]
    @test collect(r.R) == sqrt.(X[2:6])

    # all-projection select still returns a lazy RefTable
    @test query(t, "K >= 1"; select=["KK" => "K"]) isa RefTable

    # closure form + computed
    rc = query(t; select=["S" => "K + X", "F" => "iif(K == 0, 1, 0)"]) do row
        row.K <= 2
    end
    @test rc isa MSv2.GroupedTable
    @test collect(rc.S) == Float64[1, 5, 11]
    @test collect(rc.F) == [1, 0, 0]

    # ORDER BY composes with computed columns
    ro = query(t, "K >= 0 ORDER BY K DESC"; select=["K" => "K", "NEG" => "-X"])
    @test collect(ro.K) == Int32[5, 4, 3, 2, 1, 0]
    @test collect(ro.NEG) == -X[6:-1:1]

    # aggregate in a computed column -> clear error
    @test_throws ArgumentError query(t, "TRUE"; select=["A" => "gsum(X)"])

    # persist the computed result
    dst = joinpath(mktempdir(), "OUT")
    write_table(dst, "OUT", r; nrow=nrow(r))
    @test column(readtable(dst), "X2")[:] == 2 .* X[2:6]

    # query on a GroupedTable with a computed select
    g2 = query(r, "K >= 2"; select=["K" => "K", "X4" => "X2 * 2.0"])
    @test collect(g2.X4) == 4 .* X[3:6]

    # taql string form: computed column needs AS; bare column doesn't
    tq = taql(t, "SELECT K, X * 3.0 AS X3 WHERE K >= 3")
    @test collect(tq.X3) == 3 .* X[4:6]
    @test_throws ArgumentError taql(t, "SELECT X + 1 WHERE K >= 0")
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
              td2, t.managers, t.syncmod, t.lockpath, t.container, t.precision)
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

@testset "TaQL-lite parser — arithmetic + pattern unit" begin
    validnames = Set(["A", "B", "C", "N"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    # arithmetic precedence: * binds tighter than +
    e = parse("A + B * C == 0")
    @test e isa MSv2.TQLCmp
    @test e.lhs isa MSv2.TQLArith && e.lhs.op === (+)
    @test e.lhs.rhs isa MSv2.TQLArith && e.lhs.rhs.op === (*)

    # left-assoc for - : (A - B) - C
    e2 = parse("A - B - C == 0").lhs
    @test e2.op === (-) && e2.lhs isa MSv2.TQLArith && e2.lhs.op === (-)

    # ** is right-assoc: A ** B ** C  ->  A ** (B ** C)
    e3 = parse("A ** B ** C == 0").lhs
    @test e3.op === (^) && e3.rhs isa MSv2.TQLArith && e3.rhs.op === (^)

    # unary minus on an expression
    e4 = parse("-(A + B) < 0")
    @test e4.lhs isa MSv2.TQLNeg && e4.lhs.a isa MSv2.TQLArith
    @test parse("A * -B < 0").lhs.rhs isa MSv2.TQLNeg

    # parens let the comparison be seen after an arithmetic group
    e5 = parse("(A + 1) > 2")
    @test e5 isa MSv2.TQLCmp && e5.lhs isa MSv2.TQLArith

    # / vs // vs %
    @test parse("A / B == 1").lhs.op === (/)
    @test parse("A // B == 1").lhs.op === div
    @test parse("A % B == 1").lhs.op === rem

    # LIKE / ILIKE / NOT LIKE build a TQLMatch
    m1 = parse("N LIKE 'CAS%'")
    @test m1 isa MSv2.TQLMatch && !m1.negate
    @test occursin(m1.regex, "CASA") && !occursin(m1.regex, "XCASA")
    @test !occursin(m1.regex, "casa")                          # LIKE is case-sensitive
    @test occursin(parse("N ILIKE 'cas%'").regex, "CASA")      # ILIKE is not
    @test parse("N NOT LIKE 'x%'").negate

    # ~ / !~ operator with p/ m/ f/ literals
    @test parse("N ~ p/DA*/") isa MSv2.TQLMatch
    @test parse("N !~ p/DA*/").negate
    mg = parse("N ~ p/da?/i").regex
    @test occursin(mg, "DA1") && occursin(mg, "da9")
    mp = parse("N ~ m/CAS/").regex           # partial (unanchored)
    @test occursin(mp, "XCASY")
    mf = parse("N ~ f/CAS/").regex           # full (anchored)
    @test occursin(mf, "CAS") && !occursin(mf, "XCASY")

    # ~= / !~= (approximate equality) build a TQLCmp with the near op
    @test parse("A ~= 5").op === MSv2._tql_near
    @test parse("A !~= 5").op === MSv2._tql_nnear
    @test parse("A ~= 5") isa MSv2.TQLCmp
end

@testset "TaQL-lite parser — bitwise unit" begin
    validnames = Set(["A", "B", "F"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    # binary & | ^ build TQLArith nodes
    @test parse("A & 1 == 0").lhs.op === (&)
    @test parse("A | 1 == 0").lhs.op === (|)
    @test parse("A ^ 1 == 0").lhs.op === xor
    # unary ~
    @test parse("~A > 0").lhs isa MSv2.TQLBitNot
    @test parse("~(A & B) > 0").lhs isa MSv2.TQLBitNot

    # precedence: bitwise sits above comparison, below +/-, and | < ^ < &
    @test parse("A & 1 == 0") isa MSv2.TQLCmp               # (A & 1) == 0
    e = parse("A | B & 1 == 0").lhs                          # A | ((B & 1))  ... == handled outside
    @test e.op === (|) && e.rhs.op === (&)
    @test parse("A + 1 & 2 == 0").lhs.op === (&)             # + binds tighter than &
    @test parse("A + 1 & 2 == 0").lhs.lhs isa MSv2.TQLArith  #   -> (A+1) & 2

    # `**` is still exponentiation; `^` is no longer a "use **" error
    @test parse("A ** 2 == 4").lhs.op === (^)
    @test parse("A ^ 2 == 4").lhs.op === xor

    # `~` before a p/m/f literal is still a pattern match, not bitnot
    @test parse("F ~ p/x/") isa MSv2.TQLMatch
end

@testset "TaQL-lite pattern -> regex helpers" begin
    sql = MSv2._sqlpattern_regex
    r = sql("CAS%", false)
    @test occursin(r, "CAS") && occursin(r, "CASABLANCA") && !occursin(r, "XCAS")
    r2 = sql("_A_", false)
    @test occursin(r2, "xAy") && !occursin(r2, "xAyz") && !occursin(r2, "AB")
    @test occursin(sql("a%", true), "ABC")           # ILIKE-style case-insensitive
    # a literal regex metacharacter in the pattern is escaped
    @test occursin(sql("a.c", false), "a.c") && !occursin(sql("a.c", false), "abc")

    glob = MSv2._glob_regex
    @test occursin(glob("DA*", false), "DA42") && !occursin(glob("DA*", false), "XDA")
    @test occursin(glob("DA0?", false), "DA0X") && !occursin(glob("DA0?", false), "DA0XY")
    @test occursin(glob("[AB]NT", false), "ANT") && !occursin(glob("[AB]NT", false), "CNT")
    @test occursin(glob("[!AB]NT", false), "CNT") && !occursin(glob("[!AB]NT", false), "ANT")
    @test occursin(glob("da*", true), "DA1")
end

@testset "TaQL-lite query — arithmetic string form" begin
    dir = joinpath(mktempdir(), "ar1.tab")
    A = collect(Int32, 1:12)
    B = collect(10.0:10.0:120.0)
    write_table(dir, "T", ["A" => A, "B" => B]; nrow=12)
    t = readtable(dir)

    @test query(t, "A + 1 > 6").rows == findall(i -> A[i] + 1 > 6, 1:12)
    @test query(t, "A * 2 <= 10").rows == findall(i -> A[i] * 2 <= 10, 1:12)
    @test query(t, "A % 4 == 0").rows == findall(i -> A[i] % 4 == 0, 1:12)
    @test query(t, "-A < -9").rows == findall(i -> -A[i] < -9, 1:12)
    @test query(t, "A + B > 55 AND A < 10").rows ==
          findall(i -> A[i] + B[i] > 55 && A[i] < 10, 1:12)
    @test query(t, "(A + 2) * 2 > 20").rows == findall(i -> (A[i] + 2) * 2 > 20, 1:12)
    @test query(t, "2 ** A > 500").rows == findall(i -> 2^A[i] > 500, 1:12)
    @test query(t, "A // 5 == 1").rows == findall(i -> div(A[i], 5) == 1, 1:12)
    # precedence: B * 0 evaluated before + A
    @test query(t, "A + B * 0 == A").rows == collect(1:12)
    # arithmetic composes with ORDER BY
    r = query(t, "A % 2 == 0 ORDER BY A DESC")
    @test A[r.rows] == Int32[12, 10, 8, 6, 4, 2]

    # only-referenced-columns-read still holds
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(t.desc.name, t.desc.version, t.desc.comment, t.desc.public,
                    t.desc.private, [t.desc.columns; bogus])
    t2 = Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows, t.endian,
              td2, t.managers, t.syncmod, t.lockpath, t.container, t.precision)
    @test query(t2, "A + 1 > 6").rows == query(t, "A + 1 > 6").rows
end

@testset "TaQL-lite query — pattern matching string form" begin
    dir = joinpath(mktempdir(), "pm1.tab")
    NAME = ["3C48", "3C286", "CASA", "cas9", "src1", "src2", "cal_A", "cal_B",
            "J1234+5678", "M87"]
    write_table(dir, "T", Pair{String,Any}["NAME" => NAME]; nrow=10)
    t = readtable(dir)

    @test query(t, "NAME LIKE '3C%'").rows == findall(x -> startswith(x, "3C"), NAME)
    # `_` is SQL "exactly one char" (no escape char in casacore's fromSQLPattern):
    # 'cal_A' -> c a l <any> A, matches only "cal_A" here.
    @test query(t, "NAME LIKE 'cal_A'").rows == findall(x -> occursin(r"^cal.A$", x), NAME)
    @test query(t, "NAME LIKE '%A'").rows == findall(x -> endswith(x, "A"), NAME)
    @test query(t, "NAME NOT LIKE '3C%'").rows == findall(x -> !startswith(x, "3C"), NAME)
    @test query(t, "NAME ILIKE 'cas%'").rows ==
          findall(x -> startswith(lowercase(x), "cas"), NAME)
    @test query(t, "NAME ~ p/cal_*/").rows == findall(x -> startswith(x, "cal_"), NAME)
    @test query(t, "NAME ~ p/CAS?/").rows == findall(x -> occursin(r"^CAS.$", x), NAME)
    @test query(t, "NAME ~ m/C/").rows == findall(x -> occursin("C", x), NAME)
    @test query(t, "NAME !~ p/src*/").rows == findall(x -> !startswith(x, "src"), NAME)
    @test query(t, "NAME ~ f/[0-9]C.*/i").rows == findall(x -> occursin(r"^[0-9]C.*$"i, x), NAME)

    # pattern composes with AND and ORDER BY
    r = query(t, "NAME LIKE 'c%' ORDER BY NAME")
    @test issorted(NAME[r.rows])
end

@testset "TaQL-lite parser — function unit" begin
    validnames = Set(["A", "B", "NM", "V"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    e = parse("sqrt(A) > 2")
    @test e.lhs isa MSv2.TQLFunc && length(e.lhs.args) == 1 && e.lhs.args[1] isa MSv2.TQLCol

    # nested function calls
    e2 = parse("mean(abs(V)) > 1").lhs
    @test e2 isa MSv2.TQLFunc && e2.args[1] isa MSv2.TQLFunc

    # case-insensitive names + aliases
    @test parse("ABS(A) > 0").lhs isa MSv2.TQLFunc
    @test parse("AvG(V) > 0").lhs isa MSv2.TQLFunc

    # rownumber() -> TQLRowNum ; pi/e -> literal
    @test parse("rownumber() > 1").lhs isa MSv2.TQLRowNum
    @test parse("rownr() > 1").lhs isa MSv2.TQLRowNum
    @test parse("pi() > 3").lhs isa MSv2.TQLLit
    @test parse("e() > 2").lhs.value == ℯ

    # errors: unknown function, wrong arity
    @test_throws ArgumentError parse("bogus(A) > 0")
    @test_throws ArgumentError parse("sqrt(A, B) > 0")
    @test_throws ArgumentError parse("rownumber(A) > 0")
    @test_throws ArgumentError parse("iif(A) > 0")
end

@testset "TaQL-lite — function wrappers unit" begin
    ew = MSv2._ew(abs)
    @test ew(-3) == 3
    @test ew([-1.0 2.0; -3.0 4.0]) == [1.0 2.0; 3.0 4.0]
    red = MSv2._red(sum)
    @test red(5) == 5                       # scalar -> 1-tuple path
    @test red([1, 2, 3]) == 6
    ew2 = MSv2._ew2(^)
    @test ew2(2, 3) == 8
    @test ew2([1, 2, 3], 2) == [1, 4, 9]
    @test MSv2._tql_nelem([1 2; 3 4]) == 4
    @test MSv2._tql_nelem(7) == 1
end

@testset "TaQL-lite query — function string form" begin
    dir = joinpath(mktempdir(), "fn1.tab")
    A = collect(Int32, 1:12)
    B = Float64[1.5, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121, 144]
    NM = [i % 4 == 0 ? "cal_$i" : "src_$i" for i in 1:12]
    write_table(dir, "T", Pair{String,Any}["A" => A, "B" => B, "NM" => NM]; nrow=12)
    t = readtable(dir)

    @test query(t, "sqrt(B) > 5").rows == findall(i -> sqrt(B[i]) > 5, 1:12)
    @test query(t, "abs(A - 7) <= 2").rows == findall(i -> abs(A[i] - 7) <= 2, 1:12)
    @test query(t, "floor(B / 10) == 2").rows == findall(i -> floor(B[i] / 10) == 2, 1:12)
    @test query(t, "sign(A - 6) >= 0").rows == findall(i -> sign(A[i] - 6) >= 0, 1:12)
    @test query(t, "pow(A, 2) > 50").rows == findall(i -> A[i]^2 > 50, 1:12)
    @test query(t, "rownumber() % 3 == 0").rows == findall(i -> i % 3 == 0, 1:12)
    @test query(t, "rownumber() > 9").rows == collect(10:12)
    @test query(t, "upper(NM) == 'CAL_4'").rows == findall(i -> uppercase(NM[i]) == "CAL_4", 1:12)
    @test query(t, "strlength(NM) > 5").rows == findall(i -> length(NM[i]) > 5, 1:12)
    @test query(t, "isfinite(B)").rows == collect(1:12)
    @test query(t, "iif(A > 6, A, 0) > 8").rows == findall(i -> (A[i] > 6 ? A[i] : 0) > 8, 1:12)
    @test query(t, "pi() > 3").rows == collect(1:12)
    @test query(t, "min(A, 5) == 5").rows == findall(i -> min(A[i], 5) == 5, 1:12)

    # array-cell reductions on a small tiled Float column
    vdir = joinpath(mktempdir(), "fn2.tab")
    V = [Float64[i, i + 0.5, i + 1.0, i - 0.5] for i in 1:12]
    write_table(vdir, "TV", Pair{String,Any}["V" => V]; nrow=12, tsm=[["V"]])
    tv = readtable(vdir)
    @test query(tv, "mean(V) > 6").rows == findall(i -> sum(V[i]) / 4 > 6, 1:12)
    @test query(tv, "sum(V) > 20").rows == findall(i -> sum(V[i]) > 20, 1:12)
    @test query(tv, "max(V) > 10").rows == findall(i -> maximum(V[i]) > 10, 1:12)
    @test query(tv, "any(V > 11)").rows == findall(i -> any(V[i] .> 11), 1:12)
    @test query(tv, "nelements(V) == 4").rows == collect(1:12)
    @test query(tv, "mean(abs(V)) > 6").rows == findall(i -> sum(abs.(V[i])) / 4 > 6, 1:12)

    # composes with arithmetic + ORDER BY
    r = query(t, "abs(A - 6) < 4 ORDER BY A DESC")
    @test A[r.rows] == Int32[9, 8, 7, 6, 5, 4, 3]

    # only-referenced-columns-read still holds
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(t.desc.name, t.desc.version, t.desc.comment, t.desc.public,
                    t.desc.private, [t.desc.columns; bogus])
    t2 = Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows, t.endian,
              td2, t.managers, t.syncmod, t.lockpath, t.container, t.precision)
    @test query(t2, "sqrt(B) > 5").rows == query(t, "sqrt(B) > 5").rows
end

@testset "TaQL-lite parser — aggregate unit" begin
    validnames = Set(["K", "X", "V"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    @test parse("gmean(X)") isa MSv2.TQLAggr
    @test parse("gmean(X)").fn === Statistics.mean
    @test parse("gcount()") isa MSv2.TQLAggr
    @test parse("gcount()").arg === nothing
    @test parse("gcount(X)").arg isa MSv2.TQLCol
    @test parse("gsum(mean(abs(V)))").arg isa MSv2.TQLFunc   # aggregate over a nested function

    @test MSv2._has_aggr(parse("gmean(X) > 5"))
    @test !MSv2._has_aggr(parse("mean(X) > 5"))
    @test MSv2._has_aggr(parse("gsum(X) / gcount() > 3"))

    # aggregate in a plain query() errors at eval time
    dir = joinpath(mktempdir(), "a.tab")
    write_table(dir, "T", ["K" => Int32[1, 2, 3]]; nrow=3)
    @test_throws ArgumentError query(readtable(dir), "gcount() > 0")

    @test_throws ArgumentError parse("gfoo(X)")
    @test_throws ArgumentError parse("gmean(X, K)")
    @test_throws ArgumentError parse("gmean()")
end

@testset "groupby — correctness" begin
    dir = joinpath(mktempdir(), "gb.tab")
    K = Int32[1, 1, 1, 2, 2, 3, 3, 3, 3, 1]
    X = Float64[10, 20, 30, 5, 15, 100, 200, 300, 400, 40]
    Bc = Bool[true, false, true, true, true, false, false, true, false, true]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X, "B" => Bc]; nrow=10)
    t = readtable(dir)

    grp = Dict{Int32,Vector{Int}}()
    for (i, k) in enumerate(K)
        push!(get!(grp, k, Int[]), i)
    end
    uk = sort(collect(keys(grp)))

    r = groupby(t, "K"; select=["K" => "K", "N" => "gcount()", "S" => "gsum(X)",
        "MX" => "gmax(X)", "MN" => "gmin(X)", "AV" => "gmean(X)",
        "MED" => "gmedian(X)", "SD" => "gstddev(X)"], orderby=["K"])
    @test r isa GroupedTable
    @test collect(r.K) == uk
    @test collect(r.N) == [length(grp[k]) for k in uk]
    @test collect(r.S) == [sum(X[grp[k]]) for k in uk]
    @test collect(r.MX) == [maximum(X[grp[k]]) for k in uk]
    @test collect(r.MN) == [minimum(X[grp[k]]) for k in uk]
    @test collect(r.AV) ≈ [sum(X[grp[k]]) / length(grp[k]) for k in uk]
    @test collect(r.MED) ≈ [Statistics.median(X[grp[k]]) for k in uk]
    @test collect(r.SD) ≈ [Statistics.std(X[grp[k]]; corrected=false) for k in uk]

    # gcount(col) == gcount() (no null concept)
    @test collect(groupby(t, "K"; select=["N" => "gcount(X)"], orderby=["N"]).N) ==
          sort([length(grp[k]) for k in uk])

    # multi-key
    L = Int32[i <= 5 ? 0 : 1 for i in 1:10]
    dir2 = joinpath(mktempdir(), "gb2.tab")
    write_table(dir2, "T", Pair{String,Any}["K" => K, "L" => L, "X" => X]; nrow=10)
    t2 = readtable(dir2)
    r2 = groupby(t2, ["K", "L"]; select=["K" => "K", "L" => "L", "N" => "gcount()"],
                 orderby=["K", "L"])
    mk = Dict{Tuple{Int32,Int32},Int}()
    for i in 1:10
        mk[(K[i], L[i])] = get(mk, (K[i], L[i]), 0) + 1
    end
    @test Dict((k, l) => n for (k, l, n) in zip(collect(r2.K), collect(r2.L), collect(r2.N))) == mk

    # whole-table aggregate (empty group columns)
    rw = groupby(t, String[]; select=["N" => "gcount()", "TOT" => "gsum(X)"])
    @test collect(rw.N) == [10] && collect(rw.TOT) == [sum(X)]

    # where pre-filter, having, orderby-desc-on-aggregate
    rf = groupby(t, "K"; where="X > 15", select=["K" => "K", "N" => "gcount()"], orderby=["K"])
    fg = Dict{Int32,Int}()
    for i in 1:10
        X[i] > 15 && (fg[K[i]] = get(fg, K[i], 0) + 1)
    end
    @test Dict(k => n for (k, n) in zip(collect(rf.K), collect(rf.N))) == fg

    rh = groupby(t, "K"; select=["K" => "K", "N" => "gcount()"],
                 having="gcount() >= 3", orderby=["K"])
    @test collect(rh.K) == Int32[1, 3]

    rd = groupby(t, "K"; select=["K" => "K", "S" => "gsum(X)"], orderby=["S" => :desc])
    @test issorted(collect(rd.S); rev=true)

    # bool aggregates, gfirst/glast, arithmetic in a select expr
    rb = groupby(t, "K"; select=["K" => "K", "ANY" => "gany(B)", "ALL" => "gall(B)",
        "NT" => "gntrue(B)", "F" => "gfirst(X)", "L" => "glast(X)",
        "R" => "gsum(X) / gcount()"], orderby=["K"])
    @test collect(rb.NT) == [count(Bc[grp[k]]) for k in uk]
    @test collect(rb.ALL) == [all(Bc[grp[k]]) for k in uk]
    @test collect(rb.F) == [X[grp[k][1]] for k in uk]
    @test collect(rb.L) == [X[grp[k][end]] for k in uk]
    @test collect(rb.R) ≈ [sum(X[grp[k]]) / length(grp[k]) for k in uk]
end

@testset "groupby — aggregate over an array cell" begin
    dir = joinpath(mktempdir(), "gbv.tab")
    K = Int32[1, 1, 2, 2, 2, 3]
    V = [Float64[i, 2i, 3i] for i in 1:6]
    write_table(dir, "TV", Pair{String,Any}["K" => K, "V" => V]; nrow=6, tsm=[["V"]])
    t = readtable(dir)
    grp = Dict(1 => [1, 2], 2 => [3, 4, 5], 3 => [6])
    r = groupby(t, "K"; select=["K" => "K", "MA" => "gmean(mean(abs(V)))",
        "MS" => "gmax(sum(V))"], orderby=["K"])
    @test collect(r.MA) ≈ [Statistics.mean([Statistics.mean(abs.(V[i])) for i in grp[k]]) for k in 1:3]
    @test collect(r.MS) == [maximum(sum(V[i]) for i in grp[k]) for k in 1:3]
end

@testset "groupby — per-element (gs*) aggregates" begin
    dir = joinpath(mktempdir(), "gse.tab")
    K = Int32[1, 1, 1, 2, 2]
    V = [Float64[i i+1; i+2 i+3] for i in 1:5]
    B = [Bool[isodd(i) iseven(i); true false] for i in 1:5]
    write_table(dir, "T", Pair{String,Any}["K" => K, "V" => V, "B" => B]; nrow=5,
                tsm=[["V"], ["B"]])
    t = readtable(dir)
    grp = Dict(1 => [1, 2, 3], 2 => [4, 5])

    g = groupby(t, "K"; orderby=["K"],
        select = ["K" => :K,
                  "SU" => "gsums(V)", "MN" => "gmeans(V)", "MI" => "gmins(V)",
                  "MX" => "gmaxs(V)", "PR" => "gproducts(V)",
                  "SD" => "gstddevs(V)", "RM" => "grmss(V)",
                  "AN" => "ganys(B)", "AL" => "galls(B)", "NT" => "gntrues(B)",
                  "NF" => "gnfalses(B)"])
    for k in (1, 2)
        vv = V[grp[k]]; bb = B[grp[k]]; i = k
        @test g.SU[i] == sum(vv)
        @test g.MN[i] ≈ Statistics.mean(vv)
        @test g.MI[i] == reduce((a, b) -> min.(a, b), vv)
        @test g.MX[i] == reduce((a, b) -> max.(a, b), vv)
        @test g.PR[i] == reduce((a, b) -> a .* b, vv)
        @test g.SD[i] ≈ sqrt.(Statistics.var(vv; corrected=false))
        @test g.RM[i] ≈ sqrt.(sum(x -> x .^ 2, vv) ./ length(vv))
        @test g.AN[i] == reduce((a, b) -> a .| b, bb)
        @test g.AL[i] == reduce((a, b) -> a .& b, bb)
        @test g.NT[i] == sum(bb)
        @test g.NF[i] == length(bb) .- sum(bb)
    end

    # gavgs alias, gsamplevariances/gsamplestddevs
    g2 = groupby(t, "K"; select=["K" => :K, "A" => "gavgs(V)", "SV" => "gsamplevariances(V)"])
    @test isequal(collect(g2.A), collect(groupby(t, "K"; select=["K" => :K, "A" => "gmeans(V)"]).A))
end

@testset "groupby — GroupedTable is a Tables.jl source" begin
    dir = joinpath(mktempdir(), "gt.tab")
    K = Int32[1, 1, 2, 2, 2, 3, 3]
    X = Float64[1, 2, 3, 4, 5, 6, 7]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=7)
    t = readtable(dir)
    r = groupby(t, "K"; select=["K" => "K", "N" => "gcount()", "S" => "gsum(X)"], orderby=["K"])

    @test Tables.istable(typeof(r))
    @test Tables.columnnames(r) == [:K, :N, :S]
    @test Tables.getcolumn(r, :S) == collect(r.S)
    @test Tables.getcolumn(r, 1) == collect(r.K)
    @test propertynames(r) == (:K, :N, :S)
    sch = Tables.schema(r)
    @test sch.names == (:K, :N, :S)

    ct = Tables.columntable(r)
    @test ct.K == Int32[1, 2, 3]
    @test ct.N == [2, 3, 2]

    # persist via the existing write_table (no new machinery)
    dst = joinpath(mktempdir(), "GT")
    write_table(dst, "GT", r; nrow=length(r.K))
    rt = readtable(dst)
    @test column(rt, "K")[:] == Int32[1, 2, 3]
    @test column(rt, "N")[:] == [2, 3, 2]
    @test column(rt, "S")[:] == Float64[3, 12, 13]
end

@testset "groupby — error cases" begin
    dir = joinpath(mktempdir(), "gbe.tab")
    write_table(dir, "T", Pair{String,Any}["K" => Int32[1, 2, 2], "X" => Float64[1, 2, 3]]; nrow=3)
    t = readtable(dir)
    @test_throws ArgumentError groupby(t, "NOPE"; select=["N" => "gcount()"])
    @test_throws ArgumentError groupby(t, "K"; select=Pair[])
    @test_throws ArgumentError groupby(t, "K"; select=["A" => "K", "A" => "gcount()"])
    @test_throws ArgumentError groupby(t, "K"; select=["N" => "gcount()"], where="gsum(X) > 0")
    @test_throws ArgumentError groupby(t, "K"; select=["N" => "gcount()"], orderby=["NOSUCH"])
end

# ---- Phase 27: closure-form groupby ----

@testset "GroupSlice — unit" begin
    gs = MSv2.GroupSlice(Dict{String,AbstractVector}("A" => [10, 20, 30, 40],
                                                     "B" => ["p", "q", "r", "s"]), [2, 4])
    @test gs.A == [20, 40]
    @test gs.B == ["q", "s"]
    @test length(gs) == 2
    @test Set(propertynames(gs)) == Set([:A, :B, :keys, :level, :grouping])
    @test gs.level == 0 && gs.keys == NamedTuple()
    gs2 = MSv2.GroupSlice(getfield(gs, :cols), [1, 2], ["A"], [1])
    @test gs2.keys == (A = 10,) && gs2.level == 1 && gs2.grouping == (A = false,)
    gs3 = MSv2.GroupSlice(getfield(gs, :cols), [1, 2], ["A", "B"], Int[])
    @test isequal(gs3.keys, (A = missing, B = missing)) && gs3.grouping == (A = true, B = true)
    @test_throws ArgumentError gs.NOPE
end

# ---- Phase 48: GROUP BY ROLLUP ------------------------------------

@testset "groupby — rollup (string + closure forms)" begin
    dir = joinpath(mktempdir(), "ru.tab")
    K1 = Int32[1, 1, 1, 1, 2, 2, 2]
    K2 = Int32[10, 10, 20, 20, 10, 30, 30]
    X  = Float64[1, 2, 3, 4, 5, 6, 7]
    write_table(dir, "T", Pair{String,Any}["K1" => K1, "K2" => K2, "X" => X]; nrow=7)
    t = readtable(dir)

    # hand-computed expectation: detailed groups, then subtotal-by-K1,
    # then grand total; rolled-up keys are `missing`
    want = [(1, 10, 2, 3.0), (1, 20, 2, 7.0), (2, 10, 1, 5.0), (2, 30, 2, 13.0),
            (1, missing, 4, 10.0), (2, missing, 3, 18.0),
            (missing, missing, 7, 28.0)]

    g = groupby(t, ["K1", "K2"];
        select = ["K1" => :K1, "K2" => :K2, "N" => "gcount()", "S" => "gsum(X)"],
        rollup = true)
    @test nrow(g) == 7
    got = [(g.K1[i], g.K2[i], g.N[i], g.S[i]) for i in 1:7]
    @test all(isequal.(got, want))
    @test eltype(g.K2) == Union{Missing,Int32}

    # closure form: same result via g.keys
    gc = groupby(t, [:K1, :K2]; rollup = true) do gs
        (; gs.keys..., N = length(gs), S = sum(gs.X))
    end
    @test all(isequal.([(gc.K1[i], gc.K2[i], gc.N[i], gc.S[i]) for i in 1:7], want))

    # rollup=false is unchanged (3 detailed groups only)
    g0 = groupby(t, ["K1", "K2"]; select = ["K1" => :K1, "N" => "gcount()"])
    @test nrow(g0) == 4

    # single-key rollup: detailed + grand total
    g1 = groupby(t, ["K1"]; select = ["K1" => :K1, "N" => "gcount()"], rollup = true)
    @test all(isequal.([(g1.K1[i], g1.N[i]) for i in 1:nrow(g1)],
                       [(1, 4), (2, 3), (missing, 7)]))

    # HAVING still filters (applied per level)
    gh = groupby(t, ["K1", "K2"];
        select = ["K1" => :K1, "K2" => :K2, "N" => "gcount()"],
        having = "gcount() >= 2", rollup = true)
    @test all(gh.N .>= 2)
end

# ---- Phase 50: CUBE / GROUPING SETS ------------------------------

@testset "groupby — CUBE / GROUPING SETS" begin
    dir = joinpath(mktempdir(), "cb.tab")
    K1 = Int32[1, 1, 1, 2, 2, 2]
    K2 = Int32[10, 10, 20, 10, 20, 20]
    X  = Float64[1, 2, 3, 4, 5, 6]
    write_table(dir, "T", Pair{String,Any}["K1" => K1, "K2" => K2, "X" => X]; nrow=6)
    t = readtable(dir)
    sel = ["K1" => :K1, "K2" => :K2, "N" => "gcount()", "S" => "gsum(X)"]

    _rows(g) = sort([(g.K1[i], g.K2[i], g.N[i], g.S[i]) for i in 1:nrow(g)]; by = string)

    # CUBE(K1,K2) -> (K1,K2)×4, (K1)×2, (K2)×2, ()×1 = 9 rows
    gcu = groupby(t, ["K1", "K2"]; select = sel, cube = true)
    @test nrow(gcu) == 9
    want_cube = [(1, 10, 2, 3.0), (1, 20, 1, 3.0), (2, 10, 1, 4.0), (2, 20, 2, 11.0),
                 (1, missing, 3, 6.0), (2, missing, 3, 15.0),
                 (missing, 10, 3, 7.0), (missing, 20, 3, 14.0),
                 (missing, missing, 6, 21.0)]
    @test isequal(_rows(gcu), sort(want_cube; by = string))

    # GROUPING SETS: exactly the listed sets
    ggs = groupby(t, ["K1", "K2"]; select = sel,
                  grouping_sets = [("K1",), ("K2",), ()])
    @test nrow(ggs) == 5
    @test isequal(_rows(ggs), sort([(1, missing, 3, 6.0), (2, missing, 3, 15.0),
                                    (missing, 10, 3, 7.0), (missing, 20, 3, 14.0),
                                    (missing, missing, 6, 21.0)]; by = string))

    # a single-name grouping set entry is a 1-key set
    @test isequal(_rows(groupby(t, ["K1", "K2"]; select = sel, grouping_sets = ["K1", ()])),
                  _rows(groupby(t, ["K1", "K2"]; select = sel, grouping_sets = [("K1",), ()])))

    # closure form + g.grouping
    gc = groupby(t, [:K1, :K2]; cube = true) do g
        (; g.keys..., N = length(g), gK2 = g.grouping.K2)
    end
    @test count(gc.gK2) == 3          # the 3 rows where K2 is rolled up ((K1) sets + grand total)

    # rollup is a subset of cube (both give the () and (K1) levels)
    gru = groupby(t, ["K1", "K2"]; select = sel, rollup = true)
    @test issubset(Set(_rows(gru)), Set(_rows(gcu)))

    # errors
    @test_throws ArgumentError groupby(t, ["K1"]; select = sel, cube = true, rollup = true)
    @test_throws ArgumentError groupby(t, ["K1", "K2"]; select = sel,
                                      grouping_sets = [("K1", "NOPE")])
end

# ---- Phase 51: GROUPING() in the string grammar ------------------

@testset "groupby — GROUPING() function" begin
    dir = joinpath(mktempdir(), "gr.tab")
    K1 = Int32[1, 1, 2, 2]
    K2 = Int32[10, 20, 10, 20]
    X  = Float64[1, 2, 3, 4]
    write_table(dir, "T", Pair{String,Any}["K1" => K1, "K2" => K2, "X" => X]; nrow=4)
    t = readtable(dir)

    parse(s) = MSv2._taqllite_parse(s, Set(["K1", "K2", "X"]))
    @test parse("GROUPING(K1)") isa MSv2.TQLGrouping
    @test parse("GROUPING(K1)").name == "K1"
    @test_throws ArgumentError parse("GROUPING(K1, K2)")   # arity
    @test_throws ArgumentError parse("GROUPING(X + 1)")    # needs a bare column

    # in SELECT: 0/1 flag + the classic "label the subtotal" idiom
    g = groupby(t, ["K1", "K2"];
        select = ["K1" => :K1, "K2" => :K2,
                  "gK2" => "GROUPING(K2)",
                  "lbl" => "iif(GROUPING(K2), 999, K2)",
                  "S" => "gsum(X)"],
        rollup = true)
    @test collect(g.gK2) == [false, false, false, false, true, true, true]
    @test collect(g.lbl) == [10, 20, 10, 20, 999, 999, 999]

    # in HAVING: drop rows where K1 is rolled up (CUBE's (K2) sets + grand total)
    gh = groupby(t, ["K1", "K2"]; select = ["K1" => :K1, "K2" => :K2, "N" => "gcount()"],
        cube = true, having = "GROUPING(K1) == 0")
    @test all(!ismissing, gh.K1)
    @test nrow(gh) == 6                                    # 4 detailed + 2 (K1) subtotals

    # rejected outside a group context
    @test_throws ArgumentError groupby(t, "K1"; select = ["N" => "gcount()"],
        where = "GROUPING(K1) == 1")
    @test_throws ArgumentError query(t, "GROUPING(K1) == 0")
end

@testset "groupby — do-block form" begin
    dir = joinpath(mktempdir(), "cb.tab")
    K = Int32[1, 1, 1, 2, 2, 3, 3, 3, 3, 1]
    X = Float64[10, 20, 30, 5, 15, 100, 200, 300, 400, 40]
    W = Float64[1, 1, 2, 1, 3, 1, 1, 1, 1, 2]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X, "W" => W]; nrow=10)
    t = readtable(dir)
    grp = Dict{Int32,Vector{Int}}()
    for (i, k) in enumerate(K)
        push!(get!(grp, k, Int[]), i)
    end
    uk = sort(collect(keys(grp)))

    r = groupby(t, "K"; cols=["K", "X", "W"], orderby=["K"]) do g
        (; K=first(g.K), N=length(g), WMEAN=sum(g.X .* g.W) / sum(g.W),
         P=Statistics.quantile(g.X, 0.75))
    end
    @test r isa GroupedTable
    @test collect(r.K) == uk
    @test collect(r.N) == [length(grp[k]) for k in uk]
    @test collect(r.WMEAN) ≈ [sum(X[grp[k]] .* W[grp[k]]) / sum(W[grp[k]]) for k in uk]
    @test collect(r.P) ≈ [Statistics.quantile(X[grp[k]], 0.75) for k in uk]

    # default cols = load all
    r2 = groupby(t, "K"; orderby=["K"]) do g
        (; K=first(g.K), MED=Statistics.median(g.X))
    end
    @test collect(r2.MED) ≈ [Statistics.median(X[grp[k]]) for k in uk]

    # do-block with closure where + having, orderby on an output column
    r3 = groupby(t, "K"; cols=["K", "X"], where=row -> row.X >= 10,
                 having=g -> length(g) >= 2, orderby=["S" => :desc]) do g
        (; K=first(g.K), S=sum(g.X))
    end
    keep = Dict(k => sum(x for x in X[grp[k]] if x >= 10) for k in uk
                if count(>=(10), X[grp[k]]) >= 2)
    @test Set(collect(r3.K)) == Set(keys(keep))
    @test issorted(collect(r3.S); rev=true)

    # write_table round-trip
    dst = joinpath(mktempdir(), "GT")
    write_table(dst, "GT", r; nrow=length(r.K))
    @test column(readtable(dst), "WMEAN")[:] ≈ collect(r.WMEAN)
end

@testset "groupby — closure select= entries mixed with strings" begin
    dir = joinpath(mktempdir(), "cbs.tab")
    K = Int32[1, 1, 2, 2, 2, 3]
    X = Float64[10, 20, 3, 4, 5, 99]
    W = Float64[2, 1, 1, 1, 2, 1]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X, "W" => W]; nrow=6)
    t = readtable(dir)
    grp = Dict(1 => [1, 2], 2 => [3, 4, 5], 3 => [6])

    r = groupby(t, "K"; cols=["K", "X", "W"], orderby=["K"], select=[
        :K => :K,
        "N" => "gcount()",
        "WSUM" => g -> sum(g.X .* g.W),
        "MX" => "gmax(X)",
        "R" => g -> maximum(g.X) - minimum(g.X)])
    @test collect(r.K) == Int32[1, 2, 3]
    @test collect(r.N) == [2, 3, 1]
    @test collect(r.WSUM) ≈ [sum(X[grp[k]] .* W[grp[k]]) for k in 1:3]
    @test collect(r.MX) == [maximum(X[grp[k]]) for k in 1:3]
    @test collect(r.R) == [maximum(X[grp[k]]) - minimum(X[grp[k]]) for k in 1:3]
end

@testset "groupby — where/having string vs closure agree" begin
    dir = joinpath(mktempdir(), "cbw.tab")
    K = Int32[1, 1, 1, 2, 2, 3, 3, 3, 3, 1]
    X = Float64[10, 20, 30, 5, 15, 100, 200, 300, 400, 40]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=10)
    t = readtable(dir)

    a = groupby(t, "K"; where="X > 15", select=["K" => :K, "N" => "gcount()"], orderby=["K"])
    b = groupby(t, "K"; where=row -> row.X > 15, select=["K" => :K, "N" => "gcount()"], orderby=["K"])
    @test collect(a.K) == collect(b.K) && collect(a.N) == collect(b.N)

    c = groupby(t, "K"; having="gcount() >= 3", select=["K" => :K, "N" => "gcount()"], orderby=["K"])
    d = groupby(t, "K"; having=g -> length(g) >= 3, select=["K" => :K, "N" => "gcount()"], orderby=["K"])
    @test collect(c.K) == collect(d.K)
end

@testset "groupby — cols= restricts what a closure loads" begin
    dir = joinpath(mktempdir(), "cbc.tab")
    K = Int32[1, 1, 2, 2, 3]
    X = Float64[1, 2, 3, 4, 5]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=5)
    t = readtable(dir)
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(t.desc.name, t.desc.version, t.desc.comment, t.desc.public,
                    t.desc.private, [t.desc.columns; bogus])
    t2 = Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows, t.endian,
              td2, t.managers, t.syncmod, t.lockpath, t.container, t.precision)
    # BOGUS would error if read; cols= keeps it out
    r = groupby(t2, "K"; cols=["K", "X"], orderby=["K"]) do g
        (; K=first(g.K), S=sum(g.X))
    end
    @test collect(r.S) == Float64[3, 7, 5]
    # a closure that needs a column not in cols= errors clearly
    @test_throws ArgumentError groupby(t2, "K"; cols=["K"]) do g
        (; K=first(g.K), S=sum(g.X))
    end
end

@testset "groupby — do-block error cases" begin
    dir = joinpath(mktempdir(), "cbe.tab")
    write_table(dir, "T", Pair{String,Any}["K" => Int32[1, 1, 2], "X" => Float64[1, 2, 3]]; nrow=3)
    t = readtable(dir)
    @test_throws ArgumentError groupby(t, "K") do g
        length(g)                       # not a NamedTuple
    end
    @test_throws ArgumentError groupby(t, "K"; orderby=["K"]) do g
        isodd(first(g.K)) ? (; K=first(g.K), N=length(g)) : (; K=first(g.K), M=length(g))
    end
end

# ---- Phase 28: joins ----

@testset "join — _join_matchrow unit" begin
    dir = joinpath(mktempdir(), "jm")
    A1 = Int32[0, 2, 1, 9, 0]           # 9 is out of range for a 3-row right
    S = ["a", "b", "a", "c", "b"]
    write_table(joinpath(dir, "L"), "L", Pair{String,Any}["A1" => A1, "S" => S]; nrow=5)
    write_table(joinpath(dir, "R"), "R", Pair{String,Any}["K" => ["a", "b", "z"],
                                                          "V" => Float64[1, 2, 3]]; nrow=3)
    L = readtable(joinpath(dir, "L"))
    R = readtable(joinpath(dir, "R"))

    @test MSv2._join_matchrow(L, R, "A1") == [1, 3, 2, 0, 1]          # 0-based -> 1-based, 9 -> 0
    @test MSv2._join_matchrow(L, R, "S" => "K") == [1, 2, 1, 0, 2]    # "c", "z" don't match
    # composite
    write_table(joinpath(dir, "L2"), "L2", Pair{String,Any}["P" => Int32[1, 1, 2],
                                                            "Q" => Int32[10, 20, 10]]; nrow=3)
    write_table(joinpath(dir, "R2"), "R2", Pair{String,Any}["P" => Int32[1, 2, 1],
                                                            "Q" => Int32[10, 10, 20]]; nrow=3)
    L2 = readtable(joinpath(dir, "L2"))
    R2 = readtable(joinpath(dir, "R2"))
    @test MSv2._join_matchrow(L2, R2, ["P" => "P", "Q" => "Q"]) == [1, 3, 2]

    # duplicate right key errors
    write_table(joinpath(dir, "RD"), "RD", Pair{String,Any}["K" => ["a", "b", "a"]]; nrow=3)
    RD = readtable(joinpath(dir, "RD"))
    @test_throws ArgumentError MSv2._join_matchrow(L, RD, "S" => "K")
end

@testset "join — index-lookup" begin
    dir = joinpath(mktempdir(), "ji")
    A1 = Int32[0, 1, 2, 0, 1, 3, 2, 0]
    TIME = collect(Float64, 1:8)
    write_table(joinpath(dir, "MAIN"), "MAIN",
                Pair{String,Any}["ANTENNA1" => A1, "TIME" => TIME]; nrow=8)
    AN = ["DA41", "DA42", "PM01", "PM02"]
    POS = Float64[10, 20, 30, 40]
    write_table(joinpath(dir, "ANT"), "ANT",
                Pair{String,Any}["NAME" => AN, "POS" => POS]; nrow=4)
    main = readtable(joinpath(dir, "MAIN"))
    ant = readtable(joinpath(dir, "ANT"))

    r = join(main, ant; on="ANTENNA1", rightcols=["NAME" => "AN", "POS" => "APOS"])
    @test r isa GroupedTable
    @test Set(r.names) == Set([:ANTENNA1, :TIME, :AN, :APOS])
    @test collect(r.AN) == [AN[a+1] for a in A1]
    @test collect(r.APOS) == [POS[a+1] for a in A1]
    @test collect(r.TIME) == TIME
    # lazy result columns
    @test r.cols[findfirst(==(:AN), r.names)] isa MSv2.MappedColumn
    @test r.cols[findfirst(==(:TIME), r.names)] isa MSv2.MappedColumn

    # write_table round-trip
    dst = joinpath(mktempdir(), "JT")
    write_table(dst, "JT", r; nrow=8)
    jt = readtable(dst)
    @test column(jt, "AN")[:] == collect(r.AN)
    @test column(jt, "APOS")[:] == collect(r.APOS)

    # leftcols subset + rename; source => output convention
    r2 = join(main, ant; on="ANTENNA1", leftcols=["TIME" => "T"], rightcols=["NAME" => "AN"])
    @test Set(r2.names) == Set([:T, :AN])
    @test collect(r2.T) == TIME

    # output-name clash errors
    @test_throws ArgumentError join(main, ant; on="ANTENNA1", rightcols=["NAME" => "TIME"])
end

@testset "join — equi-join" begin
    dir = joinpath(mktempdir(), "je")
    SRC = ["3C48", "3C286", "3C48", "cal", "3C286"]
    X = Float64[1, 2, 3, 4, 5]
    write_table(joinpath(dir, "MAIN"), "MAIN",
                Pair{String,Any}["SRC" => SRC, "X" => X]; nrow=5)
    FN = ["3C48", "3C286", "cal"]
    RA = Float64[1.1, 2.2, 3.3]
    write_table(joinpath(dir, "FLD"), "FLD",
                Pair{String,Any}["NAME" => FN, "RA" => RA]; nrow=3)
    main = readtable(joinpath(dir, "MAIN"))
    fld = readtable(joinpath(dir, "FLD"))

    r = join(main, fld; on="SRC" => "NAME", rightcols=["RA"])
    @test collect(r.RA) == [RA[findfirst(==(s), FN)] for s in SRC]
    @test Set(r.names) == Set([:SRC, :X, :RA])

    # composite key
    dc = joinpath(mktempdir(), "jc")
    write_table(joinpath(dc, "L"), "L", Pair{String,Any}["S" => Int32[1, 1, 2, 2],
        "P" => Int32[10, 20, 10, 20], "Z" => Float64[1, 2, 3, 4]]; nrow=4)
    write_table(joinpath(dc, "R"), "R", Pair{String,Any}["S" => Int32[1, 1, 2, 2],
        "P" => Int32[10, 20, 10, 20], "V" => ["w", "x", "y", "z"]]; nrow=4)
    L = readtable(joinpath(dc, "L"))
    R = readtable(joinpath(dc, "R"))
    rc = join(L, R; on=["S" => "S", "P" => "P"], rightcols=["V"])
    @test collect(rc.V) == ["w", "x", "y", "z"]
end

@testset "join — unmatched policy" begin
    dir = joinpath(mktempdir(), "ju")
    A1 = Int32[0, 1, 9, 0]             # 9 dangles
    write_table(joinpath(dir, "M"), "M",
                Pair{String,Any}["ANTENNA1" => A1, "X" => Float64[1, 2, 3, 4]]; nrow=4)
    write_table(joinpath(dir, "A"), "A",
                Pair{String,Any}["NAME" => ["DA41", "DA42", "PM01", "PM02"]]; nrow=4)
    m = readtable(joinpath(dir, "M"))
    a = readtable(joinpath(dir, "A"))

    @test_throws ArgumentError join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"])

    rd = join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"], unmatched=:drop)
    @test length(rd.cols[1]) == 3
    @test collect(rd.AN) == ["DA41", "DA42", "DA41"]
    @test collect(rd.X) == Float64[1, 2, 4]

    rmi = join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"], unmatched=:missing)
    @test length(rmi.cols[1]) == 4
    @test ismissing(collect(rmi.AN)[3])
    @test Missing <: eltype(rmi.cols[findfirst(==(:AN), rmi.names)])

    @test_throws ArgumentError join(m, a; on="ANTENNA1", rightcols=["NAME"], unmatched=:bogus)
end

@testset "join — post-join where and orderby" begin
    dir = joinpath(mktempdir(), "jw")
    A1 = Int32[0, 1, 2, 0, 1, 2, 0]
    TIME = collect(Float64, 1:7)
    write_table(joinpath(dir, "M"), "M",
                Pair{String,Any}["ANTENNA1" => A1, "TIME" => TIME]; nrow=7)
    AN = ["DA41", "DA42", "PM01"]
    write_table(joinpath(dir, "A"), "A", Pair{String,Any}["NAME" => AN]; nrow=3)
    m = readtable(joinpath(dir, "M"))
    a = readtable(joinpath(dir, "A"))

    w1 = join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"], where="AN == 'DA41'")
    w2 = join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"], where=row -> row.AN == "DA41")
    want = TIME[findall(x -> AN[x+1] == "DA41", A1)]
    @test collect(w1.TIME) == collect(w2.TIME) == want

    o = join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"], orderby=["AN", "TIME" => :desc])
    @test issorted(collect(o.AN))
end

# ---- Phase 49: M:N joins (multi=true) ----

@testset "join — M:N (multi=true)" begin
    d = mktempdir()
    write_table(joinpath(d, "L"), "L",
                Pair{String,Any}["OBS" => Int32[1, 2, 3, 4], "SRC" => ["a", "b", "a", "c"]]; nrow=4)
    write_table(joinpath(d, "R"), "R",
                Pair{String,Any}["NAME" => ["a", "a", "b", "d"], "F" => Float64[10, 11, 20, 40]]; nrow=4)
    L = readtable(joinpath(d, "L")); R = readtable(joinpath(d, "R"))
    on = "SRC" => "NAME"

    # inner: a matches {10,11}, b matches {20}, c dropped
    ji = join(L, R; on, rightcols=["F"], multi=true, unmatched=:drop)
    @test collect(ji.OBS) == [1, 1, 2, 3, 3]
    @test collect(ji.F) == [10.0, 11.0, 20.0, 10.0, 11.0]

    # left outer: + OBS 4 with F missing
    jl = join(L, R; on, rightcols=["F"], multi=true, unmatched=:missing)
    @test collect(jl.OBS) == [1, 1, 2, 3, 3, 4]
    @test isequal(collect(jl.F), [10.0, 11.0, 20.0, 10.0, 11.0, missing])
    @test eltype(jl.F) == Union{Missing,Float64}

    # right outer: matched pairs + the unmatched right row "d" (OBS missing)
    jr = join(L, R; on, leftcols=["OBS"], rightcols=["NAME", "F"], multi=true, unmatched=:right)
    @test isequal(collect(jr.OBS), [1, 1, 2, 3, 3, missing])
    @test collect(jr.NAME) == ["a", "a", "b", "a", "a", "d"]

    # full outer
    jf = join(L, R; on, leftcols=["OBS"], rightcols=["NAME"], multi=true, unmatched=:full)
    @test isequal(collect(jf.OBS), [1, 1, 2, 3, 3, 4, missing])
    @test isequal(collect(jf.NAME), ["a", "a", "b", "a", "a", missing, "d"])

    # :error throws when a left row has no match
    @test_throws ArgumentError join(L, R; on, rightcols=["F"], multi=true, unmatched=:error)

    # index-lookup `on` is rejected with multi=true
    @test_throws ArgumentError join(L, R; on="OBS", rightcols=["F"], multi=true)

    # composes with where / orderby
    jw = join(L, R; on, rightcols=["F"], multi=true, unmatched=:drop,
              where="F > 10.0", orderby=["F" => :desc])
    @test collect(jw.F) == [20.0, 11.0, 11.0]

    # multi=false still rejects a non-unique right key
    @test_throws ArgumentError join(L, R; on, rightcols=["F"])
end

@testset "join — non-equi predicate" begin
    d = mktempdir()
    write_table(joinpath(d, "L"), "L",
        Pair{String,Any}["T" => Float64[1, 5, 9, 15], "X" => Int32[10, 20, 30, 40]]; nrow=4)
    write_table(joinpath(d, "R"), "R",
        Pair{String,Any}["T0" => Float64[0, 4, 20], "T1" => Float64[6, 12, 30],
                         "LAB" => ["a", "b", "c"]]; nrow=3)
    L = readtable(joinpath(d, "L")); R = readtable(joinpath(d, "R"))
    pred = (a, b) -> b.T0 <= a.T <= b.T1

    # T=1->a, T=5->a & b (M:N), T=9->b, T=15->none
    jd = join(L, R; on=pred, rightcols=["LAB"], unmatched=:drop)
    @test collect(jd.T) == [1.0, 5.0, 5.0, 9.0]
    @test collect(jd.LAB) == ["a", "a", "b", "b"]

    jm = join(L, R; on=pred, rightcols=["LAB"], unmatched=:missing)
    @test collect(jm.T) == [1.0, 5.0, 5.0, 9.0, 15.0]
    @test isequal(collect(jm.LAB), ["a", "a", "b", "b", missing])

    jf = join(L, R; on=pred, leftcols=["T"], rightcols=["LAB"], unmatched=:full)
    @test isequal(collect(jf.T), [1.0, 5.0, 5.0, 9.0, 15.0, missing])
    @test isequal(collect(jf.LAB), ["a", "a", "b", "b", missing, "c"])

    jrt = join(L, R; on=pred, leftcols=["T"], rightcols=["LAB"], unmatched=:right)
    @test isequal(collect(jrt.LAB), ["a", "a", "b", "b", "c"])
    @test isequal(collect(jrt.T), [1.0, 5.0, 5.0, 9.0, missing])

    # :error throws on the dangling left row T=15
    @test_throws ArgumentError join(L, R; on=pred, rightcols=["LAB"])

    # oncols restricts what's loaded -- BOGUS would error if read
    bogus = ColumnDesc("BOGUS", "", "NoSuchManager", "g", MSv2.TpInt,
                       "ScalarColumnDesc<Int>", (), Int32(0), UInt32(0), Record(), nothing, 999)
    td2 = TableDesc(L.desc.name, L.desc.version, L.desc.comment, L.desc.public,
                    L.desc.private, [L.desc.columns; bogus])
    Lb = Table(L.path, L.type, L.subtype, L.readme, L.version, L.rows, L.endian,
               td2, L.managers, L.syncmod, L.lockpath, L.container, L.precision)
    j2 = join(Lb, R; on=(a, b) -> b.T0 <= a.T <= b.T1, leftcols=["T"], rightcols=["LAB"],
              unmatched=:missing, oncols=(["T"], ["T0", "T1", "LAB"]))
    @test collect(j2.T) == [1.0, 5.0, 5.0, 9.0, 15.0]

    # composes with where / orderby
    jw = join(L, R; on=pred, rightcols=["LAB"], unmatched=:drop,
              where="LAB == 'b'", orderby=["T" => :desc])
    @test collect(jw.T) == [9.0, 5.0]

    # duplicate output name still errors
    @test_throws ArgumentError join(L, R; on=pred, leftcols=["T" => "LAB"], rightcols=["LAB"],
                                   unmatched=:drop)
end

# ---- Phase 29: chainable query results ----

@testset "GroupedTable is an AbstractTable" begin
    dir = joinpath(mktempdir(), "ch.tab")
    K = Int32[0, 1, 0, 1, 2, 0]
    X = Float64[1, 2, 3, 4, 5, 6]
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=6)
    t = readtable(dir)
    gt = groupby(t, "K"; select=["K" => :K, "N" => "gcount()", "S" => "gsum(X)"], orderby=["K"])

    @test gt isa MSv2.AbstractTable
    @test nrow(gt) == 3
    @test columnnames(gt) == ["K", "N", "S"]
    @test column(gt, "N")[:] == [3, 2, 1]
    @test gt.S[:] == Float64[10, 6, 5]        # .OUTNAME sugar
    @test gt[:S][:] == Float64[10, 6, 5]      # generic AbstractTable getindex
    @test getcell(gt, "N", 1) == 3
    @test keywords(gt) isa Record
    @test subtables(gt) == Pair{String,String}[]
    @test columndesc(gt, "N").type == MSv2.TpInt64
    @test columndesc(gt, "S").type == MSv2.TpDouble

    # Tables.jl regression -- the generic ::AbstractTable methods must
    # fully cover what the deleted GroupedTable-specific ones did
    @test Tables.istable(typeof(gt))
    @test Tables.columnnames(gt) == [:K, :N, :S]
    @test Tables.getcolumn(gt, :S) == column(gt, "S")
    @test Tables.getcolumn(gt, 2) == column(gt, "N")
    ct = Tables.columntable(gt)
    @test ct.K == Int32[0, 1, 2] && ct.N == [3, 2, 1]
    @test Tables.schema(gt).names == (:K, :N, :S)
    dst = joinpath(mktempdir(), "GT2")
    write_table(dst, "GT2", gt; nrow=nrow(gt))
    @test column(readtable(dst), "S")[:] == Float64[10, 6, 5]

    @test MSv2.resync(gt) === gt
    @test MSv2.is_stale(gt) == false
end

@testset "chain — groupby(join(...))" begin
    dir = joinpath(mktempdir(), "cj")
    A1 = Int32[0, 1, 0, 1, 2, 0, 2, 1, 0, 2]
    TIME = collect(Float64, 1:10)
    write_table(joinpath(dir, "MAIN"), "MAIN",
                Pair{String,Any}["ANTENNA1" => A1, "TIME" => TIME]; nrow=10)
    AN = ["DA41", "DA42", "PM01"]
    write_table(joinpath(dir, "ANT"), "ANT", Pair{String,Any}["NAME" => AN]; nrow=3)
    main = readtable(joinpath(dir, "MAIN"))
    ant = readtable(joinpath(dir, "ANT"))

    j = join(main, ant; on="ANTENNA1", rightcols=["NAME" => "AN"])
    g = groupby(j, "AN"; select=["AN" => :AN, "N" => "gcount()", "MT" => "gmean(TIME)"],
                orderby=["AN"])
    grp = Dict(n => Int[] for n in AN)
    for i in 1:10
        push!(grp[AN[A1[i]+1]], i)
    end
    uk = sort(AN)
    @test collect(g.AN) == uk
    @test collect(g.N) == [length(grp[k]) for k in uk]
    @test collect(g.MT) ≈ [Statistics.mean(TIME[grp[k]]) for k in uk]
end

@testset "chain — join(groupby(...), right)" begin
    dir = joinpath(mktempdir(), "jg")
    SPW = Int32[0, 0, 1, 1, 0, 1, 0, 1, 0, 1]
    X = collect(Float64, 1:10)
    write_table(joinpath(dir, "MAIN"), "MAIN",
                Pair{String,Any}["SPW" => SPW, "X" => X]; nrow=10)
    FR = Float64[100, 200]
    write_table(joinpath(dir, "SPW"), "SPW", Pair{String,Any}["FREQ" => FR]; nrow=2)
    main = readtable(joinpath(dir, "MAIN"))
    spw = readtable(joinpath(dir, "SPW"))

    gs = groupby(main, "SPW"; select=["SPW" => :SPW, "N" => "gcount()", "SX" => "gsum(X)"],
                 orderby=["SPW"])
    js = join(gs, spw; on="SPW", rightcols=["FREQ"])
    @test collect(js.FREQ) == FR
    @test collect(js.N) == [count(==(Int32(0)), SPW), count(==(Int32(1)), SPW)]
    @test collect(js.SX) == [sum(X[SPW.==0]), sum(X[SPW.==1])]
end

@testset "chain — query on a GroupedTable" begin
    dir = joinpath(mktempdir(), "qg")
    K = Int32[0, 1, 0, 1, 2, 0, 2, 1, 0, 2, 3, 3]
    X = collect(Float64, 1:12)
    write_table(dir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=12)
    t = readtable(dir)
    g = groupby(t, "K"; select=["K" => :K, "N" => "gcount()", "S" => "gsum(X)"], orderby=["K"])

    # K counts: 0->4, 1->3, 2->3, 3->2  =>  N >= 3 keeps K in {0,1,2}
    q = query(g, "N >= 3 ORDER BY N DESC")
    @test q isa GroupedTable
    @test issorted(collect(q.N); rev=true)
    @test all(>=(3), collect(q.N))
    @test Set(collect(q.K)) == Set(Int32[0, 1, 2])
    @test collect(q.K)[1] == 0                       # the N=4 group sorts first

    # closure form agrees
    qc = query(g) do row
        row.N >= 3
    end
    @test Set(collect(qc.K)) == Set(collect(query(g, "N >= 3").K))

    # select= projection/rename
    q2 = query(g, "N >= 2"; select=["key" => "K", "cnt" => "N"])
    @test columnnames(q2) == ["key", "cnt"]
    @test collect(q2.cnt) == [c for c in collect(g.N) if c >= 2]

    # deep 3-step chain
    dir2 = joinpath(mktempdir(), "dc")
    A1 = Int32[0, 1, 0, 1, 2, 0, 2, 1, 0, 2]
    write_table(joinpath(dir2, "M"), "M",
                Pair{String,Any}["ANTENNA1" => A1, "V" => collect(Float64, 1:10)]; nrow=10)
    AN = ["a", "b", "c"]
    write_table(joinpath(dir2, "A"), "A", Pair{String,Any}["NAME" => AN]; nrow=3)
    m = readtable(joinpath(dir2, "M"))
    a = readtable(joinpath(dir2, "A"))
    deep = query(groupby(join(m, a; on="ANTENNA1", rightcols=["NAME" => "AN"]),
                         "AN"; select=["AN" => :AN, "N" => "gcount()"]),
                 "N >= 3")
    @test Set(collect(deep.AN)) == Set(["a", "b", "c"])
end

@testset "chain — GroupedTable as groupby/join input" begin
    dir = joinpath(mktempdir(), "gtchain")
    K = Int32[0, 0, 1, 1, 1, 2]
    G = Int32[0, 1, 0, 1, 0, 1]
    X = Float64[1, 2, 3, 4, 5, 6]
    write_table(dir, "T", Pair{String,Any}["K" => K, "G" => G, "X" => X]; nrow=6)
    t = readtable(dir)

    # a per-(K,G) grouped table, then re-grouped by K
    g = groupby(t, ["K", "G"]; select=["K" => :K, "G" => :G, "N" => "gcount()", "S" => "gsum(X)"])
    @test g isa GroupedTable && nrow(g) == 5

    gg = groupby(g, "K"; select=["K" => :K, "TN" => "gsum(N)", "TS" => "gsum(S)"], orderby=["K"])
    @test collect(gg.K) == Int32[0, 1, 2]
    @test collect(gg.TN) == [2, 3, 1]
    @test collect(gg.TS) == [sum(X[K.==0]), sum(X[K.==1]), sum(X[K.==2])]

    # closure groupby of a GroupedTable, with cols=
    gc = groupby(g, "K"; cols=["K", "N"]) do gs
        (; K=first(gs.K), MX=maximum(gs.N))
    end
    @test Set(collect(gc.K)) == Set(Int32[0, 1, 2])

    # groupby of a computed-select query result
    qcomp = query(t; select=["K" => "K", "X10" => "X * 10.0"]) do row
        true
    end
    @test qcomp isa GroupedTable
    gq = groupby(qcomp, "K"; select=["K" => :K, "SX" => "gsum(X10)"], orderby=["K"])
    @test collect(gq.SX) == [10 * sum(X[K.==0]), 10 * sum(X[K.==1]), 10 * sum(X[K.==2])]

    # join: GroupedTable on the left, plain Table on the right
    write_table(joinpath(dir, "R"), "R",
        Pair{String,Any}["KK" => Int32[0, 1, 2], "LAB" => ["a", "b", "c"]]; nrow=3)
    r = readtable(joinpath(dir, "R"))
    gsum = groupby(t, "K"; select=["K" => :K, "S" => "gsum(X)"], orderby=["K"])
    jl = join(gsum, r; on="K" => "KK", rightcols=["LAB"])
    @test collect(jl.LAB) == ["a", "b", "c"]
    @test collect(jl.S) == [sum(X[K.==0]), sum(X[K.==1]), sum(X[K.==2])]

    # join: plain Table on the left, GroupedTable on the right
    write_table(joinpath(dir, "L"), "L", Pair{String,Any}["KK" => Int32[2, 0, 1]]; nrow=3)
    l = readtable(joinpath(dir, "L"))
    jr = join(l, gsum; on="KK" => "K", rightcols=["S"])
    @test collect(jr.S) == [sum(X[K.==2]), sum(X[K.==0]), sum(X[K.==1])]

    # join: both sides GroupedTable, M:N
    g2 = groupby(t, "K"; select=["K" => :K, "MX" => "gmax(X)"], orderby=["K"])
    jgg = join(gsum, g2; on="K" => "K", rightcols=["MX"], multi=true, unmatched=:full)
    @test collect(jgg.K) == Int32[0, 1, 2]

    # predicate join with a GroupedTable side
    jp = join(gsum, r; on=(a, b) -> a.K == b.KK, rightcols=["LAB"], unmatched=:missing)
    @test collect(jp.LAB) == ["a", "b", "c"]

    # persist a doubly-chained result
    dst = joinpath(mktempdir(), "GTCH")
    write_table(dst, "GTCH", jl; nrow=nrow(jl))
    @test column(readtable(dst), "LAB")[:] == ["a", "b", "c"]
end

# ---- Phase 42: array indexing + slices ---------------------------------

@testset "TaQL-lite parser — array indexing unit" begin
    validnames = Set(["A", "UVW", "V"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    e = parse("UVW[3] > 0").lhs
    @test e isa MSv2.TQLIndex && length(e.axes) == 1 && e.axes[1] isa MSv2.TQLExpr

    e2 = parse("V[1,2] > 0").lhs
    @test e2 isa MSv2.TQLIndex && length(e2.axes) == 2

    e3 = parse("V[1:4,1] > 0").lhs                      # range + scalar
    @test e3.axes[1] isa NamedTuple && e3.axes[2] isa MSv2.TQLExpr
    @test e3.axes[1].lo isa MSv2.TQLLit && e3.axes[1].hi isa MSv2.TQLLit
    @test e3.axes[1].step === nothing

    e4 = parse("V[:,1] > 0").lhs                        # full axis
    @test e4.axes[1] == (; lo=nothing, hi=nothing, step=nothing)

    e5 = parse("V[2:,1] > 0").lhs                       # open end
    @test e5.axes[1].lo isa MSv2.TQLLit && e5.axes[1].hi === nothing

    e6 = parse("V[1:8:2,1] > 0").lhs                    # start:end:step (casacore order)
    @test e6.axes[1].hi isa MSv2.TQLLit && e6.axes[1].step isa MSv2.TQLLit

    e7 = parse("A[1][2] > 0").lhs                       # chained
    @test e7 isa MSv2.TQLIndex && e7.base isa MSv2.TQLIndex

    e8 = parse("V[rownumber(),1] > 0").lhs              # expression subscript
    @test e8.axes[1] isa MSv2.TQLRowNum

    e9 = parse("V[-1,1] > 0").lhs                       # negative scalar index
    @test e9.axes[1] isa MSv2.TQLLit && e9.axes[1].value == -1
    e10 = parse("V[end,1] > 0").lhs                     # `end` keyword
    @test e10.axes[1] isa MSv2.TQLEnd
    e11 = parse("V[end-2:end,1] > 0").lhs               # `end` arithmetic in a range
    @test e11.axes[1].lo isa MSv2.TQLArith && e11.axes[1].hi isa MSv2.TQLEnd
    @test parse("end") isa MSv2.TQLEnd                  # parses; errors only at eval

    @test_throws ArgumentError parse("V[] > 0")
end

@testset "TaQL-lite query — array indexing" begin
    dir = joinpath(mktempdir(), "ix.tab")
    UVW = [Float64[i, i + 1, i + 2] for i in 1:6]
    V = [reshape(Float64.(1:12) .+ 10k, 3, 4) for k in 0:5]   # (3,4) cells
    write_table(dir, "T", Pair{String,Any}["K" => collect(1:6), "UVW" => UVW,
                                           "V" => V]; nrow=6, tsm=[["V"]])
    t = readtable(dir)

    @test query(t, "UVW[3] > 6").rows == [i for i in 1:6 if i + 2 > 6]
    @test query(t, "V[1,1] > 15").rows == [i for i in 1:6 if V[i][1, 1] > 15]
    @test query(t, "V[1,1] * 2.0 > 30").rows == [i for i in 1:6 if V[i][1, 1] * 2 > 30]
    # slice -> sub-array -> reduction
    @test query(t, "mean(V[:,1]) > 20").rows ==
          [i for i in 1:6 if sum(V[i][:, 1]) / 3 > 20]
    @test query(t, "sum(V[1:2,1]) > 12").rows ==
          [i for i in 1:6 if sum(V[i][1:2, 1]) > 12]
    # closure equivalent reads the same
    @test query(t) do row; row.UVW[3] > 6 end |> x -> x.rows == query(t, "UVW[3] > 6").rows

    # only referenced columns read (K would be fine; V/UVW touched)
    @test query(t, "UVW[1] > 100").rows == Int[]

    # Phase 44: negative / `end`-relative indices
    @test query(t, "UVW[-1] > 6").rows == [i for i in 1:6 if UVW[i][end] > 6]
    @test query(t, "UVW[end] > 6").rows == [i for i in 1:6 if UVW[i][end] > 6]
    @test query(t, "V[end,1] > 25").rows == [i for i in 1:6 if V[i][end, 1] > 25]
    @test query(t, "V[end-1,1] > 15").rows == [i for i in 1:6 if V[i][end - 1, 1] > 15]
    @test query(t, "sum(V[-2:-1,1]) > 40").rows ==
          [i for i in 1:6 if sum(V[i][end - 1:end, 1]) > 40]
    @test query(t, "sum(V[end-2:end,1]) > 40").rows ==
          [i for i in 1:6 if sum(V[i][end - 2:end, 1]) > 40]
    @test_throws ArgumentError query(t, "end > 0")                  # bare `end`
    @test_throws ArgumentError query(t, "V[1:5:0,1] > 0")           # non-positive step
end

@testset "TaQL-lite — array indexing in groupby / update!" begin
    dir = joinpath(mktempdir(), "ixg.tab")
    K = Int32[0, 1, 0, 1, 0, 1]
    V = [reshape(Float64.(1:6) .+ 10k, 2, 3) for k in 0:5]
    X = zeros(6)
    write_table(dir, "T", Pair{String,Any}["K" => K, "V" => V, "X" => X]; nrow=6, tsm=[["V"]])

    g = groupby(readtable(dir), "K"; select=["K" => :K, "M" => "gmean(V[1,1])"])
    byk = Dict(collect(g.K) .=> collect(g.M))
    @test byk[0] ≈ Statistics.mean(V[i][1, 1] for i in (1, 3, 5))
    @test byk[1] ≈ Statistics.mean(V[i][1, 1] for i in (2, 4, 6))

    update!(dir; set=["X" => "V[2,3] + 1.0"])
    r = readtable(dir)
    @test column(r, "X")[:] == [V[i][2, 3] + 1 for i in 1:6]
end

# ---- Phase 43: BETWEEN ------------------------------------------------

@testset "TaQL-lite parser — BETWEEN unit" begin
    validnames = Set(["A", "B"])
    parse(s) = MSv2._taqllite_parse(s, validnames)

    e = parse("A BETWEEN 3 AND 7")
    @test e isa MSv2.TQLBetween && !e.negate
    @test e.lo isa MSv2.TQLLit && e.hi isa MSv2.TQLLit

    e2 = parse("A NOT BETWEEN 3 AND 7")
    @test e2 isa MSv2.TQLBetween && e2.negate

    e3 = parse("A + 1 BETWEEN B AND B * 2")     # arithexpr operands
    @test e3.lhs isa MSv2.TQLArith && e3.hi isa MSv2.TQLArith

    # BETWEEN binds like a comparison: `x BETWEEN a AND b OR c` -> `(...) OR c`
    e4 = parse("A BETWEEN 2 AND 4 OR A == 9")
    @test e4 isa MSv2.TQLOr && e4.a isa MSv2.TQLBetween

    @test_throws ArgumentError parse("A BETWEEN 3")
    @test_throws ArgumentError parse("A BETWEEN 3 7")
end

@testset "TaQL-lite query — BETWEEN" begin
    dir = joinpath(mktempdir(), "bt.tab")
    A = collect(1:12)
    B = collect(0.0:11.0)
    write_table(dir, "T", Pair{String,Any}["A" => A, "B" => B]; nrow=12)
    t = readtable(dir)
    @test query(t, "A BETWEEN 3 AND 7").rows == 3:7
    @test query(t, "A NOT BETWEEN 3 AND 7").rows == [1, 2, 8, 9, 10, 11, 12]
    @test query(t, "A BETWEEN B AND B + 1").rows == 1:12          # A == B+1 always
    @test query(t, "A BETWEEN 5 AND 5").rows == [5]               # inclusive both ends
    @test query(t, "(A BETWEEN 2 AND 4) OR A == 10 ORDER BY A DESC").rows == [10, 4, 3, 2]
end

# ---- Phase 46: bitwise operators ------------------------------------

@testset "TaQL-lite query — bitwise" begin
    dir = joinpath(mktempdir(), "bw.tab")
    A = Int32.(1:15)
    B = Int32.(fill(6, 15))
    F = [isodd(i) for i in 1:15]
    write_table(dir, "T", Pair{String,Any}["A" => A, "B" => B, "F" => F]; nrow=15)
    t = readtable(dir)

    @test query(t, "A & 1 == 0").rows == [i for i in 1:15 if iseven(A[i])]
    @test query(t, "A | 8 > 12").rows == [i for i in 1:15 if (A[i] | 8) > 12]
    @test query(t, "A ^ B == 0").rows == [i for i in 1:15 if xor(A[i], 6) == 0]  # A == 6
    @test query(t, "~A > -6").rows == [i for i in 1:15 if (~A[i]) > -6]          # A in 1..4
    @test query(t, "~F").rows == [i for i in 1:15 if !F[i]]
    # precedence: (A & 3) | 4, then == ; and + binds tighter than &
    @test query(t, "A & 3 | 4 == 5").rows == [i for i in 1:15 if ((A[i] & 3) | 4) == 5]
    @test query(t, "A + 1 & 6 == 6").rows == [i for i in 1:15 if ((A[i] + 1) & 6) == 6]
    # composes with AND / arithmetic
    @test query(t, "A & 1 == 1 AND A > 8").rows == [i for i in 1:15 if isodd(A[i]) && A[i] > 8]
end

# ---- Phase 47: approximate equality (~= / !~=) ---------------------

@testset "TaQL-lite — _tql_near unit" begin
    n = MSv2._tql_near
    @test n(1.0, 1.0) && n(1.0, 1.0 + 1e-7) && !n(1.0, 1.001)
    @test n(0.0, 0.0) && !n(0.0, 1e-30)                 # ~0 test: relative, 0 stays 0
    @test !n(1.0, -1.0) && n(-2.0, -2.0 + 1e-7)         # opposite sign -> not near
    @test n(3, 3) && !n(3, 4)                           # integers use the same relative form
                                                        # (not casacore's `|a|-|b|` Int near)
    @test n(1.0 + 0im, 1.0 + 1e-7im) && !n(1.0 + 0im, 1.0 + 0.1im)
    @test MSv2._tql_nnear(1.0, 2.0) && !MSv2._tql_nnear(1.0, 1.0)
end

@testset "TaQL-lite query — approximate equality" begin
    dir = joinpath(mktempdir(), "ae.tab")
    X = [1.0, 1.0 + 3e-6, 1.01, 2.0, 2.0 - 1e-6, -1.0, 0.0]
    write_table(dir, "T", Pair{String,Any}["X" => X]; nrow=7)
    t = readtable(dir)
    @test query(t, "X ~= 1.0").rows == [i for i in 1:7 if MSv2._tql_near(X[i], 1.0)]
    @test query(t, "X !~= 1.0").rows == [i for i in 1:7 if !MSv2._tql_near(X[i], 1.0)]
    @test query(t, "X ~= 2.0").rows == [i for i in 1:7 if MSv2._tql_near(X[i], 2.0)]
    @test query(t, "X ~= 0.0").rows == [7]
    # composes with arithmetic / AND
    @test query(t, "X * 2.0 ~= 2.0").rows == [i for i in 1:7 if MSv2._tql_near(X[i] * 2, 2.0)]
    @test query(t, "X ~= 1.0 OR X ~= 2.0").rows ==
          [i for i in 1:7 if MSv2._tql_near(X[i], 1.0) || MSv2._tql_near(X[i], 2.0)]
end

if _HAVE_TAQL
    @testset "TaQL-lite query — real TaQL cross-check" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        A = collect(Int32, 1:20)
        B = collect(0.0:1.0:19.0)
        C = [isodd(i) ? "x" : "y" for i in 1:20]
        NM = [i % 3 == 0 ? "cal_$i" : "src_$i" for i in 1:20]
        write_table(pdir, "T", Pair{String,Any}["A" => A, "B" => B, "C" => C,
                                                "NM" => NM]; nrow=20)
        d = mktempdir(); pdir = joinpath(d, "T")
        A = collect(Int32, 1:20)
        B = collect(0.0:1.0:19.0)
        C = [isodd(i) ? "x" : "y" for i in 1:20]
        NM = [i % 3 == 0 ? "cal_$i" : "src_$i" for i in 1:20]
        write_table(pdir, "T", Pair{String,Any}["A" => A, "B" => B, "C" => C,
                                                "NM" => NM]; nrow=20)

        function _taql_rows(wherestr)
            rdir = joinpath(mktempdir(), "sel")
            _taqlcmd("SELECT FROM \$1 WHERE $wherestr GIVING '$rdir'", pdir)
            return readtable(rdir).rows
        end

        t = readtable(pdir)
        for wherestr in ("A > 5", "A >= 15 OR A <= 2", "A > 3 AND A < 10",
                         "C == 'x'", "NOT (A > 10)", "A IN [1,5,10,20]",
                         "A BETWEEN 5 AND 12", "A NOT BETWEEN 5 AND 12",
                         "A BETWEEN 5 AND 12 OR A == 18",
                         "B BETWEEN A - 1 AND A",
                         # Phase 46: bitwise (A is Int32) -- pins precedence
                         # (bitwise above comparison, | < ^ < & < + -) and
                         # ^ == xor / ~ == bitnot against real TaQL
                         "A & 1 == 0", "A | 8 > 12", "A ^ 3 == 0",
                         "~A > -6", "A & 3 | 4 == 5", "A + 1 & 6 == 6",
                         # Phase 47: approximate equality (B is Double)
                         "B ~= 5.0", "B !~= 5.0", "B / 2.0 ~= 5.0",
                         "B ~= 5.0 OR B ~= 12.0")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end

        # ORDER BY -- row ORDER matters here (unlike the WHERE-only cross-
        # check above, which only needs set equality since it never sorts).
        for wherestr in ("A > 5 ORDER BY A DESC", "A > 3 AND A < 15 ORDER BY B",
                         "A > 0 ORDER BY B DESC, A")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end

        # Phase 24 -- arithmetic + pattern matching, same string through
        # both engines. (`/` on int columns avoided -- Julia yields a
        # float where TaQL keeps ints, a documented semantic difference.)
        for wherestr in ("A + 1 > 10", "A * 2 <= 30", "A % 3 == 0",
                         "A - 5 > B - 4", "(A + B) > 25 AND A < 12",
                         "NM LIKE 'cal%'", "NM NOT LIKE 'cal%'",
                         "NM ~ p/src*/", "C ~ p/x/")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end

        # Phase 25 -- functions. Thresholds kept away from exact boundaries
        # so Julia-vs-TaQL float promotion differences don't flip a row.
        for wherestr in ("sqrt(A) > 3", "abs(A - 10) <= 4", "sin(A) > 0",
                         "floor(B / 3) == 2", "sign(A - 10) >= 0",
                         "rownumber() > 15", "rownumber() % 4 == 0",
                         "upper(NM) == 'CAL_3'", "strlength(NM) > 5",
                         "iif(A > 10, A, 0) > 12", "min(A, 8) == 8",
                         "isfinite(B)")
            @test query(t, wherestr).rows == _taql_rows(wherestr)
        end
    end

    @testset "TaQL-lite — array indexing real TaQL cross-check" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        UVW = [Float64[i, 2i, 3i] for i in 1:20]
        V = [reshape(Float64.(1:12) .+ i, 3, 4) for i in 1:20]
        write_table(pdir, "T", Pair{String,Any}["UVW" => UVW, "V" => V]; nrow=20, tsm=[["V"]])
        t = readtable(pdir)
        function _rows(w)
            rdir = joinpath(mktempdir(), "sel")
            _taqlcmd("SELECT FROM \$1 WHERE $w GIVING '$rdir'", pdir)
            return readtable(rdir).rows
        end
        # 1-based scalar index, arithmetic on an indexed value, a slice
        # sum (exercises inclusive range), and a start:end:step range
        # (casacore order -> must match our a:b:s -> Julia a:s:b mapping).
        for w in ("UVW[3] > 30", "V[1,1] > 8", "V[2,3] - V[1,1] > 1",
                  "sum(V[1:2,1]) > 12", "sum(V[1:3:2,1]) > 8",
                  # Phase 44: negative-from-end (casacore-compatible; `end`
                  # has no TaQL equivalent so it is not cross-checked here)
                  "UVW[-1] > 30", "V[-1,1] > 8", "sum(V[-2:-1,1]) > 20")
            @test query(t, w).rows == _rows(w)
        end
    end

    @testset "groupby — real TaQL cross-check" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        K = Int32[(i - 1) % 4 for i in 1:40]
        X = Float64[sin(i) * 10 + i for i in 1:40]
        write_table(pdir, "T", Pair{String,Any}["K" => K, "X" => X]; nrow=40)

        # SELECT K, gcount(K) AS N, gsum(X) AS S, ... GROUP BY K -> a table;
        # read it, index by K, compare to our groupby (sorted by K -- group
        # ORDER is unspecified in both engines).
        function _taql_group(wherestr)
            rdir = joinpath(mktempdir(), "g")
            w = wherestr === nothing ? "" : "WHERE $wherestr "
            _taqlcmd("SELECT K, gcount(K) AS N, gsum(X) AS S, gmean(X) AS MX, " *
                     "gmin(X) AS XMN, gmax(X) AS XMX FROM \$1 $(w)GROUP BY K GIVING '$rdir'",
                     pdir)
            g = readtable(rdir)
            ks = column(g, "K")[:]
            p = sortperm(ks)
            return (K=ks[p], N=column(g, "N")[:][p], S=column(g, "S")[:][p],
                    MX=column(g, "MX")[:][p], XMN=column(g, "XMN")[:][p],
                    XMX=column(g, "XMX")[:][p])
        end

        t = readtable(pdir)
        for wherestr in (nothing, "X > 5", "K != 2")
            ref = _taql_group(wherestr)
            got = groupby(t, "K"; where=wherestr,
                select=["K" => "K", "N" => "gcount()", "S" => "gsum(X)",
                        "MX" => "gmean(X)", "XMN" => "gmin(X)", "XMX" => "gmax(X)"],
                orderby=["K"])
            @test collect(got.K) == ref.K
            @test collect(got.N) == ref.N
            @test collect(got.S) ≈ ref.S
            @test collect(got.MX) ≈ ref.MX
            @test collect(got.XMN) ≈ ref.XMN
            @test collect(got.XMX) ≈ ref.XMX
        end
    end

    @testset "groupby — per-element (gs*) real TaQL cross-check" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        K = Int32[(i - 1) % 3 for i in 1:24]
        V = [Float64[i, i + 1, i + 2, i + 3] for i in 1:24]      # (4,) cells
        write_table(pdir, "T", Pair{String,Any}["K" => K, "V" => V]; nrow=24, tsm=[["V"]])
        rdir = joinpath(mktempdir(), "g")
        _taqlcmd("SELECT K, gsums(V) AS SU, gmeans(V) AS MN, gmaxs(V) AS MX, " *
                 "gstddevs(V) AS SD FROM \$1 GROUP BY K GIVING '$rdir'", pdir)
        g = readtable(rdir)
        ks = column(g, "K")[:]; p = sortperm(ks)
        t = readtable(pdir)
        got = groupby(t, "K"; orderby=["K"],
            select=["K" => "K", "SU" => "gsums(V)", "MN" => "gmeans(V)",
                    "MX" => "gmaxs(V)", "SD" => "gstddevs(V)"])
        for i in 1:3
            @test collect(got.SU)[i] ≈ collect(column(g, "SU")[:][p][i])
            @test collect(got.MN)[i] ≈ collect(column(g, "MN")[:][p][i])
            @test collect(got.MX)[i] ≈ collect(column(g, "MX")[:][p][i])
            @test collect(got.SD)[i] ≈ collect(column(g, "SD")[:][p][i])
        end
    end

    @testset "join — real TaQL cross-check" begin
        d = mktempdir()
        A1 = Int32[(i - 1) % 5 for i in 1:30]
        X = collect(Float64, 1:30)
        SRC = ["src$(A1[i])" for i in 1:30]
        write_table(joinpath(d, "MAIN"), "MAIN",
                    Pair{String,Any}["ANTENNA1" => A1, "X" => X, "SRC" => SRC]; nrow=30)
        AN = ["DA4$i" for i in 0:4]
        write_table(joinpath(d, "ANT"), "ANT", Pair{String,Any}["NAME" => AN]; nrow=5)
        FN = ["src$i" for i in 0:4]
        FR = Float64[10 + i for i in 0:4]
        write_table(joinpath(d, "FLD"), "FLD",
                    Pair{String,Any}["NAME" => FN, "FREQ" => FR]; nrow=5)

        function _taql_join(sel, fromjoin)
            rdir = joinpath(mktempdir(), "j")
            _taqlcmd("SELECT $sel FROM \$1 JOIN \$2 $(fromjoin[2]) GIVING '$rdir'",
                     joinpath(d, "MAIN"), joinpath(d, fromjoin[1]))
            readtable(rdir)
        end

        main = readtable(joinpath(d, "MAIN"))
        ant = readtable(joinpath(d, "ANT"))
        fld = readtable(joinpath(d, "FLD"))

        # index-lookup: ANTENNA1 == ANT.rowid()
        tj = _taql_join("X, ANT.NAME AS AN", ("ANT", "ANT ON ANTENNA1 == ANT.rowid()"))
        oj = join(main, ant; on="ANTENNA1", leftcols=["X"], rightcols=["NAME" => "AN"])
        @test collect(oj.X) == column(tj, "X")[:]
        @test collect(oj.AN) == column(tj, "AN")[:]

        # equi-join: SRC == FLD.NAME
        tj2 = _taql_join("X, FLD.FREQ AS FREQ", ("FLD", "FLD ON SRC == FLD.NAME"))
        oj2 = join(main, fld; on="SRC" => "NAME", leftcols=["X"], rightcols=["FREQ"])
        @test collect(oj2.X) == column(tj2, "X")[:]
        @test collect(oj2.FREQ) ≈ column(tj2, "FREQ")[:]
    end
end
