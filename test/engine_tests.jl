# Phase 12: virtual column engines (ScaledArrayEngine, ScaledComplexData,
# CompressFloat, CompressComplex, CompressComplexSD, MappedArrayEngine).

const MSv2E = MeasurementSets

_engine_manager(r, vname) =
    r.managers[findfirst(m -> m.sequ == columndesc(r, vname).sequ, r.managers)]

@testset "engine — ScaledArrayEngine round-trip (Float,Int / Double,Int)" begin
    for (J, ST) in ((Float32, MSv2E.TpInt), (Float64, MSv2E.TpInt))
        dir = joinpath(mktempdir(), "sa.tab")
        V = [J.(reshape(1:(2k), 2, k)) .* J(0.5) for k in 2:4]     # multiples of scale
        write_table(dir, "T", ["V" => V]; nrow=3,
            engines = Dict("V" => (; kind=MSv2E.ScaledArray(), scale=J(0.5), offset=J(1.0),
                                    stored=:tsm, stored_type=ST)))
        r = readtable(dir)
        m = _engine_manager(r, "V")
        @test startswith(m.name, "ScaledArrayEngine")
        @test "V_COMPRESSED" in columnnames(r)
        @test !isfile(joinpath(dir, "table.f$(m.sequ)"))          # engine writes no file
        vc = column(r, "V")
        @test [vc[i] for i in 1:3] == V                            # exact: values are on-grid
        # hand-computed: stored = trunc((v-1)/0.5)
        st = column(r, "V_COMPRESSED")[1]
        @test st == Int32.(trunc.((V[1] .- 1) ./ J(0.5)))
    end
end

@testset "engine — ScaledComplexData round-trip" begin
    dir = joinpath(mktempdir(), "scd.tab")
    sc = ComplexF32(0.25, 0.5)
    W = [ComplexF32.(reshape(1:4, 2, 2)) .* sc for _ in 1:3]       # on-grid
    write_table(dir, "T", ["W" => W]; nrow=3,
        engines = Dict("W" => (; kind=MSv2E.ScaledComplex(), scale=sc, offset=ComplexF32(0),
                                stored_type=MSv2E.TpShort)))
    r = readtable(dir)
    @test startswith(_engine_manager(r, "W").name, "ScaledComplexData")
    @test size(column(r, "W_COMPRESSED")[1]) == (2, 2, 2)          # extra leading axis
    @test [column(r, "W")[i] for i in 1:3] == W
end

@testset "engine — CompressFloat / CompressComplex / SD vs Casacore.jl" begin
    d = mktempdir()
    cases = [
        (MSv2E.CompressFloat(), "F", [Float32.(reshape(range(-3, 3, length=6), 2, 3)) .* k
                                      for k in 1:4], 0.001f0),
        (MSv2E.CompressComplex(), "C", [ComplexF32.(fill(k, 2, 3)) .+ ComplexF32(0, 2k)
                                        for k in 1:4], 0.01f0),
        (MSv2E.CompressComplexSD(), "S",
         [ComplexF32[k 2k+0im; 3k+1im 0-2k*im] for k in 1:4], 0.005f0),
    ]
    for (kind, nm, vals, scale) in cases
        dir = joinpath(d, "$nm.tab")
        write_table(dir, "T", [nm => vals]; nrow=length(vals),
            engines = Dict(nm => (; kind, scale, offset=0.0f0)))
        r = readtable(dir)
        vc = column(r, nm)
        bound = scale * 1.01
        @test all(maximum(abs.(vc[i] .- vals[i])) <= bound for i in eachindex(vals))
        if _HAVE_CASACORE
            ct = CCT.Table(dir)
            @test all(maximum(abs.(ct[Symbol(nm)][i] .- vals[i])) <= bound for i in eachindex(vals))
            # our decoder and casacore's decode the identical stored ints
            @test all(vc[i] == ct[Symbol(nm)][i] for i in eachindex(vals))
        end
    end
end

@testset "engine — MappedArrayEngine (Complex <-> DComplex)" begin
    dir = joinpath(mktempdir(), "m.tab")
    X = [ComplexF32.(reshape(1:6, 2, 3)) .+ ComplexF32(0.5, -0.5) for _ in 1:3]
    write_table(dir, "T", ["X" => X]; nrow=3,
        engines = Dict("X" => (; kind=MSv2E.Mapped(), stored_type=MSv2E.TpDComplex)))
    r = readtable(dir)
    @test startswith(_engine_manager(r, "X").name, "MappedArrayEngine")
    @test [column(r, "X")[i] for i in 1:3] == X
    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test [ct[:X][i] for i in 1:3] == X
    end
end

@testset "engine — autoScale (per-row scale/offset)" begin
    dir = joinpath(mktempdir(), "as.tab")
    W = ComplexF32[]
    rows = [
        ComplexF32.(reshape(range(-2, 2, length=6), 2, 3)),        # min<max
        fill(ComplexF32(7), 2, 3),                                  # single value -> scale 1
        fill(ComplexF32(NaN), 2, 3),                                # all NaN -> scale 0
    ]
    write_table(dir, "T", ["W" => rows]; nrow=3,
        engines = Dict("W" => (; kind=MSv2E.CompressComplex(), autoscale=true)))
    r = readtable(dir)
    @test Set(("W", "W_COMPRESSED", "W_SCALE", "W_OFFSET")) ⊆ Set(columnnames(r))
    scol = column(r, "W_SCALE"); ocol = column(r, "W_OFFSET")
    @test scol[1] ≈ Float32(4 / 65534)          # (max-min)/65534, max=2 min=-2
    @test scol[2] == 1.0f0 && ocol[2] == 7.0f0
    @test scol[3] == 0.0f0
    wc = column(r, "W")
    @test maximum(abs.(wc[1] .- rows[1])) <= scol[1] * 1.01
    @test wc[2] == fill(ComplexF32(7), 2, 3)
    @test all(isnan, real.(wc[3]))
    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test maximum(abs.(ct[:W][1] .- rows[1])) <= scol[1] * 1.01
        @test ct[:W][2] == fill(ComplexF32(7), 2, 3)
    end
end

@testset "engine — NaN sentinels" begin
    dir = joinpath(mktempdir(), "nan.tab")
    F = [Float32[1.0 NaN; 2.0 3.0], Float32[NaN NaN; NaN NaN]]
    write_table(dir, "T", ["F" => F]; nrow=2,
        engines = Dict("F" => (; kind=MSv2E.CompressFloat(), scale=0.001f0, offset=0.0f0)))
    r = readtable(dir)
    f1 = column(r, "F")[1]
    @test isnan(f1[1, 2]) && f1[1, 1] ≈ 1.0f0
    @test all(isnan, column(r, "F")[2])
    @test column(r, "F_COMPRESSED")[1][1, 2] == Int16(-32768)

    dir2 = joinpath(mktempdir(), "nanc.tab")
    C = [ComplexF32[1+1im NaN; 2+2im 3+3im]]
    write_table(dir2, "T", ["C" => C]; nrow=1,
        engines = Dict("C" => (; kind=MSv2E.CompressComplex(), scale=0.001f0, offset=0.0f0)))
    c1 = column(readtable(dir2), "C")[1]
    @test isnan(real(c1[1, 2])) && isnan(imag(c1[1, 2]))
    @test c1[1, 1] ≈ ComplexF32(1, 1)
end

@testset "engine — copyms preserves the engine" begin
    src = joinpath(mktempdir(), "src.tab")
    X = collect(1.0:5.0)
    V = [ComplexF32.(fill(k, 2, 3)) .+ ComplexF32(0, k) for k in 1:5]
    write_table(src, "T", ["X" => X, "V" => V]; nrow=5,
        engines = Dict("V" => (; kind=MSv2E.CompressComplex(), scale=0.0008f0, offset=0.0f0)))
    dst = joinpath(mktempdir(), "dst.tab")
    MSv2E._copy_table(dst, readtable(src), 1:5)

    r = readtable(dst)
    @test any(m -> m.name == "CompressComplex", r.managers)
    @test count(==("V_COMPRESSED"), columnnames(r)) == 1
    @test !("V_COMPRESSED_COMPRESSED" in columnnames(r))
    @test !isempty(String(columndesc(r, "V").keywords["_BaseMappedArrayEngine_Name"]))
    @test [column(r, "V")[i] for i in 1:5] == V              # re-encode is idempotent
    @test column(r, "X")[:] == X
    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test all(maximum(abs.(ct[:V][i] .- V[i])) < 0.001 for i in 1:5)
    end
end

@testset "engine — edit: overwrite / addrows! / removerows!" begin
    dir = joinpath(mktempdir(), "e.tab")
    X = collect(1.0:6.0)
    V = [ComplexF32.(fill(k, 2, 3)) for k in 1:6]
    write_table(dir, "T", ["X" => X, "V" => V]; nrow=6,
        engines = Dict("V" => (; kind=MSv2E.CompressComplex(), scale=0.01f0, offset=0.0f0)))

    edit(dir) do t
        t[:V][3] = ComplexF32.(fill(50, 2, 3))
    end
    r = readtable(dir)
    @test abs(column(r, "V")[3][1, 1] - 50) < 0.02
    @test abs(column(r, "V")[2][1, 1] - 2) < 0.02              # sibling untouched
    @test column(r, "X")[:] == X

    edit(dir) do t
        addrows!(t, 2)
        t[:V][7] = ComplexF32.(fill(7, 2, 3))
        t[:V][8] = ComplexF32.(fill(8, 2, 3))
    end
    r2 = readtable(dir)
    @test r2.rows == 8
    @test abs(column(r2, "V")[7][1, 1] - 7) < 0.02
    if _HAVE_CASACORE
        @test size(CCT.Table(dir), 1) == 8
        @test abs(CCT.Table(dir)[:V][7][1, 1] - 7) < 0.02
    end

    edit(dir) do t
        removerows!(t, [1, 4])
    end
    r3 = readtable(dir)
    @test r3.rows == 6
    @test abs(column(r3, "V")[1][1, 1] - 2) < 0.02            # old row 2 -> new row 1
    @test abs(column(r3, "V")[5][1, 1] - 7) < 0.02            # old row 7 -> new row 5
    @test column(r3, "X")[:] == [2.0, 3.0, 5.0, 6.0, 0.0, 0.0]  # keep old [2,3,5,6,7,8]; 7,8 unset
end
