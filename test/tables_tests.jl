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
