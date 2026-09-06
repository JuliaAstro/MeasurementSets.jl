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

L = []
L.append("(")
L.append(f"  epochs_mjd = {tuple(EPOCHS_MJD)},")
L.append(f"  src_ra = {SRC_RA!r}, src_dec = {SRC_DEC!r},")
L.append(f"  obs_xyz = {tuple(OBS_XYZ)},")
L.append(f"  freq_hz = {FREQ_HZ!r},")

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

# frequency: TOPO -> {...}
f = me.frequency("TOPO", qa.quantity(FREQ_HZ, "Hz"))
me.doframe(e0)
me.doframe(pos)
me.doframe(d)
fparts = [f"{fr} = {me.measure(f, fr)['m0']['value']!r}"
          for fr in ("GEO", "BARY", "LSRK", "LSRD", "GALACTO")]
L.append(f"  frequency = ({', '.join(fparts)}),")
L.append(")")

with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(L) + "\n")
print("wrote", sys.argv[1])
