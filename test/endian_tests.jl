# Phase 268: big-endian tables, and memory safety of the raw byte loads.
#
# Found: `write_table(...; endian = :big)` wrote big-endian storage-manager files but a
# table.dat that said "little-endian" (so neither our reader nor casacore could read it), and
# `edit` of a big-endian table did the same on every rewrite; reading a casacore ISM table with
# a Direct fixed-shape STRING array (`[uInt total][uInt len, chars]...` per cell -- our reader
# assumed strings are never direct there) read a garbage file offset and crashed the whole
# process (SIGBUS) because the raw-pointer loads did not check their range; `addrows!` on a
# fixed-shape String array column failed (`zero(String)`).

@testset "raw byte loads are bounds-checked (Phase 268)" begin
    b = UInt8[1, 2, 3, 4, 5, 6, 7, 8]
    @test MSv2._ld(UInt32, b, 0, false) == 0x04030201
    @test MSv2._ld(UInt32, b, 4, true) == 0x05060708
    @test_throws BoundsError MSv2._ld(UInt32, b, 5, false)
    @test_throws BoundsError MSv2._ld(UInt32, b, -1, false)
    @test_throws BoundsError MSv2._ld(Int64, b, 1, false)
    out = zeros(UInt16, 4)
    @test MSv2._rd_run!(out, 0, UInt16, b, 0, 4, false) == UInt16[0x0201, 0x0403, 0x0605, 0x0807]
    @test_throws BoundsError MSv2._rd_run!(out, 0, UInt16, b, 2, 4, false)
    bits = zeros(Bool, 16)
    @test_throws BoundsError MSv2._rd_bits!(bits, 0, b, 7, 0, 16)
    @test MSv2._rd_bits!(bits, 0, b, 0, 0, 16)[1:3] == [true, false, false]
end

@testset "big-endian write, every type x shape x manager (Phase 268)" begin
    rng = MSv2.Random.MersenneTwister(5)
    N = 3
    gen(::Type{Bool}) = rand(rng, Bool)
    gen(::Type{String}) = MSv2.Random.randstring(rng, rand(rng, 0:6))
    gen(T::Type{<:Integer}) = T(rand(rng, 0:100))
    gen(T::Type{<:AbstractFloat}) = T(rand(rng) * 100)
    gen(::Type{Complex{T}}) where {T} = Complex{T}(rand(rng) * 10, rand(rng) * 10)
    same(a, b) = a isa AbstractArray ? (size(a) == size(b) && all(isequal.(a, b))) : isequal(a, b)
    types = [Bool, UInt8, Int16, UInt16, Int32, UInt32, Int64, Float32, Float64, ComplexF32, ComplexF64, String]
    shapes = [(:scalar, ()), (:fixed, (2, 3)), (:var, nothing)]
    nfail = 0
    for T in types, (sn, sh) in shapes, m in (:ssm, :ism, :tsm, :tcm)
        (m in (:tsm, :tcm) && (sh === () || T === String)) && continue
        (m === :tcm && sh === nothing) && continue
        col = sh === () ? [gen(T) for _ in 1:N] : sh === nothing ? [[gen(T) for _ in 1:i] for i in 1:N] :
              [reshape([gen(T) for _ in 1:prod(sh)], sh...) for _ in 1:N]
        kw = m === :ism ? (; ism=["X"]) : m === :tsm ? (; tsm=[["X"]]) : m === :tcm ? (; tcm=[["X"]]) : (;)
        dir = joinpath(mktempdir(), "t")
        ok = try
            write_table(dir, "T", Pair{String,Any}["X" => col]; nrow=N, endian=:big, kw...)
            t = readtable(dir)
            good = t.endian === :big && all(i -> same(column(t, "X")[:][i], col[i]), 1:N)
            if good && _HAVE_CASACORE && m !== :tsm
                cc = CCT.Table(dir)[:X]; nd = ndims(cc)
                good = sh === () ? all(i -> isequal(cc[i], col[i]), 1:N) :
                       sh === nothing ? all(i -> vec(collect(cc[ntuple(_ -> Colon(), nd - 1)..., i])) == vec(col[i]), 1:N) :
                       (arr = cc[ntuple(_ -> Colon(), nd)...]; all(i -> vec(collect(selectdim(arr, nd, i))) == vec(col[i]), 1:N))
            end
            good
        catch
            false
        end
        ok || (nfail += 1; @info "big-endian write" T sn m)
    end
    @test nfail == 0
    # the byte order is table.dat's flag: 0 = big
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["A" => Int32[1, 2]]; nrow=2, endian=:big)
    @test readtable(d).endian === :big
    write_table(d * "l", "T", Pair{String,Any}["A" => Int32[1, 2]]; nrow=2)
    @test readtable(d * "l").endian === :little
end

@testset "editing a big-endian table keeps it big-endian (Phase 268)" begin
    n = 4
    for kw in ((;), (; ism=["B"]), (; tsm=[["V"]]), (; tcm=[["U"]]))
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["A" => collect(1:n), "B" => Float64.(1:n), "V" => [fill(Float32(i), 2, 3) for i in 1:n],
                                              "U" => [fill(Float64(i), 3) for i in 1:n], "S" => ["s$i" for i in 1:n]];
                    nrow=n, endian=:big, kw...)
        edit(d) do e
            MSv2.addrows!(e, 1)
            e["A"][5] = 50; e["B"][5] = 5.5; e["V"][5] = fill(5f0, 2, 3); e["U"][5] = fill(5.0, 3); e["S"][5] = "s5"
            MSv2.removerows!(e, [2])
        end
        t = readtable(d)
        @test t.endian === :big && MSv2.nrow(t) == n
        @test column(t, "A")[:] == [1, 3, 4, 50] && column(t, "B")[:] == [1.0, 3.0, 4.0, 5.5]
        @test column(t, "V")[4] == fill(5f0, 2, 3) && column(t, "U")[4] == fill(5.0, 3) && column(t, "S")[:] == ["s1", "s3", "s4", "s5"]
        if _HAVE_CASACORE
            c = d * "_cc"; cp(d, c)
            cc = CCT.Table(c)
            @test size(cc, 1) == n && cc[:A][:] == [1, 3, 4, 50] && cc[:S][:] == ["s1", "s3", "s4", "s5"]
        end
    end
end

@testset "appended cells of a fixed-shape String array (Phase 268)" begin
    for kw in ((;), (; ism=["X"]))
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => [fill("a$i", 2, 3) for i in 1:3]]; nrow=3, kw...)
        edit(d) do e; MSv2.addrows!(e, 2); e["X"][4] = fill("z", 2, 3); end
        got = column(readtable(d), "X")[:]
        @test size.(got) == fill((2, 3), 5) && got[4] == fill("z", 2, 3) && got[5] == fill("", 2, 3)
    end
end

const _END_CASA = get(ENV, "MEASUREMENTSETS_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")

@testset "casacore ISM tables with Direct string arrays, both byte orders (Phase 268)" begin
    if isfile(_END_CASA)
        script = """
import sys, numpy as np
from casatools import table
out, endian = sys.argv[1], sys.argv[2]
desc = {'S_F': {'valueType':'string','option':5,'maxlen':0,'comment':'','ndim':2,'shape':[2,3]},
        'I_F': {'valueType':'int','option':5,'maxlen':0,'comment':'','ndim':2,'shape':[2,3]},
        'S_V': {'valueType':'string','option':0,'maxlen':0,'comment':'','ndim':1}}
tb = table()
tb.create(out, desc, nrow=3, endianformat=endian, dminfo={'*1': {'TYPE':'IncrementalStMan','NAME':'ISM','COLUMNS':list(desc)}})
for r in range(3):
    tb.putcell('S_F', r, np.full((2,3), 'row%d' % (r+1), dtype=object).tolist())
    tb.putcell('I_F', r, np.full((2,3), (r+1)*70000))
    tb.putcell('S_V', r, ['v%d' % (r+1)] * (r+1))
tb.close()
"""
        for endian in ("big", "little")
            d = joinpath(mktempdir(), "$endian.tab")
            run(pipeline(`$_END_CASA -c $script $d $endian`; stderr=devnull))
            t = readtable(d)
            @test t.endian === Symbol(endian)
            @test column(t, "S_F")[:] == [fill("row$i", 2, 3) for i in 1:3]
            @test column(t, "I_F")[:] == [fill(i * 70000, 2, 3) for i in 1:3]
            @test column(t, "S_V")[:] == [fill("v$i", i) for i in 1:3]
            # ... and rewriting it (edit) keeps the values and the byte order
            edit(d) do e; MSv2.addrows!(e, 1); end
            t2 = readtable(d)
            @test t2.endian === Symbol(endian) && MSv2.nrow(t2) == 4
            @test column(t2, "S_F")[1:3] == [fill("row$i", 2, 3) for i in 1:3]
        end
    else
        @info "casatools python not found; skipping the casacore byte-order cross-check" _END_CASA
    end
end
