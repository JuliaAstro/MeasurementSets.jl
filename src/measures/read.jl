# Read a measure-valued column cell as a typed `Measure` (or a vector of
# them, for an array-valued measure column such as `SPECTRAL_WINDOW.CHAN_FREQ`).

"""
    measure(t, col, row; epoch=nothing) -> Measure | Vector{Measure}
    measure(t, col)                      -> Vector

Read column `col` of `t` as a physical measure, taking its reference
frame from the `MEASINFO` keyword (a fixed `Ref`, or a per-row
`VarRefCol` code).  An epoch column yields [`MEpoch`](@ref) (MJD days),
a direction column [`MDirection`](@ref) (radians), a position column
[`MPosition`](@ref) (metres), a frequency column [`MFrequency`](@ref)
(Hz) -- an array-valued frequency/direction cell yields a `Vector` of
them.

Passing `epoch` (an [`MEpoch`](@ref)) to a direction cell of a FIELD
subtable evaluates a moving target: if that field row is a comet /
planet ([`field_ephemeris`](@ref) finds one), the returned direction is
the ephemeris position at `epoch` (in the ephemeris table's own
`posrefsys` frame), shifted by the stored `PHASE_DIR` offset.
"""
function measure(t::AbstractTable, col::AbstractString, row::Integer;
                 epoch::Union{Nothing,MEpoch} = nothing)
    mi = measinfo(t, col)
    mi === nothing && throw(ArgumentError("column \"$col\" has no MEASINFO keyword"))
    if epoch !== nothing && mi.kind === :direction && t isa Table
        e = field_ephemeris(t, row - 1)
        if e !== nothing
            d = ephemeris_direction(e, epoch.mjd)      # UTC ~ TDB (coarse table)
            off = _lonlat(getcell(t, col, row))
            lo, la = _ephem_shift(d.lon, d.lat, off[1], off[2])
            return MDirection{e.frame}(lo, la)
        end
    end
    R = _frame_type(mi.kind, _ref_string(mi, t, col, row))
    _wrap_measure(mi.kind, R, getcell(t, col, row), mi)
end

# whole-column: parse MEASINFO once and bulk-read the value column (and,
# for a per-row `VarRefCol`, the code column) instead of going cell by
# cell / re-parsing the keyword per row.
function measure(t::AbstractTable, col::AbstractString)
    mi = measinfo(t, col)
    mi === nothing && throw(ArgumentError("column \"$col\" has no MEASINFO keyword"))
    vals = column(t, col)[:]
    if mi.fixedref !== nothing
        R = _frame_type(mi.kind, mi.fixedref)
        return [_wrap_measure(mi.kind, R, v, mi) for v in vals]
    end
    codes = column(t, mi.varrefcol)[:]
    return [_wrap_measure(mi.kind, _frame_type(mi.kind, _ref_from_code(mi, codes[i])),
                          vals[i], mi) for i in eachindex(vals)]
end

# seconds -> MJD days for an epoch value (casacore stores epoch as an
# MJD in the QuantumUnits, almost always "s").
_epoch_mjd(v::Real, units) =
    (isempty(units) || lowercase(strip(units[1])) in ("s", "sec", "second", "seconds")) ?
    float(v) / SEC_PER_DAY : float(v)

function _wrap_measure(kind::Symbol, R::Type, v, mi::MeasInfo)
    if kind === :epoch
        return MEpoch{R}(_epoch_mjd(_scalar(v), mi.units))

    elseif kind === :position
        return MPosition{R}(_vec3(v)...)

    elseif kind === :uvw
        return MuvW{R}(_vec3(v)...)

    elseif kind === :baseline
        return MBaseline{R}(_vec3(v)...)

    elseif kind === :direction
        lo, la = _lonlat(v)
        return MDirection{R}(lo, la)

    elseif kind === :frequency
        return v isa AbstractArray && length(v) != 1 ?
               [MFrequency{R}(float(x)) for x in vec(v)] :
               MFrequency{R}(float(_scalar(v)))

    elseif kind === :radialvelocity
        return v isa AbstractArray && length(v) != 1 ?
               [MRadialVelocity{R}(float(x)) for x in vec(v)] :
               MRadialVelocity{R}(float(_scalar(v)))

    elseif kind === :doppler
        R <: DopplerType || throw(ArgumentError(
            "measure: unknown Doppler convention in the MEASINFO of a :doppler column"))
        return v isa AbstractArray && length(v) != 1 ?
               [MDoppler{R}(float(x)) for x in vec(v)] :
               MDoppler{R}(float(_scalar(v)))
    end
    throw(ArgumentError("measure: unsupported MEASINFO type \"$kind\""))
end

_scalar(v::Real) = v
_scalar(v::AbstractArray) = length(v) == 1 ? first(v) : first(v)

_vec3(v::AbstractArray) = (Float64(v[1]), Float64(v[2]), Float64(v[3]))

# a direction cell is `[lon, lat]` (rad), possibly a `(2, npoly)` matrix
# (take the 0-order term), or a 3-vector unit direction.
function _lonlat(v::AbstractArray)
    if ndims(v) == 2
        return (Float64(v[1, 1]), Float64(v[2, 1]))
    elseif length(v) == 2
        return (Float64(v[1]), Float64(v[2]))
    elseif length(v) == 3
        r = hypot(Float64(v[1]), Float64(v[2]), Float64(v[3]))
        return (atan(Float64(v[2]), Float64(v[1])), asin(clamp(Float64(v[3]) / r, -1, 1)))
    end
    throw(ArgumentError("measure: cannot read a direction from a length-$(length(v)) cell"))
end
