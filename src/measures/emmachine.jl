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
