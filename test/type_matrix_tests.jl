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
        if ok && _HAVE_CASACORE && !(m === :tsm && sh === nothing)   # Phase 365: fixed-shape tiled columns are cross-checked too
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

# Phase 366: variable-shape arrays (including the tiled managers, which Casacore.jl cannot
# read) written by us, read back by REAL TaQL (nelements / ndim / sum): sweep, no bug found.
@testset "variable-shape arrays read by real TaQL (Phase 366)" begin
    if _HAVE_TAQL
        rng = MSv2.Random.MersenneTwister(366)
        gen(::Type{Bool}) = rand(rng, Bool)
        gen(T::Type{<:Integer}) = T(rand(rng, 0:100))
        gen(T::Type{<:AbstractFloat}) = T(rand(rng) * 100)
        gen(::Type{Complex{T}}) where {T} = Complex{T}(rand(rng) * 10, rand(rng) * 10)
        nfail = 0
        for T in (Bool, UInt8, Int16, Int32, Float32, Float64, ComplexF32), nd in 1:3, m in (:tsm, :tcell, :ssm, :ism)
            N = rand(rng, 1:40)
            col = [reshape([gen(T) for _ in 1:prod(sz)], sz...) for sz in (Tuple(rand(rng, 1:4, nd)) for _ in 1:N)]
            d = joinpath(mktempdir(), "t")
            kw = m === :tsm ? (; tsm=[["X"]]) : m === :tcell ? (; tcell=[["X"]]) : m === :ism ? (; ism=["X"]) : (;)
            write_table(d, "T", Pair{String,Any}["X" => col]; nrow=N, kw...)
            se = T <: Bool ? "ntrue(X)" : T <: Complex ? "sum(abs(X))" : "sum(X)"
            r = _taqlcmd("SELECT nelements(X) AS NE, ndim(X) AS ND, $se AS S FROM \$1", d)
            ws = T <: Bool ? count.(col) : T <: Complex ? [sum(abs.(Complex{Float64}.(c))) for c in col] : [sum(Float64.(c)) for c in col]
            ok = [r[:NE][i] for i in 1:N] == length.(col) && all(i -> r[:ND][i] == nd, 1:N) &&
                 all(i -> isapprox(r[:S][i], ws[i]; rtol=1e-4), 1:N)
            ok || (nfail += 1; @info "variable-shape TaQL read failed" T nd m)
        end
        @test nfail == 0
    end
end

# Phase 367: extreme values (NaN, +-Inf, -0.0, subnormal / max floats, integer limits) round-trip
# bit-exactly through StandardStMan / IncrementalStMan (scalar, fixed and variable arrays, both
# byte orders), in our reader and Casacore.jl: sweep, no bug found.
@testset "extreme values round-trip (Phase 367)" begin
    rng = MSv2.Random.MersenneTwister(367)
    special(::Type{T}) where {T<:AbstractFloat} = T[NaN, Inf, -Inf, 0, -0.0, floatmin(T), floatmax(T), -floatmax(T), nextfloat(T(0)), T(1) / 3]
    special(::Type{Complex{T}}) where {T} = vec([Complex{T}(a, b) for a in special(T)[1:6], b in special(T)[[1, 2, 5, 10]]])
    special(::Type{T}) where {T<:Integer} = T[typemin(T), typemax(T), 0, 1, T(typemax(T) ÷ 2)]
    special(::Type{Bool}) = [true, false]
    isame(a, b) = a isa AbstractFloat ? (isnan(a) ? isnan(b) : (a == b && signbit(a) == signbit(b))) :
                  a isa Complex ? isame(real(a), real(b)) && isame(imag(a), imag(b)) : isequal(a, b)
    nfail = 0
    for T in (Bool, UInt8, Int16, Int32, UInt32, Int64, Float32, Float64, ComplexF32, ComplexF64),
        m in (:ssm, :ism), endian in (:little, :big), shape in (:scalar, :fixed, :var)
        sp = special(T); N = rand(rng, 20:120); mk() = rand(rng, sp)
        col = shape === :scalar ? [mk() for _ in 1:N] :
              shape === :fixed ? [reshape([mk() for _ in 1:4], 2, 2) for _ in 1:N] :
              [[mk() for _ in 1:rand(rng, 1:4)] for _ in 1:N]
        shape === :scalar && m === :ism && (col = [col[(i ÷ 7) + 1] for i in 0:N-1])
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => col]; nrow=N, endian, (m === :ism ? (; ism=["X"]) : (;))...)
        got = column(readtable(d), "X")[:]
        ok = all(i -> got[i] isa AbstractArray ? all(isame.(got[i], col[i])) : isame(got[i], col[i]), 1:N)
        if ok && _HAVE_CASACORE
            cc = CCT.Table(d)[:X]; nd = ndims(cc)
            cv = shape === :scalar ? [cc[i] for i in 1:N] :
                 shape === :var ? [vec(collect(cc[i])) for i in 1:N] :
                 (arr = cc[ntuple(_ -> Colon(), nd)...]; [Array(selectdim(arr, nd, i)) for i in 1:N])
            ok = all(i -> cv[i] isa AbstractArray ? (length(cv[i]) == length(col[i]) && all(isame.(vec(cv[i]), vec(col[i])))) : isame(cv[i], col[i]), 1:N)
        end
        ok || (nfail += 1; @info "extreme value round trip failed" T m endian shape)
    end
    @test nfail == 0
end
