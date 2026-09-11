# Measures (reference frames)

```@meta
CurrentModule = MeasurementSets
```

`import SOFA` (and optionally `EarthOrientation`) activates
[`measconvert`](@ref); see [Concepts](concepts.md#Reference-frames-(measures)).
Split off from the main [API reference](api.md) page since this
category alone (measure types, `measconvert`, and ~50 reference-frame
singleton types) is large enough to push the combined API page past
Documenter's HTML size limit.

```@docs
measinfo
MeasInfo
measure
measconvert
observatory
MeasFrame
MEpoch
MDirection
MPosition
MFrequency
MRadialVelocity
MDoppler
MBaseline
MuvW
MEarthMagnetic
earthfield
EarthMagneticMachine
emm_lineofsight
rotation_measure
faraday_rotation
derotate_angle
RM_IONOSPHERE
Ephemeris
open_ephemeris
field_ephemeris
ephemeris_direction
ephemeris_radvel
ephemeris_distance
ephemeris_diskpos
doppler
frequency
radialvelocity
restfrequency
shiftfreq
reftype
RefFrame
DopplerType
```

```@docs
UTC
TAI
TT
TDB
UT1
J2000
ICRS
B1950
APP
GALACTIC
ECLIPTIC
HADEC
AZEL
AZELGEO
ITRF
WGS84
TOPO
REST
LSRK
LSRD
BARY
GEO
GALACTO
LGROUP
CMB
MERCURY
VENUS
MARS
JUPITER
SATURN
URANUS
NEPTUNE
SUN
MOON
IGRF
RADIO
OPTICAL
RATIO
BETA
GAMMA
Z
RELATIVISTIC
```
