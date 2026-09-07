# Write side (Phase 70): a `write_table` column whose Julia eltype is a
# `Measure` (`MEpoch{UTC}`, `MDirection{J2000}`, ...) is flattened to
# plain numbers on disk in the canonical unit, and gets a `MEASINFO`
# (+ `QuantumUnits`) keyword stamped -- the inverse of `measure()` /
# `_wrap_measure` in `read.jl`.  Needs no extension (the `M*` structs
# have plain `Float64` fields).

# a column of measure values -> (; data = plain numbers / vectors,
# kind::Symbol, ref::String, units::Vector{String}) or `nothing` if the
# eltype is not a `Measure` (or the column is empty -- can't infer the
# frame; use `measures=` explicitly).  The stored frame is the FIRST
# row's frame; a real MS column has one fixed `Ref` (or a hand-built
# `VarRefCol`, which the auto path does not attempt).
_measure_column_spec(::AbstractVector) = nothing

function _measure_column_spec(vals::AbstractVector{<:MEpoch})
    isempty(vals) && return nothing
    (; data = Float64[m.mjd * SEC_PER_DAY for m in vals],
       kind = :epoch, ref = _frame_string(reftype(first(vals))), units = ["s"])
end
function _measure_column_spec(vals::AbstractVector{<:MDirection})
    isempty(vals) && return nothing
    (; data = [Float64[m.lon, m.lat] for m in vals],
       kind = :direction, ref = _frame_string(reftype(first(vals))),
       units = ["rad", "rad"])
end
function _measure_column_spec(vals::AbstractVector{<:MPosition})
    isempty(vals) && return nothing
    (; data = [Float64[m.x, m.y, m.z] for m in vals],
       kind = :position, ref = _frame_string(reftype(first(vals))),
       units = ["m", "m", "m"])
end
function _measure_column_spec(vals::AbstractVector{<:MFrequency})
    isempty(vals) && return nothing
    (; data = Float64[m.hz for m in vals],
       kind = :frequency, ref = _frame_string(reftype(first(vals))), units = ["Hz"])
end
function _measure_column_spec(vals::AbstractVector{<:MRadialVelocity})
    isempty(vals) && return nothing
    (; data = Float64[m.mps for m in vals],
       kind = :radialvelocity, ref = _frame_string(reftype(first(vals))), units = ["m/s"])
end
function _measure_column_spec(vals::AbstractVector{<:MDoppler})
    isempty(vals) && return nothing
    (; data = Float64[m.d for m in vals],
       kind = :doppler, ref = _frame_string(reftype(first(vals))), units = String[])
end
function _measure_column_spec(vals::AbstractVector{<:MBaseline})
    isempty(vals) && return nothing
    (; data = [Float64[m.x, m.y, m.z] for m in vals],
       kind = :baseline, ref = _frame_string(reftype(first(vals))),
       units = ["m", "m", "m"])
end
function _measure_column_spec(vals::AbstractVector{<:MuvW})
    isempty(vals) && return nothing
    (; data = [Float64[m.u, m.v, m.w] for m in vals],
       kind = :uvw, ref = _frame_string(reftype(first(vals))),
       units = ["m", "m", "m"])
end
function _measure_column_spec(vals::AbstractVector{<:MEarthMagnetic})
    isempty(vals) && return nothing
    (; data = [Float64[m.x, m.y, m.z] for m in vals],
       kind = :earthmagnetic, ref = _frame_string(reftype(first(vals))),
       units = ["nT", "nT", "nT"])
end
