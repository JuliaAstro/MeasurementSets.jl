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

# Phase 278: random UPDATE / DELETE / INSERT command sequences applied to twin tables -- ours
# (`taql`) and real TaQL -- with every column compared after each command.  80 seeds found no
# divergence in TaQL-lite.  Not compared: the Bool column after a DELETE (real casacore drops set
# bits when it deletes rows from a bit-packed Bool column -- reproduced on a table casacore created
# itself, so an upstream bug), the array column on inserted rows (undefined), and a column named
# `F` (a `False` literal in real TaQL); signed zeros compare equal (`-0.0 % 4` is `-0.0` in real TaQL).
@testset "TaQL-lite write commands vs real TaQL: random sequences (Phase 278)" begin
    if _HAVE_TAQL
        num(r, dep) = dep <= 0 ? rand(r, ("I", "D", "ID", string(rand(r, 0:5)), string(round(rand(r) * 4; digits=1)))) : begin
            k = rand(r, 1:9); a = num(r, dep - 1); b = num(r, dep - 1)
            k <= 2 ? "($a + $b)" : k == 3 ? "($a - $b)" : k <= 5 ? "($a * $b)" : k == 6 ? "abs($a)" : k == 7 ? "($a % 4)" : k == 8 ? "floor($a)" : "($a / 3)"
        end
        function boo(r, dep)
            k = rand(r, 1:(dep <= 0 ? 5 : 8))
            k == 1 && return "B"; k == 2 && return "S $(rand(r, ("==", "!="))) '$(rand(r, ("ab", "b", "")))'"
            k == 3 && return "S LIKE '$(rand(r, ("a%", "%b", "%")))'"; k == 4 && return "I IN [$(join(rand(r, -6:6, 3), ","))]"
            (k == 5 || dep <= 0) && return "$(num(r, 1)) $(rand(r, ("<", ">", "==", "!=", "<=", ">="))) $(num(r, 1))"
            k <= 6 ? "($(boo(r, dep - 1)) AND $(boo(r, dep - 1)))" : k == 7 ? "($(boo(r, dep - 1)) OR $(boo(r, dep - 1)))" : "NOT ($(boo(r, dep - 1)))"
        end
        function gencmd(r)
            k = rand(r, 1:10)
            if k <= 4
                col = rand(r, ("I", "D", "S", "B", "I", "D"))
                rhs = col == "S" ? rand(r, ("'x'", "S", "(S + 'y')", "upper(S)", "'k' + string(I)", "substr(S, 0, 1)")) : col == "B" ? boo(r, 1) : num(r, rand(r, 0:2))
                "UPDATE \$1 SET $col = $rhs" * (rand(r) < 0.8 ? " WHERE " * boo(r, rand(r, 0:2)) : "")
            elseif k <= 6; "UPDATE \$1 SET FA[$(rand(r, 1:3))] = $(num(r, 1)) WHERE $(boo(r, 1))"
            elseif k <= 8; "DELETE FROM \$1 WHERE $(boo(r, rand(r, 0:2)))"
            else "INSERT INTO \$1 (ID, I, D, S, B) VALUES ($(100 + rand(r, 0:900)), $(rand(r, -5:5)), $(round(randn(r) * 3; digits=1)), '$(rand(r, ("ab", "b", "z", "")))', $(rand(r, ("T", "F"))))" end
        end
        snap(d) = (t = readtable(d); Dict(c => collect(column(t, c; precision=:full)[:]) for c in ("I", "D", "S", "B", "FA", "ID")))
        same(a, b) = length(a) == length(b) && all(i -> a[i] isa AbstractArray ? a[i] == b[i] : (isequal(a[i], b[i]) || (a[i] isa Real && isapprox(a[i], b[i]; rtol=1e-9))), eachindex(a))
        bad = String[]
        for seed in 1:6
            r = MersenneTwister(seed); N = 10; r0 = MersenneTwister(seed + 1000); deleted = false
            cols = Pair{String,Any}["ID" => Int32.(1:N), "I" => Int32.(rand(r0, -6:6, N)), "D" => round.(randn(r0, N) .* 3; digits=1),
                "S" => rand(r0, ["ab", "abc", "b", ""], N), "B" => rand(r0, Bool, N), "FA" => [Float64[i, 2i, 3i] for i in 1:N]]
            da = joinpath(mktempdir(), "ours"); db = joinpath(mktempdir(), "real")
            write_table(da, "T", cols; nrow=N); write_table(db, "T", cols; nrow=N)
            for _ in 1:10
                cmd = gencmd(r); startswith(cmd, "DELETE") && (deleted = true)
                ea = try taql(da, replace(cmd, "\$1" => "t")); nothing catch e; :err end
                eb = try _taqlcmd(cmd, db); nothing catch e; :err end
                (ea === nothing) == (eb === nothing) || (push!(bad, "error mismatch: $cmd"); break)
                ea === nothing || continue
                sa, sb = snap(da), snap(db)
                keepa = [i for i in eachindex(sa["ID"]) if sa["ID"][i] <= 10]; keepb = [i for i in eachindex(sb["ID"]) if sb["ID"][i] <= 10]
                keepa == keepb && length(sa["ID"]) == length(sb["ID"]) || (push!(bad, "rows differ after: $cmd"); break)
                ok = all(c -> (c == "B" && deleted) || (c == "FA" ? same(sa[c][keepa], sb[c][keepb]) : same(sa[c], sb[c])), keys(sa))
                ok || (push!(bad, "values differ after: $cmd"); break)
            end
        end
        @test isempty(bad)
        isempty(bad) || println(bad)
    end
end

# Phase 284: random GROUP BY queries (1-2 key columns incl. String / Bool keys, 1-3 `g*` aggregates over
# random expressions, WHERE, HAVING) compared with real TaQL.  700 queries found one divergence: the
# sample variance / stddev of a ONE-ROW group is 0.0 in real TaQL (Julia's `var` gave NaN).  Not
# compared: `gmax` of an all-negative group (real casacore returns DBL_MIN = 2.2e-308, an upstream bug --
# it also lets `HAVING gmax(x) > 0` keep such groups).
@testset "TaQL-lite GROUP BY vs real TaQL: random queries (Phase 284)" begin
    if _HAVE_TAQL
        N = 60; r0 = MersenneTwister(11)
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["ID" => Int32.(1:N), "K" => Int32.(rand(r0, 0:3, N)), "L" => Int32.(rand(r0, 0:2, N)), "I" => Int32.(rand(r0, -6:6, N)),
            "D" => round.(randn(r0, N) .* 3; digits=1), "E" => Float64.(rand(r0, 1:4, N)) .* 0.5, "B" => rand(r0, Bool, N), "S" => rand(r0, ["ab", "abc", "b", "z"], N)]; nrow=N)
        t = readtable(d)
        pick(r, xs) = xs[rand(r, 1:length(xs))]
        num(r) = pick(r, ("I", "D", "E", "(I + D)", "(D * E)", "abs(D)", "(I % 3)", "ID"))
        fns = ["gcount()", "gsum", "gmean", "gmin", "gvariance", "gstddev", "grms", "gmedian", "gsamplevariance", "gsamplestddev", "gfirst", "glast"]
        r = MersenneTwister(284); bad = String[]
        for _ in 1:60
            kk = pick(r, (["K"], ["L"], ["K", "L"], ["S"], ["B"], ["K", "S"]))
            aggs = ["A$i" => (a = pick(r, fns); a == "gcount()" ? a : "$a($(num(r)))") for i in 1:rand(r, 1:3)]
            wh = rand(r) < 0.4 ? pick(r, ("I > -3", "B", "D < 2.0", "S != 'z'", "ID % 2 == 0")) : nothing
            hv = rand(r) < 0.3 ? pick(r, ("gcount() > 3", "gsum(I) >= 0", "gmin(E) < 1.5")) : nothing
            sel = join(vcat(kk, ["$(a.second) AS $(a.first)" for a in aggs]), ", ")
            cmd = "SELECT $sel FROM \$1" * (wh === nothing ? "" : " WHERE $wh") * " GROUP BY $(join(kk, ", "))" * (hv === nothing ? "" : " HAVING $hv")
            g = MSv2.groupby(t, kk; select = vcat([k => Symbol(k) for k in kk], [a.first => a.second for a in aggs]), where = wh, having = hv)
            ours = Dict(Tuple(getproperty(g, Symbol(k))[i] for k in kk) => [getproperty(g, Symbol(a.first))[i] for a in aggs] for i in 1:MSv2.nrow(g))
            rt = _taqlcmd(cmd, d)
            real = size(rt, 1) == 0 ? Dict() : Dict(Tuple(collect(rt[Symbol(k)][:])[i] for k in kk) => [collect(rt[Symbol(a.first)][:])[i] for a in aggs] for i in 1:size(rt, 1))
            ok = length(ours) == length(real) && all(k -> haskey(real, k) && all(j -> (a = ours[k][j]; b = real[k][j];
                    a == b || (a isa Real && b isa Real && isapprox(a, b; rtol=1e-8, atol=1e-10))), eachindex(ours[k])), keys(ours))
            ok || push!(bad, cmd)
        end
        @test isempty(bad)
        isempty(bad) || println(bad)
        # a one-row group: sample variance / stddev are 0.0, not NaN
        g = MSv2.groupby(t, ["ID"]; select = ["ID" => :ID, "V" => "gsamplevariance(D)", "S" => "gsamplestddev(D)"])
        @test all(==(0.0), g.V) && all(==(0.0), g.S)
    end
end

# Phase 285: seeded random ARRAY-expression differential fuzz against real TaQL.  Random
# expressions over 3x4 array cells (arithmetic, comparisons, AND/OR/NOT/iif on arrays, axis-
# collapse reductions, transpose/reversearray/resize, running*/boxed* windows, slices, and
# masked arrays via `arr[boolexpr]`/`replacemasked`) are compared by computed value.  A run of
# ~5000 expressions found the Phase 285 divergences (Bool-array AND/OR, scalar window widths,
# masked running*/boxed*/axis reductions, empty masked reductions, resize's shape argument,
# array-shape mismatches); this keeps 150 as a regression guard.  (Real TaQL segfaults on an
# `iif` with a masked branch, and rejects a bare `:` slice / Bool arithmetic, so the generator
# avoids those.)
@testset "TaQL-lite array expressions vs real TaQL: random queries (Phase 285)" begin
    if _HAVE_TAQL
        N = 5; r0 = MersenneTwister(3)
        d = joinpath(mktempdir(), "t")
        mk() = [round.(randn(r0, 3, 4) .* 3; digits=1) for _ in 1:N]
        write_table(d, "T", Pair{String,Any}["ID" => Int32.(1:N), "A" => mk(), "B" => mk(),
            "C" => [Int32.(rand(r0, -4:4, 3, 4)) for _ in 1:N], "M" => [rand(r0, Bool, 3, 4) for _ in 1:N],
            "K" => Int32.(rand(r0, 1:3, N)), "D" => round.(randn(r0, N) .* 2; digits=1)]; nrow=N)
        t = readtable(d)
        pick(r, xs) = xs[rand(r, 1:length(xs))]
        redfns = ("sums", "means", "mins", "maxs", "medians", "variances", "stddevs", "rmss", "avdevs", "sumsqrs", "products")
        scfns = ("sum", "mean", "min", "max", "median", "variance", "stddev", "rms", "avdev", "sumsqr")
        runfns = ("runningmean", "runningsum", "runningmedian", "runningmin", "runningmax", "runningavdev", "runningrms", "runningvariance")
        boxfns = ("boxedmean", "boxedsum", "boxedmedian", "boxedmin", "boxedmax", "boxedvariance")
        function gen(r, k, dep)
            if k == :sc
                dep <= 0 && return pick(r, ("D", string(rand(r, 1:3)), "K", "A[$(rand(r,1:3)),$(rand(r,1:4))]", "C[$(rand(r,1:3)),$(rand(r,-4:-1))]"))
                c = rand(r, 1:9)
                c == 1 && return "$(pick(r, scfns))($(gen(r, :s34, dep-1)))"
                c == 2 && return "$(pick(r, scfns))($(gen(r, :v4, dep-1)))"
                c == 3 && return "$(pick(r, ("ntrue", "nfalse")))($(gen(r, :b34, dep-1)))"
                c == 4 && return "($(gen(r, :sc, dep-1)) $(pick(r, ("+", "-", "*"))) $(gen(r, :sc, dep-1)))"
                c == 5 && return "$(pick(r, scfns))(abs($(gen(r, :s34, dep-1)))[$(pick(r, ("1:2,2", "2,1:3", "1:3,1", "1:2,2:3", "2:,:2")))])"
                c == 6 && return "$(pick(r, scfns))(abs($(gen(r, :s34, dep-1)))[$(gen(r, :b34, dep-1))])"
                c == 7 && return "$(pick(r, ("nelements", "ndim")))($(gen(r, pick(r, (:s34, :v4, :v3)), dep-1)))"
                return "fractile($(gen(r, :s34, dep-1)), $(pick(r, ("0.5", "0.75"))))"
            elseif k == :s34
                dep <= 0 && return pick(r, ("A", "B", "C"))
                c = rand(r, 1:11)
                c == 1 && return "($(gen(r, :s34, dep-1)) $(pick(r, ("+", "-", "*"))) $(gen(r, :s34, dep-1)))"
                c == 2 && return "($(gen(r, :s34, dep-1)) $(pick(r, ("+", "-", "*", "/"))) $(gen(r, :sc, dep-1)))"
                c == 3 && return "abs($(gen(r, :s34, dep-1)))"
                c == 4 && return "$(pick(r, runfns))($(gen(r, :s34, dep-1)), $(pick(r, ("1", "[1,0]", "[0,1]", "[1,1]", "[2,1]", "2"))))"
                c == 5 && return "$(pick(r, boxfns))($(gen(r, :s34, dep-1)), $(pick(r, ("1", "2", "[1,2]", "[3,2]", "[2,3]", "[4,4]"))))"
                c == 6 && return "reversearray($(gen(r, :s34, dep-1))$(pick(r, ("", ", 1", ", 2", ", 1, 2", ", 3"))))"
                c == 7 && return "transpose($(gen(r, :s43, dep-1)))"
                c == 8 && return "-$(gen(r, :s34, dep-1))"
                c == 9 && return "resize($(gen(r, :s34, dep-1)), [3, 4])"
                c == 10 && return "iif($(gen(r, :b34, dep-1)), $(gen(r, :s34, 0)), $(gen(r, :s34, 0)))"
                return "replacemasked(abs($(gen(r, :s34, dep-1)))[$(gen(r, :b34, dep-1))], $(rand(r, 0:3)))"
            elseif k == :s43
                dep <= 0 && return "transpose(A)"
                c = rand(r, 1:3)
                c == 1 && return "transpose($(gen(r, :s34, dep-1)))"
                c == 2 && return "reversearray($(gen(r, :s43, dep-1))$(pick(r, ("", ", 1", ", 2"))))"
                return "($(gen(r, :s43, dep-1)) $(pick(r, ("+", "-"))) $(gen(r, :sc, dep-1)))"
            elseif k == :v4 || k == :v3
                ax = k == :v4 ? "1" : "2"
                dep <= 0 && return "sums(A, $ax)"
                c = rand(r, 1:4)
                c == 1 && return "$(pick(r, redfns))($(gen(r, :s34, dep-1)), $ax)"
                c == 2 && return "fractiles($(gen(r, :s34, dep-1)), $(pick(r, ("0.25", "0.5", "0.9"))), $ax)"
                c == 3 && return "$(pick(r, ("ntrues", "nfalses")))($(gen(r, :b34, dep-1)), $ax)"
                return "($(gen(r, k, dep-1)) $(pick(r, ("+", "*"))) $(gen(r, :sc, dep-1)))"
            elseif k == :bsc
                return "$(pick(r, ("any", "all")))($(gen(r, :b34, dep-1)))"
            elseif k == :bv
                return "$(pick(r, ("anys", "alls")))($(gen(r, :b34, dep-1)), $(rand(r, 1:2)))"
            else # :b34
                dep <= 0 && return pick(r, ("M", "(A > 0.0)", "(C < 1)"))
                c = rand(r, 1:5)
                c == 1 && return "($(gen(r, :s34, dep-1)) $(pick(r, ("<", ">", "<=", ">=", "==", "!="))) $(gen(r, :sc, dep-1)))"
                c == 2 && return "($(gen(r, :s34, dep-1)) $(pick(r, ("<", ">"))) $(gen(r, :s34, dep-1)))"
                c == 3 && return "(NOT $(gen(r, :b34, dep-1)))"
                c == 4 && return "($(gen(r, :b34, dep-1)) $(pick(r, ("AND", "OR"))) $(gen(r, :b34, dep-1)))"
                return "isnan(A)"
            end
        end
        same(a, b) = a isa AbstractArray || b isa AbstractArray ?
            (a isa AbstractArray && b isa AbstractArray && size(a) == size(b) && all(same.(a, b))) :
            (a == b || (a isa Real && b isa Real && (isnan(a) && isnan(b) || isapprox(a, b; rtol=1e-6, atol=1e-8))))
        r = MersenneTwister(285); bad = String[]
        for _ in 1:150
            ex = gen(r, pick(r, (:sc, :sc, :s34, :s34, :v4, :v3, :b34, :s43, :bsc, :bv)), rand(r, 1:3))
            ours = try collect(column(query(t, "rownumber() > 0"; select = ["R" => ex]), "R")[:]) catch; nothing end
            real = try collect(_taqlcmd("SELECT $ex AS R FROM \$1", d)[:R][:]) catch; nothing end
            ours === nothing && real === nothing && continue            # both reject it
            (ours === nothing || real === nothing || length(ours) != length(real) || !all(same.(ours, real))) && push!(bad, ex)
        end
        @test isempty(bad)
        isempty(bad) || println(bad)
    end
end

# Phase 286: seeded random GROUP BY differential fuzz where the AGGREGATE ARGUMENT is itself an
# array-cell expression (`gmean(mean(A))`, `gsum(sums(A,1)[2])`, `gvariance(min(A) + D)`, …) --
# continuing the Phase 285 array-expression sweep into the aggregate position.  2000 queries
# across 4 seeds found no divergence beyond the already-known upstream `gmax`-of-an-all-negative-
# group bug (Phase 284, `gmax` excluded from the generator here since it's not our bug); this
# keeps 300 as a regression guard.
@testset "TaQL-lite GROUP BY over array-cell aggregate arguments vs real TaQL (Phase 286)" begin
    if _HAVE_TAQL
        N = 24; r0 = MersenneTwister(5)
        d = joinpath(mktempdir(), "t")
        mk() = [round.(randn(r0, 3, 4) .* 3; digits=1) for _ in 1:N]
        write_table(d, "T", Pair{String,Any}["ID" => Int32.(1:N), "A" => mk(), "M" => [rand(r0, Bool, 3, 4) for _ in 1:N],
            "K" => Int32.(rand(r0, 0:2, N)), "D" => round.(randn(r0, N) .* 2; digits=1)]; nrow=N)
        t = readtable(d)
        pick(r, xs) = xs[rand(r, 1:length(xs))]
        scfns = ("sum", "mean", "min", "max", "median", "variance", "stddev", "rms", "avdev", "sumsqr")
        # gmax excluded: real TaQL's running maximum starts at DBL_MIN, not our bug (Phase 284)
        aggfns = ("gsum", "gmean", "gmin", "gvariance", "gstddev", "grms", "gmedian", "gfirst", "glast")
        function argexpr(r)
            c = rand(r, 1:5)
            c == 1 && return "$(pick(r, scfns))(A)"
            c == 2 && return "$(pick(r, scfns))(abs(A)[A > 0.0])"
            c == 3 && return "D"
            c == 4 && return "$(pick(r, scfns))(A) + D"
            return "sums(A, $(rand(r, 1:2)))[$(rand(r, 1:2))]"
        end
        r = MersenneTwister(286); bad = String[]
        for _ in 1:300
            agg = pick(r, aggfns); arg = argexpr(r)
            wh = rand(r) < 0.4 ? pick(r, ("D > 0.0", "K == 1", "sum(A) > 0")) : nothing
            cmd = "SELECT K, $agg($arg) AS X FROM \$1" * (wh === nothing ? "" : " WHERE $wh") * " GROUP BY K"
            g = MSv2.groupby(t, ["K"]; select = ["K" => :K, "X" => "$agg($arg)"], where = wh)
            ours = Dict(g.K[i] => g.X[i] for i in 1:MSv2.nrow(g))
            rt = _taqlcmd(cmd, d)
            real = size(rt, 1) == 0 ? Dict() : Dict(collect(rt[:K][:])[i] => collect(rt[:X][:])[i] for i in 1:size(rt, 1))
            ok = length(ours) == length(real) && all(k -> haskey(real, k) &&
                (ours[k] == real[k] || (ours[k] isa Real && real[k] isa Real && isapprox(ours[k], real[k]; rtol=1e-6, atol=1e-8))),
                keys(ours))
            ok || push!(bad, cmd)
        end
        @test isempty(bad)
        isempty(bad) || println(bad)
    end
end

# Phase 287: seeded random differential fuzz of `UPDATE ... SET` on ARRAY-CELL columns (whole-
# array RHS, subscript slices, boolean masks, the masked `(D, M) = expr[cond]` pair form) against
# real TaQL, mirroring Phase 278's write-command fuzz but for array cells. 1000 queries across 5
# seeds found two real bugs, both fixed:
#  * a scalar Bool value used as an array subscript (`FA[B]` where `B` is a per-row scalar Bool
#    column, not an array) silently misbehaved as an integer index via Julia's own `Int(::Bool)`
#    (`FA[false]` -> `FA[0]`, a `BoundsError`; `FA[true]` -> the wrong element, `FA[1]`), where real
#    TaQL requires a Bool subscript to be shaped like the array ("... must be an array"). Now a
#    clear `ArgumentError`.
#  * `update!` evaluated every SET item lazily, only against the WHERE-matched rows -- so a
#    structurally invalid target/RHS (the bug above, or any other) on an `UPDATE` whose WHERE
#    matches ZERO rows silently "succeeded" with no error, while real TaQL type-checks the whole
#    SET list once, independent of how many rows match. Fixed by validating every spec once
#    against row 1 (into a throwaway copy, never persisted) whenever no row is actually matched.
# Kept as a seeded 200-query guard.
@testset "TaQL-lite UPDATE on array-cell columns vs real TaQL: random sequences (Phase 287)" begin
    if _HAVE_TAQL
        num(r, dep) = dep <= 0 ? rand(r, ("I", "D", "ID", string(rand(r, 0:5)), string(round(rand(r) * 4; digits=1)))) : begin
            k = rand(r, 1:9); a = num(r, dep - 1); b = num(r, dep - 1)
            k <= 2 ? "($a + $b)" : k == 3 ? "($a - $b)" : k <= 5 ? "($a * $b)" : k == 6 ? "abs($a)" : k == 7 ? "($a % 4)" : k == 8 ? "floor($a)" : "($a / 3)"
        end
        function boo(r, dep)
            k = rand(r, 1:(dep <= 0 ? 5 : 8))
            k == 1 && return "B"; k == 2 && return "S $(rand(r, ("==", "!="))) '$(rand(r, ("ab", "b", "")))'"
            k == 3 && return "I IN [$(join(rand(r, -6:6, 3), ","))]"; k == 4 && return "FA[$(rand(r, 1:3))] > $(num(r, 1))"
            (k == 5 || dep <= 0) && return "$(num(r, 1)) $(rand(r, ("<", ">", "==", "!=", "<=", ">="))) $(num(r, 1))"
            k <= 6 ? "($(boo(r, dep - 1)) AND $(boo(r, dep - 1)))" : k == 7 ? "($(boo(r, dep - 1)) OR $(boo(r, dep - 1)))" : "NOT ($(boo(r, dep - 1)))"
        end
        arrexpr(r, dep) = dep <= 0 ? rand(r, ("FA", "GA")) : begin
            k = rand(r, 1:6); a = arrexpr(r, dep - 1)
            k == 1 ? "($a * $(num(r, 0)))" : k == 2 ? "abs($a)" : k == 3 ? "($a + $(arrexpr(r, dep - 1)))" :
                k == 4 ? "-$a" : k == 5 ? "iif($(boo(r, 0)), $a, $a)" : "reversearray($a)"
        end
        function gencmd(r)
            k = rand(r, 1:5)
            k == 1 && return "UPDATE \$1 SET FA = $(arrexpr(r, rand(r, 0:2)))" * (rand(r) < 0.7 ? " WHERE $(boo(r, rand(r, 0:1)))" : "")
            k == 2 && return "UPDATE \$1 SET FA[$(rand(r, 1:3))] = $(num(r, 1))" * (rand(r) < 0.7 ? " WHERE $(boo(r, rand(r, 0:1)))" : "")
            k == 3 && return "UPDATE \$1 SET FA[$(boo(r, 0))] = $(num(r, 1))" * (rand(r) < 0.7 ? " WHERE $(boo(r, rand(r, 0:1)))" : "")
            k == 4 && return "UPDATE \$1 SET (FA, MA) = FA[$(boo(r, 0))]" * (rand(r) < 0.7 ? " WHERE $(boo(r, rand(r, 0:1)))" : "")
            return "UPDATE \$1 SET FA = $(arrexpr(r, 1))[$(boo(r, 0))]" * (rand(r) < 0.7 ? " WHERE $(boo(r, rand(r, 0:1)))" : "")
        end
        snap(d) = (t = readtable(d); Dict(c => collect(column(t, c; precision=:full)[:]) for c in ("FA", "MA")))
        same(a, b) = length(a) == length(b) && all(i -> size(a[i]) == size(b[i]) && all(isapprox.(a[i], b[i]; rtol=1e-6, atol=1e-9)), eachindex(a))
        bad = String[]
        for seed in 1:5, run in 1:40
            r = MersenneTwister(seed * 10000 + run); N = 8; r0 = MersenneTwister(seed * 10000 + run + 500000)
            cols = Pair{String,Any}["ID" => Int32.(1:N), "I" => Int32.(rand(r0, -6:6, N)), "D" => round.(randn(r0, N) .* 3; digits=1),
                "S" => rand(r0, ["ab", "abc", "b", ""], N), "B" => rand(r0, Bool, N),
                "FA" => [round.(randn(r0, 3) .* 3; digits=1) for _ in 1:N], "GA" => [round.(randn(r0, 3) .* 3; digits=1) for _ in 1:N],
                "MA" => [zeros(3) for _ in 1:N]]
            da = joinpath(mktempdir(), "ours"); db = joinpath(mktempdir(), "real")
            write_table(da, "T", cols; nrow=N); write_table(db, "T", cols; nrow=N)
            cmd = gencmd(r)
            ea = try taql(da, replace(cmd, "\$1" => "t")); nothing catch e; :err end
            eb = try _taqlcmd(cmd, db); nothing catch e; :err end
            if (ea === nothing) != (eb === nothing)
                push!(bad, "error mismatch: $cmd"); continue
            end
            ea === nothing || continue
            sa, sb = snap(da), snap(db)
            same(sa["FA"], sb["FA"]) && same(sa["MA"], sb["MA"]) || push!(bad, "values differ: $cmd")
        end
        @test isempty(bad)
        isempty(bad) || println(bad)
    end
end

# Phase 377: mutation fuzz of the TaQL-lite parser / dispatcher with garbage input.  Valid queries
# and commands are mutated (tokens deleted / swapped / duplicated / replaced, absurd literals,
# unbalanced brackets) and pure garbage (deep nesting, huge IN lists, long chains) is thrown at
# `query` and `taql`.  Whatever happens, it must end in a result or an ordinary error -- never a
# stack overflow, an unchecked `BoundsError`/`InexactError`/`OverflowError`, a `KeyError` or a
# `StringIndexError` leaking out of the parser.  (Property-only guard: it holds for any RNG stream.)
@testset "TaQL-lite: garbage-input mutation fuzz never crashes (Phase 377)" begin
    N = 8; r0 = MersenneTwister(377)
    base = joinpath(mktempdir(), "t")
    write_table(base, "T", Pair{String,Any}["ID" => Int32.(1:N), "I" => Int32.(rand(r0, -6:6, N)), "J" => Int32.(rand(r0, 0:5, N)),
        "D" => round.(randn(r0, N) .* 3; digits=1), "B" => rand(r0, Bool, N), "S" => rand(r0, ["ab", "abc", "b", ""], N),
        "V" => [rand(r0, 3, 4) for _ in 1:N]]; nrow=N, tsm=[["V"]])
    exprs = ["I > 2", "I + J * 2 > D", "S LIKE 'a%'", "S ~ p/a*/", "I IN [1,2,3]", "I IN [1:3]", "J BETWEEN 1 AND 3", "NOT (B OR I > 0)",
        "abs(D) < 2.5 AND S != ''", "mean(V) > 0.5", "V[1,2] > 0.5", "sum(V[1:2,2]) > 1", "any(V > 0.9)", "iif(I > 0, I, -I) > 2",
        "sqrt(abs(D)) > 1", "strlength(S) >= 2", "upper(S) == 'AB'", "I % 3 == 0", "I // 2 == 1", "datetime('2020-02-12') > 0", "I ~= 2",
        "I & 3 == 1", "rownumber() > 3", "min(I, J) > 1", "D ** 2 > 4", "S IN ['a','ab']", "V[V > 0.5][1] > 0.5", "marray(V,V>0.5)",
        "meas.j2000('GALACTIC',1.0,0.5)[1] > 0"]
    cmds = ["SELECT FROM \$1 WHERE I > 2", "SELECT I, J AS K, I+J AS L FROM \$1 WHERE I > 0 ORDER BY J DESC LIMIT 4", "SELECT DISTINCT J FROM \$1",
        "SELECT J, gcount() AS N, gsum(I) AS S FROM \$1 GROUP BY J HAVING gcount() > 1", "UPDATE \$1 SET I = I + 1 WHERE I > 2",
        "UPDATE \$1 SET V[1,1] = 0.0 WHERE B", "DELETE FROM \$1 WHERE I > 100", "INSERT INTO \$1 (I, J) VALUES (1, 2)", "INSERT INTO \$1 SET I = 3",
        "SELECT FROM \$1 WHERE I IN (SELECT J FROM \$1)", "SELECT FROM \$1 a JOIN \$1 b ON a.I == b.J"]
    alphabet = collect("()[]{},.:;'\"+-*/%&|^~!=<>_ \\@#\$?0123456789eEabcxyzABCXYZ")
    toks(s) = [m.match for m in eachmatch(r"[A-Za-z_][A-Za-z_0-9.]*|\d+\.?\d*(?:[eE][+-]?\d+)?[A-Za-z]*|'[^']*'|\s+|.", s)]
    rng = MersenneTwister(3770)
    function mutate(s)
        tk = toks(s)
        for _ in 1:rand(rng, 1:3)
            isempty(tk) && break
            k = rand(rng, 1:10); i = rand(rng, 1:length(tk))
            if k == 1; deleteat!(tk, i)
            elseif k == 2; insert!(tk, i, string(rand(rng, alphabet)))
            elseif k == 3; tk[i] = string(rand(rng, alphabet))
            elseif k == 4; j = rand(rng, 1:length(tk)); tk[i], tk[j] = tk[j], tk[i]
            elseif k == 5; insert!(tk, i, tk[rand(rng, 1:length(tk))])
            elseif k == 6; tk[i] = rand(rng, ("99999999999999999999", "1e999", "-1e999", "0x", "0xFFFFFFFFFFFFFFFFFF", "1e-999", "NaN", "inf", "\u00e9", "'", "[", "]", "(", ")"))
            elseif k == 7; insert!(tk, i, "(" ^ rand(rng, 1:3))
            elseif k == 8; tk[i] = string(tk[i], rand(rng, ("[", "[1", "[1,", "[:", "(", "'", "/")))
            elseif k == 9; tk = tk[1:i]
            else; tk[i] = lowercase(tk[i]) == tk[i] ? uppercase(tk[i]) : lowercase(tk[i])
            end
        end
        join(tk)
    end
    garbage() = (k = rand(rng, 1:5);
        k == 1 ? String(rand(rng, alphabet, rand(rng, 0:40))) :
        k == 2 ? "(" ^ rand(rng, [10, 1000, 20000]) * "1" * ")" ^ rand(rng, [10, 1000, 20000]) :
        k == 3 ? "I > " * join(fill("-", rand(rng, [10, 1000, 20000]))) * "1" :
        k == 4 ? "I IN [" * join(fill("1", rand(rng, [10, 1000, 20000])), ",") * "]" :
                 "I > " * "1 + " ^ rand(rng, [100, 5000]) * "1")
    forbidden = Dict{String,Int}(); examples = String[]
    for c in 1:240
        usecmd = rand(rng) < 0.4
        s = rand(rng) < 0.1 ? garbage() : mutate(rand(rng, usecmd ? cmds : exprs))
        dc = joinpath(mktempdir(), "w"); cp(base, dc)
        try
            usecmd ? taql(dc, s) : (q = query(readtable(dc), s); MSv2.nrow(q) >= 0 && collect(column(q, "ID")[:]))
        catch e
            if e isa Union{StackOverflowError,OutOfMemoryError,InexactError,OverflowError,AssertionError,UndefVarError,
                           UndefRefError,BoundsError,KeyError,StringIndexError,DomainError,InterruptException}
                forbidden[string(typeof(e))] = get(forbidden, string(typeof(e)), 0) + 1
                length(examples) < 8 && push!(examples, string(typeof(e), ": ", first(s, 100)))
            end
        end
    end
    @test isempty(forbidden)
    isempty(forbidden) || println("forbidden exceptions from garbage input: ", forbidden, "\n  ", join(examples, "\n  "))
end
