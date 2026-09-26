# Phase 277: seeded random-expression differential fuzz of TaQL-lite against real TaQL.  Random
# WHERE clauses (arithmetic, comparisons, AND/OR/NOT, LIKE/ILIKE, IN, BETWEEN, glob patterns,
# string functions) are compared by matched row set, and random numeric expressions (rounding,
# `%`, `//`, `pow`, `iif`, `min`/`max`, trig, ...) by computed value, on a small table.  A larger
# run (3300 expressions) found no divergence; this keeps a few hundred as a regression guard.

using Random

@testset "TaQL-lite vs real TaQL: random expressions (Phase 277)" begin
    if _HAVE_TAQL
        N = 24; r0 = MersenneTwister(1)
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["ID" => Int32.(1:N), "I" => Int32.(rand(r0, -6:6, N)), "J" => Int32.(rand(r0, 0:5, N)),
            "D" => round.(randn(r0, N) .* 3; digits=1), "E" => Float64.(rand(r0, 1:4, N)) .* 0.5,
            "B" => rand(r0, Bool, N), "S" => rand(r0, ["ab", "abc", "b", "Zed", ""], N)]; nrow=N)
        t = readtable(d)
        num(r, dep) = dep <= 0 ? rand(r, ("I", "J", "D", "E", string(rand(r, 0:5)), string(round(rand(r) * 4; digits=1)))) : begin
            k = rand(r, 1:10); a = num(r, dep - 1); b = num(r, dep - 1)
            k <= 3 ? "($a + $b)" : k <= 5 ? "($a - $b)" : k <= 7 ? "($a * $b)" : k == 8 ? "(-$a)" : k == 9 ? "abs($a)" : "($a / $(rand(r, ("2", "4", "E", "(J+1)"))))"
        end
        function bool(r, dep)
            k = rand(r, 1:(dep <= 0 ? 9 : 12))
            k == 1 && return "B"
            k == 2 && return "S $(rand(r, ("==", "!="))) '$(rand(r, ("ab", "b", "Zed", "")))'"
            k == 3 && return "S $(rand(r, ("LIKE", "NOT LIKE", "ILIKE"))) '$(rand(r, ("a%", "%b", "_b%", "z%", "%", "A_C")))'"
            k == 4 && return "I $(rand(r, ("IN", "NOT IN"))) [$(join(rand(r, -6:6, rand(r, 1:4)), ","))]"
            k == 5 && return "J $(rand(r, ("BETWEEN", "NOT BETWEEN"))) $(rand(r, 0:2)) AND $(rand(r, 2:5))"
            k == 6 && return "S ~ p/$(rand(r, ("a*", "*b", "?b*", "Z*", "a{b,c}*")))/"
            k == 7 && return "strlength(S) $(rand(r, ("<", ">", "==", ">="))) $(rand(r, 0:3))"
            k == 8 && return "upper(S) == '$(rand(r, ("AB", "B", "ZED", "ABC")))'"
            (k == 9 || dep <= 0) && return "$(num(r, 1)) $(rand(r, ("<", "<=", ">", ">=", "==", "!="))) $(num(r, 1))"
            k <= 10 ? "($(bool(r, dep - 1)) AND $(bool(r, dep - 1)))" : k == 11 ? "($(bool(r, dep - 1)) OR $(bool(r, dep - 1)))" : "NOT ($(bool(r, dep - 1)))"
        end
        val(r, dep) = dep <= 0 ? rand(r, ("I", "J", "D", "E", "ID", string(rand(r, 1:5)), string(round(rand(r) * 4 + 0.1; digits=1)))) : begin
            k = rand(r, 1:22); a = val(r, dep - 1); b = val(r, dep - 1)
            k == 1 ? "($a + $b)" : k == 2 ? "($a - $b)" : k == 3 ? "($a * $b)" : k == 4 ? "($a / ($b + 7.5))" : k == 5 ? "($a % 3)" :
            k == 6 ? "($a // 2)" : k == 7 ? "abs($a)" : k == 8 ? "floor($a)" : k == 9 ? "ceil($a)" : k == 10 ? "round($a)" : k == 11 ? "int($a)" :
            k == 12 ? "sqrt(abs($a))" : k == 13 ? "min($a, $b)" : k == 14 ? "max($a, $b)" : k == 15 ? "iif($a > $b, $a, $b)" : k == 16 ? "sign($a)" :
            k == 17 ? "sin($a)" : k == 18 ? "exp(min($a, 3))" : k == 19 ? "pow(abs($a), 2)" : k == 20 ? "($a ** 2)" : k == 21 ? "(-$a)" : "fmod($a, 3)"
        end
        rng = MersenneTwister(277)
        badrows = String[]; badvals = String[]
        for _ in 1:150
            ex = bool(rng, rand(rng, 0:3))
            ours = try Int.(column(query(t, ex), "ID")[:]) catch e; :err end
            real = try (rt = _taqlcmd("SELECT FROM \$1 WHERE $ex", d); size(rt, 1) == 0 ? Int[] : Int.(collect(rt[:ID][:]))) catch e; :err end
            ours == real || push!(badrows, ex)
        end
        for _ in 1:100
            ex = val(rng, rand(rng, 0:3))
            ours = try Vector{Float64}(column(query(t, "ID > 0"; select=["X" => ex]), "X")[:]) catch e; :err end
            real = try (rt = _taqlcmd("SELECT $ex AS X FROM \$1", d); Vector{Float64}(collect(rt[:X][:]))) catch e; :err end
            same = ours isa Symbol || real isa Symbol ? ours === real :
                   all(i -> isequal(ours[i], real[i]) || isapprox(ours[i], real[i]; rtol=1e-9, atol=1e-12), eachindex(ours))
            same || push!(badvals, ex)
        end
        @test isempty(badrows)
        @test isempty(badvals)
        isempty(badrows) || println("row-set mismatches: ", badrows)
        isempty(badvals) || println("value mismatches: ", badvals)
    end
end
