# TiledStMan / TiledShapeStMan / TiledColumnStMan tests against the sample MS.

@testset "TSM structural" begin
    t = readtable(SAMPLE_MS; precision=:full)   # byte-exact decode checks

    uvw = getcell(t, "UVW", 1)
    @test uvw isa AbstractVector{Float64} && size(uvw) == (3,)

    d = getcell(t, "DATA", 1)
    @test eltype(d) == ComplexF32 && size(d) == (4, 64)

    f = getcell(t, "FLAG", 1)
    @test eltype(f) == Bool && size(f) == (4, 64)

    @test size(getcell(t, "WEIGHT", 1)) == (4,)
    @test size(getcell(t, "SIGMA", 1)) == (4,)

    # WEIGHT_SPECTRUM / FLAG_CATEGORY are defined-but-never-written in the
    # full MS; the fixture drops them on copy. Either way: not usable data.
    if "WEIGHT_SPECTRUM" in columnnames(t)
        @test_throws Exception getcolumn(t, "WEIGHT_SPECTRUM")
    end

    uvwcol = getcolumn(t, "UVW")
    @test length(uvwcol) == nrow(t)
    @test uvwcol[1] == getcell(t, "UVW", 1)
    @test uvwcol[end] == getcell(t, "UVW", nrow(t))
end

if _HAVE_CASACORE
    _cccell(c, r) = ndims(c) == 1 ? c[r] :
                    c[ntuple(_ -> Colon(), ndims(c) - 1)..., r]

    @testset "TSM vs casacore" begin
        t = readtable(SAMPLE_MS; precision=:full)   # byte-exact decode checks
        ct = CCT.Table(SAMPLE_MS)
        cols = Dict(n => ct[Symbol(n)] for n in
                    ("UVW", "DATA", "FLAG", "WEIGHT", "SIGMA"))
        probe = Tuple(unique(clamp.((1, 2, 37, 1000, nrow(t) ÷ 2, nrow(t)), 1, nrow(t))))
        for (n, col) in cols
            @testset "$n" begin
                for r in probe
                    @test getcell(t, n, r) == collect(_cccell(col, r))
                end
            end
        end

        # whole-column bulk path (UVW is only ~235 MB)
        uvw = getcolumn(t, "UVW")
        cU = cols["UVW"]
        @test all(uvw[r] == collect(_cccell(cU, r)) for r in probe)

        # Phase 234: `getcolumn`/`getcell` for a Bool tiled column (`FLAG`)
        # matches casacore's whole-column read exactly -- pins the
        # `read_plane`/`read_cube_whole` bit-unpack fast path (`_rd_bits!`)
        # against a real interop oracle, not just self-consistency.
        flagcol = getcolumn(t, "FLAG")
        cF = cols["FLAG"]
        @test length(flagcol) == nrow(t)
        @test all(flagcol[r] == collect(_cccell(cF, r)) for r in 1:nrow(t))
    end
end

@testset "TSM Bool tile read — allocation regression (Phase 234)" begin
    # `read_plane`'s old `Bool` branch (a doubly-nested `CartesianIndices`
    # per-bit walk, taken unconditionally regardless of tiling) allocated
    # ~3,100 times / ~90 KiB per `getcell` for a 4x64 `FLAG` plane --
    # ~100x more than the equal-size `DATA` cell via the unsafe-pointer
    # `_rd_run!` fast path, live-measured against a real casacore
    # (Casacore.jl) cross-check on the real ALMA MS (111x wall-clock).
    # `FLAG` now shares the SAME contiguous-run fast path via `_rd_bits!`
    # (the bit-packed counterpart of `_rd_run!`) -- assert it allocates no
    # more per cell than `DATA`'s own already-fast path, not orders of
    # magnitude more.
    t = readtable(SAMPLE_MS; precision=:full)
    n = min(200, nrow(t))

    getcell(t, "FLAG", 1); getcell(t, "DATA", 1)              # warm up (compile)
    GC.gc()
    a_flag = @allocated for r in 1:n
        getcell(t, "FLAG", r)
    end
    GC.gc()
    a_data = @allocated for r in 1:n
        getcell(t, "DATA", r)
    end
    # generous bound (Bool cells are 1/8 the on-disk bytes of ComplexF32,
    # so this is deliberately loose -- the old code was ~100x worse, not
    # merely "somewhat more")
    @test a_flag < 3 * a_data
end
