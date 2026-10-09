# Phase 382: a `"""` docstring is silently DROPPED when anything -- even a `#` comment or a helper function -- sits between it
# and the definition it documents.  That broke the Documenter build three times (Phases 160/212/228, then 379 and 380).
# This scans every source file: the line after a docstring (blank lines are transparent) must define the name the docstring's
# signature line starts with.
@testset "docstrings sit directly above what they document (Phase 382)" begin
    root = dirname(@__DIR__)
    files = String[]
    for dir in ("src", "ext"), (d, _, fs) in walkdir(joinpath(root, dir)), f in fs
        endswith(f, ".jl") && push!(files, joinpath(d, f))
    end
    @test length(files) > 40
    bad = String[]
    for f in files
        L = readlines(f); i = 1
        while i <= length(L)
            if L[i] == "\"\"\""                       # opening of a docstring (bare `\"\"\"` line)
                j = findnext(==("\"\"\""), L, i + 1)
                j === nothing && break
                sig = i + 1 <= length(L) ? L[i+1] : ""
                m = match(r"^    ([\w!.]+)[\s(\{\[]", sig)
                k = j + 1
                while k <= length(L) && isempty(strip(L[k])); k += 1; end
                if m !== nothing && k <= length(L)
                    name = split(m[1], '.')[end]
                    nxt = L[k]
                    # the documented line mentions the name (function / struct / const / macro / call form), or is a macro call
                    ok = occursin(name, nxt) || startswith(nxt, "@")
                    # a docstring above a comment is never attached
                    startswith(lstrip(nxt), "#") && (ok = false)
                    ok || push!(bad, "$(relpath(f, root)):$(j): docstring for `$name` is followed by: $(first(nxt, 70))")
                end
                i = j + 1
            else
                i += 1
            end
        end
    end
    @test isempty(bad)
    isempty(bad) || println(join(bad, "\n"))
end
