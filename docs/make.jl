using Documenter, MeasurementSets

# Keep the site's Changelog page in step with the repo's CHANGELOG.md
# (git-ignored; regenerated on every build).  Rewrite the one repo-root
# relative link so it resolves inside the site.
let src = read(joinpath(@__DIR__, "..", "CHANGELOG.md"), String)
    src = replace(src, "[README](README.md)" => "[Home](index.md)")
    write(joinpath(@__DIR__, "src", "changelog.md"), src)
end

const REPO = "github.com/JuliaAstro/MeasurementSets.jl"

makedocs(
    sitename = "MeasurementSets.jl",
    modules  = [MeasurementSets],
    authors  = "Paul Barrett",
    format   = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical  = "https://juliaastro.org/MeasurementSets/stable/",
    ),
    repo     = Documenter.Remotes.GitHub("JuliaAstro", "MeasurementSets.jl"),
    pages = [
        "Home"          => "index.md",
        "Concepts"      => "concepts.md",
        "Guide"         => "guide.md",
        "API reference" => "api.md",
        "Changelog"     => "changelog.md",
    ],
    checkdocs = :exported,
)

# Deployment (the `docs` job in .github/workflows/CI.yml, via
# julia-actions/julia-docdeploy). `deploydocs` self-detects and no-ops
# outside a CI deploy context, but guard it explicitly to match the
# JuliaAstro convention.
if get(ENV, "CI", "false") == "true"
    deploydocs(
        repo = REPO,
        devbranch = "main",
        versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
        push_preview = true,
    )
end
