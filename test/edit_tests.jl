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
