using MeasurementSetv2
using Test

const MSv2 = MeasurementSetv2

# A real ALMA MS on the developer's machine.  All data-dependent tests are
# skipped when it is not present (e.g. on CI).
const SAMPLE_MS = get(ENV, "MEASUREMENTSETV2_TEST_MS",
    "/Users/paul/Development/MSv2/data/24A-005.sb45337587.eb46111741.60454.422525601854.ms")

@testset "MeasurementSetv2" begin
    include("aipsio_tests.jl")
    include("casacore_crosscheck.jl")       # defines _HAVE_CASACORE / CCT

    if isdir(SAMPLE_MS)
        include("metadata_tests.jl")
        include("ssm_tests.jl")
        include("tsm_tests.jl")
        include("ism_tests.jl")
        include("api_tests.jl")
        include("tables_tests.jl")
        include("schema_tests.jl")
    else
        @info "SAMPLE_MS not found; skipping data-dependent tests" SAMPLE_MS
    end

    include("writer_tests.jl")
    include("indirect_tests.jl")
    include("ism_writer_tests.jl")
end
