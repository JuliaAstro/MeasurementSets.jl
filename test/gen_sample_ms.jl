# Regenerate `test/data/sample.ms` -- the small MeasurementSet fixture the
# data-dependent tests run against by default.
#
# Not run by the test suite. Run it by hand when the fixture needs to
# change:
#
#     MEASUREMENTSETS_TEST_MS=/path/to/a/real.ms \
#         julia --project=. test/gen_sample_ms.jl
#
# It is a `copyms` row-slice of a real ALMA MS:
#   * MAIN         -> first 600 rows (spans 2 integrations -> exercises the
#                     IncrementalStMan run-length + change paths; covers all
#                     26 antennas; both flagged and unflagged rows)
#   * POINTING     -> first 150 rows
#   * SYSPOWER     -> first 150 rows
#   * every other subtable -> full (they are already small; keeping them
#     whole means the exact row-count / dimension assertions in
#     `metadata_tests.jl` etc. stay valid)
#
# The MAIN cell shape (4 pol x 64 chan) and the storage-manager mix
# (StandardStMan / IncrementalStMan / TiledShapeStMan / TiledColumnStMan)
# are preserved by `copyms`. `FLAG_CATEGORY` / `WEIGHT_SPECTRUM` are
# "defined but never written" in the source, so `copyms` drops them;
# `FLAG_CATEGORY` (schema-required) is re-added here as an empty column so
# `validate` stays clean.

using MeasurementSets

const SRC = get(ENV, "MEASUREMENTSETS_TEST_MS",
    "/Users/paul/Development/MSv2/data/24A-005.sb45337587.eb46111741.60454.422525601854.ms")
const DST = joinpath(@__DIR__, "data", "sample.ms")

isdir(SRC) || error("source MS not found: $SRC (set MEASUREMENTSETS_TEST_MS)")
isdir(DST) && rm(DST; recursive = true)

copyms(SRC, DST; rows = 1:600,
       subtable_rows = Dict("POINTING" => 1:150, "SYSPOWER" => 1:150))

edit(DST) do t
    addcolumn!(t, "FLAG_CATEGORY")     # schema-required; empty (VariableShape)
end

# table.lock is per-open runtime state -- casacore recreates it. Don't ship it.
for f in readdir(DST; join = true)
    isfile(joinpath(f, "table.lock")) && rm(joinpath(f, "table.lock"))
end
isfile(joinpath(DST, "table.lock")) && rm(joinpath(DST, "table.lock"))

@info "wrote fixture" DST filesize_MB = round(
    sum(filesize, [joinpath(root, f) for (root, _, fs) in walkdir(DST) for f in fs]) / 1e6;
    digits = 2)
