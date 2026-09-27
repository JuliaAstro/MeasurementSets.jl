# Phase 5: Tables.jl integration.

import Tables

@testset "Tables.jl interface" begin
    ms = MeasurementSet(SAMPLE_MS)
    ant = subtable(ms, "ANTENNA")

    @test Tables.istable(ant)
    @test Tables.columnaccess(typeof(ant))
    @test Tables.rowaccess(typeof(ant))

    sch = Tables.schema(ant)
    @test sch.names == Tuple(Symbol.(columnnames(ant)))
    @test sch.types[findfirst(==(:NAME), sch.names)] == String
    @test sch.types[findfirst(==(:POSITION), sch.names)] == Vector{Float64}

    cols = Tables.columns(ant)
    @test collect(Tables.getcolumn(cols, :NAME)) == getcolumn(ant, "NAME")

    # column source -> row table
    rt = Tables.rowtable(ant)
    @test length(rt) == nrow(ant)
    @test rt[1].NAME == getcell(ant, "NAME", 1)
    @test rt[end].STATION == getcell(ant, "STATION", nrow(ant))

    # row iteration over the table itself
    n = 0
    lastname = ""
    for row in ant
        n += 1
        lastname = row.NAME
    end
    @test n == nrow(ant)
    @test lastname == getcell(ant, "NAME", nrow(ant))

    # MeasurementSet delegates to MAIN
    @test Tables.schema(ms).names == Tuple(Symbol.(columnnames(getfield(ms, :data))))
end

@testset "Tables.jl interface — sweep (Phase 289)" begin
    d = mktempdir()
    write_table(joinpath(d, "t"), "T", ["A" => Int32[1, 2, 3], "B" => ["x", "y", "z"]]; nrow=3)
    t = readtable(joinpath(d, "t"))

    # a row's getcolumn(::Symbol) for an unknown name used to give a raw,
    # confusing `ArgumentError("invalid index: nothing of type Nothing")`
    # instead of the KeyError column()/columndesc() themselves already give
    # for exactly this mistake — real, fixed.
    r = first(Tables.rows(t))
    @test_throws KeyError Tables.getcolumn(r, :NOPE)
    @test Tables.getcolumn(r, :A) == 1   # regression: a valid name still works

    # each `for r in t` gets its own fresh row-iteration state, so nested
    # loops over the same table object don't interfere with each other
    pairs = [(row1.B, row2.B) for row1 in t for row2 in t]
    @test length(pairs) == 9
    @test pairs[1] == ("x", "x") && pairs[end] == ("z", "z")

    # a zero-row table
    write_table(joinpath(d, "e"), "T", ["A" => Int32[], "B" => String[]]; nrow=0)
    et = readtable(joinpath(d, "e"))
    @test length(collect(Tables.rows(et))) == 0
    @test collect(et) == MSv2.CTDSRow[]
    @test Tables.schema(et).names == (:A, :B)   # schema still resolves with no rows

    @test Tables.columntable(t) == (A=Int32[1, 2, 3], B=["x", "y", "z"])

    # row (not just column) access for the non-plain-Table `AbstractTable`
    # kinds — only the column side had test coverage before this.
    rt = query(t, "A > 1")
    @test [Tables.getcolumn(r, :B) for r in Tables.rows(rt)] == ["y", "z"]

    gt = groupby(t, "A"; select=["A" => :A, "N" => "gcount()"])
    @test [Tables.getcolumn(r, :N) for r in Tables.rows(gt)] == fill(1, 3)

    write_table(joinpath(d, "t2"), "T", ["A" => Int32[9, 9], "B" => ["p", "q"]]; nrow=2)
    ct = MSv2.ConcatTable(joinpath(d, "cc"), MSv2.AbstractTable[t, readtable(joinpath(d, "t2"))],
                          [0, 3, 5], String[], "", "", "")
    @test [Tables.getcolumn(r, :A) for r in Tables.rows(ct)] == Int32[1, 2, 3, 9, 9]
    @test [Tables.getcolumn(r, :A) for r in ct] == Int32[1, 2, 3, 9, 9]   # direct iteration too
end
