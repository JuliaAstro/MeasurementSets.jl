# Child process for the Phase 429 thread-safety test (run with `julia -t N`): the caches of Phases 416-428 -- the per-table
# `Column` cache (+ its eviction), the SOFA astrometry context cache (more frames than it holds, so it is cleared while other
# tasks use it) and the compiled aggregate-argument cache -- under many tasks at once.  Every value must equal the serial one;
# exit code 0 = all equal, 1 = a difference or an exception.
using MeasurementSets, SOFA, Random
const MSv2 = MeasurementSets
rounds = parse(Int, ARGS[1]); base = mktempdir(); N = 3000
d = joinpath(base, "t")
write_table(d, "T", Pair{String,Any}["K" => Int32.(1 .+ (0:N-1) .% 7), "B" => Float64.(1:N) ./ 7, "C" => Float64.(N:-1:1), "S" => ["s$(i % 5)" for i in 1:N]]; nrow = N, ism = ["K"])
fr(k) = MSv2.MeasFrame(epoch = MSv2.MEpoch{MSv2.UTC}(58000.0 + 17.3k),
                       position = MSv2.MPosition{MSv2.ITRF}(2.2e6 + 1e4k, -5.4e6, -2.48e6 + 3e3k))
dirs = [MSv2.MDirection{MSv2.J2000}(0.1k, 0.05k - 0.5) for k in 1:12]
frames = [fr(k) for k in 1:40]                                   # more distinct frames than the astrometry cache holds (16)
truth = Dict((i, j, B) => MSv2.measconvert(dirs[i], B; frame = frames[j]) for i in 1:12, j in 1:40, B in (MSv2.AZEL, MSv2.HADEC, MSv2.APP))
sel = ["K" => "K", "a" => "gsum(B*C)", "b" => "gmean(sqrt(B)+C)", "n" => "gcount()"]
gtruth = MSv2.groupby(readtable(d), "K"; select = sel, orderby = ["K"])
bad = String[]; lk = ReentrantLock(); report(s) = lock(() -> push!(bad, s), lk)
for r in 1:rounds
    t = readtable(d)
    @sync for k in 1:16
        Threads.@spawn try
            rng = MersenneTwister(r * 100 + k)
            for _ in 1:20
                x = rand(rng, 1:4)
                if x == 1                                          # cached Column: first access races, eviction races
                    nm = rand(rng, ("K", "B", "C", "S")); i = rand(rng, 1:N)
                    MSv2.getcell(t, nm, i) == MSv2.column(readtable(d), nm)[i] || report("getcell $nm[$i] differs")
                elseif x == 2 && k == 1
                    MSv2._evict_dms!(t)                            # others hold a Column from before the eviction
                elseif x == 3                                      # astrometry context cache under eviction
                    i = rand(rng, 1:12); j = rand(rng, 1:40); B = rand(rng, (MSv2.AZEL, MSv2.HADEC, MSv2.APP))
                    got = MSv2.measconvert(dirs[i], B; frame = frames[j])
                    (got.lon == truth[(i, j, B)].lon && got.lat == truth[(i, j, B)].lat) || report("measconvert $i,$j,$B differs")
                else                                               # compiled aggregate arguments
                    g = MSv2.groupby(t, "K"; select = sel, orderby = ["K"])
                    (g.K == gtruth.K && g.a ≈ gtruth.a && g.b ≈ gtruth.b && g.n == gtruth.n) || report("groupby differs")
                end
            end
        catch e
            report("exception: " * first(replace(sprint(showerror, e), '\n' => ' '), 200))
        end
    end
end
println(isempty(bad) ? "ALL OK" : join(unique(bad)[1:min(end, 8)], "\n"))
exit(isempty(bad) ? 0 : 1)
