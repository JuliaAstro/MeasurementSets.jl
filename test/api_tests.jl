# Phase 5: lazy Column type + indexing sugar.

@testset "Column API" begin
    t = readtable(SAMPLE_MS; precision=:full)   # exact eltype / value checks below

    tc = column(t, "TIME")
    @test tc isa AbstractVector{Float64}
    @test length(tc) == nrow(t)
    @test size(tc) == (nrow(t),)
    @test tc[1] == getcell(t, "TIME", 1)
    @test tc[3:6] == [getcell(t, "TIME", i) for i in 3:6]
    @test tc[:] == getcolumn(t, "TIME")
    @test collect(tc) == tc[:]
    @test_throws BoundsError tc[nrow(t) + 1]

    # indexing sugar returns a Column, not a description
    @test t[:TIME] isa Column
    @test t["TIME"] isa Column
    @test eltype(t[:UVW]) == Vector{Float64}
    @test size(t[:UVW][7]) == (3,)

    d = column(t, "DATA")
    @test eltype(d) == Matrix{ComplexF32}
    @test size(d[42]) == (4, 64)

    ms = MeasurementSet(SAMPLE_MS; precision=:full)
    @test ms[:DATA][10] == d[10]
    @test ms["ANTENNA1"][100] == column(t, "ANTENNA1")[100]

    # spot cross-check per storage manager (SSM / TSM / ISM)
    if _HAVE_CASACORE
        ct = CCT.Table(SAMPLE_MS)
        @test column(t, "ANTENNA1")[500] == ct[:ANTENNA1][500]        # SSM
        @test column(t, "TIME")[500] == ct[:TIME][500]                # ISM
        @test column(t, "UVW")[500] == collect(ct[:UVW][:, 500])      # TSM
    end
end

# Phase 374: a `MeasurementSet` acts as its MAIN table for the table verbs (it used to support only
# `ms[:COL]` / `ms.SUBTABLE` / Tables.jl).
@testset "MeasurementSet acts as its MAIN table (Phase 374)" begin
    ms = MeasurementSet(SAMPLE_MS); t = readtable(SAMPLE_MS)
    @test MSv2.nrow(ms) == MSv2.nrow(t) && MSv2.columnnames(ms) == MSv2.columnnames(t)
    @test MSv2.columndesc(ms, "TIME").name == "TIME" && MSv2.keywords(ms).names == MSv2.keywords(t).names
    @test length(subtables(ms)) == length(subtables(t))
    @test column(ms, "TIME")[:] == column(t, "TIME")[:] && getcolumn(ms, "ANTENNA1") == getcolumn(t, "ANTENNA1")
    @test getcell(ms, "TIME", 3) == getcell(t, "TIME", 3)
    # the existing subtable forms are unchanged
    @test length(column(ms, "ANTENNA", "NAME")) == MSv2.nrow(subtable(ms, "ANTENNA"))
    @test getcell(ms, "ANTENNA", "NAME", 1) == getcell(subtable(ms, "ANTENNA"), "NAME", 1)
    @test MSv2.nrow(query(ms, "ANTENNA1 == 0")) == MSv2.nrow(query(t, "ANTENNA1 == 0"))
    @test MSv2.nrow(query(r -> r.ANTENNA1 == 0, ms; cols=["ANTENNA1"])) == MSv2.nrow(query(t, "ANTENNA1 == 0"))
    g = groupby(ms, "ANTENNA1"; select=["A" => :ANTENNA1, "N" => "gcount()"])
    @test sum(column(g, "N")[:]) == MSv2.nrow(t)
    @test groupby(ms, "ANTENNA1") do g; (; N = length(g)); end isa GroupedTable
    j = join(ms, subtable(ms, "ANTENNA"); on="ANTENNA1", rightcols=["NAME"])
    @test MSv2.nrow(j) == MSv2.nrow(t)
    @test MSv2.measinfo(ms, "TIME").kind === :epoch && size(MSv2.rawblock(ms, "UVW"), 1) == 3
    d = joinpath(mktempdir(), "c.ms"); copyms(SAMPLE_MS, d; rows=1:40)
    c = MeasurementSet(d)
    d2 = joinpath(mktempdir(), "t"); copytable(d2, c); @test MSv2.nrow(readtable(d2)) == 40
    r = joinpath(mktempdir(), "r"); write_reftable(r, c, [1, 5]); @test MSv2.nrow(readtable(r)) == 2
    @test MSv2.update!(c; set=["EXPOSURE" => "EXPOSURE + 1"], where="ANTENNA1 == 0") > 0
    @test taql(c, "UPDATE t SET SCAN_NUMBER = 7 WHERE ANTENNA1 == 0") > 0
    edit(c) do e; e["FIELD_ID"][1] = 0; end
    edit(c) do e; MSv2.removerows!(e, [1, 2]); end
    @test MSv2.nrow(readtable(d)) == 38 && MSv2.nrow(MeasurementSet(d)) == 38
    n0 = MSv2.nrow(readtable(d))
    @test MSv2.insert!(c; values=["SCAN_NUMBER" => 9]) == 1 && MSv2.nrow(readtable(d)) == n0 + 1
    @test MSv2.delete!(c; where="ANTENNA1 == 0") > 0
    @test MSv2.nrow(taql(MeasurementSet(d), "SELECT TIME WHERE ANTENNA1 == 1")) > 0
end
