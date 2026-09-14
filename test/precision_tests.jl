# Phase 34: half-precision (ComplexF16) MAIN-table visibility reads.

@testset "precision — MAIN DATA defaults to ComplexF16" begin
    t  = readtable(SAMPLE_MS)
    tf = readtable(SAMPLE_MS; precision=:full)

    @test t.type == "Measurement Set"
    @test t.precision === :half
    @test tf.precision === :full

    # TpComplex visibility columns narrow; TpFloat / Bool / Float64 do not
    @test eltype(column(t, "DATA"))   == Matrix{ComplexF16}
    @test eltype(column(t, "WEIGHT")) == Vector{Float32}     # real weights exceed Float16
    @test eltype(column(t, "SIGMA"))  == Vector{Float32}
    @test eltype(column(t, "FLAG"))   == Matrix{Bool}
    @test eltype(column(t, "TIME"))   == Float64
    @test eltype(column(t, "UVW"))    == Vector{Float64}

    # :full restores ComplexF32
    @test eltype(column(tf, "DATA")) == Matrix{ComplexF32}

    # values agree to ComplexF16 precision
    for r in (1, 2, 37, nrow(t))
        dh = column(t, "DATA")[r]
        df = column(tf, "DATA")[r]
        @test dh isa Matrix{ComplexF16}
        @test isapprox(ComplexF32.(dh), df; rtol = 2.0f0^-9, atol = 1f-3)
    end

    # cell read and bulk read narrow consistently
    dcol_head = [column(t, "DATA")[r] for r in 1:4]
    @test all(eltype(x) == ComplexF16 for x in dcol_head)

    # per-column overrides
    @test eltype(column(t, "DATA"; precision=:full))     == Matrix{ComplexF32}
    @test eltype(column(t, "WEIGHT"; precision=Float16)) == Vector{Float16}   # forced, caller's risk
    @test eltype(column(t, "WEIGHT"; precision=BFloat16)) == Vector{BFloat16}

    # off-MAIN: subtable defaults to :full, an explicit type still narrows
    sp = readtable(joinpath(SAMPLE_MS, "SYSPOWER"))
    @test sp.precision === :full
    @test eltype(column(sp, "SWITCHED_DIFF")) <: AbstractArray{Float32}
    @test eltype(column(sp, "SWITCHED_DIFF"; precision=Float16)) <: AbstractArray{Float16}
end

@testset "precision — BFloat16" begin
    t  = readtable(SAMPLE_MS; precision=BFloat16)
    tf = readtable(SAMPLE_MS; precision=:full)
    @test t.precision === BFloat16

    @test eltype(column(t, "DATA"))   == Matrix{Complex{BFloat16}}
    @test eltype(column(t, "WEIGHT")) == Vector{BFloat16}      # no overflow (BFloat16 has F32 range)
    @test eltype(column(t, "SIGMA"))  == Vector{BFloat16}
    @test eltype(column(t, "FLAG"))   == Matrix{Bool}
    @test eltype(column(t, "TIME"))   == Float64               # never narrowed

    for r in (1, 37, nrow(t))
        wb = column(t, "WEIGHT")[r]
        @test all(isfinite, Float32.(wb))
        @test isapprox(Float32.(wb), column(tf, "WEIGHT")[r]; rtol = 2.0f0^-7)
        db = column(t, "DATA")[r]
        @test isapprox(ComplexF32.(db), column(tf, "DATA")[r]; rtol = 2.0f0^-6, atol = 1f-2)
    end
    @test column(t, "DATA")[:][1] isa AbstractMatrix{Complex{BFloat16}}   # bulk path

    # precision=Float32 is an alias for :full
    @test readtable(SAMPLE_MS; precision=Float32).precision === :full
    @test_throws ArgumentError readtable(SAMPLE_MS; precision=Int32)

    # non-float types are left alone by the narrowing map
    @test MSv2._narrowtype(Float64, BFloat16) === Float64
    @test MSv2._narrowtype(Bool, BFloat16) === Bool
    @test MSv2._narrowtype(ComplexF64, BFloat16) === ComplexF64
end

# Phase 198: found live -- an invalid `precision=` on `column`/
# `getcolumn`/`getcell` (a typo like `:hal` for `:half`) used to be
# silently accepted as "no narrowing" instead of erroring, unlike the
# identical check `readtable` already made on the same set of values.
# `_narrowtarget`'s own three branches simply fell through to `nothing`
# for anything they didn't recognize -- no validation at all. Fixed by
# routing every `precision=` override through the same
# `_normalize_precision` `readtable` uses.
@testset "precision — column()/getcolumn()/getcell() validate precision= too (Phase 198)" begin
    t = readtable(SAMPLE_MS)
    # valid values still work identically to before
    @test eltype(column(t, "DATA"; precision = :half)) == Matrix{ComplexF16}
    @test eltype(column(t, "DATA"; precision = :full)) == Matrix{ComplexF32}
    @test eltype(column(t, "DATA"; precision = Float32)) == Matrix{ComplexF32}   # alias for :full
    @test eltype(column(t, "DATA"; precision = BFloat16)) == Matrix{Complex{BFloat16}}
    # an invalid value now errors on every precision-accepting entry point
    @test_throws ArgumentError column(t, "DATA"; precision = :hal)      # typo
    @test_throws ArgumentError column(t, "DATA"; precision = :HALF)     # wrong case
    @test_throws ArgumentError column(t, "DATA"; precision = Int32)
    @test_throws ArgumentError getcolumn(t, "DATA"; precision = :bogus)
    @test_throws ArgumentError getcell(t, "DATA", 1; precision = :bogus)
    # propagates through a RefTable's MappedColumn (forwards to
    # `column(::Table, …)`, so no separate fix was needed there)
    rt = query(t, "ANTENNA1 == 0")
    @test_throws ArgumentError column(rt, "DATA"; precision = :bogus)
    @test_throws ArgumentError getcolumn(rt, "DATA"; precision = :bogus)
end

@testset "precision — MeasurementSet + views" begin
    ms  = MeasurementSet(SAMPLE_MS)
    msf = MeasurementSet(SAMPLE_MS; precision=:full)
    @test eltype(ms[:DATA])  == Matrix{ComplexF16}
    @test eltype(msf[:DATA]) == Matrix{ComplexF32}

    # a query / RefTable over a half MAIN inherits the narrowed eltype
    q = query(ms.data, "ANTENNA1 == 0")
    @test eltype(column(q, "DATA")) == Matrix{ComplexF16}
end

@testset "precision — getcolumn(ms, sub, name; precision=...) (Phase 206)" begin
    # the 3-arg `getcolumn(ms, sub, name)` convenience overload had no
    # `precision=` kwarg at all -- its 2-arg sibling `getcolumn(t, name;
    # precision)` has had one since Phase 34, and `column(t, name;
    # precision)`/`getcell(t, name, row; precision)` both have it too --
    # found via the "one last sweep, look for feature gaps too" pass.
    # `FEED.POL_RESPONSE` is a real `TpComplex` subtable column (both in
    # the sample MS and a synthetic `create_ms`), so it's a genuine
    # narrowing candidate even though subtables default to `:full`.
    ms = MeasurementSet(SAMPLE_MS)
    @test eltype(getcolumn(ms, "FEED", "POL_RESPONSE")) == Matrix{ComplexF32}   # subtable default: :full
    @test eltype(getcolumn(ms, "FEED", "POL_RESPONSE"; precision=:half)) == Matrix{ComplexF16}
    @test eltype(getcolumn(ms, "FEED", "POL_RESPONSE"; precision=:full)) == Matrix{ComplexF32}
    @test getcolumn(ms, "FEED", "POL_RESPONSE") ==
          getcolumn(subtable(ms, "FEED"), "POL_RESPONSE")   # unchanged default behaviour

    # `getcell(ms, sub, name, row)` was missing entirely -- an asymmetry
    # with `getcolumn(ms, sub, name)`, which already existed; added
    # alongside it in the same phase.
    @test eltype(getcell(ms, "FEED", "POL_RESPONSE", 1)) == ComplexF32
    @test eltype(getcell(ms, "FEED", "POL_RESPONSE", 1; precision=:half)) == ComplexF16
    @test getcell(ms, "FEED", "POL_RESPONSE", 1) ==
          getcell(subtable(ms, "FEED"), "POL_RESPONSE", 1)

    # `column(ms, sub, name)` — the lazy verb `getcolumn`/`getcell` are
    # both built on — was missing too, completing the family.
    lcol = column(ms, "FEED", "POL_RESPONSE")
    @test lcol isa MSv2.Column
    @test eltype(lcol) == Array{ComplexF32}
    @test eltype(column(ms, "FEED", "POL_RESPONSE"; precision=:half)) == Array{ComplexF16}
    @test lcol[1] == getcell(ms, "FEED", "POL_RESPONSE", 1)
    @test collect(lcol) == getcolumn(ms, "FEED", "POL_RESPONSE")
end

@testset "precision — readtable(refpath; precision=...) on a persisted RefTable/ConcatTable (Phase 203)" begin
    # `readtable` computed its own resolved `prec` but never threaded it
    # into `_read_reftable`/`_read_concattable` at all -- so
    # `readtable(refpath; precision=:full)` on a *persisted*
    # RefTable/ConcatTable silently reopened the parent(s) at THEIR OWN
    # auto-derived default instead, a real no-op for the explicit-override
    # case. Masked in the common case because a RefTable's own
    # `table.info` Type is always copied verbatim from its parent (Phase
    # 15), so the auto-derived DEFAULT happened to already agree with
    # what the parent would derive on its own -- only an *explicit*
    # `precision=` was silently dropped. Live-verified reachable via
    # `write_reftable`/`write_concattable` + `readtable(...;
    # precision=:full)`. Fixed by threading the raw (possibly `nothing`)
    # `precision` argument through `_read_reftable`/`_read_concattable`/
    # `_open_referenced`, so the default case re-derives exactly as
    # before (unchanged) and an explicit value now genuinely propagates.
    dir = mktempdir()
    rdir = joinpath(dir, "RT")
    write_reftable(rdir, query(readtable(SAMPLE_MS), "rownumber() <= 5"))

    @test eltype(column(readtable(rdir), "DATA")) == Matrix{ComplexF16}         # default unchanged
    @test eltype(column(readtable(rdir; precision=:full), "DATA")) == Matrix{ComplexF32}
    @test eltype(column(readtable(rdir; precision=BFloat16), "DATA")) == Matrix{Complex{BFloat16}}

    # `resync` preserves whatever precision was actually in effect (a
    # RefTable/ConcatTable has no `precision` field of its own -- it's
    # recovered from the underlying Table(s), the same fix needed on the
    # `resync` side as on the initial-open side).
    rt_full = readtable(rdir; precision=:full)
    @test MSv2._effective_precision(rt_full) == :full
    @test resync(rt_full) === rt_full                    # not stale yet
    @test eltype(column(resync(rt_full), "DATA")) == Matrix{ComplexF32}

    # ConcatTable
    cdir = joinpath(dir, "C")
    p1 = joinpath(dir, "p1"); p2 = joinpath(dir, "p2")
    copyms(SAMPLE_MS, p1; rows=1:3, subtables=String[])
    copyms(SAMPLE_MS, p2; rows=4:6, subtables=String[])
    write_concattable(cdir, [readtable(p1), readtable(p2)])
    @test eltype(column(readtable(cdir), "DATA")) == Matrix{ComplexF16}
    @test eltype(column(readtable(cdir; precision=:full), "DATA")) == Matrix{ComplexF32}
end

@testset "precision — copies stay byte-exact, half writes upcast" begin
    dir = mktempdir()
    dst = joinpath(dir, "c.ms")
    copyms(SAMPLE_MS, dst; rows = 1:80, subtables = ["ANTENNA", "SPECTRAL_WINDOW"])

    src = readtable(SAMPLE_MS; precision=:full)
    cp  = readtable(dst; precision=:full)
    @test cp.type == "Measurement Set"
    @test column(cp, "DATA")[:]   == column(src, "DATA")[1:80]     # not ComplexF16-rounded
    @test column(cp, "WEIGHT")[:] == column(src, "WEIGHT")[1:80]

    # Phase 35: the narrow col[:] holds a half-size buffer (decoded straight
    # into ComplexF16 -- no wide intermediate) and allocates less than the
    # old "read wide then convert" would.
    th = readtable(dst); tf = readtable(dst; precision=:full)
    dh = column(th, "DATA")[:]
    df = column(tf, "DATA")[:]
    @test eltype(eltype(dh)) == ComplexF16
    @test Base.summarysize(dh) < 0.6 * Base.summarysize(df)
    column(th, "DATA")[:]; column(tf, "DATA")[:]                 # warm caches
    GC.gc(); a_new = @allocated column(th, "DATA")[:]
    GC.gc(); a_old = @allocated map(x -> ComplexF16.(x), column(tf, "DATA")[:])
    @test a_new < a_old

    # a BFloat16 read source still copies byte-exact (copy path forces :full)
    dst2 = joinpath(dir, "bf.ms")
    copyms(SAMPLE_MS, dst2; rows = 1:80, subtables = ["ANTENNA"])
    @test column(readtable(dst2; precision=:full), "DATA")[:] == column(src, "DATA")[1:80]

    # Float16 / BFloat16 / their Complex are writable (upcast to Float32 CTDS type)
    p = joinpath(dir, "half")
    write_table(p, "T", Pair{String,Any}["X"  => Float16[1, 2, 3],
                                         "Z"  => ComplexF16[1+0im, 2-1im, 0+3im],
                                         "XB" => BFloat16[1, 2, 3],
                                         "ZB" => Complex{BFloat16}[1+0im, 2-1im, 0+3im]]; nrow=3)
    r = readtable(p)                                               # type "" -> :full
    @test MSv2.columndesc(r, "X").type  == MSv2.TpFloat
    @test MSv2.columndesc(r, "Z").type  == MSv2.TpComplex
    @test MSv2.columndesc(r, "XB").type == MSv2.TpFloat
    @test MSv2.columndesc(r, "ZB").type == MSv2.TpComplex
    @test column(r, "X")[:]  == Float32[1, 2, 3]
    @test column(r, "XB")[:] == Float32[1, 2, 3]
    @test column(r, "ZB")[:] == ComplexF32[1+0im, 2-1im, 0+3im]
end
