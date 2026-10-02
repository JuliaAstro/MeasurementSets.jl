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


# Phase 330: every column of a casatools-simulator-built MS (134 columns over MAIN and 12 subtables) diffed
# against the standard schema (`stdtable`).  Types agree for all of them, no required schema column is
# missing from a casacore-built MS, and every `Dims` shape in the schema has casacore's rank.  (The units
# differ only in representation: casacore repeats a unit per component, `m,m,m`, where the schema has `m`;
# MODEL_DATA / CORRECTED_DATA are casacore-added optional columns not in the standard.)  Static snapshot of
# casatools' (table, column, valueType, ndim).
const _CASACORE_SIM_COLUMNS = [
    ("MAIN", "UVW", "double", 1),
    ("MAIN", "FLAG", "boolean", 2),
    ("MAIN", "FLAG_CATEGORY", "boolean", 3),
    ("MAIN", "WEIGHT", "float", 1),
    ("MAIN", "SIGMA", "float", 1),
    ("MAIN", "ANTENNA1", "int", -1),
    ("MAIN", "ANTENNA2", "int", -1),
    ("MAIN", "ARRAY_ID", "int", -1),
    ("MAIN", "DATA_DESC_ID", "int", -1),
    ("MAIN", "EXPOSURE", "double", -1),
    ("MAIN", "FEED1", "int", -1),
    ("MAIN", "FEED2", "int", -1),
    ("MAIN", "FIELD_ID", "int", -1),
    ("MAIN", "FLAG_ROW", "boolean", -1),
    ("MAIN", "INTERVAL", "double", -1),
    ("MAIN", "OBSERVATION_ID", "int", -1),
    ("MAIN", "PROCESSOR_ID", "int", -1),
    ("MAIN", "SCAN_NUMBER", "int", -1),
    ("MAIN", "STATE_ID", "int", -1),
    ("MAIN", "TIME", "double", -1),
    ("MAIN", "TIME_CENTROID", "double", -1),
    ("MAIN", "DATA", "complex", 2),
    ("MAIN", "MODEL_DATA", "complex", 2),
    ("MAIN", "CORRECTED_DATA", "complex", 2),
    ("ANTENNA", "OFFSET", "double", 1),
    ("ANTENNA", "POSITION", "double", 1),
    ("ANTENNA", "TYPE", "string", -1),
    ("ANTENNA", "DISH_DIAMETER", "double", -1),
    ("ANTENNA", "FLAG_ROW", "boolean", -1),
    ("ANTENNA", "MOUNT", "string", -1),
    ("ANTENNA", "NAME", "string", -1),
    ("ANTENNA", "STATION", "string", -1),
    ("DATA_DESCRIPTION", "FLAG_ROW", "boolean", -1),
    ("DATA_DESCRIPTION", "POLARIZATION_ID", "int", -1),
    ("DATA_DESCRIPTION", "SPECTRAL_WINDOW_ID", "int", -1),
    ("FEED", "POSITION", "double", 1),
    ("FEED", "BEAM_OFFSET", "double", 2),
    ("FEED", "POLARIZATION_TYPE", "string", 1),
    ("FEED", "POL_RESPONSE", "complex", 2),
    ("FEED", "RECEPTOR_ANGLE", "double", 1),
    ("FEED", "ANTENNA_ID", "int", -1),
    ("FEED", "BEAM_ID", "int", -1),
    ("FEED", "FEED_ID", "int", -1),
    ("FEED", "INTERVAL", "double", -1),
    ("FEED", "NUM_RECEPTORS", "int", -1),
    ("FEED", "SPECTRAL_WINDOW_ID", "int", -1),
    ("FEED", "TIME", "double", -1),
    ("FIELD", "DELAY_DIR", "double", 2),
    ("FIELD", "PHASE_DIR", "double", 2),
    ("FIELD", "REFERENCE_DIR", "double", 2),
    ("FIELD", "CODE", "string", -1),
    ("FIELD", "FLAG_ROW", "boolean", -1),
    ("FIELD", "NAME", "string", -1),
    ("FIELD", "NUM_POLY", "int", -1),
    ("FIELD", "SOURCE_ID", "int", -1),
    ("FIELD", "TIME", "double", -1),
    ("FLAG_CMD", "APPLIED", "boolean", -1),
    ("FLAG_CMD", "COMMAND", "string", -1),
    ("FLAG_CMD", "INTERVAL", "double", -1),
    ("FLAG_CMD", "LEVEL", "int", -1),
    ("FLAG_CMD", "REASON", "string", -1),
    ("FLAG_CMD", "SEVERITY", "int", -1),
    ("FLAG_CMD", "TIME", "double", -1),
    ("FLAG_CMD", "TYPE", "string", -1),
    ("HISTORY", "APP_PARAMS", "string", 1),
    ("HISTORY", "CLI_COMMAND", "string", 1),
    ("HISTORY", "APPLICATION", "string", -1),
    ("HISTORY", "MESSAGE", "string", -1),
    ("HISTORY", "OBJECT_ID", "int", -1),
    ("HISTORY", "OBSERVATION_ID", "int", -1),
    ("HISTORY", "ORIGIN", "string", -1),
    ("HISTORY", "PRIORITY", "string", -1),
    ("HISTORY", "TIME", "double", -1),
    ("OBSERVATION", "TIME_RANGE", "double", 1),
    ("OBSERVATION", "LOG", "string", 1),
    ("OBSERVATION", "SCHEDULE", "string", 1),
    ("OBSERVATION", "FLAG_ROW", "boolean", -1),
    ("OBSERVATION", "OBSERVER", "string", -1),
    ("OBSERVATION", "PROJECT", "string", -1),
    ("OBSERVATION", "RELEASE_DATE", "double", -1),
    ("OBSERVATION", "SCHEDULE_TYPE", "string", -1),
    ("OBSERVATION", "TELESCOPE_NAME", "string", -1),
    ("POINTING", "DIRECTION", "double", 2),
    ("POINTING", "ANTENNA_ID", "int", -1),
    ("POINTING", "INTERVAL", "double", -1),
    ("POINTING", "NAME", "string", -1),
    ("POINTING", "NUM_POLY", "int", -1),
    ("POINTING", "TARGET", "double", -1),
    ("POINTING", "TIME", "double", -1),
    ("POINTING", "TIME_ORIGIN", "double", -1),
    ("POINTING", "TRACKING", "boolean", -1),
    ("POLARIZATION", "CORR_TYPE", "int", 1),
    ("POLARIZATION", "CORR_PRODUCT", "int", 2),
    ("POLARIZATION", "FLAG_ROW", "boolean", -1),
    ("POLARIZATION", "NUM_CORR", "int", -1),
    ("PROCESSOR", "FLAG_ROW", "boolean", -1),
    ("PROCESSOR", "MODE_ID", "int", -1),
    ("PROCESSOR", "TYPE", "string", -1),
    ("PROCESSOR", "TYPE_ID", "int", -1),
    ("PROCESSOR", "SUB_TYPE", "string", -1),
    ("SOURCE", "CALIBRATION_GROUP", "int", -1),
    ("SOURCE", "CODE", "string", -1),
    ("SOURCE", "DIRECTION", "double", -1),
    ("SOURCE", "INTERVAL", "double", -1),
    ("SOURCE", "NAME", "string", -1),
    ("SOURCE", "NUM_LINES", "int", -1),
    ("SOURCE", "PROPER_MOTION", "double", -1),
    ("SOURCE", "SOURCE_ID", "int", -1),
    ("SOURCE", "SPECTRAL_WINDOW_ID", "int", -1),
    ("SOURCE", "TIME", "double", -1),
    ("SOURCE", "POSITION", "double", -1),
    ("SOURCE", "PULSAR_ID", "int", -1),
    ("SOURCE", "REST_FREQUENCY", "double", -1),
    ("SOURCE", "SYSVEL", "double", -1),
    ("SOURCE", "TRANSITION", "string", -1),
    ("SPECTRAL_WINDOW", "MEAS_FREQ_REF", "int", -1),
    ("SPECTRAL_WINDOW", "CHAN_FREQ", "double", 1),
    ("SPECTRAL_WINDOW", "REF_FREQUENCY", "double", -1),
    ("SPECTRAL_WINDOW", "CHAN_WIDTH", "double", 1),
    ("SPECTRAL_WINDOW", "EFFECTIVE_BW", "double", 1),
    ("SPECTRAL_WINDOW", "RESOLUTION", "double", 1),
    ("SPECTRAL_WINDOW", "FLAG_ROW", "boolean", -1),
    ("SPECTRAL_WINDOW", "FREQ_GROUP", "int", -1),
    ("SPECTRAL_WINDOW", "FREQ_GROUP_NAME", "string", -1),
    ("SPECTRAL_WINDOW", "IF_CONV_CHAIN", "int", -1),
    ("SPECTRAL_WINDOW", "NAME", "string", -1),
    ("SPECTRAL_WINDOW", "NET_SIDEBAND", "int", -1),
    ("SPECTRAL_WINDOW", "NUM_CHAN", "int", -1),
    ("SPECTRAL_WINDOW", "TOTAL_BANDWIDTH", "double", -1),
    ("STATE", "CAL", "double", -1),
    ("STATE", "FLAG_ROW", "boolean", -1),
    ("STATE", "LOAD", "double", -1),
    ("STATE", "OBS_MODE", "string", -1),
    ("STATE", "REF", "boolean", -1),
    ("STATE", "SIG", "boolean", -1),
    ("STATE", "SUB_SCAN", "int", -1),
]
@testset "schema — column types/ranks match a casacore-built MS (Phase 330)" begin
    vt = Dict("boolean" => MSv2.TpBool, "int" => MSv2.TpInt, "float" => MSv2.TpFloat, "double" => MSv2.TpDouble,
              "complex" => MSv2.TpComplex, "dcomplex" => MSv2.TpDComplex, "string" => MSv2.TpString,
              "short" => MSv2.TpShort, "uint" => MSv2.TpUInt)
    nchecked = 0
    for (tab, col, t, nd) in _CASACORE_SIM_COLUMNS
        st = stdtable(tab)
        @test st !== nothing
        i = findfirst(c -> c.name == col, st.columns)
        i === nothing && (@test col in ("MODEL_DATA", "CORRECTED_DATA"); continue)
        c = st.columns[i]; nchecked += 1
        @test c.type == vt[t]
        # casatools: scalar -> -1; a few columns (SOURCE.DIRECTION / PROPER_MOTION / POSITION in the simulator's
        # SOURCE table) report no rank at all, which is not a disagreement
        c.shape isa Tuple && (isempty(c.shape) || nd != -1) && @test (isempty(c.shape) ? -1 : length(c.shape)) == nd
    end
    @test nchecked == length(_CASACORE_SIM_COLUMNS) - 2
    for tab in unique(first.(_CASACORE_SIM_COLUMNS))
        have = Set(c[2] for c in _CASACORE_SIM_COLUMNS if c[1] == tab)
        @test all(c.name in have for c in stdtable(tab).columns if c.required)
    end
end
