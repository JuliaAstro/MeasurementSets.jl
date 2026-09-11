using Documenter, MeasurementSets

# Keep the site's Changelog page(s) in step with the repo's CHANGELOG.md
# (git-ignored; regenerated on every build). The rendered HTML for a
# single-page changelog eventually crosses Documenter's 200 KiB
# hard-fail size threshold (100 KiB just warns) as more phases are
# appended -- so the source is auto-paginated into
# `changelog.md`, `changelog-2.md`, … at `### Phase` boundaries, each
# capped well under that limit, with "newer"/"older" nav links between
# them. Splitting only ever happens here at build time; the repo-root
# CHANGELOG.md itself stays one plain, ungrouped file (normal for
# GitHub, which has no such limit).
const CHANGELOG_CHUNK_BYTES = 55_000   # raw-markdown budget per page (~95 KiB HTML observed, under the 100 KiB warn threshold)

changelog_pages = let src = read(joinpath(@__DIR__, "..", "CHANGELOG.md"), String)
    src = replace(src, "[README](README.md)" => "[Home](index.md)")
    # split right before every top-level phase heading; keep the
    # leading preamble (title + intro prose) attached to the first chunk
    heads = [first(m) for m in findall(r"(?m)^### ", src)]
    bounds = [1; heads; ncodeunits(src) + 1]
    sections = [src[bounds[i]:prevind(src, bounds[i+1])] for i in 1:length(bounds)-1]
    chunks = String[]
    cur = IOBuffer()
    for s in sections
        if position(cur) > 0 && position(cur) + ncodeunits(s) > CHANGELOG_CHUNK_BYTES
            push!(chunks, String(take!(cur)))
        end
        write(cur, s)
    end
    position(cur) > 0 && push!(chunks, String(take!(cur)))
    names = length(chunks) == 1 ? ["changelog.md"] :
            ["changelog.md"; ["changelog-$i.md" for i in 2:length(chunks)]]
    for (i, (name, body)) in enumerate(zip(names, chunks))
        nav = IOBuffer()
        i > 1 && println(nav, "[← older entries](", names[i-1], ")\n")
        print(nav, body)
        i < length(chunks) && println(nav, "\n[newer entries →](", names[i+1], ")")
        write(joinpath(@__DIR__, "src", name), String(take!(nav)))
    end
    length(chunks) == 1 ? "changelog.md" :
        ["changelog.md"; [("Changelog (part $i)" => names[i]) for i in 2:length(names)]]
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
        "API reference" => ["api.md", "Part 2" => "api-2.md", "Measures" => "api-measures.md"],
        "Changelog"     => changelog_pages,
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
