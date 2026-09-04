#!/usr/bin/env python3
"""Write a small real DyscoStMan-compressed table via casatools, plus raw
little-endian binary dumps of the same casatools process's own getcol()
decode -- used by test/dysco_tests.jl as a byte-level interop oracle.

Run with the CASA-bundled python3 (has casatools with Dysco compiled into
libcasa_tables).  Not part of the normal Julia test run -- test/dysco_tests.jl
shells out to this script only when a CASA python3 is found on the machine
(see `_CASA_PYTHON` / `_HAVE_CASA` there); this file is otherwise inert.

Usage:
    python3 dysco_fixture.py <outdir> <nant> <ntime> <nchan> <npol> \
                              <dataBitCount> <weightBitCount> <seed>

Writes into <outdir>:
    dysco.tab/            the DyscoStMan-backed casacore table
    data_decoded.bin       complex64, C-order (npol, nchan, nrow)
    weight_decoded.bin     float32,   C-order (npol, nchan, nrow)
    antenna1.bin, antenna2.bin   int32, length nrow
    meta.txt                nant nbl ntime nrow nchan npol (space-separated)

Rows are laid out the way a real MS is: all baselines of one integration
(including autocorrelations, ant1<=ant2) written consecutively before the
next timestamp -- DyscoStMan determines rowsPerBlock/antennaCount from the
*first* such group when a table is freshly created (ThreadedDyscoColumn::
putValues), and a naive one-row-per-timestamp layout undersizes its
internal antenna-indexed buffers and crashes on a later, larger antenna
index (discovered the hard way during Phase-18 development).
"""
import os
import shutil
import sys

import numpy as np


def main():
    outdir, nant, ntime, nchan, npol, dbits, wbits, seed = sys.argv[1:9]
    nant, ntime, nchan, npol = int(nant), int(ntime), int(nchan), int(npol)
    dbits, wbits, seed = int(dbits), int(wbits), int(seed)

    tabname = os.path.join(outdir, "dysco.tab")
    if os.path.exists(tabname):
        shutil.rmtree(tabname)

    import casatools
    tb = casatools.table()

    baselines = [(a1, a2) for a1 in range(nant) for a2 in range(a1, nant)]
    nbl = len(baselines)
    nrow = nbl * ntime

    desc = {
        "TIME": {"valueType": "double", "dataManagerType": "IncrementalStMan",
                 "dataManagerGroup": "ISMT", "option": 0, "maxlen": 0,
                 "comment": "", "keywords": {}},
        "ANTENNA1": {"valueType": "int", "dataManagerType": "IncrementalStMan",
                     "dataManagerGroup": "ISMA1", "option": 0, "maxlen": 0,
                     "comment": "", "keywords": {}},
        "ANTENNA2": {"valueType": "int", "dataManagerType": "IncrementalStMan",
                     "dataManagerGroup": "ISMA2", "option": 0, "maxlen": 0,
                     "comment": "", "keywords": {}},
        "FIELD_ID": {"valueType": "int", "dataManagerType": "IncrementalStMan",
                     "dataManagerGroup": "ISMF", "option": 0, "maxlen": 0,
                     "comment": "", "keywords": {}},
        "DATA_DESC_ID": {"valueType": "int", "dataManagerType": "IncrementalStMan",
                         "dataManagerGroup": "ISMD", "option": 0, "maxlen": 0,
                         "comment": "", "keywords": {}},
        "DATA": {"valueType": "complex", "dataManagerType": "DyscoStMan",
                 "dataManagerGroup": "dysco", "option": 5, "maxlen": 0,
                 "comment": "", "keywords": {}, "ndim": 2, "shape": [npol, nchan]},
        "WEIGHT_SPECTRUM": {"valueType": "float", "dataManagerType": "DyscoStMan",
                            "dataManagerGroup": "dysco", "option": 5, "maxlen": 0,
                            "comment": "", "keywords": {}, "ndim": 2, "shape": [npol, nchan]},
    }
    dminfo = {
        "*1": {"TYPE": "DyscoStMan", "NAME": "dysco",
               "SPEC": {"dataBitCount": dbits, "weightBitCount": wbits,
                        "distribution": "TruncatedGaussian", "normalization": "AF",
                        "studentTNu": 0.0, "distributionTruncation": 2.5},
               "COLUMNS": ["DATA", "WEIGHT_SPECTRUM"]}
    }

    # nrow must be given at create time -- creating with 0 rows then
    # addrows()-ing after leaves the private Dysco file empty (0 bytes)
    # and a later re-open throws "is the file corrupted?".
    tb.create(tabname, desc, dminfo=dminfo, nrow=nrow)

    rng = np.random.default_rng(seed)
    a1 = np.zeros(nrow, dtype=np.int32)
    a2 = np.zeros(nrow, dtype=np.int32)
    t = np.zeros(nrow, dtype=np.float64)
    row = 0
    for it in range(ntime):
        time_val = 5e9 + it * 10.0
        for (b1, b2) in baselines:
            a1[row] = b1
            a2[row] = b2
            t[row] = time_val
            row += 1
    fid = np.zeros(nrow, dtype=np.int32)
    ddid = np.zeros(nrow, dtype=np.int32)

    tb.putcol("TIME", t)
    tb.putcol("ANTENNA1", a1)
    tb.putcol("ANTENNA2", a2)
    tb.putcol("FIELD_ID", fid)
    tb.putcol("DATA_DESC_ID", ddid)

    data = (rng.standard_normal((npol, nchan, nrow)) +
            1j * rng.standard_normal((npol, nchan, nrow))).astype(np.complex64) * 3
    weight = (rng.random((npol, nchan, nrow)).astype(np.float32) * 10)
    tb.putcol("DATA", data)
    tb.putcol("WEIGHT_SPECTRUM", weight)
    tb.flush()
    tb.close()

    tb.open(tabname)
    data_decoded = tb.getcol("DATA")
    weight_decoded = tb.getcol("WEIGHT_SPECTRUM")
    tb.close()

    data_decoded.astype(np.complex64).tofile(os.path.join(outdir, "data_decoded.bin"))
    weight_decoded.astype(np.float32).tofile(os.path.join(outdir, "weight_decoded.bin"))
    a1.astype(np.int32).tofile(os.path.join(outdir, "antenna1.bin"))
    a2.astype(np.int32).tofile(os.path.join(outdir, "antenna2.bin"))
    with open(os.path.join(outdir, "meta.txt"), "w") as f:
        f.write(f"{nant} {nbl} {ntime} {nrow} {nchan} {npol}\n")

    print("DYSCO_FIXTURE_OK")


if __name__ == "__main__":
    main()
