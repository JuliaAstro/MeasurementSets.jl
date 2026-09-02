# Structural checks against the sample MS (no external oracle).

@testset "MAIN metadata" begin
    t = readtable(SAMPLE_MS)
    @test t.type == "Measurement Set"
    @test t.version == 2
    @test t.endian in (:big, :little)
    @test nrow(t) == 9_817_600
    @test length(t.desc.columns) == 23

    names = Set(columnnames(t))
    for c in ("TIME", "ANTENNA1", "ANTENNA2", "UVW", "DATA", "FLAG",
              "WEIGHT", "SIGMA", "FLAG_ROW", "DATA_DESC_ID")
        @test c in names
    end

    @test get(keywords(t), "MS_VERSION", nothing) == 2.0f0

    time = columndesc(t, "TIME")
    @test time.type == MSv2.TpDouble
    @test !isarray(time)
    @test time.manager == "StandardStMan"

    data = columndesc(t, "DATA")
    @test data.type == MSv2.TpComplex
    @test isarray(data)
    @test data.manager == "TiledShapeStMan"
    @test data.shape isa VariableShape          # 2-D, per-row-variable shape

    uvw = columndesc(t, "UVW")
    @test isarray(uvw) && uvw.shape == (3,)
    @test columndesc(t, "TIME").shape == ()     # scalar

    # QuantumUnits / MEASINFO nested keyword records decode
    tk = columndesc(t, "TIME").keywords
    @test "MEASINFO" in keys(tk)
    @test tk["QuantumUnits"] == ["s"]
end

@testset "subtable tree" begin
    ms = MeasurementSet(SAMPLE_MS)
    expected = ["ANTENNA", "DATA_DESCRIPTION", "FEED", "FLAG_CMD", "FIELD",
                "HISTORY", "OBSERVATION", "POLARIZATION", "PROCESSOR",
                "SPECTRAL_WINDOW", "STATE", "SOURCE", "POINTING", "SYSCAL",
                "WEATHER", "SYSPOWER", "CALDEVICE", "ASDM_CALATMOSPHERE",
                "ASDM_RECEIVER"]
    @test Set(subtablenames(ms)) == Set(expected)

    counts = Dict("ANTENNA" => 26, "DATA_DESCRIPTION" => 96, "FEED" => 2496,
                  "FIELD" => 3, "OBSERVATION" => 1, "POLARIZATION" => 1,
                  "SPECTRAL_WINDOW" => 96, "STATE" => 4, "SOURCE" => 256)
    for (n, k) in counts
        @test nrow(subtable(ms, n)) == k
    end

    spw = subtable(ms, "SPECTRAL_WINDOW")
    for c in ("CHAN_FREQ", "NUM_CHAN", "REF_FREQUENCY", "MEAS_FREQ_REF")
        @test c in columnnames(spw)
    end
    @test columndesc(spw, "CHAN_FREQ").type == MSv2.TpDouble
    @test isarray(columndesc(spw, "CHAN_FREQ"))

    ant = subtable(ms, "ANTENNA")
    @test columndesc(ant, "NAME").type == MSv2.TpString
    @test columndesc(ant, "POSITION").shape == (3,)
end
