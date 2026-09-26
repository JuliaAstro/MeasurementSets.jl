# Phase 265: element type × cell shape × storage manager matrix, both directions.
#
# * ours -> ours (always) and ours -> real casacore (`_HAVE_CASACORE`): every
#   `write_table` type (Bool, UInt8/uChar, Int16/Short, UInt16/uShort, Int32, UInt32/uInt,
#   Int64, Float32, Float64, ComplexF32, ComplexF64, String) as a scalar, a fixed-shape
#   1-D / 2-D array and a variable-shape array, bound to StandardStMan, IncrementalStMan
#   and the tiled managers.  Found: UInt8 / Int16 / UInt16 / UInt32 columns could not be
#   written (`_casatype_of`), and a fixed-shape String array bound to IncrementalStMan
#   crashed.  (Casacore.jl cannot read a variable-shape tiled column, so those are
#   ours-only.)
# * real casacore -> ours (`_HAVE_TAQL`): the same matrix created by TaQL.  Found: a
#   casacore-created fixed-shape array column (option FixedShape, NOT Direct) is
#   INDIRECT in StandardStMan / IncrementalStMan; we read every one as direct -- garbage.
@testset "column type × shape × manager matrix (Phase 265)" begin
    rng = MSv2.Random.MersenneTwister(3)
    N = 4
    gen(::Type{Bool}) = rand(rng, Bool)
    gen(::Type{String}) = MSv2.Random.randstring(rng, rand(rng, 0:12))
    gen(T::Type{<:Integer}) = T(rand(rng, 0:100))
    gen(T::Type{<:AbstractFloat}) = T(rand(rng) * 100)
    gen(::Type{Complex{T}}) where {T} = Complex{T}(rand(rng) * 10, rand(rng) * 10)
    types = [Bool, UInt8, Int16, UInt16, Int32, UInt32, Int64, Float32, Float64, ComplexF32, ComplexF64, String]
    shapes = [(:scalar, ()), (:fixed1, (3,)), (:fixed2, (2, 3)), (:var, nothing)]
    function mkcol(T, sh)
        sh === () && return [gen(T) for _ in 1:N]
        sh === nothing && return [[gen(T) for _ in 1:rand(rng, 1:4)] for _ in 1:N]
        [reshape([gen(T) for _ in 1:prod(sh)], sh...) for _ in 1:N]
    end
    same(a, b) = a isa AbstractArray ? (size(a) == size(b) && all(isequal.(a, b))) : isequal(a, b)
    nfail = 0
    for T in types, (sn, sh) in shapes, m in (:ssm, :ism, :tsm, :tcm)
        (m in (:tsm, :tcm) && (sh === () || T === String)) && continue
        (m === :tcm && sh === nothing) && continue
        col = mkcol(T, sh)
        dir = joinpath(mktempdir(), "t")
        kw = m === :ism ? (; ism=["X"]) : m === :tsm ? (; tsm=[["X"]]) : m === :tcm ? (; tcm=[["X"]]) : (;)
        ok = try
            write_table(dir, "T", Pair{String,Any}["X" => col]; nrow=N, kw...)
            got = column(readtable(dir), "X")[:]
            all(i -> same(got[i], col[i]), 1:N)
        catch
            false
        end
        ok || (nfail += 1; @info "type matrix (ours→ours) failed" T sn m)
        if ok && _HAVE_CASACORE && m !== :tsm
            cc = CCT.Table(dir)[:X]; nd = ndims(cc)
            cok = if sh === ()
                all(i -> isequal(cc[i], col[i]), 1:N)
            elseif sh === nothing
                all(i -> vec(collect(cc[ntuple(_ -> Colon(), nd - 1)..., i])) == vec(col[i]), 1:N)
            else
                arr = cc[ntuple(_ -> Colon(), nd)...]
                all(i -> vec(collect(selectdim(arr, nd, i))) == vec(col[i]), 1:N)
            end
            cok || (nfail += 1; @info "type matrix (ours→casacore) failed" T sn m)
        end
    end
    @test nfail == 0

    if _HAVE_TAQL
        tt = [("B", Bool, "rownumber()%2==0"), ("UC", UInt8, "rownumber()"), ("I2", Int16, "rownumber()*3"), ("U2", UInt16, "rownumber()*3"),
              ("I4", Int32, "rownumber()*3"), ("U4", UInt32, "rownumber()*3"), ("I8", Int64, "rownumber()*3"), ("R4", Float32, "rownumber()*1.5"),
              ("R8", Float64, "rownumber()*1.5"), ("C4", ComplexF32, "complex(rownumber(), 1)"), ("C8", ComplexF64, "complex(rownumber(), 1)"),
              ("S", String, "string(rownumber())")]
        want(T, i) = T === Bool ? i % 2 == 0 : T === String ? string(i) : T <: Integer ? (T === UInt8 ? T(i) : T(i * 3)) : T <: AbstractFloat ? T(i * 1.5) : T(i, 1)
        shp = [("scalar", "", "", ()), ("fixed3", " [SHAPE=[3]]", "array(#, [3])", (3,)), ("fixed23", " [SHAPE=[2,3]]", "array(#, [2,3])", (2, 3)),
               ("var", " [NDIM=1]", "array(#, [3])", (3,))]
        mg = [("ssm", ""), ("ism", " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"X\"]]"),
              ("tsm", " DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"TSM\", SPEC=[DEFAULTTILESHAPE=[2,2,2]], COLUMNS=[\"X\"]]"),
              ("tcm", " DMINFO [TYPE=\"TiledColumnStMan\", NAME=\"TCM\", SPEC=[TILESHAPE=[2,2,2]], COLUMNS=[\"X\"]]")]
        rfail = 0
        for (tn, T, ex) in tt, (sn, sd, arrex, cs) in shp, (mn, md) in mg
            (mn in ("tsm", "tcm") && (sn == "scalar" || T === String)) && continue
            (mn == "tcm" && sn == "var") && continue
            dir = joinpath(mktempdir(), "t")
            got = try
                _taql_create("CREATE TABLE $dir [X $tn$sd] LIMIT 4$md")
                _taqlcmd("UPDATE \$1 SET X = " * (sn == "scalar" ? ex : replace(arrex, "#" => ex)), dir)
                column(readtable(dir), "X")[:]
            catch
                nothing
            end
            ok = got !== nothing && all(i -> same(got[i], sn == "scalar" ? want(T, i) : fill(want(T, i), cs...)), 1:4)
            ok || (rfail += 1; @info "type matrix (casacore→ours) failed" tn sn mn)
        end
        @test rfail == 0
    end
end
