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

@testset "TSM Bool WHOLE-COLUMN read — bulk path, not per-row (Phase 235)" begin
    # `_read_cube_bulk` (the bulk `getcolumn` fast path -- one shared
    # backing buffer for the whole column, added in Phase 35/68 for every
    # OTHER type) used to bail out for `Bool` entirely
    # (`T === Bool && return nothing`), forcing `getcolumn(t, "FLAG")` to
    # fall back to `[getcell(...) for r in 1:nrow]` -- ONE fresh
    # `Array{Bool}` allocation PER ROW for a whole-column read, even
    # though Phase 234 had already made each individual `getcell` fast.
    # `Bool` now shares the SAME single-backing-buffer bulk path as every
    # other type (via `_rd_bits!`); every row's cell is a zero-copy view
    # into it, not its own allocation.
    dir = mktempdir()
    n = 20_000
    F = [rand(Bool, 4, 8) for _ in 1:n]
    write_table(joinpath(dir, "t.ms"), "T", ["F" => F]; nrow=n, tsm=[["F"]])
    t = readtable(joinpath(dir, "t.ms"))
    @test columndesc(t, "F").manager == "TiledShapeStMan"

    c = getcolumn(t, "F")
    @test length(c) == n
    @test all(c[r] == F[r] for r in 1:n)                  # correctness unchanged
    # THE regression guard: every row's cell is a view sharing ONE
    # backing buffer (a fresh per-row `Array{Bool}(undef, ...)`, the old
    # fallback, would give each row an unrelated, non-shared buffer).
    @test parent(vec(c[1])) isa Vector{Bool}
    @test parent(vec(c[1])) === parent(vec(c[end]))

    # a real allocation comparison against the actual old-code-equivalent
    # (a per-row `getcell` loop is exactly what `getcolumn`'s fallback
    # used to reduce to for `Bool`) -- not a guessed byte count, which
    # turned out to undercount `Base.ReshapedArray`'s own wrapper cost on
    # top of the `SubArray` it wraps.
    getcolumn(t, "F"); [getcell(t, "F", r) for r in 1:n]  # warm up (compile)
    GC.gc()
    a_bulk = @allocated getcolumn(t, "F")
    GC.gc()
    a_perrow = @allocated [getcell(t, "F", r) for r in 1:n]
    @test a_bulk < a_perrow / 3   # live-measured ~10.6x; a loose 3x margin
end
