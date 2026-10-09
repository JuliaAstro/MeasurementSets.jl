# Phase 376: corrupted / truncated table files must give Julia errors -- never crash the process, never
# allocate gigabytes.  A random-corruption fuzz found (1) a segfault: IncrementalStMan's whole-column
# read wrote `out[r]` under `@inbounds` with row numbers taken from the file, (2) corrupt row counts in
# `table.dat` made every whole-column read try to allocate tens of gigabytes (casacore refuses such a
# table: "mismatch in #row"), (3) corrupt element / axis / hypercube counts in the AipsIO headers
# preallocated gigabytes or built enormous types (12-76 s per read).
@testset "row-count mismatch is an error (Phase 376)" begin
    N = 30
    for (nm, kw) in (("ssm", (;)), ("ism", (; ism=["X"])), ("tsm", (; tsm=[["X"]]))), endian in (:little, :big)
        d = joinpath(mktempdir(), "t")
        X = nm == "tsm" ? [fill(1.0i, 3) for i in 1:N] : Float64.(1:N)
        write_table(d, "T", Pair{String,Any}["X" => X, "K" => Int32.(1:N)]; nrow=N, endian, kw...)
        @test column(readtable(d), "X")[N] == (nm == "tsm" ? fill(30.0, 3) : 30.0)
        bytes = read(joinpath(d, "table.dat"))
        @test bytes[22:25] == reinterpret(UInt8, [hton(UInt32(N))])      # the row count in the "Table" object
        bytes[22:25] = reinterpret(UInt8, [hton(UInt32(N + 7))])
        write(joinpath(d, "table.dat"), bytes); rm(joinpath(d, "table.lock"); force=true)
        t = readtable(d)
        @test MSv2.nrow(t) == N + 7
        @test_throws ErrorException collect(column(t, "X")[:])
        @test_throws ErrorException collect(column(t, "K")[:])
    end
    # a count that would need gigabytes fails at once, not after allocating
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["X" => Float64.(1:N)]; nrow=N, ism=["X"])
    bytes = read(joinpath(d, "table.dat")); bytes[22:25] = reinterpret(UInt8, [hton(UInt32(4_000_000_000))])
    write(joinpath(d, "table.dat"), bytes); rm(joinpath(d, "table.lock"); force=true)
    t = readtable(d)
    @test (@elapsed(try collect(column(t, "X")[:]) catch; end)) < 5
end

@testset "corrupted table files never crash or exhaust memory (Phase 376)" begin
    child = joinpath(@__DIR__, "corrupt_fuzz_child.jl")
    proj = dirname(@__DIR__)
    for (kind, seed, n) in (("mixed", 11, 60), ("big", 12, 40), ("multifile", 13, 40), ("engines", 14, 40), ("dysco", 15, 40), ("refs", 16, 30), ("ismwords", 17, 0))
        r = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --project=$proj $child $kind $seed $n`); stdout=devnull, stderr=devnull))
        @test r.exitcode == 0          # 139 = segfault, 137 = killed (out of memory), 3 = a read took > 15 s
    end
end

# Phase 377 (x86 CI): a flipped bit in table.dat gave WEIGHT_SPECTRUM a 9764866 x 4 cell; a Dysco weight block holds one
# value per channel, so the block size could not catch it and the read built 30 gigabyte-sized zero-filled cells
# (35-80 s and swapping on x86-64).  The cell shape of every Dysco column must now agree with the DATA column's.
@testset "Dysco: a weight cell shape that disagrees with DATA is an error, not gigabytes (Phase 377)" begin
    a1 = Int32[0, 0, 1, 0, 0, 1]; a2 = Int32[1, 2, 2, 1, 2, 2]; nr = 6
    mk(wshape) = (d = joinpath(mktempdir(), "t");
        write_table(d, "T", Pair{String,Any}["TIME" => collect(5.0e9 .+ [1, 1, 1, 2, 2, 2]), "ANTENNA1" => a1, "ANTENNA2" => a2,
            "DATA" => [rand(ComplexF32, 2, 4) for _ in 1:nr], "WEIGHT_SPECTRUM" => [rand(Float32, wshape...) for _ in 1:nr]]; nrow=nr,
            ism=["TIME", "ANTENNA1", "ANTENNA2"], dysco=[["DATA", "WEIGHT_SPECTRUM"]],
            dysco_spec=Dict("DATA" => (; normalization=MSv2.AFNorm(), distribution=MSv2.TruncatedGaussian(), dataBitCount=10,
                                       weightBitCount=12, antenna1=Int.(a1), antenna2=Int.(a2), rowsPerBlock=3, dither=false))); d)
    t = readtable(mk((2, 4)))
    @test size(column(t, "WEIGHT_SPECTRUM")[1]) == (2, 4)
    t2 = readtable(mk((3, 4)))
    @test (@elapsed(@test_throws ErrorException collect(column(t2, "WEIGHT_SPECTRUM")[:]))) < 5
end
