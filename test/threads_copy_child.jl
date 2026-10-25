# Child process for the Phase 473 thread-safety test (run with `julia -t N`): the chunked (streaming) copy of Phases
# 469-471 -- lazy `RowsView` columns, chunked tile-file appends, typed partial-range reads -- with many tasks copying the
# SAME source table at once (whole, by row range, and through a RefTable), plus a reader hammering the source.  Every
# copy must equal the serial one; exit code 0 = all equal, 1 = a difference or an exception.
using MeasurementSets, Random
const MSv2 = MeasurementSets
rounds = parse(Int, ARGS[1]); base = mktempdir(); N = 600
MSv2.TSM_STREAM_MIN_ROWS[] = 20; MSv2.TSM_STREAM_BYTES[] = 600     # several chunks per copy
d = joinpath(base, "t"); rng0 = MersenneTwister(473)
TS = [rand(rng0, ComplexF32, 2, 3) for _ in 1:N]; TF = [rand(rng0, Bool, 2, 3) for _ in 1:N]; UV = [rand(rng0, 3) for _ in 1:N]
K = Int32.(1:N); R = rand(rng0, N); S = ["s$i" for i in 1:N]
write_table(d, "T", Pair{String,Any}["K" => K, "R" => R, "S" => S, "TS" => TS, "TF" => TF, "UV" => UV, "UD" => [Float32[] for _ in 1:N]];
            nrow = N, tsm = [["TS", "TF"]], tcm = [["UV"]], tcell = [["UD"]])
bad = String[]; lk = ReentrantLock(); report(s) = lock(() -> push!(bad, s), lk)
function check(dst, rows)
    u = readtable(dst); rr = collect(rows)
    MSv2.nrow(u) == length(rr) || return "nrow"
    MSv2.column(u, "K")[:] == K[rr] || return "K"
    MSv2.column(u, "R")[:] == R[rr] || return "R"
    MSv2.column(u, "S")[:] == S[rr] || return "S"
    collect(MSv2.column(u, "TS")[:]) == TS[rr] || return "TS"
    collect(MSv2.column(u, "TF")[:]) == TF[rr] || return "TF"
    collect(MSv2.column(u, "UV")[:]) == UV[rr] || return "UV"
    return ""
end
for r in 1:rounds
    t = readtable(d)                                         # one source table shared by every task of the round
    @sync for k in 1:10
        Threads.@spawn try
            rng = MersenneTwister(r * 100 + k)
            for it in 1:3
                dst = joinpath(base, "o$(r)_$(k)_$it"); x = rand(rng, 1:4)
                if x == 1
                    copytable(dst, t); e = check(dst, 1:N)
                elseif x == 2
                    a = rand(rng, 1:N-50); b = rand(rng, a+25:N); copytable(dst, t; rows = a:b); e = check(dst, a:b)
                elseif x == 3
                    sel = sort(unique(rand(rng, 1:N, 80))); copytable(dst, MSv2.query(t, "TRUE"); rows = sel); e = check(dst, sel)
                else
                    for _ in 1:20; i = rand(rng, 1:N); MSv2.getcell(t, "TS", i) == TS[i] || (e = "read TS"); end   # concurrent reads of the source
                    e = ""
                end
                isempty(e) || report("copy kind $x differs in column $e")
                # no leftover temporary file of a streaming write
                isdir(dst) && any(f -> endswith(f, ".tmp"), readdir(dst; join = false)) && report("leftover .tmp")
            end
        catch err
            report("exception: " * first(replace(sprint(showerror, err), '\n' => ' '), 200))
        end
    end
end
println(isempty(bad) ? "ALL OK" : join(unique(bad)[1:min(end, 8)], "\n"))
exit(isempty(bad) ? 0 : 1)
