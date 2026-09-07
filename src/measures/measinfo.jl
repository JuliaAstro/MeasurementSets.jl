# casacore `MEASINFO` column-keyword parsing + serialisation.
#
# A measure-valued column carries a `MEASINFO` sub-record keyword:
#   type        -- "epoch" / "direction" / "frequency" / "position" /
#                  "radialvelocity" / "doppler" / "uvw" / "baseline"
#   Ref         -- a fixed reference-frame name  ("J2000", "UTC", ...)   XOR
#   VarRefCol   -- name of a companion column holding a per-row Int code
#   TabRefTypes -- Vector{String}   (code -> name map for VarRefCol)
#   TabRefCodes -- Vector{UInt}
# plus the sibling `QuantumUnits` keyword for the value's unit(s).
# (`RefOff`, an offset-measure sub-record, is parsed-and-carried but not
# applied -- see the phase non-goals.)
#
# Ref: casacore/measures/TableMeasures/TableMeasRefDesc.cc:117-155 (read),
#      TableMeasDescBase::write (.cc:126-160) + MeasureHolder::toRecord.

# name-string (casacore enum spelling, incl. synonyms) -> RefFrame type,
# per measure kind.  Unknown strings become `OtherRef{Symbol(s)}`.
const _MEAS_FRAMES = Dict{Symbol,Dict{String,DataType}}(
    :epoch => Dict(
        "UTC" => UTC, "TAI" => TAI, "IAT" => TAI,
        "TDT" => TT, "TT" => TT, "ET" => TT,
        "TDB" => TDB, "UT1" => UT1, "UT" => UT1),
    :direction => Dict(
        "J2000" => J2000, "ICRS" => ICRS, "B1950" => B1950,
        "B1950_VLA" => B1950, "APP" => APP,
        "GALACTIC" => GALACTIC, "ECLIPTIC" => ECLIPTIC,
        "HADEC" => HADEC,
        "AZEL" => AZEL, "AZELNE" => AZEL,
        "AZELGEO" => AZELGEO, "AZELNEGEO" => AZELGEO,
        "ITRF" => ITRF, "TOPO" => TOPO),
    :position => Dict("ITRF" => ITRF, "WGS84" => WGS84),
    :frequency => Dict(
        "REST" => REST, "LSRK" => LSRK, "LSR" => LSRK, "LSRD" => LSRD,
        "BARY" => BARY, "GEO" => GEO, "TOPO" => TOPO, "GALACTO" => GALACTO),
    :radialvelocity => Dict(
        "LSRK" => LSRK, "LSR" => LSRK, "LSRD" => LSRD, "BARY" => BARY,
        "GEO" => GEO, "TOPO" => TOPO, "GALACTO" => GALACTO),
    :uvw => Dict("J2000" => J2000, "ITRF" => ITRF, "APP" => APP),
)

# fixed casacore refcode enum order for the kinds that use VarRefCol
# without an explicit TabRefCodes/TabRefTypes map (rare -- the fixture
# always supplies the map).  Index 0-based, matching the C++ enum.
const _MEAS_ENUM = Dict{Symbol,Vector{String}}(
    :direction => ["J2000", "JMEAN", "JTRUE", "APP", "B1950", "B1950_VLA",
                   "BMEAN", "BTRUE", "GALACTIC", "HADEC", "AZEL", "AZELSW",
                   "AZELGEO", "AZELSWGEO", "JNAT", "ECLIPTIC", "MECLIPTIC",
                   "TECLIPTIC", "SUPERGAL", "ITRF", "TOPO", "ICRS"],
    :frequency => ["REST", "LSRK", "LSRD", "BARY", "GEO", "TOPO", "GALACTO",
                   "LGROUP", "CMB"],
    :epoch => ["LAST", "LMST", "GMST1", "GAST", "UT1", "UT2", "UTC", "TAI",
               "TDT", "TCG", "TDB", "TCB"],
)

"""
    MeasInfo

The parsed `MEASINFO` (+ `QuantumUnits`) of a measure-valued column.
`fixedref` xor `varrefcol` is set.
"""
struct MeasInfo
    kind::Symbol                       # :epoch / :direction / :frequency / ...
    fixedref::Union{Nothing,String}
    varrefcol::Union{Nothing,String}
    tabtypes::Vector{String}
    tabcodes::Vector{Int}
    units::Vector{String}
end

"""
    measinfo(t, col) -> Union{Nothing,MeasInfo}

Parse the `MEASINFO` keyword of column `col`.  `nothing` if the column
carries no measure information.
"""
function measinfo(t::AbstractTable, col::AbstractString)
    kw = columndesc(t, col).keywords
    haskey(kw, "MEASINFO") || return nothing
    mi = kw["MEASINFO"]
    mi isa Record || return nothing
    kind = Symbol(lowercase(String(mi["type"])))
    fixed = haskey(mi, "Ref") ? String(mi["Ref"]) : nothing
    varcol = haskey(mi, "VarRefCol") ? String(mi["VarRefCol"]) : nothing
    tt = haskey(mi, "TabRefTypes") ? String.(collect(mi["TabRefTypes"])) : String[]
    tc = haskey(mi, "TabRefCodes") ? Int.(collect(mi["TabRefCodes"])) : Int[]
    units = haskey(kw, "QuantumUnits") ? String.(collect(kw["QuantumUnits"])) :
            (haskey(kw, "QuantumUnit") ? [String(kw["QuantumUnit"])] : String[])
    MeasInfo(kind, fixed, varcol, tt, tc, units)
end

"""
    _ref_string(mi, t, col, row) -> String

The reference-frame name for one row: the fixed `Ref`, or the
`VarRefCol` companion column's code for that row mapped through
`TabRefCodes` -> `TabRefTypes` (or the fixed enum order).
"""
# a per-row `VarRefCol` code -> its reference-frame name
function _ref_from_code(mi::MeasInfo, code::Integer)
    c = Int(code)
    if !isempty(mi.tabcodes)
        i = findfirst(==(c), mi.tabcodes)
        i === nothing && throw(ArgumentError("MEASINFO ref code $c not in TabRefCodes"))
        return mi.tabtypes[i]
    end
    enum = get(_MEAS_ENUM, mi.kind, String[])
    0 <= c < length(enum) || throw(ArgumentError(
        "MEASINFO ref code $c out of range for $(mi.kind)"))
    return enum[c + 1]
end

function _ref_string(mi::MeasInfo, t::AbstractTable, col::AbstractString, row::Integer)
    mi.fixedref !== nothing && return mi.fixedref
    mi.varrefcol === nothing && throw(ArgumentError(
        "column \"$col\": MEASINFO has neither Ref nor VarRefCol"))
    _ref_from_code(mi, getcell(t, mi.varrefcol, row))
end

_frame_type(kind::Symbol, s::AbstractString) =
    get(get(_MEAS_FRAMES, kind, Dict{String,DataType}()),
        uppercase(strip(String(s))), OtherRef{Symbol(strip(String(s)))})

# ------------------------------------------------------------------
# write side
# ------------------------------------------------------------------

_frame_string(::Type{OtherRef{S}}) where {S} = String(S)
_frame_string(R::Type{<:RefFrame}) = _FRAME_STRING[R]

const _FRAME_STRING = Dict{DataType,String}(
    UTC => "UTC", TAI => "TAI", TT => "TT", TDB => "TDB", UT1 => "UT1",
    J2000 => "J2000", ICRS => "ICRS", B1950 => "B1950", APP => "APP",
    GALACTIC => "GALACTIC", ECLIPTIC => "ECLIPTIC", HADEC => "HADEC",
    AZEL => "AZEL", AZELGEO => "AZELGEO", ITRF => "ITRF", WGS84 => "WGS84",
    TOPO => "TOPO", REST => "REST", LSRK => "LSRK", LSRD => "LSRD",
    BARY => "BARY", GEO => "GEO", GALACTO => "GALACTO")

_kwpush_mi!(r::Record, name, t::CasaType, v) =
    (push!(r.names, name); push!(r.types, t); push!(r.values, v); push!(r.comments, ""))

"""
    _measinfo_record(kind; ref, varrefcol, tabtypes, tabcodes) -> Record

Build a `MEASINFO` sub-record for the write path.  Give either `ref`
(a fixed frame name / `RefFrame` type) or `varrefcol` + `tabtypes` +
`tabcodes`.
"""
function _measinfo_record(kind::Symbol;
                          ref=nothing, varrefcol=nothing,
                          tabtypes::AbstractVector=String[],
                          tabcodes::AbstractVector=Int[])
    r = Record()
    _kwpush_mi!(r, "type", TpString, String(kind))
    if varrefcol !== nothing
        _kwpush_mi!(r, "VarRefCol", TpString, String(varrefcol))
        if !isempty(tabtypes)
            _kwpush_mi!(r, "TabRefTypes", TpArrayString, collect(String, tabtypes))
            _kwpush_mi!(r, "TabRefCodes", TpArrayUInt, UInt32.(collect(tabcodes)))
        end
    elseif ref !== nothing
        s = ref isa AbstractString ? String(ref) :
            ref isa DataType ? _frame_string(ref) : String(ref)
        _kwpush_mi!(r, "Ref", TpString, s)
    else
        throw(ArgumentError("_measinfo_record: give `ref` or `varrefcol`"))
    end
    return r
end
