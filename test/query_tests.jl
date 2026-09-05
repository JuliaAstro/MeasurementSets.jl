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

    # rejected operators give clear errors
    @test_throws ArgumentError parse("A ~= 5")
    @test_throws ArgumentError parse("A & 1 == 0")
    @test_throws ArgumentError parse("A ^ 2 > 3")
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
              td2, t.managers, t.syncmod, t.lockpath, t.container)
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
              td2, t.managers, t.syncmod, t.lockpath, t.container)
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
    @test Set(propertynames(gs)) == Set([:A, :B])
    @test_throws ArgumentError gs.NOPE
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
              td2, t.managers, t.syncmod, t.lockpath, t.container)
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
            v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
            parent = CCT.Table(pdir)
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(parent.tableref)))
            w = wherestr === nothing ? "" : "WHERE $wherestr "
            GC.@preserve parent CCT.Table(Casacore.LibCasacore.tableCommand(
                "SELECT K, gcount(K) AS N, gsum(X) AS S, gmean(X) AS MX, " *
                "gmin(X) AS XMN, gmax(X) AS XMX FROM \$1 $(w)GROUP BY K GIVING '$rdir'", v))
            GC.gc(); GC.gc()
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
            v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
            m = CCT.Table(joinpath(d, "MAIN"))
            r = CCT.Table(joinpath(d, fromjoin[1]))
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(m.tableref)))
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(r.tableref)))
            GC.@preserve m r CCT.Table(Casacore.LibCasacore.tableCommand(
                "SELECT $sel FROM \$1 JOIN \$2 $(fromjoin[2]) GIVING '$rdir'", v))
            GC.gc(); GC.gc()
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
