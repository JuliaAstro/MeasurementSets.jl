# IncrementalStMan tests against the sample MS.
#
# In this MS only MAIN's metadata columns use ISM (all scalar Int32/Float64);
# the direct-array and string ISM paths are implemented but not exercised here.

const _MAIN_ISM = ("TIME", "INTERVAL", "EXPOSURE", "FEED1", "FEED2",
                   "FIELD_ID", "ARRAY_ID", "OBSERVATION_ID", "PROCESSOR_ID",
                   "SCAN_NUMBER", "STATE_ID", "TIME_CENTROID")

@testset "ISM structural" begin
    t = readtable(SAMPLE_MS)

    time = getcolumn(t, "TIME")
    @test length(time) == nrow(t)
    @test eltype(time) == Float64
    @test getcell(t, "TIME", 1) == time[1]
    @test getcell(t, "TIME", nrow(t)) == time[end]
    @test getcell(t, "TIME", 4_000_000) == time[4_000_000]

    @test unique(getcolumn(t, "INTERVAL")) == [3.0]     # constant in this MS
    @test eltype(getcolumn(t, "FIELD_ID")) == Int32
end

if _HAVE_CASACORE
    @testset "ISM vs casacore" begin
        t = readtable(SAMPLE_MS)
        ct = CCT.Table(SAMPLE_MS)
        for name in _MAIN_ISM
            @test getcolumn(t, name) == collect(ct[Symbol(name)][:])
        end
        # a few random cells too
        for name in ("TIME", "SCAN_NUMBER"), r in (1, 12345, 5_000_000, nrow(t))
            @test getcell(t, name, r) == ct[Symbol(name)][r]
        end
    end
end
