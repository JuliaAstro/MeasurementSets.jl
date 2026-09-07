# EarthMagneticMachine: the line-of-sight geomagnetic field toward a
# source direction, evaluated where the ray pierces a spherical shell a
# given height above the observer -- the input to ionospheric
# Faraday-rotation / rotation-measure corrections.
#
# Port of casacore `measures/Measures/EarthMagneticMachine.{h,cc}`.  The
# direction rotation into ITRF needs `import SOFA`, so `emm_lineofsight`
# has a stub here and the real method in `ext/SOFAExt.jl`.

"""
    emm_lineofsight(dir::MDirection, height, pos::MPosition, epoch::MEpoch)
        -> (; losfield, field, subpoint, sublon, sublat)

The geomagnetic field along the line of sight to `dir`, sampled where the
ray from `pos` crosses a sphere `height` metres above the observer's
geocentric radius (e.g. `height = 350e3` for the ionospheric F-layer):

  * `losfield`  — the field component parallel to the line of sight (nT);
                  multiply by the slant TEC and `2.63e-13` for the RM.
  * `field`     — the full field vector at the pierce point, `MEarthMagnetic{ITRF}`.
  * `subpoint`  — the pierce point, `MPosition{ITRF}`.
  * `sublon` / `sublat` — its geocentric longitude / latitude (rad).

`dir` may be in any direction frame; it is rotated to ITRF using
`epoch` + `pos`.  Needs `import SOFA`.
"""
function emm_lineofsight end

"""
    EarthMagneticMachine(height, pos::MPosition, epoch::MEpoch)

A reusable [`emm_lineofsight`](@ref) evaluator for one shell height,
observer and epoch — call it on a direction: `machine(dir)`.
"""
struct EarthMagneticMachine
    height::Float64
    pos::MPosition
    epoch::MEpoch
end

EarthMagneticMachine(height::Real, pos::MPosition, epoch::MEpoch) =
    EarthMagneticMachine(Float64(height), pos, epoch)

(m::EarthMagneticMachine)(dir::MDirection) =
    emm_lineofsight(dir, m.height, m.pos, m.epoch)

# --- ionospheric Faraday rotation --------------------------------------

"""
Ionospheric rotation-measure constant (SI collapsed to practical units):
`RM [rad/m²] = RM_IONOSPHERE · STEC[TECU] · B∥[nT]`, where
`RM_IONOSPHERE = e³/(8π²ε₀mₑ²c³) · 10¹⁶ · 10⁻⁹ ≈ 2.631e-6`.
"""
const RM_IONOSPHERE = 2.631e-6

"""
    rotation_measure(dir, epoch, pos; stec, height=350e3) -> Float64
    rotation_measure(m::EarthMagneticMachine, dir; stec)  -> Float64

The ionospheric rotation measure (rad/m²) toward `dir`, in the thin-shell
approximation: `RM_IONOSPHERE · stec · B∥`, with `B∥` the geomagnetic
field component **along the direction of propagation** (source → observer)
where the line of sight pierces a shell `height` m up
([`emm_lineofsight`](@ref)), and `stec` the slant total electron content
in TECU (10¹⁶ e⁻/m²).  Positive RM ⇔ the field points toward the
observer.  Needs `import SOFA`.
"""
rotation_measure(dir::MDirection, epoch::MEpoch, pos::MPosition;
                 stec::Real, height::Real = 350e3) =
    -RM_IONOSPHERE * stec * emm_lineofsight(dir, height, pos, epoch).losfield

rotation_measure(m::EarthMagneticMachine, dir::MDirection; stec::Real) =
    -RM_IONOSPHERE * stec * m(dir).losfield

"""
    faraday_rotation(rm, freq) -> Δχ   (rad)

The polarization-angle rotation `RM · λ²` at frequency `freq` (Hz — a
number or [`MFrequency`](@ref)).  `λ = c / freq`.
"""
faraday_rotation(rm::Real, freq::Real) = rm * (C_LIGHT / freq)^2
faraday_rotation(rm::Real, f::MFrequency) = faraday_rotation(rm, f.hz)

"""
    derotate_angle(χ, rm, freq) -> χ − RM·λ²

Remove the Faraday rotation from an observed polarization angle `χ` (rad).
"""
derotate_angle(χ::Real, rm::Real, freq) = χ - faraday_rotation(rm, freq)
