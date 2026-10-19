# Child process for the Phase 448 thread-safety test (run with `julia -t N`): the block reader of tiled array columns
# (`ChunkedColumn` / `getrows`, Phase 441) and the in-place cell patch / touched-cell tracking of edit sessions (Phases
# 437, 443) under many tasks at once.  Queries over one shared table, per-cell reads and edits of private copies must all
# equal the serial results; exit code 0 = all equal, 1 = a difference or an exception.
using MeasurementSets, Random
const MSv2 = MeasurementSets
rounds = parse(Int, ARGS[1]); base = mktempdir(); N = 9000       # > CHUNK_ROWS, so the block reader refills many times
d = joinpath(base, "t")
rng0 = MersenneTwister(448)
D = [rand(rng0, ComplexF32, 2, 4) for _ in 1:N]; F = [rand(rng0, Bool, 2, 4) for _ in 1:N]
U = [rand(rng0, 3) for _ in 1:N]
K = Int32.(1 .+ (0:N-1) .% 7); X = rand(rng0, N); R = rand(rng0, Bool, N)
write_table(d, "T", Pair{String,Any}["K" => K, "X" => X, "R" => R, "DATA" => D, "FLAG" => F, "U" => U];
            nrow = N, tsm = [["DATA", "FLAG"]], tcm = [["U"]])
qs = ["any(FLAG)", "mean(abs(DATA)) > 0.5", "real(DATA[1,1]) > 0.5", "U[1] > 0.5 AND K == 3", "ntrue(FLAG) > 4", "sum(U) > 1.5"]
truth = Dict(q => MSv2.query(readtable(d), q).rows for q in qs)
bad = String[]; lk = ReentrantLock(); report(s) = lock(() -> push!(bad, s), lk)
for r in 1:rounds
    t = readtable(d)                                              # one table shared by every task of the round
    @sync for k in 1:12
        Threads.@spawn try
            rng = MersenneTwister(r * 100 + k)
            for it in 1:6
                x = rand(rng, 1:4)
                if x == 1                                         # block-streamed queries over the shared table
                    q = rand(rng, qs)
                    MSv2.query(t, q).rows == truth[q] || report("query $q differs")
                elseif x == 2                                     # per-cell reads (plane + layout caches)
                    i = rand(rng, 1:N)
                    MSv2.getcell(t, "DATA", i) == D[i] || report("DATA[$i] differs")
                    MSv2.getcell(t, "FLAG", i) == F[i] || report("FLAG[$i] differs")
                    MSv2.getcell(t, "U", i) == U[i] || report("U[$i] differs")
                elseif x == 3                                     # a whole tiled column and its block
                    a = MSv2.getcolumn(t, "DATA")
                    (length(a) == N && a[N] == D[N] && a[1] == D[1]) || report("getcolumn DATA differs")
                else                                              # edit session on a private copy: cell patch + readback
                    w = joinpath(base, "w$(r)_$(k)_$it"); cp(d, w)
                    idx = sort(unique(rand(rng, 1:N, 20))); newx = rand(rng, length(idx)); newr = rand(rng, Bool, length(idx))
                    edit(w) do e
                        for (j, i) in enumerate(idx); e[:X][i] = newx[j]; e[:R][i] = newr[j]; end
                    end
                    tw = readtable(w)
                    ex = copy(X); er = copy(R); ex[idx] = newx; er[idx] = newr
                    (MSv2.column(tw, "X")[:] == ex && MSv2.column(tw, "R")[:] == er) || report("edit readback differs")
                    MSv2.getcell(tw, "DATA", idx[1]) == D[idx[1]] || report("edit disturbed DATA")
                end
            end
        catch e
            report("exception: " * first(replace(sprint(showerror, e), '\n' => ' '), 200))
        end
    end
end
println(isempty(bad) ? "ALL OK" : join(unique(bad)[1:min(end, 8)], "\n"))
exit(isempty(bad) ? 0 : 1)
