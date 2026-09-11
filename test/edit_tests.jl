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
    dfile = joinpath(dst, "table.f$(dataseq)_TSM1")   # DATA+FLAG+WEIGHT_SPECTRUM share it
    dbefore = read(dfile)

    edit(dst) do t
        addcolumn!(t, "SIGMA_SPECTRUM")
        t[:SIGMA_SPECTRUM][:] = [fill(Float32(i), 2, 4) for i in 1:6]
    end

    @test read(dfile) == dbefore                    # untouched shared TSM file byte-identical
    ms = MeasurementSet(dst)
    @test "SIGMA_SPECTRUM" in columnnames(getfield(ms, :data))
    @test ms[:SIGMA_SPECTRUM][3] == fill(3f0, 2, 4)
    @test ms[:DATA][2] == zeros(ComplexF32, 2, 4)   # other columns intact
    @test isempty(validate(ms))

    if _HAVE_CASACORE
        ct = CCT.Table(dst)
        @test ct[:SIGMA_SPECTRUM][3] == fill(3f0, 2, 4)
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

# Phase 125: edit(rt::RefTable) -- a thin write-through view: `rv[name][i]
# = v` translates through rt.rows/rt.namemap and writes the *parent*
# table's mapped row (casacore's own RefColumn::put is a pure row-index
# translation to the parent's column -- no separate storage to edit).
@testset "edit — through a RefTable view (Phase 125)" begin
    dir = joinpath(mktempdir(), "re.tab")
    n = 8
    write_table(dir, "T",
        ["K" => collect(Int32, 1:n), "V" => Float64.(1:n),
         "A" => [Float64[i, i + 1, i + 2] for i in 1:n]];
        nrow = n, tsm = [["A"]])

    t0 = readtable(dir)
    rt = query(t0, "K > 4")                      # rows 5,6,7,8
    @test rt.rows == [5, 6, 7, 8]

    edit(rt) do rv
        rv["V"][1] = 100.0                        # -> parent row 5
        rv[:V][4] = 400.0                          # -> parent row 8
        rv["A"][2] = [9.0, 9.0, 9.0]               # tsm cell -> parent row 6
    end

    r2 = readtable(dir)
    @test column(r2, "V")[:] == [1.0, 2.0, 3.0, 4.0, 100.0, 6.0, 7.0, 400.0]
    @test column(r2, "A")[6] == [9.0, 9.0, 9.0]
    @test column(r2, "A")[5] == [5.0, 6.0, 7.0]    # untouched sibling row

    # whole-view-column assignment
    rt2 = query(readtable(dir), "K <= 4")          # rows 1,2,3,4
    edit(rt2) do rv
        rv[:V][:] = [10.0, 20.0, 30.0, 40.0]
    end
    r3 = readtable(dir)
    @test column(r3, "V")[1:4] == [10.0, 20.0, 30.0, 40.0]
    @test column(r3, "V")[5:8] == [100.0, 6.0, 7.0, 400.0]   # unaffected

    # errors: unknown column
    rt3 = query(readtable(dir), "K > 4")
    @test_throws ErrorException edit(rt3) do rv
        rv[:NOPE]
    end

    # a RefTable of a RefTable flattens to the real (plain-Table) ancestor
    # (Phase 22's `_flatten_query_parent`), so it's editable too -- the
    # "only a plain Table parent" guard needs a genuinely non-Table
    # ancestor, e.g. a ConcatTable.
    rtnest = query(rt3, "K > 6")
    @test rtnest.parent isa Table
    edit(rtnest) do rv
        rv[:V][1] = 700.0
    end
    @test column(readtable(dir), "V")[7] == 700.0

    ccdir = joinpath(mktempdir(), "cc.tab")
    write_concattable(ccdir, [readtable(dir), readtable(dir)])
    rtcc = query(readtable(ccdir), "K > 4")
    @test rtcc.parent isa MSv2.ConcatTable
    @test_throws ErrorException edit(rtcc)

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:V][:] == [10.0, 20.0, 30.0, 40.0, 100.0, 6.0, 700.0, 400.0]
    end
end

# Phase 126: addcolumn! through a RefTable view -- matches
# RefTable::addColumn(addToParent=true): the column lands on the
# PARENT's schema (every parent row gets a default), and only the
# view's own mapped rows get the given data.
@testset "edit — addcolumn! through a RefTable view (Phase 126)" begin
    dir = joinpath(mktempdir(), "rac.tab")
    n = 6
    write_table(dir, "T", ["K" => collect(Int32, 1:n), "V" => Float64.(1:n)]; nrow = n)

    rt = query(readtable(dir), "K > 3")           # rows 4,5,6
    edit(rt) do rv
        addcolumn!(rv, "W", [10.0, 20.0, 30.0])   # one value per view row
    end
    r2 = readtable(dir)
    @test "W" in columnnames(r2)
    @test column(r2, "W")[:] == [0.0, 0.0, 0.0, 10.0, 20.0, 30.0]   # rest defaulted

    # standard-schema no-data form (every parent row gets the default)
    rt2 = query(readtable(dir), "K <= 2")
    edit(rt2) do rv
        addcolumn!(rv, "SCAN_NUMBER")
        rv[:SCAN_NUMBER][1] = Int32(99)
    end
    r3 = readtable(dir)
    @test "SCAN_NUMBER" in columnnames(r3)
    @test column(r3, "SCAN_NUMBER")[1] == 99
    @test column(r3, "SCAN_NUMBER")[3] == 0

    # errors: duplicate name, wrong length
    rt3 = query(readtable(dir), "K > 3")
    @test_throws ErrorException edit(rt3) do rv
        addcolumn!(rv, "V", [1.0, 2.0, 3.0])       # "V" already exists
    end
    rt4 = query(readtable(dir), "K > 3")
    @test_throws ErrorException edit(rt4) do rv
        addcolumn!(rv, "X", [1.0, 2.0])            # wrong length (3 rows, not 2)
    end

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:W][:] == [0.0, 0.0, 0.0, 10.0, 20.0, 30.0]
    end
end

# Phase 127: removecolumn! on a RefEditTable -- a pure view-level hide,
# matching RefTable::removeColumn exactly: the parent's real storage
# (and anything pending in its own edit session) is never touched.
@testset "edit — removecolumn! on a RefEditTable view (Phase 127)" begin
    dir = joinpath(mktempdir(), "rrc.tab")
    n = 5
    write_table(dir, "T", ["K" => collect(Int32, 1:n), "V" => Float64.(1:n)]; nrow = n)

    rt = query(readtable(dir), "K > 2")           # rows 3,4,5
    edit(rt) do rv
        removecolumn!(rv, "V")
        @test_throws ErrorException rv[:V]        # hidden for the rest of THIS view
        @test_throws ErrorException removecolumn!(rv, "V")   # already gone from the view
        @test_throws ErrorException removecolumn!(rv, "NOPE")
    end

    # the parent's actual column is completely untouched -- it's still
    # there, unchanged, exactly as casacore's RefTable::removeColumn
    r2 = readtable(dir)
    @test "V" in columnnames(r2)
    @test column(r2, "V")[:] == Float64.(1:n)

    # a column added THIS session and then hidden from the view is still
    # written to the parent at flush -- removecolumn! never reaches
    # t.parent, matching real casacore's own "still stored" semantics
    rt2 = query(readtable(dir), "K > 2")
    edit(rt2) do rv
        addcolumn!(rv, "TMP", [1.0, 2.0, 3.0])
        removecolumn!(rv, "TMP")
        @test_throws ErrorException rv[:TMP]
    end
    r3 = readtable(dir)
    @test "TMP" in columnnames(r3)
    @test column(r3, "TMP")[:] == [0.0, 0.0, 1.0, 2.0, 3.0]

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test ct[:V][:] == Float64.(1:n)
        @test ct[:TMP][:] == [0.0, 0.0, 1.0, 2.0, 3.0]
    end
end

# Phase 129: edit(ct::ConcatTable) -- write-through onto whichever PART a
# row actually belongs to, matching casacore's ConcatColumn::put exactly
# (a pure row -> (part, local row) translation, no storage of its own).
@testset "edit — through a ConcatTable view (Phase 129)" begin
    dir1 = joinpath(mktempdir(), "cp1.tab")
    dir2 = joinpath(mktempdir(), "cp2.tab")
    write_table(dir1, "T", ["K" => collect(Int32, 1:3), "V" => Float64.(1:3)]; nrow = 3)
    write_table(dir2, "T", ["K" => collect(Int32, 4:6), "V" => Float64.(4:6)]; nrow = 3)

    ccdir = joinpath(mktempdir(), "cc.tab")
    write_concattable(ccdir, [readtable(dir1), readtable(dir2)])
    ct = readtable(ccdir)
    @test ct isa MSv2.ConcatTable
    @test nrow(ct) == 6

    edit(ct) do cv
        cv["V"][1] = 100.0     # row 1 -> part 1 (dir1), local row 1
        cv[:V][3] = 300.0      # row 3 -> part 1, local row 3
        cv["V"][4] = 400.0     # row 4 -> part 2 (dir2), local row 1
        cv[:V][6] = 600.0      # row 6 -> part 2, local row 3
    end

    r1 = readtable(dir1)
    r2 = readtable(dir2)
    @test column(r1, "V")[:] == [100.0, 2.0, 300.0]
    @test column(r2, "V")[:] == [400.0, 5.0, 600.0]

    # whole-view-column assignment spans both parts
    ct2 = readtable(ccdir)
    edit(ct2) do cv
        cv[:V][:] = collect(10.0:10.0:60.0)
    end
    @test column(readtable(dir1), "V")[:] == [10.0, 20.0, 30.0]
    @test column(readtable(dir2), "V")[:] == [40.0, 50.0, 60.0]

    # a part that is itself a RefTable/ConcatTable errors clearly
    rtdir = joinpath(mktempdir(), "rt.tab")
    ct3 = ConcatTable("", MSv2.AbstractTable[query(readtable(dir1), "K > 0"), readtable(dir2)],
                      [0, 3, 6], String[], "", "", "")
    @test_throws ErrorException edit(ct3)

    if _HAVE_CASACORE
        cct1 = CCT.Table(dir1)
        cct2 = CCT.Table(dir2)
        @test cct1[:V][:] == [10.0, 20.0, 30.0]
        @test cct2[:V][:] == [40.0, 50.0, 60.0]
    end
end
