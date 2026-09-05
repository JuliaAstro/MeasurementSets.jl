using Documenter, MeasurementSetv2

# Keep the site's Changelog page in step with the repo's CHANGELOG.md
# (git-ignored; regenerated on every build).  Rewrite the one repo-root
# relative link so it resolves inside the site.
let src = read(joinpath(@__DIR__, "..", "CHANGELOG.md"), String)
    src = replace(src, "[README](README.md)" => "[Home](index.md)")
    write(joinpath(@__DIR__, "src", "changelog.md"), src)
end

makedocs(
    sitename = "MeasurementSetv2.jl",
    modules  = [MeasurementSetv2],
    authors  = "Paul Barrett",
    format   = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        edit_link  = nothing,          # no valid repo slug yet -> no "Edit on GitHub" links
        repolink   = nothing,
    ),
    remotes  = nothing,                # silence the `git remote` lookup (placeholder slug)
    pages = [
        "Home"          => "index.md",
        "Concepts"      => "concepts.md",
        "Guide"         => "guide.md",
        "API reference" => "api.md",
        "Changelog"     => "changelog.md",
    ],
    checkdocs = :exported,
)

# Deployment is intentionally not wired yet -- the GitHub repo slug is a
# placeholder (`github.com/Paul Barrett/...`).  Once it is real, append:
#
#   deploydocs(repo = "github.com/<owner>/MeasurementSetv2.jl", devbranch = "main")
#
# and add a docs job to .github/workflows/ (see the PkgTemplates default).
