# The MeasurementSet v2 standard schema (NRAO Memo 229 §5).
#
# Used for `validate` now and by the writer (Phase 6) to create a
# conformant MS.  Only the standard columns/keywords are encoded; an MS may
# carry additional instrument-specific ones.

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

# compact builders -------------------------------------------------
_c(n, t, s=(); u="", req=true, doc="") = StdColumn(n, t, s, u, req, doc)
_req(n, t, s=(); u="", doc="") = _c(n, t, s; u, req=true, doc)
_opt(n, t, s=(); u="", doc="") = _c(n, t, s; u, req=false, doc)

const _V = VariableShape()
const _VD = VariableDims()

const MS_SCHEMA = Dict{String,StdTable}()

_deftable(name, cols; keywords=Pair{String,Any}[], subtables=String[]) =
    MS_SCHEMA[name] = StdTable(name, cols, keywords, subtables)

# --- MAIN --------------------------------------------------------
_deftable("MAIN", [
    _req("TIME", TpDouble; u="s", doc="Integration midpoint"),
    _req("ANTENNA1", TpInt), _req("ANTENNA2", TpInt),
    _req("FEED1", TpInt), _req("FEED2", TpInt),
    _req("DATA_DESC_ID", TpInt), _req("PROCESSOR_ID", TpInt),
    _req("FIELD_ID", TpInt),
    _req("INTERVAL", TpDouble; u="s"), _req("EXPOSURE", TpDouble; u="s"),
    _req("TIME_CENTROID", TpDouble; u="s"),
    _req("SCAN_NUMBER", TpInt), _req("ARRAY_ID", TpInt),
    _req("OBSERVATION_ID", TpInt), _req("STATE_ID", TpInt),
    _req("UVW", TpDouble, (3,); u="m", doc="UVW coordinates"),
    _req("SIGMA", TpFloat, _V; doc="rms noise per correlator"),
    _req("WEIGHT", TpFloat, _V),
    _req("FLAG", TpBool, _V), _req("FLAG_CATEGORY", TpBool, _V),
    _req("FLAG_ROW", TpBool),
    _opt("DATA", TpComplex, _V; doc="complex visibility matrix"),
    _opt("FLOAT_DATA", TpFloat, _V; doc="single-dish float data"),
    _opt("WEIGHT_SPECTRUM", TpFloat, _V),
    _opt("SIGMA_SPECTRUM", TpFloat, _V),
];
    keywords = Pair{String,Any}["MS_VERSION" => 2.0f0],
    subtables = ["ANTENNA", "DATA_DESCRIPTION", "FEED", "FIELD", "FLAG_CMD",
                 "HISTORY", "OBSERVATION", "POINTING", "POLARIZATION",
                 "PROCESSOR", "SPECTRAL_WINDOW", "STATE"])

# --- standard subtables ---------------------------------------
_deftable("ANTENNA", [
    _req("NAME", TpString), _req("STATION", TpString),
    _req("TYPE", TpString), _req("MOUNT", TpString),
    _req("POSITION", TpDouble, (3,); u="m"),
    _req("OFFSET", TpDouble, (3,); u="m"),
    _req("DISH_DIAMETER", TpDouble; u="m"),
    _req("FLAG_ROW", TpBool),
    _opt("ORBIT_ID", TpInt), _opt("MEAN_ORBIT", TpDouble, (6,)),
    _opt("PHASED_ARRAY_ID", TpInt),
])

_deftable("DATA_DESCRIPTION", [
    _req("SPECTRAL_WINDOW_ID", TpInt), _req("POLARIZATION_ID", TpInt),
    _req("FLAG_ROW", TpBool), _opt("LAG_ID", TpInt),
])

_deftable("DOPPLER", [
    _req("DOPPLER_ID", TpInt), _req("SOURCE_ID", TpInt),
    _req("TRANSITION_ID", TpInt), _req("VELDEF", TpDouble; u="m/s"),
])

_deftable("FEED", [
    _req("ANTENNA_ID", TpInt), _req("FEED_ID", TpInt),
    _req("SPECTRAL_WINDOW_ID", TpInt),
    _req("TIME", TpDouble; u="s"), _req("INTERVAL", TpDouble; u="s"),
    _req("NUM_RECEPTORS", TpInt), _req("BEAM_ID", TpInt),
    _req("BEAM_OFFSET", TpDouble, _V; u="rad"),
    _req("POLARIZATION_TYPE", TpString, _V),
    _req("POL_RESPONSE", TpComplex, _V),
    _req("POSITION", TpDouble, (3,); u="m"),
    _req("RECEPTOR_ANGLE", TpDouble, _V; u="rad"),
    _opt("FOCUS_LENGTH", TpDouble; u="m"), _opt("PHASED_FEED_ID", TpInt),
])

_deftable("FIELD", [
    _req("NAME", TpString), _req("CODE", TpString),
    _req("TIME", TpDouble; u="s"), _req("NUM_POLY", TpInt),
    _req("DELAY_DIR", TpDouble, _V; u="rad"),
    _req("PHASE_DIR", TpDouble, _V; u="rad"),
    _req("REFERENCE_DIR", TpDouble, _V; u="rad"),
    _req("SOURCE_ID", TpInt), _req("FLAG_ROW", TpBool),
    _opt("EPHEMERIS_ID", TpInt),
])

_deftable("FLAG_CMD", [
    _req("TIME", TpDouble; u="s"), _req("INTERVAL", TpDouble; u="s"),
    _req("TYPE", TpString), _req("REASON", TpString),
    _req("LEVEL", TpInt), _req("SEVERITY", TpInt),
    _req("APPLIED", TpBool), _req("COMMAND", TpString),
])

_deftable("FREQ_OFFSET", [
    _req("ANTENNA1", TpInt), _req("ANTENNA2", TpInt),
    _req("FEED_ID", TpInt), _req("SPECTRAL_WINDOW_ID", TpInt),
    _req("TIME", TpDouble; u="s"), _req("INTERVAL", TpDouble; u="s"),
    _req("OFFSET", TpDouble; u="Hz"),
])

_deftable("HISTORY", [
    _req("TIME", TpDouble; u="s"), _req("OBSERVATION_ID", TpInt),
    _req("MESSAGE", TpString), _req("PRIORITY", TpString),
    _req("ORIGIN", TpString), _req("OBJECT_ID", TpInt),
    _req("APPLICATION", TpString),
    _req("CLI_COMMAND", TpString, _V), _req("APP_PARAMS", TpString, _V),
])

_deftable("OBSERVATION", [
    _req("TELESCOPE_NAME", TpString),
    _req("TIME_RANGE", TpDouble, (2,); u="s"),
    _req("OBSERVER", TpString), _req("LOG", TpString, _V),
    _req("SCHEDULE_TYPE", TpString), _req("SCHEDULE", TpString, _V),
    _req("PROJECT", TpString), _req("RELEASE_DATE", TpDouble; u="s"),
    _req("FLAG_ROW", TpBool),
])

_deftable("POINTING", [
    _req("ANTENNA_ID", TpInt), _req("TIME", TpDouble; u="s"),
    _req("INTERVAL", TpDouble; u="s"), _req("NAME", TpString),
    _req("NUM_POLY", TpInt), _req("TIME_ORIGIN", TpDouble; u="s"),
    _req("DIRECTION", TpDouble, _V; u="rad"),
    _req("TARGET", TpDouble, _V; u="rad"),
    _req("TRACKING", TpBool),
    _opt("POINTING_OFFSET", TpDouble, _V; u="rad"),
    _opt("SOURCE_OFFSET", TpDouble, _V; u="rad"),
    _opt("ENCODER", TpDouble, (2,); u="rad"),
    _opt("POINTING_MODEL_ID", TpInt),
    _opt("ON_SOURCE", TpBool), _opt("OVER_THE_TOP", TpBool),
])

_deftable("POLARIZATION", [
    _req("NUM_CORR", TpInt),
    _req("CORR_TYPE", TpInt, _V), _req("CORR_PRODUCT", TpInt, _V),
    _req("FLAG_ROW", TpBool),
])

_deftable("PROCESSOR", [
    _req("TYPE", TpString), _req("SUB_TYPE", TpString),
    _req("TYPE_ID", TpInt), _req("MODE_ID", TpInt),
    _req("FLAG_ROW", TpBool), _opt("PASS_ID", TpInt),
])

_deftable("SOURCE", [
    _req("SOURCE_ID", TpInt), _req("TIME", TpDouble; u="s"),
    _req("INTERVAL", TpDouble; u="s"), _req("SPECTRAL_WINDOW_ID", TpInt),
    _req("NUM_LINES", TpInt), _req("NAME", TpString),
    _req("CALIBRATION_GROUP", TpInt), _req("CODE", TpString),
    _req("DIRECTION", TpDouble, (2,); u="rad"),
    _req("PROPER_MOTION", TpDouble, (2,); u="rad/s"),
    _opt("POSITION", TpDouble, (3,); u="m"),
    _opt("TRANSITION", TpString, _V),
    _opt("REST_FREQUENCY", TpDouble, _V; u="Hz"),
    _opt("SYSVEL", TpDouble, _V; u="m/s"),
    _opt("PULSAR_ID", TpInt),
])

_deftable("SPECTRAL_WINDOW", [
    _req("NUM_CHAN", TpInt), _req("NAME", TpString),
    _req("REF_FREQUENCY", TpDouble; u="Hz"),
    _req("CHAN_FREQ", TpDouble, _V; u="Hz"),
    _req("CHAN_WIDTH", TpDouble, _V; u="Hz"),
    _req("MEAS_FREQ_REF", TpInt),
    _req("EFFECTIVE_BW", TpDouble, _V; u="Hz"),
    _req("RESOLUTION", TpDouble, _V; u="Hz"),
    _req("TOTAL_BANDWIDTH", TpDouble; u="Hz"),
    _req("NET_SIDEBAND", TpInt), _req("IF_CONV_CHAIN", TpInt),
    _req("FREQ_GROUP", TpInt), _req("FREQ_GROUP_NAME", TpString),
    _req("FLAG_ROW", TpBool),
    _opt("BBC_NO", TpInt), _opt("BBC_SIDEBAND", TpInt),
    _opt("RECEIVER_ID", TpInt), _opt("DOPPLER_ID", TpInt),
    _opt("ASSOC_SPW_ID", TpInt, _VD), _opt("ASSOC_NATURE", TpString, _VD),
])

_deftable("STATE", [
    _req("SIG", TpBool), _req("REF", TpBool),
    _req("CAL", TpDouble; u="K"), _req("LOAD", TpDouble; u="K"),
    _req("SUB_SCAN", TpInt), _req("OBS_MODE", TpString),
    _req("FLAG_ROW", TpBool),
])

_deftable("SYSCAL", [
    _req("ANTENNA_ID", TpInt), _req("FEED_ID", TpInt),
    _req("SPECTRAL_WINDOW_ID", TpInt),
    _req("TIME", TpDouble; u="s"), _req("INTERVAL", TpDouble; u="s"),
])

_deftable("WEATHER", [
    _req("ANTENNA_ID", TpInt), _req("TIME", TpDouble; u="s"),
    _req("INTERVAL", TpDouble; u="s"),
])

# --- accessors + validation --------------------------------------

"""
    stdtable(name) -> StdTable

The standard MS v2 definition for table `name` ("MAIN", "ANTENNA", …).
"""
stdtable(name::AbstractString) = MS_SCHEMA[uppercase(name)]
stdcolumns(name::AbstractString) = stdtable(name).columns

"""
    validate(t::CTDSTable; table="MAIN") -> Vector{String}

Check `t` against the standard schema for `table`.  Returns a list of
issues (missing required column, element-type mismatch, missing required
subtable, unexpected keyword value); empty means conformant.  Never throws.
"""
function validate(t::CTDSTable; table::AbstractString="MAIN")
    issues = String[]
    std = get(MS_SCHEMA, uppercase(table), nothing)
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
        haskey(MS_SCHEMA, name) || continue
        for i in validate(subtable(ms, name); table=name)
            push!(issues, "$name: $i")
        end
    end
    return issues
end
