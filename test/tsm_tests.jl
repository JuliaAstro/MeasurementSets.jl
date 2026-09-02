# TiledStMan / TiledShapeStMan / TiledColumnStMan tests against the sample MS.

@testset "TSM structural" begin
    t = readtable(SAMPLE_MS)

    uvw = getcell(t, "UVW", 1)
    @test uvw isa AbstractVector{Float64} && size(uvw) == (3,)

    d = getcell(t, "DATA", 1)
    @test eltype(d) == ComplexF32 && size(d) == (4, 64)

    f = getcell(t, "FLAG", 1)
    @test eltype(f) == Bool && size(f) == (4, 64)

    @test size(getcell(t, "WEIGHT", 1)) == (4,)
    @test size(getcell(t, "SIGMA", 1)) == (4,)

    # WEIGHT_SPECTRUM / FLAG_CATEGORY are defined but never written
    @test_throws ErrorException getcolumn(t, "WEIGHT_SPECTRUM")

    uvwcol = getcolumn(t, "UVW")
    @test length(uvwcol) == nrow(t)
    @test uvwcol[1] == getcell(t, "UVW", 1)
    @test uvwcol[end] == getcell(t, "UVW", nrow(t))
end

if _HAVE_CASACORE
    _cccell(c, r) = ndims(c) == 1 ? c[r] :
                    c[ntuple(_ -> Colon(), ndims(c) - 1)..., r]

    @testset "TSM vs casacore" begin
        t = readtable(SAMPLE_MS)
        ct = CCT.Table(SAMPLE_MS)
        cols = Dict(n => ct[Symbol(n)] for n in
                    ("UVW", "DATA", "FLAG", "WEIGHT", "SIGMA"))
        probe = (1, 2, 37, 1000, 250_000, 5_000_000, nrow(t))
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
    end
end
