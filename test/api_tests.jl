# Phase 5: lazy Column type + indexing sugar.

@testset "Column API" begin
    t = readtable(SAMPLE_MS)

    tc = column(t, "TIME")
    @test tc isa AbstractVector{Float64}
    @test length(tc) == nrow(t)
    @test size(tc) == (nrow(t),)
    @test tc[1] == getcell(t, "TIME", 1)
    @test tc[3:6] == [getcell(t, "TIME", i) for i in 3:6]
    @test tc[:] == getcolumn(t, "TIME")
    @test collect(tc) == tc[:]
    @test_throws BoundsError tc[nrow(t) + 1]

    # indexing sugar returns a Column, not a description
    @test t[:TIME] isa Column
    @test t["TIME"] isa Column
    @test eltype(t[:UVW]) == Vector{Float64}
    @test size(t[:UVW][7]) == (3,)

    d = column(t, "DATA")
    @test eltype(d) == Matrix{ComplexF32}
    @test size(d[42]) == (4, 64)

    ms = MeasurementSet(SAMPLE_MS)
    @test ms[:DATA][10] == d[10]
    @test ms["ANTENNA1"][100] == column(t, "ANTENNA1")[100]

    # spot cross-check per storage manager (SSM / TSM / ISM)
    if _HAVE_CASACORE
        ct = CCT.Table(SAMPLE_MS)
        @test column(t, "ANTENNA1")[500] == ct[:ANTENNA1][500]        # SSM
        @test column(t, "TIME")[500] == ct[:TIME][500]                # ISM
        @test column(t, "UVW")[500] == collect(ct[:UVW][:, 500])      # TSM
    end
end
