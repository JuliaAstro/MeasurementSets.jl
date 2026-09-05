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
    for r in (1, 2, 37, 1000)
        dh = column(t, "DATA")[r]
        df = column(tf, "DATA")[r]
        @test dh isa Matrix{ComplexF16}
        @test isapprox(ComplexF32.(dh), df; rtol = 2.0f0^-9, atol = 1f-3)
    end

    # cell read and bulk read narrow consistently
    dcol_head = [column(t, "DATA")[r] for r in 1:4]
    @test all(eltype(x) == ComplexF16 for x in dcol_head)

    # per-column overrides
    @test eltype(column(t, "DATA"; precision=:full))   == Matrix{ComplexF32}
    @test eltype(column(t, "WEIGHT"; precision=:half)) == Vector{Float16}   # forced, caller's risk

    # off-MAIN: subtable defaults to :full, explicit :half still works
    sp = readtable(joinpath(SAMPLE_MS, "SYSPOWER"))
    @test sp.precision === :full
    @test eltype(column(sp, "SWITCHED_DIFF")) <: AbstractArray{Float32}
    @test eltype(column(sp, "SWITCHED_DIFF"; precision=:half)) <: AbstractArray{Float16}
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

    # a Float16 / ComplexF16 column is writable (upcast to the Float32 CTDS type)
    p = joinpath(dir, "half")
    write_table(p, "T", Pair{String,Any}["X" => Float16[1, 2, 3],
                                         "Z" => ComplexF16[1+0im, 2-1im, 0+3im]]; nrow=3)
    r = readtable(p)                                               # type "" -> :full
    @test MSv2.columndesc(r, "X").type == MSv2.TpFloat
    @test MSv2.columndesc(r, "Z").type == MSv2.TpComplex
    @test column(r, "X")[:] == Float32[1, 2, 3]
end
