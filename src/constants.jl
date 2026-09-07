# Shared physical / astronomical / calendar constants.
#
# One definition each -- core files and the SOFA / EarthOrientation
# extensions all reference these (`MeasurementSets.C_LIGHT`, …) instead
# of repeating a literal.  Every value is an exact SI / IAU definition;
# each matches `SOFA.jl`'s own constant (verified) and casacore's
# `casa/BasicSL/Constants.h`.

import Dates

"Speed of light in vacuum, m/s (exact SI; equals `SOFA.LIGHTSPEED`)."
const C_LIGHT = 2.99792458e8

"Astronomical unit, m (IAU 2012 definition; equals `SOFA.ASTRUNIT`)."
const AU_METRES = 149_597_870_700.0

"Seconds per day (equals `SOFA.SECPERDAY`)."
const SEC_PER_DAY = 86_400.0

"Milliseconds per day."
const MSEC_PER_DAY = 86_400_000

"`JD = MJD + MJD_JD_OFFSET` (equals `SOFA.MJD0`)."
const MJD_JD_OFFSET = 2_400_000.5

"MJD 0 as a calendar `DateTime` — 1858-11-17T00:00:00."
const MJD_EPOCH = Dates.DateTime(1858, 11, 17)

"One arcsecond in radians."
const ARCSEC = deg2rad(1 / 3600)

# casacore `MeasTable` solar- / LSR-motion velocity vectors (J2000, m/s),
# index 0 -- MeasTable.cc:3616-3690.  Used by the SOFA extension's
# frequency / radial-velocity frame conversions.
"LSRK (kinematic Local Standard of Rest) velocity, J2000, m/s."
const VEL_LSRK = 20_000.0 .* (0.0145021, -0.865863, 0.500071)
"LSRD (dynamical Local Standard of Rest) velocity, J2000, m/s."
const VEL_LSRD = sqrt(274.0) * 1e3 .* (-0.0385568, -0.881138, 0.471285)
"Galactic-rotation velocity toward the LSRD frame, J2000, m/s."
const VEL_LSRGAL = 220_000.0 .* (0.494109, -0.44483, 0.746982)
"Local Group barycentre velocity wrt BARY, J2000, m/s (casacore `MeasTable::calcVelocityLGROUP`, 308 km/s)."
const VEL_LGROUP = 308_000.0 .* (0.593553979227, -0.177954636914, 0.784873124106)
"CMB rest-frame velocity wrt BARY, J2000, m/s (casacore `MeasTable::calcVelocityCMB`, F. Ghigo, 369.5 km/s)."
const VEL_CMB = 369_500.0 .* (-0.97176985257, 0.202393953108, -0.121243727187)
