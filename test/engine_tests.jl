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

# Phase 214: real casacore's `CompressFloat::scaleOnPut` (CompressFloat.cc:
# 274-296) has NO clamp at all before its raw `short(...)` cast -- unlike
# `CompressComplex::scaleOnPut`, which explicitly clamps each part to
# ±32767 first. An out-of-dynamic-range value is undefined behaviour in
# real casacore's own C++; this package deliberately clamps `CompressFloat`
# too (reusing `CompressComplex`'s own clamp constant) rather than trying
# to replicate unreproducible UB -- no real-Casacore.jl cross-check here
# on purpose (feeding an out-of-range value through the real C++ library
# would itself be UB, not something to rely on). Not previously tested at
# all -- no existing fixture ever exceeded the dynamic range.
@testset "engine — CompressFloat clamps an out-of-range value (Phase 214)" begin
    dir = joinpath(mktempdir(), "cfclamp.tab")
    scale = 0.001f0
    V = [reshape([1.0f6], 1, 1), reshape([-1.0f6], 1, 1)]   # far outside Int16 range once scaled
    write_table(dir, "T", ["F" => V]; nrow=2,
        engines = Dict("F" => (; kind=MSv2E.CompressFloat(), scale, offset=0.0f0)))
    r = readtable(dir)
    st = column(r, "F_COMPRESSED")[:]
    @test st[1][1] == Int16(32767) && st[2][1] == Int16(-32767)   # clamped, not overflowed/crashed
    out = column(r, "F")[:]
    @test out[1][1] ≈ 32767 * scale && out[2][1] ≈ -32767 * scale
end

# Phase 213 (src/datamanagers sweep, continued): the existing cross-check
# above never has a negative *real* part paired with a non-negative
# *imag* part (CompressComplex) or a genuinely mixed-sign complex value
# (CompressComplexSD) -- so `_decode(::CompressComplex,...)`'s
# `im < -ENG_C_WRAP` correction, and BOTH of `_decode(::CompressComplexSD,
# ...)`'s wrap-correction branches, were never exercised. Also pins a
# real, confirmed-matching-upstream quirk found while constructing this:
# `CompressComplexSD::scaleOnPut` (`CompressComplex.cc:787-788`) encodes a
# non-finite value the SAME way as plain `CompressComplex` (`stored =
# -32768*65536`) -- but that value is EVEN, and SD's own decode
# (`scaleOnGet`, `.cc:750`) dispatches on `inval%2==0` *before* ever
# checking the `r==-32768` NaN sentinel (which only lives in the ODD
# branch) -- so a NaN written through `CompressComplexSD` does NOT come
# back as NaN in real casacore either; it's silently misdecoded as a
# huge bogus real-only value. This package's port reproduces that
# upstream limitation exactly (live-verified against real Casacore.jl
# below) rather than "fixing" a divergence that doesn't actually exist.
@testset "engine — CompressComplex(SD) wrap-correction + the SD NaN quirk (Phase 213)" begin
    dir = mktempdir()

    # CompressComplex: real<0, imag>=0 -- forces decode's `r -= 1` branch.
    p1 = joinpath(dir, "cc.tab")
    scale1 = 0.01f0
    V1 = [ComplexF32(-k, k * 0.3f0) for k in 1:6]
    write_table(p1, "T", ["C" => [reshape([v], 1, 1) for v in V1]]; nrow=6,
        engines = Dict("C" => (; kind=MSv2E.CompressComplex(), scale=scale1, offset=0.0f0)))
    r1 = readtable(p1)
    bound1 = scale1 * 1.01
    @test all(maximum(abs.(column(r1, "C")[i] .- reshape([V1[i]], 1, 1))) <= bound1 for i in 1:6)
    if _HAVE_CASACORE
        ct1 = CCT.Table(p1)
        @test all(ct1[:C][i] == column(r1, "C")[i] for i in 1:6)
    end

    # CompressComplexSD: a NaN row + genuinely mixed-sign finite rows
    # (both wrap-correction directions).
    p2 = joinpath(dir, "sd.tab")
    scale2 = 0.005f0
    V2 = ComplexF32[ComplexF32(NaN, NaN), ComplexF32(-3, -7), ComplexF32(2, -5), ComplexF32(-2, 6)]
    write_table(p2, "T", ["S" => [reshape([v], 1, 1) for v in V2]]; nrow=4,
        engines = Dict("S" => (; kind=MSv2E.CompressComplexSD(), scale=scale2, offset=0.0f0)))
    r2 = readtable(p2)
    out2 = [column(r2, "S")[i][1, 1] for i in 1:4]
    bound2 = scale2 * 3          # SD's imag has its own (coarser) scale
    @test all(maximum(abs.([real(out2[i]) - real(V2[i]), imag(out2[i]) - imag(V2[i])])) <= bound2
              for i in 2:4)
    # the confirmed-matching-upstream NaN quirk: NOT NaN, a finite value
    @test isfinite(real(out2[1])) && isfinite(imag(out2[1])) && imag(out2[1]) == 0.0f0
    if _HAVE_CASACORE
        ct2 = CCT.Table(p2)
        @test all(ct2[:S][i][1, 1] == out2[i] for i in 1:4)   # incl. row 1 -- same bogus value
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

# ---- Phase 40: BitFlagsEngine + ForwardColumnEngine ----------------------

@testset "engine — BitFlagsEngine round-trip + cross-check" begin
    dir = joinpath(mktempdir(), "bfe.tab")
    F = [rand(Bool, 2, 3) for _ in 1:5]
    write_table(dir, "T", ["FLAG" => F]; nrow=5,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt)))
    r = readtable(dir)
    m = _engine_manager(r, "FLAG")
    @test startswith(m.name, "BitFlagsEngine<")
    @test !isfile(joinpath(dir, "table.f$(m.sequ)"))          # engine writes no file
    fc = column(r, "FLAG")
    @test eltype(fc) == Array{Bool}
    @test [fc[i] for i in 1:5] == F
    st = column(r, "FLAG_COMPRESSED")[1]
    @test eltype(st) <: Integer
    @test all(x -> x == 0 || x == 1, st)                      # raw 0/1, no write mask
    @test (st .!= 0) == F[1]

    if _HAVE_CASACORE
        ct = CCT.Table(dir)                                   # BitFlagsEngine<Int> auto-registered
        @test [Bool.(ct[:FLAG][i]) for i in 1:5] == F
    end

    dst = joinpath(mktempdir(), "bfe_copy.tab")
    copytable(dst, r)                                         # copyms/copytable preserve the engine
    rc = readtable(dst)
    @test startswith(_engine_manager(rc, "FLAG").name, "BitFlagsEngine<")
    @test [column(rc, "FLAG")[i] for i in 1:5] == F
end

@testset "engine — BitFlagsEngine readMask + FLAGSETS keys" begin
    dir = joinpath(mktempdir(), "bfe2.tab")
    F = [rand(Bool, 2, 2) for _ in 1:3]
    write_table(dir, "T", ["FLAG" => F]; nrow=3,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt,
                                   readmask=0x00000001)))
    @test [column(readtable(dir), "FLAG")[i] for i in 1:3] == F   # bit 0 == raw storage

    # readMask that never matches the raw 0/1 -> all false
    dir3 = joinpath(mktempdir(), "bfe3.tab")
    write_table(dir3, "T", ["FLAG" => F]; nrow=3,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt,
                                   readmask=0x00000002)))
    r3 = readtable(dir3)
    @test all(all(iszero, column(r3, "FLAG")[i]) for i in 1:3)

    # FLAGSETS + ReadMaskKeys: mask is recomputed as the OR of the named sets
    fs = MSv2E.Record()
    MSv2E._kwpush!(fs, "CAL", MSv2E.TpUInt, UInt32(2))
    MSv2E._kwpush!(fs, "RFI", MSv2E.TpUInt, UInt32(4))
    dir4 = joinpath(mktempdir(), "bfe4.tab")
    write_table(dir4, "T", ["FLAG" => F]; nrow=3,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt,
                                   readmaskkeys=["CAL", "RFI"], flagsets=fs)))
    r4 = readtable(dir4)
    inst = MSv2E._dm_instance(r4, columndesc(r4, "FLAG").sequ)
    @test inst.scale == UInt32(6)                              # 2 | 4, recomputed from FLAGSETS
    @test columndesc(r4, "FLAG_COMPRESSED").keywords["FLAGSETS"] isa MSv2E.Record

    # Phase 156: a ReadMaskKeys entry NOT present in FLAGSETS must be
    # silently skipped (`BFEngineMask::makeMask`, `isDefined` check),
    # not raise -- confirmed against real casacore live below.
    dir5 = joinpath(mktempdir(), "bfe5.tab")
    write_table(dir5, "T", ["FLAG" => F]; nrow=3,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt,
                                   readmaskkeys=["CAL", "NOSUCHKEY"], flagsets=fs)))
    r5 = readtable(dir5)
    inst5 = MSv2E._dm_instance(r5, columndesc(r5, "FLAG").sequ)
    @test inst5.scale == UInt32(2)                             # only "CAL" found, "NOSUCHKEY" skipped
    # raw storage is always bit 0 (0/1); a mask of 2 (bit 1, "CAL") never
    # matches it -- both readers must agree the column reads all-false
    @test all(all(iszero, column(r5, "FLAG")[i]) for i in 1:3)

    # every requested key missing -> mask is 0 (matches casacore's own
    # `uInt mask = 0;` with no key ever OR'd in), not an error
    dir6 = joinpath(mktempdir(), "bfe6.tab")
    write_table(dir6, "T", ["FLAG" => F]; nrow=3,
        engines = Dict("FLAG" => (; kind=MSv2E.BitFlags(), stored_type=MSv2E.TpInt,
                                   readmaskkeys=["NOPE"], flagsets=fs)))
    r6 = readtable(dir6)
    @test all(all(iszero, column(r6, "FLAG")[i]) for i in 1:3)

    if _HAVE_CASACORE
        ct5 = CCT.Table(dir5)
        @test all(all(iszero, Bool.(ct5[:FLAG][i])) for i in 1:3)
        ct6 = CCT.Table(dir6)
        @test all(all(iszero, Bool.(ct6[:FLAG][i])) for i in 1:3)
    end
end

@testset "engine — ForwardColumnEngine / reference_copy" begin
    src = joinpath(mktempdir(), "src.tab")
    A = collect(1.0:6.0)
    V = [ComplexF32.(fill(k, 2, 3)) for k in 1:6]
    B = collect(Int32, 10:15)
    write_table(src, "S", ["A" => A, "V" => V, "B" => B]; nrow=6)

    dst = joinpath(dirname(src), "ref.tab")
    reference_copy(dst, readtable(src); writable=["B"])
    r = readtable(dst)
    @test _engine_manager(r, "A").name == "ForwardColumnEngine"
    @test _engine_manager(r, "V").name == "ForwardColumnEngine"
    @test _engine_manager(r, "B").name != "ForwardColumnEngine"
    @test !isfile(joinpath(dst, "table.f$(_engine_manager(r, "A").sequ)"))
    @test column(r, "A")[:] == A
    @test [column(r, "V")[i] for i in 1:6] == V
    @test column(r, "B")[:] == B

    edit(src) do t; t[:B][1] = Int32(999); end               # writable B is independent
    @test column(readtable(dst), "B")[1] == 10
    edit(src) do t; t[:A][1] = -5.0; end                      # forwarded A tracks the source
    @test column(readtable(dst), "A")[1] == -5.0

    if _HAVE_CASACORE
        ct = CCT.Table(dst)                                   # ForwardColumnEngine auto-registered
        @test Float64.(ct[:A][:]) == column(readtable(dst), "A")[:]
    end

    plain = joinpath(dirname(src), "plain.tab")
    copytable(plain, readtable(dst))                          # materialises through the forward
    rp = readtable(plain)
    @test _engine_manager(rp, "A").name != "ForwardColumnEngine"
    @test column(rp, "A")[:] == column(readtable(dst), "A")[:]
    @test [column(rp, "V")[i] for i in 1:6] == V
end

@testset "engine — reference_copy's writable= is validated (Phase 205)" begin
    # `w = Set(String.(writable))` was checked only via `c.name in w`
    # while iterating the SOURCE's real column names — a typo'd
    # `writable=` name was never matched and had NO EFFECT AT ALL: the
    # column silently stayed a `ForwardColumnEngine` reference instead
    # of becoming the independent copy the caller asked for (defeating
    # the whole point of `writable=`), with zero error or warning. Same
    # shape as Phase 202's `ism=` / Phase 204's `subtables=`/
    # `subtable_rows=`. Live-verified: `reference_copy(dst, src;
    # writable=["AA"])` (typo for `"A"`) left `A` forwarded — editing
    # `src` afterward silently mutated `dst`'s `A` too, exactly the
    # aliasing `writable=` exists to prevent.
    src2 = joinpath(mktempdir(), "src2.tab")
    write_table(src2, "S", ["A" => collect(1.0:5.0), "B" => collect(Int32, 1:5)]; nrow=5)

    dir1 = joinpath(mktempdir(), "rc_bad.tab")
    @test_throws ErrorException reference_copy(dir1, src2; writable=["AA"])
    @test !ispath(dir1)

    dst2 = joinpath(mktempdir(), "rc_ok.tab")
    reference_copy(dst2, src2; writable=["A"])
    r2 = readtable(dst2)
    @test _engine_manager(r2, "A").name != "ForwardColumnEngine"
    @test _engine_manager(r2, "B").name == "ForwardColumnEngine"
    edit(src2) do t; t[:A][1] = -99.0; t[:B][1] = Int32(-99); end
    @test column(readtable(dst2), "A")[1] == 1.0     # independent, unchanged
    @test column(readtable(dst2), "B")[1] == Int32(-99)  # forwarded, tracks src
end

@testset "engine — unsupported (RetypedArray / ForwardColumnIndexedRow)" begin
    @test MSv2E._dmtype("RetypedArrayEngine<Float>") === MSv2E._UnsupportedDM
    @test MSv2E._dmtype("ForwardColumnIndexedRowEngine") === MSv2E._UnsupportedDM
end

# ---- Phase 41: VirtualTaQLColumn -----------------------------------------

@testset "engine — VirtualTaQLColumn round-trip + cross-check" begin
    dir = joinpath(mktempdir(), "vtq.tab")
    A = collect(1.0:6.0)
    write_table(dir, "T", ["A" => A, "CONST" => zeros(6), "CALC" => zeros(6),
                           "FLAGY" => falses(6)]; nrow=6,
        virtualtaql = Dict("CONST" => "3.5",
                           "CALC"  => "A * 2.0 + 1.0",
                           "FLAGY" => "A > 3.0"))
    r = readtable(dir)
    m = _engine_manager(r, "CONST")
    @test m.name == "VirtualTaQLColumn"
    @test !isfile(joinpath(dir, "table.f$(m.sequ)"))          # no data file
    @test column(r, "CONST")[:] == fill(3.5, 6)               # constant expr
    @test column(r, "CALC")[:] == A .* 2 .+ 1                  # column-referencing, fast path
    @test [column(r, "CALC")[i] for i in 1:6] == A .* 2 .+ 1  # per-cell
    @test column(r, "FLAGY")[:] == (A .> 3)
    @test eltype(column(r, "FLAGY")) == Bool
    @test String(columndesc(r, "CALC").keywords["_VirtualTaQLEngine_CalcExpr"]) == "A * 2.0 + 1.0"

    if _HAVE_CASACORE
        ct = CCT.Table(dir)                                   # VirtualTaQLColumn auto-registered
        @test ct[:CONST][:] == fill(3.5, 6)
        @test ct[:CALC][:] == A .* 2 .+ 1
    end
end

@testset "engine — VirtualTaQLColumn with array indexing (Phase 42)" begin
    dir = joinpath(mktempdir(), "vtqix.tab")
    UVW = [Float64[i, 2i, 3i] for i in 1:5]
    V = [reshape(Float64.(1:6) .+ 10k, 2, 3) for k in 0:4]
    write_table(dir, "T", Pair{String,Any}["UVW" => UVW, "V" => V,
                                           "W" => zeros(5), "V11" => zeros(5)]; nrow=5,
        tsm = [["V"]],
        virtualtaql = Dict("W" => "UVW[3]", "V11" => "V[1,1] * 2.0"))
    r = readtable(dir)
    @test _engine_manager(r, "W").name == "VirtualTaQLColumn"
    @test column(r, "W")[:] == [3i for i in 1:5]
    @test column(r, "V11")[:] == [V[i][1, 1] * 2 for i in 1:5]
    if _HAVE_CASACORE
        ct = CCT.Table(dir)                                   # 1-based UVW[3] must agree
        @test ct[:W][:] == [3.0i for i in 1:5]
        @test ct[:V11][:] == [V[i][1, 1] * 2 for i in 1:5]
    end
end

@testset "engine — VirtualTaQLColumn: unsupported expr + copy + edit guard" begin
    dir = joinpath(mktempdir(), "vtq2.tab")
    A = collect(1.0:5.0)
    write_table(dir, "T", ["A" => A, "BAD" => zeros(5), "OK" => zeros(5)]; nrow=5,
        virtualtaql = Dict("BAD" => "substr(A, 1, 2)", "OK" => "A + 10.0"))  # substr: unsupported fn
    r = readtable(dir)
    @test column(r, "A")[:] == A                              # rest of the table is fine
    @test column(r, "OK")[:] == A .+ 10
    err = try column(r, "BAD")[1]; nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("BAD", err.msg) && occursin("substr(A, 1, 2)", err.msg)

    dst = joinpath(mktempdir(), "vtq_copy.tab")
    copytable(dst, readtable(dir))            # BAD is dropped (unreadable); OK is preserved
    rc = readtable(dst)
    @test _engine_manager(rc, "OK").name == "VirtualTaQLColumn"        # preserved, not materialised
    @test column(rc, "OK")[:] == A .+ 10
    @test !isfile(joinpath(dst, "table.f$(_engine_manager(rc, "OK").sequ)"))

    @test_throws ErrorException edit(dir) do t end               # computed column -> refuse edit
end

# Phase 214: `_vtq_prepare!` warns (doesn't error) on a non-default TaQL
# style keyword (`_VirtualTaQLEngine_Style` -- real casacore can write
# e.g. `"python"` for 0-based array indexing; TaQL-lite has no array-
# indexing style concept at all). This package's own writer always
# writes `""`, so hand-set the style on a real, opened instance (the
# same technique used elsewhere in this file for an otherwise
# unreachable-via-our-own-writer real casacore state).
@testset "engine — VirtualTaQLColumn warns on a non-default TaQL style (Phase 214)" begin
    dir = joinpath(mktempdir(), "vtqstyle.tab")
    A = collect(1.0:5.0)
    write_table(dir, "T", ["A" => A, "CV" => zeros(5)]; nrow=5,
        virtualtaql = Dict("CV" => "A + 1.0"))
    r = readtable(dir)
    inst = MSv2E._dm_instance(r, _engine_manager(r, "CV").sequ)
    inst.style = "python"
    logs, _ = Test.collect_test_logs() do
        MSv2E._vtq_prepare!(inst)
    end
    @test length(logs) == 1 && logs[1].level == Base.CoreLogging.Warn
    @test occursin("CV", logs[1].message) && occursin("python", logs[1].message)
end

# Phase 213 (src/datamanagers sweep, continued): three genuinely-reachable
# VirtualTaQLColumn combinations that `_vtq_prepare!`/`getcell`/`getcolumn`
# already handle correctly but had zero test coverage.
import Unitful, UnitfulAngles, UnitfulAstro
const _HAVE_UNITFUL_VTQ = Base.get_extension(MSv2E, :UnitfulExt) !== nothing

if _HAVE_UNITFUL_VTQ
    @testset "engine — VirtualTaQLColumn with a quantity literal (Phase 213)" begin
        dir = joinpath(mktempdir(), "vtqqty.tab")
        A = [1.0e9, 1.5e9, 2.0e9]
        write_table(dir, "T", Pair{String,Any}["A" => A, "HI" => falses(3)]; nrow=3,
            units = Dict("A" => "Hz"), virtualtaql = Dict("HI" => "A > 1.4GHz"))
        r = readtable(dir)
        @test _engine_manager(r, "HI").name == "VirtualTaQLColumn"
        @test column(r, "HI")[:] == [false, true, true]
    end
end

@testset "engine — VirtualTaQLColumn with an array-typed result (Phase 213)" begin
    dir = joinpath(mktempdir(), "vtqarr2.tab")
    V = [reshape(Float64.(1:6), 2, 3) .+ 10i for i in 0:2]
    write_table(dir, "T", Pair{String,Any}["V" => V, "V2" => V]; nrow=3,
        tsm = [["V"]], virtualtaql = Dict("V2" => "V * 2.0"))
    r = readtable(dir)
    @test [column(r, "V2")[i] for i in 1:3] == [v .* 2 for v in V]
    @test column(r, "V2")[:] == [v .* 2 for v in V]
end

# `_vtq_err`'s wrapping is only reachable from a RUNTIME (per-row)
# evaluation error -- distinct from the parse-time error the existing
# "unsupported expr" testset above already exercises (that one throws
# inside `_vtq_prepare!`, before `getcell`'s own try/catch is even
# entered). An out-of-range, row-dependent array index is a real runtime
# error for one specific row only.
@testset "engine — VirtualTaQLColumn runtime evaluation error (Phase 213)" begin
    dir = joinpath(mktempdir(), "vtqerr.tab")
    V = [reshape(Float64.(1:6), 2, 3) for _ in 1:3]
    K = Int32[1, 1, 9]                              # row 3: out of range for V's first axis
    write_table(dir, "T", Pair{String,Any}["V" => V, "K" => K, "OUT" => zeros(3)]; nrow=3,
        tsm=[["V"]], virtualtaql = Dict("OUT" => "V[K,1]"))
    r = readtable(dir)
    @test column(r, "OUT")[1] == V[1][1, 1]
    @test column(r, "OUT")[2] == V[2][1, 1]
    err = try column(r, "OUT")[3]; nothing catch e; e end
    @test err isa ArgumentError
    @test occursin("OUT", err.msg) && occursin("V[K,1]", err.msg)

    r2 = readtable(dir)                             # same error via the bulk getcolumn path
    err2 = try column(r2, "OUT")[:]; nothing catch e; e end
    @test err2 isa ArgumentError
    @test occursin("OUT", err2.msg) && occursin("V[K,1]", err2.msg)
end
