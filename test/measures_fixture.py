#!/usr/bin/env python3
"""Dump casatools.measures() reference-frame conversions as a Julia data
file, the ground-truth oracle for test/measures_tests.jl.

Run with the CASA-bundled python3 (has casatools).  Not part of the normal
Julia test run -- measures_tests.jl shells out to this only when a CASA
python3 is found (see `_CASA_PYTHON` / `_HAVE_CASA` there).

Usage:  python3 measures_fixture.py <out.jl>

Emits a Julia file that evaluates to a NamedTuple.  Conversion inputs are
fixed here and echoed out so the Julia side converts the identical numbers.

NB: needs `~/.casa/config.py` with `measures_auto_update = False` and
`data_auto_update = False`, else `me.measure()` blocks trying to reach
ASTRON for a measures-data update.  This script writes that config if it
is absent.
"""
import os
import sys

_cfg = os.path.expanduser("~/.casa/config.py")
if not os.path.exists(_cfg):
    os.makedirs(os.path.dirname(_cfg), exist_ok=True)
    with open(_cfg, "w") as _fh:
        _fh.write("measures_auto_update = False\ndata_auto_update = False\n")

import casatools

me = casatools.measures()
qa = casatools.quanta()

EPOCHS_MJD = [60454.42255, 58849.0, 55555.25]
SRC_RA, SRC_DEC = 2.0, 0.5
OBS_XYZ = [2225061.164, -5440057.370, -2481681.150]
FREQ_HZ = 100.0e9
RV_MPS = 20000.0
DOP_RADIO = 0.01
REST_HZ = 1.42040575e9
OBS_FREQ_HZ = 1.4e9

L = []
L.append("(")
L.append(f"  epochs_mjd = {tuple(EPOCHS_MJD)},")
L.append(f"  src_ra = {SRC_RA!r}, src_dec = {SRC_DEC!r},")
L.append(f"  obs_xyz = {tuple(OBS_XYZ)},")
L.append(f"  freq_hz = {FREQ_HZ!r},")
L.append(f"  rv_mps = {RV_MPS!r},")
L.append(f"  dop_radio = {DOP_RADIO!r}, rest_hz = {REST_HZ!r}, obs_freq_hz = {OBS_FREQ_HZ!r},")

# epoch: UTC -> {TAI, TT, TDB, UT1}
erows = []
for e_mjd in EPOCHS_MJD:
    e = me.epoch("UTC", qa.quantity(e_mjd, "d"))
    me.doframe(e)
    parts = ", ".join(f"{s} = {me.measure(e, s)['m0']['value']!r}"
                      for s in ("TAI", "TT", "TDB", "UT1"))
    erows.append(f"({parts})")
L.append(f"  epoch = ({', '.join(erows)},),")

# direction: J2000 -> {...}
e0 = me.epoch("UTC", qa.quantity(EPOCHS_MJD[0], "d"))
pos = me.position("ITRF",
                  qa.quantity(OBS_XYZ[0], "m"),
                  qa.quantity(OBS_XYZ[1], "m"),
                  qa.quantity(OBS_XYZ[2], "m"))
d = me.direction("J2000", qa.quantity(SRC_RA, "rad"), qa.quantity(SRC_DEC, "rad"))
me.doframe(e0)
me.doframe(pos)
dparts = []
for frame in ("B1950", "GALACTIC", "APP", "AZEL", "AZELGEO", "HADEC"):
    m = me.measure(d, frame)
    dparts.append(f"{frame} = ({m['m0']['value']!r}, {m['m1']['value']!r})")
L.append(f"  direction = ({', '.join(dparts)}),")

# solar-system body directions: <BODY> -> {J2000, AZEL}
pparts = []
for body in ("SUN", "MOON", "MERCURY", "VENUS", "MARS", "JUPITER"):
    b = me.direction(body)
    me.doframe(e0)
    me.doframe(pos)
    j = me.measure(b, "J2000")
    a = me.measure(b, "AZEL")
    pparts.append(f"{body} = (j2000 = ({j['m0']['value']!r}, {j['m1']['value']!r}), "
                  f"azel = ({a['m0']['value']!r}, {a['m1']['value']!r}))")
L.append(f"  planet = ({', '.join(pparts)}),")

# frequency: TOPO -> {...}
f = me.frequency("TOPO", qa.quantity(FREQ_HZ, "Hz"))
me.doframe(e0)
me.doframe(pos)
me.doframe(d)
fparts = [f"{fr} = {me.measure(f, fr)['m0']['value']!r}"
          for fr in ("GEO", "BARY", "LSRK", "LSRD", "GALACTO")]
L.append(f"  frequency = ({', '.join(fparts)}),")

# radial velocity: LSRK -> {...}
rv = me.radialvelocity("LSRK", qa.quantity(RV_MPS, "m/s"))
me.doframe(e0)
me.doframe(pos)
me.doframe(d)
rvparts = [f"{fr} = {me.measure(rv, fr)['m0']['value']!r}"
           for fr in ("BARY", "LSRD", "GEO", "TOPO", "GALACTO")]
L.append(f"  radialvelocity = ({', '.join(rvparts)}),")

# doppler: RADIO -> {OPTICAL, RATIO, TRUE, GAMMA}, and the bridges.
# NB casatools reports every doppler `m0` as <raw value> * c in "m/s"
# (MVDoppler::get), so divide by c to recover the dimensionless value.
# `_C` is the exact SI speed of light -- matches `MeasurementSets.C_LIGHT`
# and casacore's `casa::C::c` (this is a separate process; the value
# cannot be imported).
_C = 2.99792458e8
dop = me.doppler("RADIO", qa.quantity(DOP_RADIO, ""))
dparts = [f"{c} = {me.measure(dop, c)['m0']['value'] / _C!r}"
          for c in ("OPTICAL", "RATIO", "TRUE", "GAMMA")]
L.append(f"  doppler = ({', '.join(dparts)}),")

obsf = me.frequency("LSRK", qa.quantity(OBS_FREQ_HZ, "Hz"))
d_from_f = me.todoppler("TRUE", obsf, qa.quantity(REST_HZ, "Hz"))
L.append(f"  dop_from_freq = {d_from_f['m0']['value'] / _C!r},")
L.append(f"  rv_from_dop = {me.toradialvelocity('LSRK', d_from_f)['m0']['value']!r},")
L.append(f"  freq_from_dop = {me.tofrequency('LSRK', d_from_f, qa.quantity(REST_HZ, 'Hz'))['m0']['value']!r},")
L.append(f"  rest_from_freq = {me.torestfrequency(obsf, d_from_f)['m0']['value']!r},")
# earth magnetic field: IGRF model -> {ITRF, J2000}.  casacore ships
# IGRF-12; MeasurementSets bundles IGRF-14 -> a ~100-150 nT (model
# generation) difference is expected, so the Julia test uses a loose
# tolerance and mainly checks the frame rotation + magnitude.
me.doframe(e0)
me.doframe(pos)
bfield = me.earthmagnetic("IGRF")
emparts = []
for fr in ("ITRF", "J2000"):
    mm = me.measure(bfield, fr)
    emparts.append(f"{fr} = ({mm['m0']['value']!r}, {mm['m1']['value']!r}, {mm['m2']['value']!r})")
L.append(f"  earthmagnetic = ({', '.join(emparts)}),")

# EarthMagneticMachine: independent re-derivation of the line-of-sight
# field geometry using casacore's `me` + numpy, at EMM_HEIGHT above the
# observer toward (SRC_RA, SRC_DEC).  casacore ships IGRF-12 (~150 nT
# model-generation difference from the bundled IGRF-14), so the Julia
# test compares the geometry tightly and the field loosely.
import math
EMM_HEIGHT = 350.0e3
me.doframe(e0)
me.doframe(pos)
dd = me.measure(me.direction("j2000", qa.quantity(SRC_RA, "rad"),
                             qa.quantity(SRC_DEC, "rad")), "itrf")
dlon, dlat = dd["m0"]["value"], dd["m1"]["value"]
ux = math.cos(dlat) * math.cos(dlon)
uy = math.cos(dlat) * math.sin(dlon)
uz = math.sin(dlat)
px, py, pz = OBS_XYZ
posl = math.sqrt(px * px + py * py + pz * pz)
subl = EMM_HEIGHT * (EMM_HEIGHT + 2 * posl)
an = px * ux + py * uy + pz * uz
xr = math.sqrt(an * an + subl)
xr = min(abs(-an + xr), abs(-an - xr))
sx, sy, sz = px + xr * ux, py + xr * uy, pz + xr * uz
bfield_sub = me.earthmagnetic("IGRF")
me.doframe(me.position("itrf", qa.quantity(sx, "m"), qa.quantity(sy, "m"),
                       qa.quantity(sz, "m")))
bm = me.measure(bfield_sub, "itrf")
bx, by, bz = bm["m0"]["value"], bm["m1"]["value"], bm["m2"]["value"]
L.append(f"  emm = (height = {EMM_HEIGHT!r}, "
         f"dir_itrf = ({dlon!r}, {dlat!r}), "
         f"subpoint = ({sx!r}, {sy!r}, {sz!r}), "
         f"field = ({bx!r}, {by!r}, {bz!r}), "
         f"losfield = {bx * ux + by * uy + bz * uz!r}),")

L.append(")")

with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(L) + "\n")
print("wrote", sys.argv[1])
