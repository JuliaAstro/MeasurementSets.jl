# Child process of test/corrupt_tests.jl (Phase 376): corrupt random bytes of every file of a table
# (truncate / flip / zero a run / huge word / bump a word) and read everything back.  Every read must
# end in a Julia exception or success -- never a crash (heap corruption used to segfault here) and
# never a multi-gigabyte allocation (a corrupt count used to take 12-76 s or be killed).
# usage: julia --project=<repo> corrupt_fuzz_child.jl <mixed|big|multifile|engines|dysco|refs> <seed> <cases>
using MeasurementSets, Random
const MSv2 = MeasurementSets
get!(ENV, "MS_CORRUPT_KEEP", "")
kind = get(ARGS, 1, "mixed"); seed = parse(Int, get(ARGS, 2, "1")); ncase = parse(Int, get(ARGS, 3, "200"))
rng = MersenneTwister(seed)
N = 40
mixed(; kw...) = (root -> write_table(root, "T", Pair{String,Any}["I" => Int32.(1:N), "R" => rand(rng, N), "S" => ["s$i" * "x"^(i % 7) for i in 1:N], "B" => rand(rng, Bool, N),
        "FX" => [fill(1.0i, 3) for i in 1:N], "VA" => [rand(rng, rand(rng, 1:4)) for i in 1:N], "SA" => [["a$i", "b"] for i in 1:N],
        "TS" => [rand(ComplexF32, 2, 3) for _ in 1:N], "TV" => [rand(Float32, rand(rng, 1:3), 2) for _ in 1:N], "IS" => Int32.(rand(rng, 1:3, N))]; nrow=N,
        ism=["IS"], tsm=[["TS"], ["TV"]], keywords=Dict{String,Any}("K" => 1, "KS" => "x", "KR" => Dict("a" => [1, 2])), kw...))
function engines(root)
    write_table(root, "T", Pair{String,Any}["F" => [rand(rng, Float32, 3) for _ in 1:N], "C" => [rand(rng, ComplexF32, 2) for _ in 1:N], "G" => [rand(rng, Float32, 3) for _ in 1:N],
        "B" => [rand(rng, Bool, 2, 2) for _ in 1:N], "K" => Int32.(1:N)]; nrow=N,
        engines=Dict("F" => (; kind=MSv2.CompressFloat(), scale=0.01f0, offset=0f0), "C" => (; kind=MSv2.CompressComplex(), scale=0.01f0, offset=0f0),
                     "G" => (; kind=MSv2.ScaledArray(), scale=0.5, offset=0.0, stored_type=MSv2.TpInt), "B" => (; kind=MSv2.BitFlags(), stored_type=MSv2.TpInt)))
end
function dysco(root)
    nant = 4; nbl = nant * (nant - 1) ÷ 2 + nant; nt = 3; n = nbl * nt
    a1 = Int32[]; a2 = Int32[]; for t in 1:nt, i in 0:nant-1, j in i:nant-1; push!(a1, i); push!(a2, j); end
    write_table(root, "T", Pair{String,Any}["ANTENNA1" => a1, "ANTENNA2" => a2, "DATA" => [rand(rng, ComplexF32, 2, 4) for _ in 1:n], "WEIGHT_SPECTRUM" => [rand(rng, Float32, 2, 4) .+ 1 for _ in 1:n]]; nrow=n,
        ism=["ANTENNA1", "ANTENNA2"], dysco=[["DATA", "WEIGHT_SPECTRUM"]], dysco_spec=Dict("DATA" => (; antenna1=Int.(a1), antenna2=Int.(a2), rowsPerBlock=nbl)))
end
function refs(root)
    d = root * "_p"; mixed()(d)
    write_reftable(root, readtable(d), [1, 3, 5, 7])
end
builders = Dict("mixed" => mixed(), "big" => mixed(; endian=:big), "multifile" => mixed(; storage=:multifile, blocksize=512), "engines" => engines, "dysco" => dysco, "refs" => refs)
function readall(p)
    t = readtable(p)
    for c in MSv2.columnnames(t)
        col = column(t, c)
        try collect(col[:]) catch; end
        for i in (1, 7, MSv2.nrow(t)); try col[i] catch; end; end
    end
    try MSv2.keywords(t); MSv2.subtables(t) catch; end
    try query(t, "TRUE"); catch; end
end
if kind == "ismwords"     # deterministic: every 4-byte word of the used part of an ISM file set to extreme values
    root = joinpath(mktempdir(), "t")
    write_table(root, "T", Pair{String,Any}["X" => Float64.([1.0i + 0.5 * (i % 3) for i in 1:N]), "Y" => Int32.(rand(rng, 1:3, N))]; nrow=N, ism=["X", "Y"])
    f = joinpath(root, "table.f0"); orig = read(f)
    spots = vcat(collect(1:4:min(length(orig), 512 + 600)), collect(max(1, length(orig) - 200):4:length(orig) - 3))
    for pos in spots, val in (0xffffffff, 0x7fffffff, 0x00100000, 0x00000000)
        b = copy(orig); b[pos:pos+3] .= reinterpret(UInt8, [val]); write(f, b)
        try readall(root) catch e; end
    end
    println("DONE ismwords $(length(spots) * 4)"); exit(0)
end
base = joinpath(mktempdir(), "base"); builders[kind](base)
isdir(base) || (base = base)
files = sort(filter(f -> isfile(joinpath(base, f)), readdir(base)))
nslow = 0
for k in 1:ncase
    d = joinpath(mktempdir(), "c"); cp(base, d)
    f = rand(rng, files); p = joinpath(d, f); b = read(p)
    mode = rand(rng, 1:5); desc = ""
    if mode == 1 && length(b) > 2
        cut = rand(rng, 0:length(b)-1); write(p, b[1:cut]); desc = "truncate $f at $cut/$(length(b))"
    elseif mode == 2
        nb = copy(b); for _ in 1:rand(rng, 1:4); nb[rand(rng, 1:length(nb))] = rand(rng, UInt8); end; write(p, nb); desc = "flip $f"
    elseif mode == 3
        nb = copy(b); i = rand(rng, 1:length(nb)); j = min(length(nb), i + rand(rng, 1:64)); nb[i:j] .= 0; write(p, nb); desc = "zero $f $i:$j"
    elseif mode == 4
        nb = copy(b); if length(nb) >= 4; i = rand(rng, 1:length(nb)-3); nb[i:i+3] .= rand(rng, [0xff, 0x7f, 0x80], 4); end; write(p, nb); desc = "huge $f"
    else   # bump one 4-byte word by a small amount (plausible-but-wrong count / offset)
        nb = copy(b); if length(nb) >= 4; i = rand(rng, 1:length(nb)-3); nb[i+3] += rand(rng, UInt8(1):UInt8(5)); end; write(p, nb); desc = "bump $f"
    end
    println("case $k: $desc"); flush(stdout)
    ENV["MS_CORRUPT_KEEP"] == "" || (rm(ENV["MS_CORRUPT_KEEP"]; recursive=true, force=true); cp(d, ENV["MS_CORRUPT_KEEP"]))
    el = @elapsed(try readall(d) catch e; end); el > 15 && (println("   SLOW $(round(el, digits=1)) s: $desc"); global nslow += 1)
end
println("DONE $kind $seed slow=$nslow")
exit(nslow == 0 ? 0 : 3)
