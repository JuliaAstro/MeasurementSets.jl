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
                        t.managers, t.syncmod, t.lockpath, t.container, t.precision)
    issues = validate(bt; table="ANTENNA")
    @test any(contains("missing required column NAME"), issues)
    @test any(contains("type"), issues)

    # keyword-value mismatch / missing-keyword / missing-subtable (Phase 288
    # — a real, previously-untested-but-correct set of `validate` branches)
    @test stdcolumns("MAIN") === stdtable("MAIN").columns

    m = readtable(SAMPLE_MS)   # a fresh MAIN
    _rebuild(desc) = MSv2.Table(m.path, m.type, m.subtype, m.readme, m.version,
                                m.rows, m.endian, desc, m.managers, m.syncmod,
                                m.lockpath, m.container, m.precision)
    _drop_kw(pub, name) = (p = deepcopy(pub); i = findfirst(==(name), p.names);
                           deleteat!(p.names, i); deleteat!(p.types, i);
                           deleteat!(p.values, i); deleteat!(p.comments, i); p)

    pub_wrong = deepcopy(m.desc.public)
    pub_wrong.values[findfirst(==("MS_VERSION"), pub_wrong.names)] = 3.0f0
    issues_kw = validate(_rebuild(MSv2.TableDesc(m.desc.name, m.desc.version,
        m.desc.comment, pub_wrong, m.desc.private, m.desc.columns)); table="MAIN")
    @test any(contains("keyword MS_VERSION = 3.0"), issues_kw)

    issues_nokw = validate(_rebuild(MSv2.TableDesc(m.desc.name, m.desc.version,
        m.desc.comment, _drop_kw(m.desc.public, "MS_VERSION"), m.desc.private,
        m.desc.columns)); table="MAIN")
    @test any(contains("missing required keyword MS_VERSION"), issues_nokw)

    issues_nosub = validate(_rebuild(MSv2.TableDesc(m.desc.name, m.desc.version,
        m.desc.comment, _drop_kw(m.desc.public, "ANTENNA"), m.desc.private,
        m.desc.columns)); table="MAIN")
    @test any(contains("missing required subtable ANTENNA"), issues_nosub)
end
