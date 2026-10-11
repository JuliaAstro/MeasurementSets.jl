# Child process for the Phase 392 thread-safety test (run with `julia -t N`): many tasks read the same
# freshly-opened tables at once -- first access to each column races to open its data manager.  Every
# value must equal the serially-read one; exit code 0 = all equal, 1 = a difference or an exception.
using MeasurementSets, Random
const MSv2 = MeasurementSets
rounds = parse(Int, ARGS[1]); base = mktempdir(); N = 300
d = joinpath(base, "t")
write_table(d, "T", Pair{String,Any}["I" => collect(1:N), "X" => Float64.(1:N) ./ 3, "S" => ["s$i"^(1 + i % 5) for i in 1:N], "B" => isodd.(1:N),
    "V" => [Float32[i, 2i, 3i] for i in 1:N], "M" => [reshape(Float64.(i .+ (1:6)), 2, 3) for i in 1:N], "R" => [collect(1:(i % 4 + 1)) for i in 1:N],
    "RS" => [fill("a$i", i % 3 + 1) for i in 1:N], "C" => ComplexF32.(1:N, 2), "E" => [Float32[i, -i] for i in 1:N], "Q" => zeros(N)];
    nrow=N, tsm=[["M"]], ism=["X"], engines=Dict("E" => (; kind=MSv2.CompressFloat(), scale=0.01f0, offset=0.0f0)),
    virtualtaql=Dict("Q" => "I * 2.0 + X"))
sample = joinpath(@__DIR__, "data", "sample.ms")
tabs = Tuple{String,Any}[(d, nothing), (sample, nothing)]
truth = Dict{String,Dict{String,Any}}()
for (p, _) in tabs
    r = readtable(p); truth[p] = Dict(nm => collect(MSv2.column(r, nm)[:]) for nm in MSv2.columnnames(r) if nm != "FLAG_CATEGORY")
end
bad = String[]; lk = ReentrantLock()
report(s) = lock(() -> push!(bad, s), lk)
for r in 1:rounds, (p, _) in tabs
    t = readtable(p); names = collect(keys(truth[p])); nrows = MSv2.nrow(t)
    @sync for k in 1:16
        Threads.@spawn try
            rng = MersenneTwister(r * 100 + k)
            for _ in 1:10
                nm = rand(rng, names)
                if rand(rng, Bool)
                    isequal(collect(MSv2.column(t, nm)[:]), truth[p][nm]) || report("whole column $nm of $(basename(p)) differs")
                else
                    i = rand(rng, 1:nrows)
                    isequal(MSv2.getcell(t, nm, i), truth[p][nm][i]) || report("cell $nm[$i] of $(basename(p)) differs")
                end
            end
        catch e
            report("exception: " * first(replace(sprint(showerror, e), '\n' => ' '), 200))
        end
    end
end
println(isempty(bad) ? "ALL OK" : join(unique(bad)[1:min(end, 8)], "\n"))
exit(isempty(bad) ? 0 : 1)
