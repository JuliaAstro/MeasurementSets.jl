# Phase 5: standard MS v2 schema + validation.

@testset "schema" begin
    @test haskey(SCHEMAVER2, "MAIN")
    @test length(SCHEMAVER2) == 18          # MAIN + 17 standard subtables
    main = stdtable("MAIN")
    @test "ANTENNA" in main.subtables
    @test any(c -> c.name == "DATA" && !c.required, main.columns)
    @test any(c -> c.name == "TIME" && c.required, main.columns)
    @test stdtable("antenna") === SCHEMAVER2["ANTENNA"]   # case-insensitive

    # the sample MS is conformant
    @test isempty(validate(MeasurementSet(SAMPLE_MS)))
    @test isempty(validate(readtable(SAMPLE_MS); table="MAIN"))
    @test isempty(validate(readtable(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW"));
                           table="SPECTRAL_WINDOW"))

    # a table missing a required column / with a wrong type is flagged
    t = readtable(joinpath(SAMPLE_MS, "ANTENNA"))
    bad = filter(c -> c.name != "NAME", t.desc.columns)          # drop NAME
    bad[1] = ColumnDesc(bad[1].name, bad[1].comment, bad[1].manager,
                        bad[1].group, MSv2.TpInt, bad[1].classname, bad[1].shape,
                        bad[1].option, bad[1].maxlength, bad[1].keywords,
                        bad[1].default, bad[1].sequ)              # wrong type
    bt = MSv2.Table(t.path, t.type, t.subtype, t.readme, t.version, t.rows,
                        t.endian, MSv2.TableDesc(t.desc.name, t.desc.version,
                        t.desc.comment, t.desc.public, t.desc.private, bad),
                        t.managers, t.syncmod, t.lockpath)
    issues = validate(bt; table="ANTENNA")
    @test any(contains("missing required column NAME"), issues)
    @test any(contains("type"), issues)
end
