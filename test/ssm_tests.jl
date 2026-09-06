# StandardStMan column-data tests against the sample MS.

_flat(x) = x isa AbstractArray ? collect(vec(x)) : [x]

@testset "SSM structural" begin
    ant = subtable(MeasurementSet(SAMPLE_MS), "ANTENNA")

    names = getcolumn(ant, "NAME")
    @test length(names) == 26
    @test names[1] == "ea01" && names[end] == "ea28"
    @test all(==("ALT-AZ"), getcolumn(ant, "MOUNT"))
    @test all(==(25.0), getcolumn(ant, "DISH_DIAMETER"))

    pos = getcolumn(ant, "POSITION")
    @test length(pos) == 26 && size(pos[1]) == (3,)
    @test getcell(ant, "POSITION", 1) == pos[1]

    t = readtable(SAMPLE_MS)
    a1 = getcolumn(t, "ANTENNA1")
    @test length(a1) == nrow(t)
    @test eltype(a1) == Int32
    @test extrema(a1) == (0, 24)
    @test eltype(getcolumn(t, "FLAG_ROW")) == Bool
end

if _HAVE_CASACORE
    function crosscheck_ssm(path, cols)
        t = readtable(path)
        ct = CCT.Table(path)
        @testset "$(basename(path))" begin
            for name in cols
                ours = getcolumn(t, name)
                col = ct[Symbol(name)]
                match = all(1:nrow(t)) do i
                    tv = ndims(col) == 1 ? col[i] :
                         col[ntuple(_ -> Colon(), ndims(col) - 1)..., i]
                    _flat(ours[i]) == _flat(tv)
                end
                @test match         # column $name matches casacore
            end
        end
    end

    @testset "SSM vs casacore" begin
        crosscheck_ssm(SAMPLE_MS,
            ["ANTENNA1", "ANTENNA2", "DATA_DESC_ID", "FLAG_ROW"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "ANTENNA"),
            ["NAME", "STATION", "MOUNT", "TYPE", "DISH_DIAMETER",
             "FLAG_ROW", "POSITION", "OFFSET"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "OBSERVATION"),
            ["TELESCOPE_NAME", "OBSERVER", "PROJECT", "SCHEDULE_TYPE",
             "TIME_RANGE", "RELEASE_DATE", "FLAG_ROW"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "SOURCE"),
            ["NAME", "CODE", "SOURCE_ID", "DIRECTION", "PROPER_MOTION",
             "NUM_LINES", "INTERVAL"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW"),
            ["NAME", "NUM_CHAN", "REF_FREQUENCY", "FREQ_GROUP_NAME",
             "TOTAL_BANDWIDTH", "NET_SIDEBAND"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "FEED"),
            ["ANTENNA_ID", "FEED_ID", "NUM_RECEPTORS", "INTERVAL", "TIME",
             "POSITION", "SPECTRAL_WINDOW_ID"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "STATE"),
            ["SIG", "REF", "CAL", "LOAD", "SUB_SCAN", "OBS_MODE"])
        crosscheck_ssm(joinpath(SAMPLE_MS, "DATA_DESCRIPTION"),
            ["SPECTRAL_WINDOW_ID", "POLARIZATION_ID", "FLAG_ROW"])
    end
end
