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

# Phase 446: how long each test file takes (printed as it finishes, so a slow CI job can be read off its log)
function timed_include(f)
    t0 = time()
    include(f)
    println("TEST FILE ", rpad(f, 36), round(time() - t0; digits = 1), " s")
end

@testset "MeasurementSets" begin
    timed_include("aqua_tests.jl")
    timed_include("aipsio_tests.jl")
    timed_include("docstring_tests.jl")
    timed_include("casacore_crosscheck.jl")       # defines _HAVE_CASACORE / CCT

    if isdir(SAMPLE_MS)
        timed_include("metadata_tests.jl")
        timed_include("ssm_tests.jl")
        timed_include("tsm_tests.jl")
        timed_include("ism_tests.jl")
        timed_include("api_tests.jl")
        timed_include("tables_tests.jl")
        timed_include("schema_tests.jl")
        timed_include("precision_tests.jl")
        timed_include("blockcolumn_tests.jl")
        timed_include("perf_guard_tests.jl")
    else
        @info "SAMPLE_MS not found; skipping data-dependent tests" SAMPLE_MS
    end

    timed_include("taql_helpers.jl")              # defines _HAVE_TAQL / _taqlcmd / _taql_create
    timed_include("writer_tests.jl")
    timed_include("indirect_tests.jl")
    timed_include("ism_writer_tests.jl")
    timed_include("tsm_multicol_tests.jl")
    timed_include("type_matrix_tests.jl")
    timed_include("reftable_tests.jl")
    timed_include("engine_tests.jl")
    timed_include("edit_tests.jl")
    timed_include("lock_tests.jl")
    timed_include("bigtable_tests.jl")
    timed_include("crash_tests.jl")
    timed_include("dysco_tests.jl")
    timed_include("empty_undefined_tests.jl")
    timed_include("corrupt_tests.jl")
    timed_include("keywords_tests.jl")
    timed_include("endian_tests.jl")
    timed_include("robustness_tests.jl")
    timed_include("docs_examples_tests.jl")
    timed_include("docstring_signature_tests.jl")
    timed_include("msvalid_tests.jl")
    timed_include("container_tests.jl")
    timed_include("taql_query_tests.jl")
    timed_include("taql_fuzz_tests.jl")
    timed_include("taql_command_tests.jl")
    timed_include("units_tests.jl")
    timed_include("beam_tests.jl")
    if isdir(SAMPLE_MS)
        timed_include("measures_tests.jl")
        timed_include("taql_mscal_tests.jl")
    end
end
