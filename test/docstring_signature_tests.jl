# Phase 397: the signature lines at the top of every exported function's docstring (`query(t, wherestr; select=...)`)
# must match a real method: some method takes that many positional arguments, and every keyword named is a keyword
# of some method.  (Docstrings are the API reference; a renamed keyword or a dropped argument leaves them lying.)
# The extensions are loaded first, so the stubs' real methods exist.
import SOFA, EarthOrientation, Unitful, UnitfulAngles, UnitfulAstro, HDF5
using REPL, Markdown

@testset "docstring signatures match the methods (Phase 397)" begin
    function sigs(name)
        md = try Base.Docs.doc(Base.Docs.Binding(MeasurementSets, name)) catch; return String[] end
        out = String[]
        walk(x) = x isa Markdown.MD ? foreach(walk, x.content) :
                  x isa Markdown.Code ? foreach(l -> match(r"^\w[\w!.]*\(.*\)", strip(l)) === nothing || push!(out, strip(l)), split(x.code, '\n')) : nothing
        walk(md)
        return out
    end
    kwnames(f) = (s = Set{Symbol}(); for m in methods(f); try; union!(s, Base.kwarg_decl(m)); catch; end; end; s)
    problems = String[]; nsig = 0
    for name in names(MeasurementSets)
        isdefined(MeasurementSets, name) || continue
        f = getfield(MeasurementSets, name); f isa Function || continue
        for sg in sigs(name)
            nsig += 1
            call = strip(first(split(sg, r"\s*(->|→)\s*")))
            ex = try Meta.parse(call) catch; push!(problems, "$name: cannot parse `$sg`"); continue end
            ex isa Expr && ex.head === :call && ex.args[1] === name || continue
            pos = Any[]; kws = Symbol[]; nopt = 0; spread = false
            for a in ex.args[2:end]
                if a isa Expr && a.head === :parameters
                    for k in a.args
                        k isa Symbol && push!(kws, k)
                        k isa Expr && k.head in (:kw, :(=)) && k.args[1] isa Symbol && push!(kws, k.args[1])
                        k isa Expr && k.head === :(...) && (spread = true)
                    end
                elseif a isa Expr && a.head in (:kw, :(=)); nopt += 1                  # `freq=default`: an optional positional
                else push!(pos, a) end
            end
            known = kwnames(f)
            spread || for k in kws
                k in known || push!(problems, "$name: keyword `$k` of `$sg` is not a keyword of any method")
            end
            n = count(a -> !(a isa Expr && a.head === :(...)), pos)
            hasva = any(a -> a isa Expr && a.head === :(...), pos)
            ok = hasva || any(methods(f)) do m
                ps = Base.unwrap_unionall(m.sig).parameters[2:end]
                va = !isempty(ps) && Base.isvarargtype(ps[end])
                np = length(ps) - (va ? 1 : 0)
                va ? n >= np : (np >= n && np <= n + nopt)
            end
            ok || push!(problems, "$name: no method takes $n positional arguments for `$sg`")
        end
    end
    @test nsig > 80
    @test isempty(problems) || (foreach(println, problems); false)
end
