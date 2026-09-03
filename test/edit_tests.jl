# Phase 9: in-place edits (open an existing table for update).

@testset "edit — overwrite cells & columns" begin
    dst = joinpath(mktempdir(), "e.ms")
    create_ms(dst; nrow=8, nchan=4, ncorr=2, nant=3)
    ms0 = MeasurementSet(dst)
    time0 = copy(ms0[:TIME][:])
    uvw1  = copy(ms0[:UVW][1])
    flag4 = copy(ms0[:FLAG][4])

    edit(dst) do t
        t[:TIME][3] = 9.9e9                     # ISM scalar -> file regen
        t[:UVW][2] = [1.0, 2.0, 3.0]            # SSM fixed array -> file regen
        t[:FLAG][5] = trues(2, 4)               # TSM cell -> in-place tile patch
        t[:SCAN_NUMBER][:] = Int32.(1:8)        # whole ISM column
    end

    ms = MeasurementSet(dst)
    @test ms[:TIME][3] == 9.9e9
    @test ms[:TIME][1] == time0[1]              # untouched row intact
    @test ms[:UVW][2] == [1.0, 2.0, 3.0]
    @test ms[:UVW][1] == uvw1
    @test all(ms[:FLAG][5])
    @test ms[:FLAG][4] == flag4
    @test ms[:SCAN_NUMBER][:] == Int32.(1:8)
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test ct[:TIME][3] == 9.9e9
        @test all(ct[:FLAG][5])
        @test collect(ct[:SCAN_NUMBER][:]) == Int32.(1:8)
        @test ct[:UVW][:, 2] == [1.0, 2.0, 3.0]
    end
end

@testset "edit — hybrid persist leaves untouched managers alone" begin
    dst = joinpath(mktempdir(), "e2.ms")
    create_ms(dst; nrow=8, nchan=4, ncorr=2, nant=3)
    r = readtable(dst)
    ismf = joinpath(dst, string("table.f",
        first(m.sequ for m in r.managers if m.name == "IncrementalStMan")))
    ssmf = joinpath(dst, string("table.f",
        first(m.sequ for m in r.managers if m.name == "StandardStMan")))
    before = (filesize(ismf), read(ismf), filesize(ssmf), read(ssmf))

    edit(dst) do t
        t[:FLAG][2] = falses(2, 4)              # touches only the TSM FLAG file
    end

    @test (filesize(ismf), read(ismf), filesize(ssmf), read(ssmf)) == before
end

@testset "edit — addrows!" begin
    dst = joinpath(mktempdir(), "e3.ms")
    create_ms(dst; nrow=8, nchan=4, ncorr=2, nant=3)
    ms0 = MeasurementSet(dst)
    time0 = copy(ms0[:TIME][:])
    data1 = copy(ms0[:DATA][1])

    edit(dst) do t
        addrows!(t, 5)
        for r in 9:13
            t[:TIME][r] = 4.6e9 + r
            t[:DATA][r] = fill(ComplexF32(r), 2, 4)
            t[:SCAN_NUMBER][r] = Int32(r)
        end
    end

    ms = MeasurementSet(dst)
    @test getfield(ms, :data).rows == 13
    @test ms[:TIME][1:8] == time0
    @test ms[:TIME][9:13] == [4.6e9 + r for r in 9:13]
    @test ms[:DATA][1] == data1                 # untouched TSM row
    @test ms[:DATA][11] == fill(ComplexF32(11), 2, 4)
    @test ms[:SCAN_NUMBER][9:13] == Int32.(9:13)
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test size(ct, 1) == 13
        @test [ct[:TIME][r] for r in 9:13] == [4.6e9 + r for r in 9:13]
        @test ct[:DATA][11] == fill(ComplexF32(11), 2, 4)
        @test collect(ct[:SCAN_NUMBER][:])[1:8] == collect(ms0[:SCAN_NUMBER][:])
    end
end

@testset "edit — re-edit converges" begin
    dst = joinpath(mktempdir(), "e4.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)
    edit(dst) do t; t[:TIME][1] = 1.0 end
    edit(dst) do t; t[:TIME][1] = 2.0 end
    edit(dst) do t; addrows!(t, 2); t[:TIME][7] = 7.0; t[:TIME][8] = 8.0 end
    ms = MeasurementSet(dst)
    @test ms[:TIME][1] == 2.0
    @test getfield(ms, :data).rows == 8
    @test ms[:TIME][7:8] == [7.0, 8.0]
end

@testset "edit — removerows!" begin
    dst = joinpath(mktempdir(), "r1.ms")
    create_ms(dst; nrow=10, nchan=4, ncorr=2, nant=3)

    edit(dst) do t
        for r in 1:10
            t[:TIME][r]  = 100.0 + r                # ISM
            t[:UVW][r]   = Float64[r, r, r]         # SSM direct array
            t[:DATA][r]  = fill(ComplexF32(r), 2, 4) # TSM
        end
        removerows!(t, [2, 5, 9])
    end

    keep = [1, 3, 4, 6, 7, 8, 10]
    ms = MeasurementSet(dst)
    @test getfield(ms, :data).rows == 7
    @test ms[:TIME][:] == [100.0 + r for r in keep]
    @test [ms[:UVW][i] for i in 1:7] == [Float64[r, r, r] for r in keep]
    @test [ms[:DATA][i] for i in 1:7] == [fill(ComplexF32(r), 2, 4) for r in keep]
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test size(ct, 1) == 7
        @test collect(ct[:TIME][:]) == [100.0 + r for r in keep]
        @test ct[:UVW][:, 4] == Float64[6, 6, 6]
        @test ct[:DATA][3] == fill(ComplexF32(4), 2, 4)
    end
end

@testset "edit — removerows! + addrows! mixed" begin
    dst = joinpath(mktempdir(), "r2.ms")
    create_ms(dst; nrow=10, nchan=4, ncorr=2, nant=3)
    time0 = copy(MeasurementSet(dst)[:TIME][:])

    edit(dst) do t
        removerows!(t, [1, 2, 3])                   # keep original rows 4..10
        addrows!(t, 2)                              # -> 9 rows
        t[:TIME][8] = 5.0
        t[:TIME][9] = 6.0
    end

    ms = MeasurementSet(dst)
    @test getfield(ms, :data).rows == 9
    @test ms[:TIME][1:7] == time0[4:10]
    @test ms[:TIME][8:9] == [5.0, 6.0]
    @test isempty(validate(ms))
end

@testset "edit — addcolumn! (standard schema)" begin
    dst = joinpath(mktempdir(), "c1.ms")
    create_ms(dst; nrow=6, nchan=4, ncorr=2, nant=3)
    dataseq = columndesc(readtable(dst), "DATA").sequ
    dfile = joinpath(dst, "table.f$(dataseq)_TSM1")
    dbefore = read(dfile)

    edit(dst) do t
        addcolumn!(t, "WEIGHT_SPECTRUM")
        t[:WEIGHT_SPECTRUM][:] = [fill(Float32(i), 2, 4) for i in 1:6]
    end

    @test read(dfile) == dbefore                    # untouched TSM file byte-identical
    ms = MeasurementSet(dst)
    @test "WEIGHT_SPECTRUM" in columnnames(getfield(ms, :data))
    @test ms[:WEIGHT_SPECTRUM][3] == fill(3f0, 2, 4)
    @test ms[:DATA][2] == zeros(ComplexF32, 2, 4)   # other columns intact
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test ct[:WEIGHT_SPECTRUM][3] == fill(3f0, 2, 4)
    end
end

@testset "edit — addcolumn! custom then removecolumn!" begin
    dst = joinpath(mktempdir(), "c2.ms")
    create_ms(dst; nrow=5, nchan=4, ncorr=2, nant=3)

    edit(dst) do t
        addcolumn!(t, "FOO", collect(1.0:5.0))
    end
    ms = MeasurementSet(dst)
    @test ms[:FOO][:] == collect(1.0:5.0)
    @test isempty(validate(ms))

    edit(dst) do t
        removecolumn!(t, "FOO")
    end
    r = readtable(dst)
    @test !("FOO" in columnnames(r))
    @test isempty(validate(MeasurementSet(dst)))
    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test !("FOO" in [string(n) for n in propertynames(ct)])
    end
end

@testset "edit — removecolumn! drops a whole storage manager" begin
    dst = joinpath(mktempdir(), "c3.ms")
    create_ms(dst; nrow=5, nchan=4, ncorr=2, nant=3)

    edit(dst) do t
        addcolumn!(t, "BAR", [zeros(Float32, 2, 2) for _ in 1:5];
                   kind=:tsm, shape=VariableShape())
    end
    barseq = columndesc(readtable(dst), "BAR").sequ
    @test isfile(joinpath(dst, "table.f$(barseq)_TSM1"))

    edit(dst) do t
        removecolumn!(t, "BAR")
    end
    @test !isfile(joinpath(dst, "table.f$(barseq)_TSM1"))
    @test !isfile(joinpath(dst, "table.f$(barseq)"))
    r = readtable(dst)
    @test !("BAR" in columnnames(r))
    @test !any(m -> m.sequ == barseq, r.managers)
    @test isempty(validate(MeasurementSet(dst)))
end

if isdir(SAMPLE_MS)
    @testset "edit — removerows! on a sample slice" begin
        src = MeasurementSet(SAMPLE_MS)
        drop = [i for i in 1:40 if iseven(i)]
        keep = [i for i in 1:40 if isodd(i)]
        d_keep = [copy(src["DATA"][i]) for i in keep]
        t_keep = [src["TIME"][i] for i in keep]
        u_keep = [copy(src["UVW"][i]) for i in keep]

        dst = joinpath(mktempdir(), "r3.ms")
        copyms(SAMPLE_MS, dst; rows=1:40,
               subtables=["ANTENNA", "SPECTRAL_WINDOW", "POLARIZATION"])
        edit(dst) do t
            removerows!(t, drop)
        end

        o = MeasurementSet(dst)
        @test getfield(o, :data).rows == 20
        @test [o[:DATA][i] for i in 1:20] == d_keep
        @test [o[:TIME][i] for i in 1:20] == t_keep
        @test [o[:UVW][i] for i in 1:20] == u_keep
        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test size(ct, 1) == 20
            @test ct[:DATA][7] == d_keep[7]
            @test collect(ct[:TIME][:]) == t_keep
        end
    end
end

if isdir(SAMPLE_MS)
    @testset "edit — copyms slice then edit" begin
        src = MeasurementSet(SAMPLE_MS)
        d10 = copy(src["DATA"][10])
        f20 = copy(src["FLAG"][20])
        dst = joinpath(mktempdir(), "e5.ms")
        copyms(SAMPLE_MS, dst; rows=1:100,
               subtables=["ANTENNA", "SPECTRAL_WINDOW", "POLARIZATION"])

        edit(dst) do t
            t[:DATA][10] = conj.(d10)
            t[:FLAG][20] = .!f20
            t[:SCAN_NUMBER][50] = Int32(9999)
            addrows!(t, 3)
            for r in 101:103
                t[:TIME][r] = 5.0e9 + r
                t[:DATA][r] = zeros(ComplexF32, size(d10))
            end
        end

        o = MeasurementSet(dst)
        @test getfield(o, :data).rows == 103
        @test o[:DATA][10] == conj.(d10)
        @test o[:DATA][9] == src["DATA"][9]
        @test o[:FLAG][20] == .!f20
        @test o[:SCAN_NUMBER][50] == 9999
        @test o[:SCAN_NUMBER][49] == src["SCAN_NUMBER"][49]
        @test o[:TIME][102] == 5.0e9 + 102
        if _HAVE_CASACORE
            ct = CCT.Table(dst)
            @test size(ct, 1) == 103
            @test ct[:DATA][10] == conj.(d10)
            @test ct[:TIME][103] == 5.0e9 + 103
        end
    end
end
