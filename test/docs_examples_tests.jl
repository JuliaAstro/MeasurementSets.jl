# Phase 396: the code examples in README.md and the guide / concepts / index pages are run against the sample MS.
# Documentation rots when an API changes (`ms.MAIN`, which the guide has used since Phase 26, never worked, and one
# example used `mean` without importing it); this keeps the examples honest.  Fragments that are illustrative
# (an install snippet, placeholders such as `pointing`, hypothetical tables with columns `A` and `B`) are skipped by
# substring; every other statement must run.
import Tables

const _DOC_ROOT = dirname(@__DIR__)
const _DOC_SKIP = ("using Pkg", "Pkg.develop", "Pkg.add", "angular_separation(pointing", "correct_flux(pb, apparent_flux", "\"my.ms\"",
                   "dst.ms", "INSERT INTO t (A, B)", "SELECT A, B AS BB")

function _doc_blocks(file)
    out = String[]; lines = readlines(file); i = 1
    while i <= length(lines)
        if startswith(lines[i], "```julia")
            j = i + 1
            while j <= length(lines) && !startswith(lines[j], "```"); j += 1; end
            push!(out, join(lines[i+1:j-1], "\n")); i = j
        end
        i += 1
    end
    return out
end

@testset "documentation examples run (Phase 396)" begin
    files = ["README.md", joinpath("docs", "src", "index.md"), joinpath("docs", "src", "concepts.md"), joinpath("docs", "src", "guide.md"), joinpath("docs", "src", "performance.md")]
    sample = joinpath(@__DIR__, "data", "sample.ms")
    if all(f -> isfile(joinpath(_DOC_ROOT, f)), files) && isdir(sample)
        for f in files
            work = mktempdir(); my = joinpath(work, "my.ms"); cp(sample, my)
            subst(s) = replace(s, "rows=1:2000" => "rows=1:500", "rows = 1:2000" => "rows = 1:500", "using DataFrames, Tables" => "using Tables", "/path/to/my.ms" => my, "/tmp/" => work * "/", "/path/to/" => work * "/")
            mod = Module(:DocRun)
            Core.eval(mod, :(using MeasurementSets, Statistics))
            Core.eval(mod, :(import SOFA, EarthOrientation, Unitful, UnitfulAngles, UnitfulAstro))
            Core.eval(mod, :(using Unitful: @u_str))
            Core.eval(mod, :(DataFrame(x) = $(Tables.columntable)(x)))          # stand-in: DataFrames.jl is not a test dependency
            Core.eval(mod, :(main = MeasurementSets.readtable($my)))             # variables the prose introduces
            Core.eval(mod, :(ms = MeasurementSets.MeasurementSet($my)))
            Core.eval(mod, :(t = MeasurementSets.readtable($my)))
            Core.eval(mod, :(other = MeasurementSets.readtable($(joinpath(sample, "STATE")))))
            ran = 0
            for code in _doc_blocks(joinpath(_DOC_ROOT, f))
                for st in Meta.parseall(subst(code)).args
                    st isa LineNumberNode && continue
                    any(s -> occursin(s, string(st)), _DOC_SKIP) && continue
                    ran += 1
                    ok = try; Core.eval(mod, st); true; catch e
                        @info "documentation example failed" file=f statement=first(string(st), 140) error=first(sprint(showerror, e), 200)
                        false
                    end
                    @test ok
                end
            end
            @test ran > 0 || f == joinpath("docs", "src", "index.md")
        end
    end
end
