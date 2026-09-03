# The MeasurementSet v2 standard schema (NRAO Memo 229 §5).
#
# Used for `validate` now and by the writer (Phase 6) to create a
# conformant MS.  Only the standard columns/keywords are encoded; an MS may
# carry additional instrument-specific ones.

const MS_VERSION = 2.0f0        # the MAIN table's `MS_VERSION` keyword value

struct StdColumn
    name::String
    type::CasaType
    shape::CellShape      # () scalar / Dims / VariableShape / VariableDims
    unit::String
    required::Bool
    comment::String
end

struct StdTable
    name::String
    columns::Vector{StdColumn}
    keywords::Vector{Pair{String,Any}}   # required keyword => expected value (or `nothing`)
    subtables::Vector{String}            # required subtables (MAIN only)
end

# builders -------------------------------------------------------
stdcol(n, t, s=(); u="", req=true, doc="") = StdColumn(n, t, s, u, req, doc)
required(n, t, s=(); u="", doc="") = stdcol(n, t, s; u, req=true, doc)
optional(n, t, s=(); u="", doc="") = stdcol(n, t, s; u, req=false, doc)

const VARSHAPE = VariableShape()
const VARDIMS = VariableDims()

const SCHEMAVER2 = Dict{String,StdTable}()

definetable(name, cols; keywords=Pair{String,Any}[], subtables=String[]) =
    SCHEMAVER2[name] = StdTable(name, cols, keywords, subtables)

# --- MAIN -----------------------------------------------------
definetable("MAIN", [
    required("TIME", TpDouble; u="s", doc="Integration midpoint"),
    required("ANTENNA1", TpInt),
    required("ANTENNA2", TpInt),
    required("FEED1", TpInt),
    required("FEED2", TpInt),
    required("DATA_DESC_ID", TpInt),
    required("PROCESSOR_ID", TpInt),
    required("FIELD_ID", TpInt),
    required("INTERVAL", TpDouble; u="s"),
    required("EXPOSURE", TpDouble; u="s"),
    required("TIME_CENTROID", TpDouble; u="s"),
    required("SCAN_NUMBER", TpInt),
    required("ARRAY_ID", TpInt),
    required("OBSERVATION_ID", TpInt),
    required("STATE_ID", TpInt),
    required("UVW", TpDouble, (3,); u="m", doc="UVW coordinates"),
    required("SIGMA", TpFloat, VARSHAPE; doc="rms noise per correlator"),
    required("WEIGHT", TpFloat, VARSHAPE),
    required("FLAG", TpBool, VARSHAPE),
    required("FLAG_CATEGORY", TpBool, VARSHAPE),
    required("FLAG_ROW", TpBool),
    optional("DATA", TpComplex, VARSHAPE; doc="complex visibility matrix"),
    optional("FLOAT_DATA", TpFloat, VARSHAPE; doc="single-dish float data"),
    optional("WEIGHT_SPECTRUM", TpFloat, VARSHAPE),
    optional("SIGMA_SPECTRUM", TpFloat, VARSHAPE),
];
    keywords = Pair{String,Any}["MS_VERSION" => MS_VERSION],
    subtables = ["ANTENNA", "DATA_DESCRIPTION", "FEED", "FIELD", "FLAG_CMD",
                 "HISTORY", "OBSERVATION", "POINTING", "POLARIZATION",
                 "PROCESSOR", "SPECTRAL_WINDOW", "STATE"])

# --- standard subtables ------------------------------------
definetable("ANTENNA", [
    required("NAME", TpString),
    required("STATION", TpString),
    required("TYPE", TpString),
    required("MOUNT", TpString),
    required("POSITION", TpDouble, (3,); u="m"),
    required("OFFSET", TpDouble, (3,); u="m"),
    required("DISH_DIAMETER", TpDouble; u="m"),
    required("FLAG_ROW", TpBool),
    optional("ORBIT_ID", TpInt),
    optional("MEAN_ORBIT", TpDouble, (6,)),
    optional("PHASED_ARRAY_ID", TpInt),
])

definetable("DATA_DESCRIPTION", [
    required("SPECTRAL_WINDOW_ID", TpInt),
    required("POLARIZATION_ID", TpInt),
    required("FLAG_ROW", TpBool),
    optional("LAG_ID", TpInt),
])

definetable("DOPPLER", [
    required("DOPPLER_ID", TpInt),
    required("SOURCE_ID", TpInt),
    required("TRANSITION_ID", TpInt),
    required("VELDEF", TpDouble; u="m/s"),
])

definetable("FEED", [
    required("ANTENNA_ID", TpInt),
    required("FEED_ID", TpInt),
    required("SPECTRAL_WINDOW_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
    required("NUM_RECEPTORS", TpInt),
    required("BEAM_ID", TpInt),
    required("BEAM_OFFSET", TpDouble, VARSHAPE; u="rad"),
    required("POLARIZATION_TYPE", TpString, VARSHAPE),
    required("POL_RESPONSE", TpComplex, VARSHAPE),
    required("POSITION", TpDouble, (3,); u="m"),
    required("RECEPTOR_ANGLE", TpDouble, VARSHAPE; u="rad"),
    optional("FOCUS_LENGTH", TpDouble; u="m"),
    optional("PHASED_FEED_ID", TpInt),
])

definetable("FIELD", [
    required("NAME", TpString),
    required("CODE", TpString),
    required("TIME", TpDouble; u="s"),
    required("NUM_POLY", TpInt),
    required("DELAY_DIR", TpDouble, VARSHAPE; u="rad"),
    required("PHASE_DIR", TpDouble, VARSHAPE; u="rad"),
    required("REFERENCE_DIR", TpDouble, VARSHAPE; u="rad"),
    required("SOURCE_ID", TpInt),
    required("FLAG_ROW", TpBool),
    optional("EPHEMERIS_ID", TpInt),
])

definetable("FLAG_CMD", [
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
    required("TYPE", TpString),
    required("REASON", TpString),
    required("LEVEL", TpInt),
    required("SEVERITY", TpInt),
    required("APPLIED", TpBool),
    required("COMMAND", TpString),
])

definetable("FREQ_OFFSET", [
    required("ANTENNA1", TpInt),
    required("ANTENNA2", TpInt),
    required("FEED_ID", TpInt),
    required("SPECTRAL_WINDOW_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
    required("OFFSET", TpDouble; u="Hz"),
])

definetable("HISTORY", [
    required("TIME", TpDouble; u="s"),
    required("OBSERVATION_ID", TpInt),
    required("MESSAGE", TpString),
    required("PRIORITY", TpString),
    required("ORIGIN", TpString),
    required("OBJECT_ID", TpInt),
    required("APPLICATION", TpString),
    required("CLI_COMMAND", TpString, VARSHAPE),
    required("APP_PARAMS", TpString, VARSHAPE),
])

definetable("OBSERVATION", [
    required("TELESCOPE_NAME", TpString),
    required("TIME_RANGE", TpDouble, (2,); u="s"),
    required("OBSERVER", TpString),
    required("LOG", TpString, VARSHAPE),
    required("SCHEDULE_TYPE", TpString),
    required("SCHEDULE", TpString, VARSHAPE),
    required("PROJECT", TpString),
    required("RELEASE_DATE", TpDouble; u="s"),
    required("FLAG_ROW", TpBool),
])

definetable("POINTING", [
    required("ANTENNA_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
    required("NAME", TpString),
    required("NUM_POLY", TpInt),
    required("TIME_ORIGIN", TpDouble; u="s"),
    required("DIRECTION", TpDouble, VARSHAPE; u="rad"),
    required("TARGET", TpDouble, VARSHAPE; u="rad"),
    required("TRACKING", TpBool),
    optional("POINTING_OFFSET", TpDouble, VARSHAPE; u="rad"),
    optional("SOURCE_OFFSET", TpDouble, VARSHAPE; u="rad"),
    optional("ENCODER", TpDouble, (2,); u="rad"),
    optional("POINTING_MODEL_ID", TpInt),
    optional("ON_SOURCE", TpBool),
    optional("OVER_THE_TOP", TpBool),
])

definetable("POLARIZATION", [
    required("NUM_CORR", TpInt),
    required("CORR_TYPE", TpInt, VARSHAPE),
    required("CORR_PRODUCT", TpInt, VARSHAPE),
    required("FLAG_ROW", TpBool),
])

definetable("PROCESSOR", [
    required("TYPE", TpString),
    required("SUB_TYPE", TpString),
    required("TYPE_ID", TpInt),
    required("MODE_ID", TpInt),
    required("FLAG_ROW", TpBool),
    optional("PASS_ID", TpInt),
])

definetable("SOURCE", [
    required("SOURCE_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
    required("SPECTRAL_WINDOW_ID", TpInt),
    required("NUM_LINES", TpInt),
    required("NAME", TpString),
    required("CALIBRATION_GROUP", TpInt),
    required("CODE", TpString),
    required("DIRECTION", TpDouble, (2,); u="rad"),
    required("PROPER_MOTION", TpDouble, (2,); u="rad/s"),
    optional("POSITION", TpDouble, (3,); u="m"),
    optional("TRANSITION", TpString, VARSHAPE),
    optional("REST_FREQUENCY", TpDouble, VARSHAPE; u="Hz"),
    optional("SYSVEL", TpDouble, VARSHAPE; u="m/s"),
    optional("PULSAR_ID", TpInt),
])

definetable("SPECTRAL_WINDOW", [
    required("NUM_CHAN", TpInt),
    required("NAME", TpString),
    required("REF_FREQUENCY", TpDouble; u="Hz"),
    required("CHAN_FREQ", TpDouble, VARSHAPE; u="Hz"),
    required("CHAN_WIDTH", TpDouble, VARSHAPE; u="Hz"),
    required("MEAS_FREQ_REF", TpInt),
    required("EFFECTIVE_BW", TpDouble, VARSHAPE; u="Hz"),
    required("RESOLUTION", TpDouble, VARSHAPE; u="Hz"),
    required("TOTAL_BANDWIDTH", TpDouble; u="Hz"),
    required("NET_SIDEBAND", TpInt),
    required("IF_CONV_CHAIN", TpInt),
    required("FREQ_GROUP", TpInt),
    required("FREQ_GROUP_NAME", TpString),
    required("FLAG_ROW", TpBool),
    optional("BBC_NO", TpInt),
    optional("BBC_SIDEBAND", TpInt),
    optional("RECEIVER_ID", TpInt),
    optional("DOPPLER_ID", TpInt),
    optional("ASSOC_SPW_ID", TpInt, VARDIMS),
    optional("ASSOC_NATURE", TpString, VARDIMS),
])

definetable("STATE", [
    required("SIG", TpBool),
    required("REF", TpBool),
    required("CAL", TpDouble; u="K"),
    required("LOAD", TpDouble; u="K"),
    required("SUB_SCAN", TpInt),
    required("OBS_MODE", TpString),
    required("FLAG_ROW", TpBool),
])

definetable("SYSCAL", [
    required("ANTENNA_ID", TpInt),
    required("FEED_ID", TpInt),
    required("SPECTRAL_WINDOW_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
])

definetable("WEATHER", [
    required("ANTENNA_ID", TpInt),
    required("TIME", TpDouble; u="s"),
    required("INTERVAL", TpDouble; u="s"),
])

# --- accessors + validation --------------------------------------

"""
    stdtable(name) -> StdTable

The standard MS v2 definition for table `name` ("MAIN", "ANTENNA", …).
"""
stdtable(name::AbstractString) = SCHEMAVER2[uppercase(name)]
stdcolumns(name::AbstractString) = stdtable(name).columns

"""
    validate(t::CTDSTable; table="MAIN") -> Vector{String}

Check `t` against the standard schema for `table`.  Returns a list of
issues (missing required column, element-type mismatch, missing required
subtable, unexpected keyword value); empty means conformant.  Never throws.
"""
function validate(t::CTDSTable; table::AbstractString="MAIN")
    issues = String[]
    std = get(SCHEMAVER2, uppercase(table), nothing)
    std === nothing && return ["no standard schema for table \"$table\""]

    have = Dict(c.name => c for c in t.desc.columns)
    for sc in std.columns
        col = get(have, sc.name, nothing)
        if col === nothing
            sc.required && push!(issues, "missing required column $(sc.name)")
            continue
        end
        sc.type == col.type || push!(issues,
            "column $(sc.name): type $(col.type), expected $(sc.type)")
    end

    for (kw, val) in std.keywords
        if !haskey(t.desc.public, kw)
            push!(issues, "missing required keyword $kw")
        elseif val !== nothing && t.desc.public[kw] != val
            push!(issues, "keyword $kw = $(t.desc.public[kw]), expected $val")
        end
    end

    if !isempty(std.subtables)
        present = Set(first.(subtables(t)))
        for s in std.subtables
            s in present || push!(issues, "missing required subtable $s")
        end
    end
    return issues
end

"""
    validate(ms::MeasurementSet) -> Vector{String}

Validate MAIN and every present standard subtable.
"""
function validate(ms::MeasurementSet)
    issues = validate(getfield(ms, :data); table="MAIN")
    for name in subtablenames(ms)
        haskey(SCHEMAVER2, name) || continue
        for i in validate(subtable(ms, name); table=name)
            push!(issues, "$name: $i")
        end
    end
    return issues
end
