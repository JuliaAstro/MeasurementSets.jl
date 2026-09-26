# Phase 271: a MeasurementSet we write is a valid MS to real casacore (CASA's `casatools.ms`).
#
# Found: `create_ms` columns carried no `QuantumUnits` / `MEASINFO`, so casacore's `MS` class
# refused the table ("table is not a valid MS"); and the short-form sync blob in `table.lock`
# (`nrcolumn = -1`) made any casacore that LOCKS the table (the `ms` tool's `getdata`, `tb.lock`)
# throw "another process changed the number of columns" -- `TableSyncData::read` leaves
# `nrcolumn` unset for that form.  The blob is now the full form (column count, table and
# per-data-manager change counters).

const _MV_CASA = get(ENV, "MEASUREMENTSETS_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")

@testset "sync blob: full form (Phase 271)" begin
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["A" => [1, 2, 3], "B" => [1.0, 2.0, 3.0]]; nrow=3)
    lk = MSv2.open_lock(d; create=false)
    s = MSv2.read_syncinfo(d)
    @test s.present && s.nrow == 3 && s.modifycounter >= 1
    bytes = read(joinpath(d, "table.lock"))[MSv2.LOCK_SIZEREQID+5:end]
    a = MSv2.AipsIO(bytes; endian=:big)
    @test MSv2.getstart(a, "sync") == 1
    @test MSv2.read_u32(a) == 3                       # nrow
    @test MSv2.read_i32(a) == 2                       # nrcolumn: the real column count
    mc = MSv2.read_u32(a)
    @test MSv2.read_u32(a) == mc                      # table change counter
    @test length(MSv2.read_block(a, UInt32)) == 1     # one data manager
    # an edit keeps the counts
    edit(d) do e; MSv2.addrows!(e, 2); end
    @test MSv2.read_syncinfo(d).nrow == 5
end

@testset "casacore's MS class opens our MeasurementSets (Phase 271)" begin
    if isfile(_MV_CASA)
        py(script, args...) = read(pipeline(`$_MV_CASA -c $script $args`; stderr=devnull), String)
        ops = """
import sys
from casatools import ms
m = ms(); m.open(sys.argv[1])
d = m.getdata(['data', 'flag', 'antenna1', 'time', 'uvw'], ifraxis=False)
md = m.metadata()
print(m.nrow(), md.nantennas(), md.nspw(), md.nchan(0), list(d['data'].shape), list(d['uvw'].shape))
m.close()
"""
        dir = joinpath(mktempdir(), "n.ms")
        create_ms(dir; nrow=20, nchan=4, ncorr=2, nant=4)
        @test strip(py(ops, dir)) == "20 4 1 4 [2, 4, 20] [3, 20]"
        # an MS copied out of the sample opens too, and stays usable after our edit
        if isdir(SAMPLE_MS)
            c = joinpath(mktempdir(), "c.ms")
            copyms(SAMPLE_MS, c; rows=1:300)
            @test startswith(py(ops, c), "300 ")
            edit(c) do e; MSv2.addrows!(e, 1); end
            @test startswith(py(ops, c), "301 ")
        end
        # a casacore-written MS has the same units / measure frames on every column we also write
        sim = """
import sys
from casatools import simulator, quanta, measures
sm = simulator(); qa = quanta(); me = measures()
sm.open(sys.argv[1])
sm.setconfig(telescopename='VLA', x=[-1601185.4,-1601085.4,-1601185.4], y=[-5041977.5,-5041977.5,-5041877.5], z=[3554875.9]*3, dishdiameter=[25.0]*3, mount=['alt-az']*3, antname=['A1','A2','A3'], coordsystem='global', referencelocation=me.observatory('VLA'))
sm.setspwindow(spwname='SPW0', freq='1.4GHz', deltafreq='1MHz', freqresolution='1MHz', nchannels=4, stokes='RR LL')
sm.setfield(sourcename='F0', sourcedirection=me.direction('J2000','0h0m0','0d0m0'))
sm.setlimits(); sm.setauto(0.0)
sm.settimes(integrationtime='10s', usehourangle=True, referencetime=me.epoch('utc','2020/01/01/00:00:00'))
sm.observe('F0','SPW0', starttime='0s', stoptime='30s')
sm.close()
"""
        kwdiff = """
import sys, os, numpy as np
from casatools import table
def norm(v):
    if isinstance(v, dict): return {k: norm(x) for k,x in sorted(v.items())}
    if isinstance(v, np.ndarray): return v.tolist()
    return v
def load(root):
    out = {}
    for t in ['ANTENNA', 'FEED', 'FIELD', 'FLAG_CMD', 'HISTORY', 'OBSERVATION', 'POINTING', 'SPECTRAL_WINDOW', 'STATE', '']:
        tb = table(); tb.open(os.path.join(root, t) if t else root)
        for c, v in tb.getdesc().items():
            if isinstance(v, dict) and 'valueType' in v:
                kw = norm(v.get('keywords', {}))
                out[(t or 'MAIN') + '.' + c] = {k: kw[k] for k in ('QuantumUnits', 'MEASINFO') if k in kw}
        tb.close()
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
n = 0
for k in sorted(set(a) & set(b)):
    n += 1
    if a[k] != b[k]: print('DIFF', k, a[k], b[k])
print('compared', n)
"""
        real = joinpath(mktempdir(), "real.ms")
        run(pipeline(`$_MV_CASA -c $sim $real`; stdout=devnull, stderr=devnull))
        out = py(kwdiff, real, dir)
        @test !occursin("DIFF", out)
        @test parse(Int, split(strip(out))[end]) > 60          # a real comparison, not an empty one
    else
        @info "casatools python not found; skipping the casacore MS cross-check" _MV_CASA
    end
end
