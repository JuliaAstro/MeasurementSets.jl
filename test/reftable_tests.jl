# Phase 14: RefTable + ConcatTable read support.

import Tables

# `name => vector` pairs with the per-column eltype preserved (a bare array
# literal would promote Int32/Float64 columns to a common type).
_cols(ps...) = Pair{String,Any}[p for p in ps]

# TaQL SELECT ... GIVING '<path>' against a seed table -> persistent RefTable.
if _HAVE_TAQL
    function _taql_sel(q, parent::CCT.Table)
        v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
        push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(parent.tableref)))
        GC.@preserve parent CCT.Table(Casacore.LibCasacore.tableCommand(q, v))
    end
end

# Hand-write a ConcatTable table.dat over `partnames` (relative "././" form).
function _write_concat(dir, partnames)
    w = MSv2.AipsWriter(; endian=:big)
    MSv2.putstart(w, "Table", 2)
    MSv2.wr_u32(w, 0)                       # nrrow (casacore ignores it on read)
    MSv2.wr_u32(w, 0)                       # endian flag
    MSv2.wr_string(w, "ConcatTable")
    MSv2.putstart(w, "ConcatTable", 0)
    MSv2.wr_u32(w, length(partnames))
    for n in partnames
        MSv2.wr_string(w, n)
    end
    MSv2.wr_block(w, String[])              # keyword subtables to concatenate
    MSv2.putend(w)
    MSv2.putend(w)
    write(joinpath(dir, "table.dat"), MSv2.bytes(w))
    write(joinpath(dir, "table.info"), "Type = test\nSubType = \n\nhand-built concat\n")
end

@testset "RefTable — path resolution" begin
    @test MSv2._resolve_tabpath("././T", "/a/b/ref") == "/a/b/ref/T"
    @test MSv2._resolve_tabpath("./T", "/a/b/ref") == "/a/b/T"
    @test MSv2._resolve_tabpath("/abs/T", "/a/b/ref") == "/abs/T"
    @test MSv2._resolve_tabpath("./././x", "/a/b/ref") == "/a/b/ref/x"
end

if _HAVE_TAQL
    @testset "RefTable — TaQL selection, our reader" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        A = collect(Int32, 1:12); B = rand(12)
        write_table(pdir, "T", _cols("A" => A, "B" => B); nrow=12)

        rdir = joinpath(d, "sel")
        _taql_sel("SELECT FROM \$1 WHERE A IN [3,6,9,12] GIVING '$rdir'", CCT.Table(pdir))
        GC.gc(); GC.gc()

        rt = readtable(rdir)
        @test rt isa RefTable
        @test nrow(rt) == 4
        @test rt.rows == [3, 6, 9, 12]
        @test columnnames(rt) == ["A", "B"]
        @test column(rt, "A")[:] == Int32[3, 6, 9, 12]
        @test rt["B"][2] == B[6]
        @test rt[:B][1:3] == B[[3, 6, 9]]
        @test !is_stale(rt)
        @test validate(rt; table="ANTENNA") isa Vector{String}   # never throws
        @test eltype(column(rt, "A")) == Int32

        if _HAVE_CASACORE
            cc = CCT.Table(rdir)
            @test size(cc, 1) == 4
            @test cc[:A][:] == Int32[3, 6, 9, 12]
        end
    end

    @testset "RefTable — projection + rename" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        B = rand(10)
        write_table(pdir, "T", _cols("A" => collect(Int32, 1:10), "B" => B); nrow=10)

        rdir = joinpath(d, "sel")
        _taql_sel("SELECT A, B AS BR FROM \$1 WHERE A>6 GIVING '$rdir'", CCT.Table(pdir))
        GC.gc(); GC.gc()

        rt = readtable(rdir)
        @test Set(columnnames(rt)) == Set(["A", "BR"])
        @test rt["BR"][:] == B[7:10]
        @test rt["A"][:] == Int32[7, 8, 9, 10]
        @test MSv2.columndesc(rt, "BR").name == "BR"
    end

    @testset "RefTable — over TSM / ISM / SSM columns" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        n = 20
        cube = [ComplexF32.(reshape(1:8, 2, 4)) .+ ComplexF32(10i) for i in 1:n]
        tim  = collect(Float64, 1:n) .* 1e3
        sca  = collect(Int32, 1:n)
        write_table(pdir, "T", _cols("DATA" => cube, "TIME" => tim, "SC" => sca);
                    nrow=n, tsm=[["DATA"]], ism=["TIME"])

        rdir = joinpath(d, "sel")
        _taql_sel("SELECT FROM \$1 WHERE SC%2==0 GIVING '$rdir'", CCT.Table(pdir))
        GC.gc(); GC.gc()

        rt = readtable(rdir)
        keep = 2:2:n
        @test rt.rows == collect(keep)
        @test column(rt, "DATA")[:] == cube[keep]
        @test column(rt, "TIME")[:] == tim[keep]
        @test column(rt, "SC")[:] == sca[keep]
        @test column(rt, "DATA")[3] == cube[6]
    end

    @testset "RefTable — Tables.jl surface" begin
        d = mktempdir(); pdir = joinpath(d, "T")
        write_table(pdir, "T", _cols("A" => collect(Int32, 1:8), "B" => collect(1.0:8.0)); nrow=8)
        rdir = joinpath(d, "sel")
        _taql_sel("SELECT FROM \$1 WHERE A>4 GIVING '$rdir'", CCT.Table(pdir))
        GC.gc(); GC.gc()
        rt = readtable(rdir)

        @test Tables.schema(rt).names == (:A, :B)
        @test Tables.schema(rt).types == (Int32, Float64)
        rows = Tables.rowtable(rt)
        @test length(rows) == 4
        @test rows[1].A == Int32(5)
        @test [r.B for r in rt] == [5.0, 6.0, 7.0, 8.0]
    end
end

@testset "ConcatTable — hand-written table.dat" begin
    d = mktempdir()
    A0 = collect(Int32, 1:3); B0 = collect(10.0:12.0)
    A1 = collect(Int32, 4:8); B1 = collect(40.0:44.0)
    write_table(joinpath(d, "p0"), "T", _cols("A" => A0, "B" => B0); nrow=3)
    write_table(joinpath(d, "p1"), "T", _cols("A" => A1, "B" => B1); nrow=5)
    _write_concat(d, ["././p0", "././p1"])

    ct = readtable(d)
    @test ct isa ConcatTable
    @test nrow(ct) == 8
    @test length(ct.parts) == 2
    @test ct.offsets == [0, 3, 8]
    @test columnnames(ct) == ["A", "B"]
    @test column(ct, "A")[:] == vcat(A0, A1)
    @test column(ct, "B")[:] == vcat(B0, B1)
    @test ct["A"][3] == Int32(3)          # last row of part 1
    @test ct["A"][4] == Int32(4)          # first row of part 2
    @test ct[:B][6] == B1[3]
    @test eltype(column(ct, "A")) == Int32

    if _HAVE_CASACORE
        cc = CCT.Table(d)
        @test size(cc, 1) == 8
        @test cc[:A][:] == vcat(A0, A1)
    end
end

@testset "ConcatTable — heterogeneous cell shape" begin
    d = mktempdir()
    C0 = [ComplexF32.(reshape(1:6, 2, 3)) for _ in 1:2]
    C1 = [ComplexF32.(reshape(1:8, 2, 4)) for _ in 1:3]
    write_table(joinpath(d, "p0"), "T", ["C" => C0]; nrow=2, tsm=[["C"]])
    write_table(joinpath(d, "p1"), "T", ["C" => C1]; nrow=3, tsm=[["C"]])
    _write_concat(d, ["././p0", "././p1"])

    ct = readtable(d)
    @test nrow(ct) == 5
    @test columndesc(ct, "C").shape isa VariableShape
    @test column(ct, "C")[:] == vcat(C0, C1)
    @test column(ct, "C")[4] == C1[2]
end

@testset "ConcatTable — is_stale / resync" begin
    d = mktempdir()
    write_table(joinpath(d, "p0"), "T", ["A" => collect(Int32, 1:3)]; nrow=3)
    write_table(joinpath(d, "p1"), "T", ["A" => collect(Int32, 4:6)]; nrow=3)
    _write_concat(d, ["././p0", "././p1"])

    ct = readtable(d)
    @test !is_stale(ct)
    edit(joinpath(d, "p1")) do t; addrows!(t, 2) end
    @test is_stale(ct)
    ct2 = resync(ct)
    @test ct2 !== ct && nrow(ct2) == 8
    @test resync(ct2) === ct2
end

@testset "RefTable / ConcatTable — edit is rejected" begin
    d = mktempdir()
    write_table(joinpath(d, "p0"), "T", ["A" => collect(Int32, 1:3)]; nrow=3)
    write_table(joinpath(d, "p1"), "T", ["A" => collect(Int32, 4:6)]; nrow=3)
    _write_concat(d, ["././p0", "././p1"])
    @test_throws ErrorException edit(d)
end
