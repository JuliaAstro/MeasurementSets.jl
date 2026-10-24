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

# Phase 130: addcolumn! through a ConcatTable view -- matches
# ConcatTable::addColumn: every PART gets the column, schema-only per
# casacore's own API; the data-carrying form (a MeasurementSets
# convenience) slices `data` by `t.offsets` across parts.
@testset "edit — addcolumn! through a ConcatTable view (Phase 130)" begin
    dir1 = joinpath(mktempdir(), "cac1.tab")
    dir2 = joinpath(mktempdir(), "cac2.tab")
    write_table(dir1, "T", ["K" => collect(Int32, 1:3)]; nrow = 3)
    write_table(dir2, "T", ["K" => collect(Int32, 4:6)]; nrow = 3)
    ccdir = joinpath(mktempdir(), "cac.tab")
    write_concattable(ccdir, [readtable(dir1), readtable(dir2)])

    edit(readtable(ccdir)) do cv
        addcolumn!(cv, "W", collect(10.0:10.0:60.0))
    end
    @test column(readtable(dir1), "W")[:] == [10.0, 20.0, 30.0]
    @test column(readtable(dir2), "W")[:] == [40.0, 50.0, 60.0]

    # standard-schema no-data form -> every part gets it, default cells
    edit(readtable(ccdir)) do cv
        addcolumn!(cv, "SCAN_NUMBER")
        cv[:SCAN_NUMBER][1] = Int32(7)
        cv[:SCAN_NUMBER][4] = Int32(9)
    end
    @test column(readtable(dir1), "SCAN_NUMBER")[:] == Int32[7, 0, 0]
    @test column(readtable(dir2), "SCAN_NUMBER")[:] == Int32[9, 0, 0]

    # wrong length errors
    @test_throws ErrorException edit(readtable(ccdir)) do cv
        addcolumn!(cv, "X", [1.0, 2.0])
    end

    if _HAVE_CASACORE
        @test CCT.Table(dir1)[:W][:] == [10.0, 20.0, 30.0]
        @test CCT.Table(dir2)[:W][:] == [40.0, 50.0, 60.0]
    end
end

# Phase 293: `flush(t)` on the non-do-block form of `edit(rt::RefTable)`/
# `edit(ct::ConcatTable)` -- found live: neither `RefEditTable` nor
# `ConcatEditTable` had a `Base.flush` method at all (only the do-block
# form, `edit(f, rt)`, committed anything), so `t = edit(rt); ...;
# flush(t)` -- the exact idiom `t = edit(path); ...; flush(t)` already
# supports for a plain `EditTable` -- raised a raw `MethodError`, leaving
# the write lock (held for the whole session since Phase 207) stuck on
# the table for the rest of the process with no way to release it short
# of reaching into the private `t.parent`/`t.parts` fields.
@testset "edit — flush() on the non-do-block RefEditTable/ConcatEditTable form (Phase 293)" begin
    dir = joinpath(mktempdir(), "flush-ref.tab")
    n = 5
    write_table(dir, "T", ["K" => collect(Int32, 1:n), "V" => Float64.(1:n)]; nrow = n)

    rt = query(readtable(dir), "K > 2")           # rows 3,4,5
    rv = edit(rt)
    rv["V"][1] = 300.0                            # -> parent row 3
    r = flush(rv)
    @test r === rv                                # flush returns what it was given, like EditTable
    @test column(readtable(dir), "V")[:] == [1.0, 2.0, 300.0, 4.0, 5.0]
    @test flush(rv) === rv                        # idempotent, doesn't error a second time

    dir1 = joinpath(mktempdir(), "flush-c1.tab")
    dir2 = joinpath(mktempdir(), "flush-c2.tab")
    write_table(dir1, "T", ["K" => collect(Int32, 1:3), "V" => Float64.(1:3)]; nrow = 3)
    write_table(dir2, "T", ["K" => collect(Int32, 4:6), "V" => Float64.(4:6)]; nrow = 3)
    ccdir = joinpath(mktempdir(), "flush-cc.tab")
    write_concattable(ccdir, [readtable(dir1), readtable(dir2)])

    cv = edit(readtable(ccdir))
    cv["V"][1] = 10.0                             # part 1
    cv["V"][5] = 50.0                              # part 2
    r2 = flush(cv)
    @test r2 === cv
    @test column(readtable(dir1), "V")[:] == [10.0, 2.0, 3.0]
    @test column(readtable(dir2), "V")[:] == [4.0, 50.0, 6.0]
    @test flush(cv) === cv                         # idempotent

    if _HAVE_CASACORE
        @test CCT.Table(dir)[:V][:] == [1.0, 2.0, 300.0, 4.0, 5.0]
        @test CCT.Table(dir1)[:V][:] == [10.0, 2.0, 3.0]
        @test CCT.Table(dir2)[:V][:] == [4.0, 50.0, 6.0]
    end
end

# Phase 293: `addcolumn!(::ConcatEditTable, ...)` looped over parts and
# mutated as it went -- found live: a name present on a LATER part but
# not an EARLIER one made the call throw "column ... already exists"
# (correctly, from the later part's own `_check_new_col`) but left the
# EARLIER part with a silently-committed pending add in its own
# `EditTable.addcols`, so a later `flush` -- even one the caller reaches
# via a completely unrelated later edit -- wrote a spurious, wrongly-
# sliced column to that one part only. Fixed by validating every part's
# `_check_new_col` up front, before mutating any of them (the same
# validate-before-mutate shape as Phases 199/202/204/205).
@testset "edit — ConcatEditTable addcolumn! validates every part before mutating any (Phase 293)" begin
    dir1 = joinpath(mktempdir(), "pm1.tab")
    dir2 = joinpath(mktempdir(), "pm2.tab")
    write_table(dir1, "T", ["A" => Int32[1, 2, 3]]; nrow = 3)
    write_table(dir2, "T", ["A" => Int32[4, 5], "B" => Float64[9.0, 10.0]]; nrow = 2)   # part 2 already has B
    ccdir = joinpath(mktempdir(), "pm.tab")
    write_concattable(ccdir, [readtable(dir1), readtable(dir2)])

    # with-data form: the collision is on part 2, but part 1 must stay untouched
    ce = edit(readtable(ccdir))
    @test_throws ErrorException addcolumn!(ce, "B", Float64[1.0, 2.0, 3.0, 4.0, 5.0])
    @test isempty(ce.parts[1].addcols)             # no leftover pending add on the clean part
    @test isempty(ce.parts[2].addcols)
    flush(ce)
    @test columnnames(readtable(dir1)) == ["A"]                 # "B" never landed on part 1
    @test columnnames(readtable(dir2)) == ["A", "B"]
    @test column(readtable(dir2), "B")[:] == [9.0, 10.0]        # part 2's own B is untouched

    # no-data form: the same up-front check
    ce2 = edit(readtable(ccdir))
    @test_throws ErrorException addcolumn!(ce2, "B"; kind=:ssm)
    @test isempty(ce2.parts[1].addcols)
    flush(ce2)
    @test columnnames(readtable(dir1)) == ["A"]

    # an invalid kind= is also rejected before any part is touched
    ce3 = edit(readtable(ccdir))
    @test_throws ArgumentError addcolumn!(ce3, "C", Float64[1.0, 2.0, 3.0, 4.0, 5.0]; kind=:bogus)
    @test isempty(ce3.parts[1].addcols)
    @test_throws ArgumentError addcolumn!(ce3, "C"; kind=:bogus)
    @test isempty(ce3.parts[1].addcols)
    flush(ce3)   # release ce3's write locks -- neither addcolumn! call above mutated anything,
                 # so this is a no-op besides that; leaving it unflushed leaked the lock into
                 # the process-global registry for the rest of the test run (caught live: it
                 # poisoned lock_tests.jl's "registry starts empty" assertions later in the
                 # same run -- ce4 below never actually deadlocked on it only because `tlock`
                 # is a per-directory ReentrantLock and every edit() call here runs on the same
                 # task, so ce4's own edit() reentered it instead of blocking).

    # a genuinely new name still succeeds on every part
    ce4 = edit(readtable(ccdir))
    addcolumn!(ce4, "C", Float64[1.0, 2.0, 3.0, 4.0, 5.0])
    flush(ce4)
    @test column(readtable(dir1), "C")[:] == [1.0, 2.0, 3.0]
    @test column(readtable(dir2), "C")[:] == [4.0, 5.0]

    if _HAVE_CASACORE
        @test CCT.Table(dir1)[:C][:] == [1.0, 2.0, 3.0]
        @test CCT.Table(dir2)[:B][:] == [9.0, 10.0]   # untouched by the failed collision above
    end
end

# Phase 133: addrows!/removerows! (and removecolumn! for ConcatEditTable)
# on a RefEditTable/ConcatEditTable give clear, actionable errors instead
# of a raw MethodError -- confirmed genuinely unsupported by casacore
# itself: `BaseTable::canAddRow()`/`canRemoveRow()` are hard-`false` and
# unoverridden by either RefTable or ConcatTable (both inherit the base
# class's throwing addRow/removeRow); RefTable::removeColumn has its own
# distinct view-level-hide semantic (Phase 127), but ConcatTable::
# removeColumn throws unconditionally too (Phase 130).
@testset "edit — clear errors for unsupported row/column ops (Phase 133)" begin
    dir = joinpath(mktempdir(), "e133.tab")
    write_table(dir, "T", ["K" => collect(Int32, 1:4), "V" => Float64.(1:4)]; nrow = 4)

    rt = query(readtable(dir), "K > 2")
    edit(rt) do rv
        @test_throws ErrorException addrows!(rv, 2)
        @test_throws ErrorException removerows!(rv, [1])
    end

    dir1 = joinpath(mktempdir(), "e133a.tab")
    dir2 = joinpath(mktempdir(), "e133b.tab")
    write_table(dir1, "T", ["K" => collect(Int32, 1:2)]; nrow = 2)
    write_table(dir2, "T", ["K" => collect(Int32, 3:4)]; nrow = 2)
    ccdir = joinpath(mktempdir(), "e133c.tab")
    write_concattable(ccdir, [readtable(dir1), readtable(dir2)])
    edit(readtable(ccdir)) do cv
        @test_throws ErrorException addrows!(cv, 1)
        @test_throws ErrorException removerows!(cv, [1])
        @test_throws ErrorException removecolumn!(cv, "K")
    end
end

@testset "edit — addcolumn! kind= is validated (Phase 201)" begin
    # `kind=` was accepted nowhere: an invalid symbol (a typo like
    # `:ssn` for `:ssm`) fell through TWO independent unguarded
    # ternaries — `_normalize_desc`'s `kind === :ism ? "IncrementalStMan"
    # : "StandardStMan"` and `_flush_regen`'s writer dispatch `k ===
    # :ssm ? write_standardstman(...) : write_incrementalstman(...)` —
    # that default to DIFFERENT branches for the same unrecognised
    # symbol, so a typo silently produced a column whose declared
    # `ColumnDesc.manager` ("StandardStMan") disagreed with the actual
    # on-disk encoding (IncrementalStMan bytes). Live-verified reachable
    # before the fix (both our own reader and real casacore still opened
    # it, since the data-manager type used for actual dispatch comes
    # from the per-instance string in the ColumnSet, not the per-column
    # `manager` field — but the metadata was still wrong). Fixed with a
    # shared `_check_kind`, validated at every `addcolumn!` entry point
    # (`EditTable`, and the `RefEditTable`/`ConcatEditTable` views that
    # delegate to or push directly onto it).
    dir = joinpath(mktempdir(), "e201.tab")
    write_table(dir, "T", ["A" => collect(Int32, 1:5)]; nrow = 5)
    @test_throws ArgumentError edit(t -> addcolumn!(t, "TIME"; kind = :ssn), dir)
    @test_throws ArgumentError edit(t -> addcolumn!(t, "B", collect(1:5); kind = :ssn), dir)

    # a RefEditTable's with-data method pushes onto the parent's
    # `addcols` directly (doesn't call `addcolumn!(::EditTable, ...)`)
    # -- needed its own, separate `_check_kind` call.
    rdir = joinpath(mktempdir(), "e201r.tab")
    write_table(rdir, "T", ["A" => collect(Int32, 1:5)]; nrow = 5)
    rt = query(readtable(rdir), "A > 2")
    @test_throws ArgumentError edit(v -> addcolumn!(v, "B", collect(1:nrow(rt)); kind = :bogus), rt)

    cdir = joinpath(mktempdir(), "e201c.tab")
    p1 = joinpath(cdir, "p1"); p2 = joinpath(cdir, "p2")
    write_table(p1, "T", ["A" => collect(Int32, 1:2)]; nrow = 2)
    write_table(p2, "T", ["A" => collect(Int32, 3:4)]; nrow = 2)
    ct = readtable(write_concattable(joinpath(cdir, "c"), [readtable(p1), readtable(p2)]))
    @test_throws ArgumentError edit(v -> addcolumn!(v, "B"; kind = :oops), ct)

    # every valid kind still works, and the metadata now genuinely
    # matches the encoding (no mismatch left behind by the fix itself)
    dir2 = joinpath(mktempdir(), "e201v.tab")
    write_table(dir2, "T", ["A" => collect(Int32, 1:5)]; nrow = 5)
    edit(dir2) do t
        addcolumn!(t, "B", collect(6:10); kind = :ssm)
        addcolumn!(t, "C", collect(11:15); kind = :ism)
    end
    r = readtable(dir2)
    @test column(r, "B")[:] == 6:10
    @test column(r, "C")[:] == 11:15
    @test columndesc(r, "B").manager == "StandardStMan"
    @test columndesc(r, "C").manager == "IncrementalStMan"
    if _HAVE_CASACORE
        ct2 = CCT.Table(dir2)
        @test collect(ct2[:B][:]) == 6:10
        @test collect(ct2[:C][:]) == 11:15
    end
end

# Phase 317: random write_table (mixed SSM / ISM / shared-TSM-group columns)
# -> copytable -> random edit session (setcell! / addrows! / removerows!)
# fuzz, checked against a plain Julia model and (where available) Casacore.jl.
# Also pins the documented appended-row default: zeros / "" for EVERY manager
# (real casacore's IncrementalStMan inherits the previous row's value instead
# -- see the `addrows!` docstring).
@testset "write_table -> copytable -> random edit pipeline fuzz (Phase 317)" begin
    rng = MersenneTwister(317)
    for case in 1:10
        n = rand(rng, (3, 20, 150))
        ism = String[]
        cols = Pair{String,Any}[]
        push!(cols, "I1" => Int32.(cumsum(rand(rng, 0:1, n)))); rand(rng) < 0.6 && push!(ism, "I1")
        push!(cols, "D1" => randn(rng, n));                      rand(rng) < 0.5 && push!(ism, "D1")
        push!(cols, "S1" => [join(rand(rng, 'a':'z', rand(rng, 0:6))) for _ in 1:n])
        shp = [(rand(rng, 2:4), rand(rng, 2:3)) for _ in 1:n]      # ragged -> Casacore.jl-readable
        push!(cols, "T1" => [randn(rng, ComplexF32, s...) for s in shp])
        push!(cols, "T2" => [rand(rng, Bool, s...) for s in shp])
        src = joinpath(mktempdir(), "w.tab")
        write_table(src, "T", cols; nrow=n, ism=ism, tsm=[["T1", "T2"]])
        model = Dict(k => copy(v) for (k, v) in cols)
        cp = joinpath(mktempdir(), "c.tab")
        copytable(cp, readtable(src))
        edit(cp) do t
            for _ in 1:rand(rng, 1:6)
                m = length(model["I1"])
                op = rand(rng, 1:4)
                if op == 1
                    i = rand(rng, 1:m); v = Int32(rand(rng, -5:5))
                    t["I1"][i] = v; model["I1"][i] = v
                elseif op == 2
                    i = rand(rng, 1:m); v = randn(rng, ComplexF32, size(model["T1"][i])...)
                    t["T1"][i] = v; model["T1"][i] = v
                elseif op == 3
                    k = rand(rng, 1:3); addrows!(t, k)
                    for _ in 1:k
                        push!(model["I1"], Int32(0)); push!(model["D1"], 0.0); push!(model["S1"], "")
                        sz = size(model["T1"][end])
                        push!(model["T1"], zeros(ComplexF32, sz...)); push!(model["T2"], falses(sz...))
                    end
                elseif m > 3
                    rr = sort(unique(rand(rng, 1:m, rand(rng, 1:2))))
                    removerows!(t, rr)
                    for k in keys(model); deleteat!(model[k], rr); end
                end
            end
        end
        r = readtable(cp)
        ms = [m.name for m in r.managers]
        @test any(startswith.(ms, "Tiled")) && any(==("StandardStMan"), ms)
        ct = _HAVE_CASACORE ? CCT.Table(cp) : nothing
        for (k, e) in model
            a = column(r, k)[:]
            @test length(a) == length(e)
            @test all(isequal(a[i], e[i]) for i in eachindex(e))
            if ct !== nothing
                cc = ct[Symbol(k)]
                b = e[1] isa AbstractArray ? [cc[i] for i in 1:length(e)] : cc[:]
                @test all(isequal(b[i], e[i]) for i in eachindex(e))
            end
        end
    end
end

# Phase 322: random-operation fuzz for in-place edits through RefTable /
# ConcatTable views (Phases 125-130 used fixed rows / fixed parts).  Random
# (possibly shuffled) RefTable row selections and random 2-3 part ConcatTables
# over scalar / String / tiled-array columns; random cell writes and whole-
# column writes through the view, then a random `addcolumn!` through the view.
# Checked against a plain Julia model of the underlying parent / parts, via our
# reader and (RefTable case) Casacore.jl.  A column added through a RefTable
# view lands on the parent: the view's rows get the data, every other row 0.0.
@testset "edit — through RefTable / ConcatTable views: random op fuzz (Phase 322)" begin
    rng = MersenneTwister(322)
    for case in 1:12
        n = rand(rng, (5, 20, 60))
        K = Int32.(1:n); V = randn(rng, n); S = [join(rand(rng, 'a':'z', 3)) for _ in 1:n]
        A = [randn(rng, 3) for _ in 1:n]
        mk(path, r) = write_table(path, "T", Pair{String,Any}["K" => K[r], "V" => V[r], "S" => S[r], "A" => A[r]];
                                  nrow=length(r), tsm=[["A"]])
        model = Dict{String,Any}("V" => copy(V), "S" => copy(S), "A" => copy(A))
        newname = "N$case"
        if rand(rng) < 0.6                                             # ---- RefTable view
            base = joinpath(mktempdir(), "p.tab"); mk(base, 1:n)
            rows = sort(unique(rand(rng, 1:n, rand(rng, 1:n))))
            vrows = rand(rng) < 0.5 ? rows : shuffle(rng, rows)
            d1 = joinpath(mktempdir(), "r.tab"); write_reftable(d1, readtable(base), vrows)
            newdata = randn(rng, length(vrows))
            edit(readtable(d1)) do rv
                for _ in 1:rand(rng, 1:8)
                    i = rand(rng, 1:length(vrows)); p = vrows[i]
                    op = rand(rng, 1:4)
                    if op == 1;     v = randn(rng);                 rv["V"][i] = v; model["V"][p] = v
                    elseif op == 2; s = join(rand(rng, 'a':'z', 3)); rv["S"][i] = s; model["S"][p] = s
                    elseif op == 3; a = randn(rng, 3);              rv["A"][i] = a; model["A"][p] = a
                    else
                        vals = randn(rng, length(vrows)); rv["V"][:] = vals
                        for (j, q) in enumerate(vrows); model["V"][q] = vals[j]; end
                    end
                end
                addcolumn!(rv, newname, newdata)
            end
            got = readtable(base)
            newfull = zeros(n); for (j, q) in enumerate(vrows); newfull[q] = newdata[j]; end
            @test column(got, newname)[:] == newfull
            ct = _HAVE_CASACORE ? CCT.Table(base) : nothing
        else                                                            # ---- ConcatTable view
            np = rand(rng, 2:3)
            cuts = sort(unique(vcat(0, rand(rng, 1:n-1, np - 1), n)))
            parts = String[]
            for k in 1:length(cuts)-1
                pd = joinpath(mktempdir(), "p$k.tab"); push!(parts, pd); mk(pd, cuts[k]+1:cuts[k+1])
            end
            cdir = joinpath(mktempdir(), "c.tab"); write_concattable(cdir, readtable.(parts))
            newdata = randn(rng, n)
            edit(readtable(cdir)) do cv
                for _ in 1:rand(rng, 1:8)
                    i = rand(rng, 1:n); op = rand(rng, 1:3)
                    if op == 1;     v = randn(rng);                 cv["V"][i] = v; model["V"][i] = v
                    elseif op == 2; s = join(rand(rng, 'a':'z', 3)); cv["S"][i] = s; model["S"][i] = s
                    else;           a = randn(rng, 3);              cv["A"][i] = a; model["A"][i] = a end
                end
                addcolumn!(cv, newname, newdata)
            end
            got = readtable(cdir)
            @test column(got, newname)[:] == newdata
            ct = nothing
        end
        for k in ("V", "S", "A")
            a = column(got, k)[:]
            @test all(isequal(a[i], model[k][i]) for i in 1:n)
        end
        if ct !== nothing
            for k in ("V", "S")
                b = ct[Symbol(k)][:]
                @test all(isequal(b[i], model[k][i]) for i in 1:n)
            end
        end
    end
end

@testset "Phase 406 — a closed edit session refuses further writes" begin
    d = mktempdir(); p = joinpath(d, "t")
    write_table(p, "T", ["A" => [1, 2, 3]]; nrow = 3)
    t = edit(p)
    t[:A][1] = 10
    flush(t)
    flush(t)                                   # idempotent
    for f in (() -> (t[:A][2] = 5), () -> (t[:A][:] = [1, 2, 3]), () -> addrows!(t, 1),
              () -> removerows!(t, [1]), () -> addcolumn!(t, "B"),
              () -> addcolumn!(t, "C", [1, 2, 3]), () -> removecolumn!(t, "A"))
        @test_throws ArgumentError f()
    end
    @test column(readtable(p), "A")[:] == [10, 2, 3]
    # an aborted do-block session is closed too
    t2 = nothing
    @test_throws ErrorException edit(p) do s
        t2 = s; error("boom")
    end
    @test_throws ArgumentError (t2[:A][1] = 0)
    edit(p) do s; s[:A][3] = 30; end           # a fresh session still works
    @test column(readtable(p), "A")[:] == [10, 2, 30]
end

# Phase 419: the flush resolves every column of a regenerated storage-manager file; an untouched scalar column
# used to be boxed into a Vector{Any} only for the writer to unbox it again.  It is now the typed vector, and a
# column with pending edits still resolves to the edited values.
@testset "Phase 419 — flush resolves untouched scalar columns as typed vectors" begin
    d = mktempdir(); p = joinpath(d, "t"); n = 40
    write_table(p, "T", Pair{String,Any}["K" => Int32.(1:n), "B" => collect(1.0:n), "S" => ["s$i" for i in 1:n]]; nrow = n)
    t = edit(p)
    @test MeasurementSets._resolve(t, "B") isa Vector{Float64}
    @test MeasurementSets._resolve(t, "K") isa Vector{Int32}
    t[:B][3] = -1.0
    r = MeasurementSets._resolve(t, "B")
    @test r[3] == -1.0 && r[4] == 4.0 && length(r) == n
    @test MeasurementSets._resolve(t, "S") == ["s$i" for i in 1:n]
    flush(t)
    u = readtable(p)
    @test column(u, "B")[:] == replace(collect(1.0:n), 3.0 => -1.0)
    @test column(u, "K")[:] == Int32.(1:n) && column(u, "S")[:] == ["s$i" for i in 1:n]
    # restricted update! through the same path, with an appended row and a removed row
    update!(p; set = ["K" => "K + 100"], where = "K > 35")
    edit(p) do e; addrows!(e, 2); removerows!(e, [1]); end
    k = column(readtable(p), "K")[:]
    @test length(k) == n + 1 && k[1:34] == Int32.(2:35) && k[35:n-1] == Int32.(136:140)
end

# Phase 422: after rows were removed or appended, every scalar column was re-read cell by cell through the row
# map (a storage-manager lookup per row) and re-boxed; it is now one bulk read and a typed gather.
@testset "Phase 422 — structural edits: removed / appended rows across scalar column kinds" begin
    rng = MersenneTwister(422)
    for (ism, endian) in ((false, :little), (true, :little), (false, :big)), trial in 1:6
        n = rand(rng, 5:60)
        K = Int32.(rand(rng, 1:9, n)); B = rand(rng, n); S = ["s$(rand(rng, 1:5))" for _ in 1:n]; F = rand(rng, Bool, n)
        V = [rand(rng, 2, 3) for _ in 1:n]
        d = mktempdir(); p = joinpath(d, "t")
        write_table(p, "T", Pair{String,Any}["K" => K, "B" => B, "S" => S, "F" => F, "V" => V]; nrow = n, endian,
                    ism = ism ? ["K", "B"] : String[])
        gone = sort(unique(rand(rng, 1:n, rand(rng, 0:n ÷ 2)))); keep = setdiff(1:n, gone); add = rand(rng, 0:5)
        edit(p) do e
            isempty(gone) || removerows!(e, gone)
            add > 0 && addrows!(e, add)
            add > 0 && (e[:K][length(keep) + 1] = Int32(77); e[:S][length(keep) + add] = "new")
        end
        r = readtable(p)
        m = length(keep) + add
        @test nrow(r) == m
        @test column(r, "K")[:] == vcat(K[keep], zeros(Int32, add)) .+ Int32.(add > 0 && m >= length(keep) + 1 ? (1:m) .== length(keep) + 1 : falses(m)) .* Int32(77)
        @test column(r, "B")[:] == vcat(B[keep], zeros(add))
        @test column(r, "S")[:] == vcat(S[keep], fill("", add)) |> x -> (add > 0 && (x[length(keep) + add] = "new"); x)
        @test column(r, "F")[:] == vcat(F[keep], falses(add))
        @test column(r, "V")[1:length(keep)] == V[keep]
    end
end

# Phase 435: a few single-cell edits of numeric StandardStMan columns patch the file in place (same inode, only the
# touched bytes), the rest of the data-manager instance (strings included) is untouched
validate_dir_leftovers(p) = [x for x in readdir(p) if endswith(x, "_tmp") || startswith(x, ".") || x == "table.commit"]
@testset "edit — numeric SSM cells are patched in place (Phase 435)" begin
    rng = MersenneTwister(435)
    for endian in (:little, :big)
        n = 4000; d = mktempdir(); p = joinpath(d, "t")
        K = rand(rng, Int32(-5):Int32(5), n); B = rand(rng, n); U = rand(rng, UInt8, n); S = rand(rng, ["a", "bb", ""], n)
        write_table(p, "T", Pair{String,Any}["K" => copy(K), "B" => copy(B), "U" => copy(U), "S" => copy(S)]; nrow = n, endian)
        f = filter(x -> startswith(x, "table.f") && !contains(x, "_"), readdir(p))
        ino0 = stat(joinpath(p, only(f))).inode
        ks = rand(rng, 1:n, 6); bs = rand(rng, 1:n, 5); us = [1, n]
        edit(p) do e
            for i in ks; e[:K][i] = Int32(100 + i % 7); K[i] = Int32(100 + i % 7); end
            for i in bs; e[:B][i] = -0.5 * i; B[i] = -0.5 * i; end
            for i in us; e[:U][i] = UInt8(7); U[i] = 7; end
        end
        r = readtable(p; precision = :full)
        @test column(r, "K")[:] == K && column(r, "B")[:] == B && column(r, "U")[:] == U && column(r, "S")[:] == S
        @test stat(joinpath(p, only(f))).inode == ino0                    # patched in place, not replaced
        @test isempty(validate_dir_leftovers(p))
        if _HAVE_CASACORE
            ct = CCT.Table(p)
            @test collect(ct[:K][:]) == K && collect(ct[:B][:]) == B && collect(ct[:S][:]) == S
        end
        # many changes -> regeneration, same result
        edit(p) do e; for i in 1:n; e[:B][i] = Float64(i); end; end
        @test column(readtable(p; precision = :full), "B")[:] == Float64.(1:n)
        # a no-op rewrite changes nothing
        edit(p) do e; e[:K][3] = column(readtable(p), "K")[3]; end
        @test column(readtable(p; precision = :full), "K")[:] == K
    end
end

# Phase 437: the edit session remembers which cells were set one by one, so the in-place patch looks at those alone;
# whatever mixes of single-cell, whole-column and structural edits follow, the result matches a plain model
@testset "edit — touched-cell tracking vs a model (Phase 437)" begin
    rng = MersenneTwister(437)
    for trial in 1:24
        n = rand(rng, [900, 2500]); d = mktempdir(); p = joinpath(d, "t")
        K = rand(rng, Int32(0):Int32(9), n); B = rand(rng, n); S = rand(rng, ["a", "b"], n)
        ism = rand(rng, Bool)
        write_table(p, "T", Pair{String,Any}["K" => copy(K), "B" => copy(B), "S" => copy(S)]; nrow = n, ism = ism ? ["K"] : String[])
        mk, mb, ms_ = copy(K), copy(B), copy(S)
        edit(p) do e
            for step in 1:rand(rng, 1:6)
                op = rand(rng, 1:7); m = length(mk)
                if op <= 3                                    # single cells, some back to the stored value
                    for _ in 1:rand(rng, 1:5)
                        i = rand(rng, 1:m)
                        if rand(rng) < 0.5; e[:K][i] = Int32(50 + step); mk[i] = Int32(50 + step)
                        else; v = rand(rng) < 0.3 ? mb[i] : rand(rng); e[:B][i] = v; mb[i] = v; end
                    end
                elseif op == 4                                # a whole column, then one more cell
                    nv = rand(rng, m); e[:B][:] = nv; mb .= nv
                    i = rand(rng, 1:m); e[:B][i] = -1.0; mb[i] = -1.0
                elseif op == 5                                # a string cell (regeneration path)
                    i = rand(rng, 1:m); e[:S][i] = "zz"; ms_[i] = "zz"
                elseif op == 6 && m > 20                      # rows removed after cells were set
                    rr = sort!(unique(rand(rng, 1:m, 3))); removerows!(e, rr)
                    deleteat!(mk, rr); deleteat!(mb, rr); deleteat!(ms_, rr)
                else                                          # rows appended
                    addrows!(e, 2); append!(mk, Int32[0, 0]); append!(mb, [0.0, 0.0]); append!(ms_, ["", ""])
                end
            end
        end
        r = readtable(p; precision = :full)
        @test column(r, "K")[:] == mk && column(r, "B")[:] == mb && column(r, "S")[:] == ms_
    end
end

# Phase 439: a scalar column pulled into the session stays a typed vector (the writers' memcpy path, no boxed values)
@testset "edit — overridden scalar columns stay typed (Phase 439)" begin
    n = 300; p = joinpath(mktempdir(), "t")
    write_table(p, "T", Pair{String,Any}["K" => Int32.(1:n), "B" => collect(1.0:n), "S" => string.(1:n), "F" => iseven.(1:n)]; nrow = n)
    e = edit(p)
    for (nm, J) in (("K", Int32), ("B", Float64), ("S", String), ("F", Bool))
        e[nm][2] = nm == "S" ? "x" : nm == "F" ? false : J(7)
        @test eltype(e.override[nm]) === J
    end
    @test_throws ArgumentError e[:K][3] = 2.5            # still refused where it is assigned
    @test_throws ArgumentError e[:K][3] = "no"
    addrows!(e, 2); e[:K][n + 1] = 9; removerows!(e, [1])
    flush(e)
    r = readtable(p; precision = :full)
    @test column(r, "K")[:] == Int32[7; 3:n; 9; 0] && column(r, "S")[:][1] == "x" && column(r, "B")[:][1] == 7.0 && column(r, "F")[:][1] == false
    @test nrow(r) == n + 1
end

# Phase 443: a few Bool cells of a StandardStMan column (FLAG_ROW-style flagging) are patched bit by bit in place
@testset "edit — Bool SSM cells are patched in place (Phase 443)" begin
    rng = MersenneTwister(443)
    for endian in (:little, :big), n in (3000, 20000)
        d = mktempdir(); p = joinpath(d, "t")
        F = rand(rng, Bool, n); K = rand(rng, Int32, n); S = rand(rng, ["a", "bb"], n)
        write_table(p, "T", Pair{String,Any}["F" => copy(F), "K" => copy(K), "S" => copy(S)]; nrow = n, endian)
        f = only(filter(x -> startswith(x, "table.f") && !contains(x, "_"), readdir(p)))
        ino0 = stat(joinpath(p, f)).inode
        rows = unique!(vcat([1, 2, 7, 8, 9, n - 1, n], rand(rng, 1:n, 20)))
        edit(p) do e
            for i in rows; F[i] = !F[i]; e[:F][i] = F[i]; end
            e[:F][rows[end]] = F[rows[end]]                       # set again to the same value
        end
        r = readtable(p; precision = :full)
        @test column(r, "F")[:] == F && column(r, "K")[:] == K && column(r, "S")[:] == S
        @test stat(joinpath(p, f)).inode == ino0                  # in place
        if _HAVE_CASACORE
            ct = CCT.Table(p); @test collect(ct[:F][:]) == F && collect(ct[:K][:]) == K
        end
    end
end

# Phase 447: a whole-column assignment that changes only a few cells still patches those cells in place (the plan
# falls back to comparing the column), and one that changes many regenerates -- same table either way
@testset "edit — whole-column assignment with few differences (Phase 447)" begin
    rng = MersenneTwister(447); n = 4000
    for (nchg, inplace) in ((3, true), (900, false))
        p = joinpath(mktempdir(), "t"); B = rand(rng, n); K = rand(rng, Int32, n)
        write_table(p, "T", Pair{String,Any}["B" => copy(B), "K" => copy(K), "S" => fill("s", n)]; nrow = n)
        f = only(filter(x -> startswith(x, "table.f") && !contains(x, "_"), readdir(p))); ino0 = stat(joinpath(p, f)).inode
        nb = copy(B); idx = unique!(rand(rng, 100:n, nchg)); nb[idx] .= -1.0
        edit(p) do e; e[:B][:] = nb; end
        r = readtable(p; precision = :full)
        @test column(r, "B")[:] == nb && column(r, "K")[:] == K && column(r, "S")[:] == fill("s", n)
        @test (stat(joinpath(p, f)).inode == ino0) == inplace
    end
end

using Random

# Phase 449: random edit sessions against a model.  Cell sets, whole-column sets, addrows! and removerows!, several
# sessions in a row, on tables of 50..30000 rows (one to many SSM buckets, so the in-place cell patch of Phases 435/443
# fires for some sessions and the regenerating path for others), both byte orders, SSM and ISM scalars, shared tiled
# hypercube / TiledColumnStMan / ragged arrays.  Nothing differed from the model.  (An appended ragged cell is zeros of
# the previous row's shape -- the documented addrows! default, unlike casacore's undefined cell.)
@testset "random edit sessions vs a model (Phase 449)" begin
    rng = Random.MersenneTwister(449)
    for seed in 1:14
        N = rand(rng, (50, 700, 5000, 30000)); endian = rand(rng, (:little, :big))
        d = joinpath(mktempdir(), "t")
        cols = Pair{String,Any}["I" => Int32.(rand(rng, -100:100, N)), "X" => rand(rng, N), "B" => rand(rng, Bool, N),
                                "S" => ["s$(rand(rng, 1:9))" for _ in 1:N], "F" => Float32.(rand(rng, N))]
        write_table(d, "T", cols; nrow = N, endian = endian, (rand(rng, Bool) ? (; ism = ["I"]) : (;))...)
        m = Dict(c => copy(v) for (c, v) in cols)
        defs = Dict("I" => Int32(0), "X" => 0.0, "B" => false, "S" => "", "F" => Float32(0))
        gen = Dict("I" => () -> Int32(rand(rng, -100:100)), "X" => () -> rand(rng), "B" => () -> rand(rng, Bool),
                   "S" => () -> "v$(rand(rng, 1:99))", "F" => () -> Float32(rand(rng)))
        for session in 1:rand(rng, 1:3)
            edit(d) do t
                for _ in 1:rand(rng, 1:12)
                    n = length(m["I"]); op = rand(rng, 1:6); c = rand(rng, ("I", "X", "B", "S", "F"))
                    if op <= 3 && n > 0
                        for _ in 1:rand(rng, 1:max(1, n ÷ 20)); i = rand(rng, 1:n); v = gen[c](); t[Symbol(c)][i] = v; m[c][i] = v; end
                    elseif op == 4 && n > 0
                        nv = [gen[c]() for _ in 1:n]; t[Symbol(c)][:] = nv; m[c] = nv
                    elseif op == 5
                        k = rand(rng, 1:5); addrows!(t, k)
                        for (cc, v) in m; append!(v, fill(defs[cc], k)); end
                    elseif op == 6 && n > 3
                        r = sort(unique(rand(rng, 1:n, rand(rng, 1:3)))); removerows!(t, r)
                        for (_, v) in m; deleteat!(v, r); end
                    end
                end
            end
            tt = readtable(d)
            for c in keys(m)
                @test column(tt, c; precision = :full)[:] == m[c]
            end
        end
    end
    for seed in 1:10
        N = rand(rng, (30, 400, 6000)); endian = rand(rng, (:little, :big))
        d = joinpath(mktempdir(), "t")
        cols = Pair{String,Any}["K" => Int32.(rand(rng, 1:9, N)), "A" => [rand(rng, Float32, 2, 3) for _ in 1:N],
                                "Z" => [rand(rng, ComplexF32, 2, 3) for _ in 1:N], "V" => [rand(rng, 1:4) |> k -> rand(rng, k) for _ in 1:N]]
        grp = rand(rng, Bool) ? (; tsm = [["A", "Z"]]) : (; tsm = [["A"]], tcm = [["Z"]])
        write_table(d, "T", cols; nrow = N, endian = endian, grp...)
        m = Dict{String,Any}(c => copy(v) for (c, v) in cols)
        gen = Dict("K" => () -> Int32(rand(rng, 1:9)), "A" => () -> rand(rng, Float32, 2, 3),
                   "Z" => () -> rand(rng, ComplexF32, 2, 3), "V" => () -> rand(rng, rand(rng, 1:4)))
        dflt(c, v) = c == "K" ? Int32(0) : c == "A" ? zeros(Float32, 2, 3) : c == "Z" ? zeros(ComplexF32, 2, 3) : zeros(length(v[end]))
        for session in 1:rand(rng, 1:3)
            edit(d) do t
                for _ in 1:rand(rng, 1:8)
                    n = length(m["K"]); op = rand(rng, 1:5); c = rand(rng, ("K", "A", "Z", "V"))
                    if op <= 3 && n > 0
                        for _ in 1:rand(rng, 1:5); i = rand(rng, 1:n); v = gen[c](); t[Symbol(c)][i] = v; m[c][i] = v; end
                    elseif op == 4
                        k = rand(rng, 1:4); addrows!(t, k)
                        for (cc, v) in m; for _ in 1:k; push!(v, dflt(cc, v)); end; end
                    elseif op == 5 && n > 3
                        r = sort(unique(rand(rng, 1:n, rand(rng, 1:3)))); removerows!(t, r)
                        for (_, v) in m; deleteat!(v, r); end
                    end
                end
            end
            tt = readtable(d)
            for c in keys(m)
                got = column(tt, c; precision = :full)[:]
                @test length(got) == length(m[c]) && all(collect(got[i]) == collect(m[c][i]) for i in eachindex(got))
            end
        end
    end
end

# Phase 455: edit-session paths the coverage run found never executed: a column added in the session sees appended rows
# (and the in-session read of an appended row is the default cell), removing a column added in the same session, a
# non-standard column name without data, and removing an engine column removes its stored / scale / offset companions;
# an autoscaled engine column is re-encoded when a cell changes.
@testset "edit: added columns and engine columns in one session (Phase 455)" begin
    n = 40
    fresh(kw...) = (d = joinpath(mktempdir(), "t");
        write_table(d, "T", Pair{String,Any}["A" => collect(1.0:n), "K" => Int32.(1:n)]; nrow = n, kw...); d)
    d = fresh()
    edit(d) do t
        addcolumn!(t, "X", [fill(Float64(i), 3) for i in 1:n])
        addrows!(t, 2)
        @test t[:X][n + 1] == zeros(3) && t[:A][n + 2] == 0.0 && t[:K][n + 1] == 0      # defaults, read before the flush
        t[:X][n + 2] = [7.0, 8.0, 9.0]
    end
    r = readtable(d)
    @test nrow(r) == n + 2 && column(r, "X")[n] == fill(Float64(n), 3) && column(r, "X")[n + 1] == zeros(3) && column(r, "X")[n + 2] == [7.0, 8.0, 9.0]
    d = fresh()
    edit(d) do t; addcolumn!(t, "X", rand(n)); removecolumn!(t, "X"); end                  # added and removed: never written
    @test columnnames(readtable(d)) == ["A", "K"]
    d = fresh()
    edit(d) do t; @test_throws ErrorException addcolumn!(t, "NOT_A_STANDARD_COLUMN"); end
    rng = Random.MersenneTwister(455)
    for eng in ((; kind = MSv2.ScaledArray(), scale = 0.5, offset = 1.0, stored_type = MSv2.TpInt),
                (; kind = MSv2.CompressFloat(), autoscale = true))
        d = joinpath(mktempdir(), "t")
        V = [Float32.(rand(rng, 2, 3)) for _ in 1:n]
        write_table(d, "T", Pair{String,Any}["K" => Int32.(1:n), "V" => V]; nrow = n, engines = Dict("V" => eng))
        before = columnnames(readtable(d)); v4 = column(readtable(d), "V")[4]      # (as decoded: the engine quantises)
        @test "V_COMPRESSED" in before
        edit(d) do t; t[:V][3] = fill(Float32(0.25), 2, 3); addrows!(t, 1); end            # re-encodes (and the scale / offset columns of an autoscale)
        r = readtable(d); v3 = column(r, "V")[3]
        @test nrow(r) == n + 1 && columnnames(r) == before && all(abs.(v3 .- 0.25) .<= 0.5)
        @test column(r, "V")[4] ≈ v4 atol = 0.05                                          # untouched cells survive the re-encode
        edit(d) do t; removecolumn!(t, "V"); end                                          # companions go with it
        @test columnnames(readtable(d)) == ["K"] && sort(filter(f -> startswith(f, "table.f"), readdir(d))) == ["table.f0"]
    end
end

# Phase 459: random edit sessions on tables whose array column is a virtual engine (ScaledArray, CompressFloat, BitFlags)
# or a Dysco column: cell sets, addrows!, removerows!, one to three sessions, both byte orders, against a model (exact
# for the lossless cases, within the codec's quantisation for CompressFloat / Dysco).  An appended cell is zeros.
@testset "random edit sessions on engine and Dysco columns (Phase 459)" begin
    rng = Random.MersenneTwister(459)
for iter in 1:_fz(24)
    N = rand(rng, (24, 60, 150)); endian = rand(rng, (:little, :big))
    kind = rand(rng, (:scaled, :compress, :bitflags, :dysco))
    d = joinpath(mktempdir(), "t")
    sh = (2, 3)
    if kind === :bitflags
        gen = () -> rand(rng, Bool, sh...); dflt = falses(sh...) |> collect
        eng = Dict("V" => (; kind = MSv2.BitFlags(), stored_type = MSv2.TpInt)); tol = 0.0
        V = [gen() for _ in 1:N]
    elseif kind === :scaled
        gen = () -> Float32.(rand(rng, -20:20, sh...) .* 0.5 .+ 1.0); dflt = zeros(Float32, sh...)
        eng = Dict("V" => (; kind = MSv2.ScaledArray(), scale = 0.5, offset = 1.0, stored_type = MSv2.TpInt)); tol = 1e-5
        V = [gen() for _ in 1:N]
    elseif kind === :compress
        gen = () -> Float32.(rand(rng, -500:500, sh...) .* 0.01); dflt = zeros(Float32, sh...)
        eng = Dict("V" => (; kind = MSv2.CompressFloat(), scale = 0.01, offset = 0.0)); tol = 2e-2
        V = [gen() for _ in 1:N]
    else
        gen = () -> ComplexF32.(randn(rng, 2, 3), randn(rng, 2, 3)); dflt = zeros(ComplexF32, 2, 3); eng = nothing; tol = 0.05
        V = [gen() for _ in 1:N]
    end
    K = Int32.(rand(rng, 1:9, N))
    if kind === :dysco
        nant = 4; bl = [(a,b) for a in 0:nant-1 for b in a:nant-1]; nbl = length(bl)
        N = nbl * cld(N, nbl); K = Int32.(rand(rng, 1:9, N)); V = [gen() for _ in 1:N]
        a1 = Int32[bl[mod1(i,nbl)][1] for i in 1:N]; a2 = Int32[bl[mod1(i,nbl)][2] for i in 1:N]
        write_table(d, "T", Pair{String,Any}["K"=>K, "ANTENNA1"=>a1, "ANTENNA2"=>a2, "TIME"=>collect(5e9 .+ (1:N)),
            "V"=>V]; nrow=N, endian=endian, ism=["ANTENNA1","ANTENNA2","TIME"], dysco=[["V"]],
            dysco_spec=Dict("V"=>(; normalization=MSv2.RowNorm(), distribution=MSv2.TruncatedGaussian(), dataBitCount=16,
              weightBitCount=12, antenna1=Int.(a1), antenna2=Int.(a2), rowsPerBlock=nbl, dither=false)))
    else
        write_table(d, "T", Pair{String,Any}["K"=>K, "V"=>V]; nrow=N, endian=endian, engines=eng)
    end
    mK = copy(K); mV = [copy(x) for x in V]
    try
    for session in 1:rand(rng, 1:3)
        edit(d) do t
            for _ in 1:rand(rng, 1:6)
                n = length(mK); op = rand(rng, 1:5)
                if op <= 2 && n > 0
                    for _ in 1:rand(rng,1:4); i = rand(rng,1:n); v = gen(); t[:V][i] = v; mV[i] = v; end
                elseif op == 3 && n > 0
                    i = rand(rng,1:n); v = Int32(rand(rng,1:9)); t[:K][i] = v; mK[i] = v
                elseif op == 4
                    k = rand(rng,1:3); addrows!(t, k); for _ in 1:k; push!(mK, Int32(0)); push!(mV, copy(dflt)); end
                elseif op == 5 && n > 6
                    r = sort(unique(rand(rng,1:n,rand(rng,1:3)))); removerows!(t, r); deleteat!(mK, r); deleteat!(mV, r)
                end
            end
        end
        tt = readtable(d)
        gK = column(tt,"K")[:]; gV = column(tt,"V"; precision=:full)[:]
        ok = gK == mK && length(gV) == length(mV) && all(size(gV[i]) == size(mV[i]) && maximum(abs.(gV[i] .- mV[i]), init=0.0) <= tol + 1e-6 for i in eachindex(gV))
        @test ok
        ok || break
    end
    catch e
        @test false
        @info "random engine edit failed" iter kind exception = e
    end
    end
end
