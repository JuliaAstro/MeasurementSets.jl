using MeasurementSets
using Test

const MSv2 = MeasurementSets

# The MeasurementSet the data-dependent tests run against.  By default a
# small committed fixture (`test/data/sample.ms`, a 600-row `copyms` slice
# of a real ALMA MS -- see `test/gen_sample_ms.jl`); set
# `MEASUREMENTSETS_TEST_MS` to point at a full real MS instead (the tests
# derive their row/dimension expectations from the MS, so both work).
const SAMPLE_MS = get(ENV, "MEASUREMENTSETS_TEST_MS",
    joinpath(@__DIR__, "data", "sample.ms"))

@testset "MeasurementSets" begin
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
        include("precision_tests.jl")
    else
        @info "SAMPLE_MS not found; skipping data-dependent tests" SAMPLE_MS
    end

    include("taql_helpers.jl")              # defines _HAVE_TAQL / _taqlcmd / _taql_create
    include("writer_tests.jl")
    include("indirect_tests.jl")
    include("ism_writer_tests.jl")
    include("tsm_multicol_tests.jl")
    include("reftable_tests.jl")
    include("engine_tests.jl")
    include("edit_tests.jl")
    include("lock_tests.jl")
    include("dysco_tests.jl")
    include("container_tests.jl")
    include("taql_query_tests.jl")
    include("taql_command_tests.jl")
    include("units_tests.jl")
    if isdir(SAMPLE_MS)
        include("measures_tests.jl")
    end
end
