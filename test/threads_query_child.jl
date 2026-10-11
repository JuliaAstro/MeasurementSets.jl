# Child process for the Phase 393 thread-safety test (run with `julia -t N`): tasks evaluate TaQL-lite
# queries in parallel, many of them building new `regex()` / `pattern()` values -- the shared pattern cache
# used to be a plain Dict (corrupted: "Multiple concurrent writes to Dict", UndefRefError).  Exit 0 = every
# parallel result equals the serial one.
using MeasurementSets, Random
const MSv2 = MeasurementSets
d = joinpath(mktempdir(), "t")
write_table(d, "T", Pair{String,Any}["S" => ["name$(i % 97)_$i" for i in 1:200], "I" => collect(1:200), "X" => Float64.(1:200) ./ 7]; nrow=200)
t = readtable(d)
qs = ["I < 50 AND S LIKE 'name1%'", "S == pattern('name1*')", "S == regex('name[0-9]_[0-9]+')", "X > 5.0 OR I % 7 == 0", "S ~ p/name2*/"]
serial = Dict(q => collect(MSv2.column(query(t, q), "I")[:]) for q in qs)
bad = String[]; lk = ReentrantLock(); report(s) = lock(() -> push!(bad, s), lk)
@sync for k in 1:12
    Threads.@spawn try
        rng = MersenneTwister(k)
        for _ in 1:8
            q = rand(rng, qs)
            isequal(collect(MSv2.column(query(t, q), "I")[:]), serial[q]) || report("query differs: $q")
        end
        for j in 1:500                      # distinct patterns: fill the cache past its 2000-entry cap together
            query(t, "S == pattern('name$(rand(rng, 0:96))_*$(rand(rng, 1:9999))')")
            query(t, "S == regex('name$(rand(rng, 0:96))_[0-9]+$j')")
        end
    catch e
        report("exception: " * first(replace(sprint(showerror, e), '\n' => ' '), 200))
    end
end
println(isempty(bad) ? "ALL OK" : join(unique(bad)[1:min(end, 6)], "\n"))
exit(isempty(bad) ? 0 : 1)
