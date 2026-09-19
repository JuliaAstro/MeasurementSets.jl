# IERS Earth-orientation parameters for the measure conversions.
# Loaded when the caller has BOTH `SOFA` and `EarthOrientation` imported;
# `SOFAExt._eop` calls `_eop_lookup` here instead of its
# ΔUT1 = 0 / no-polar-motion fallback.

module EarthOrientationExt

import EarthOrientation as EO
import MeasurementSets as MS
using Dates: Millisecond

const _READY = Ref(false)
const _WARNED = Ref(false)

# `MJD_EPOCH` / `ARCSEC` / `MSEC_PER_DAY` are shared -- see src/constants.jl
_datetime(mjd::Float64) = MS.MJD_EPOCH + Millisecond(round(Int, mjd * MS.MSEC_PER_DAY))

function _ensure!()
    _READY[] && return
    try
        EO.update()                      # download / refresh the IERS table
    catch
        # bundled data (loaded by EO.__init__) is usually enough
    end
    _READY[] = true
end

"""
    _eop_lookup(mjd_utc) -> (dut1, xp, yp)

ΔUT1 (seconds) and polar motion (radians) at a UTC MJD, from the IERS
`finals2000A` table via `EarthOrientation.jl`.  Falls back to zeros (with
one warning) if the table has no coverage for the date -- including a
non-finite `mjd_utc` (a NaN/±Inf epoch, e.g. from a malformed `TIME`
cell): `_datetime` used to be called OUTSIDE the `try` below, so a raw
`round(Int, NaN*...)`-derived crash (Phase 192/193/194's same finding,
a fourth corner) escaped the existing "no coverage" fallback entirely
instead of hitting it. Moved inside the `try` so it does.

Phase 220 fix: `EarthOrientation.jl`'s own `outside_range=:nothing`
keyword does NOT mean "return nothing" (which this docstring's "falls
back to zeros" claim implicitly assumed) -- reading
`EarthOrientation.jl`'s `interpolate` directly shows `:nothing` means
"skip the warn/error, just continue" -- i.e. silently return an
Akima-spline *extrapolation* past the table's covered range, with no
indication at all. Live-reproduced: a date past the table's current
forward bound (`~2027-09-25` for the finals2000A table bundled/fetched
at investigation time, and creeping forward every day) returned a real,
never-warned, silently-extrapolated `xp`/`yp`/`dut1` instead of ever
reaching the `catch` block below -- so the documented zero+warning
fallback had never actually fired for a genuinely out-of-coverage date,
only for the non-finite-input case above. `outside_range=:error` is the
value that actually makes `EarthOrientation.jl` raise
`EarthOrientation.OutOfRangeError` when a date has no coverage (verified
directly against its source, `interpolate`'s `if outside_range ==
:error` branch) -- switching to it makes this function's own documented
behaviour true, with zero effect on any in-range date (confirmed
unaffected numerically).
"""
function _eop_lookup(mjd_utc::Float64)
    _ensure!()
    try
        dt = _datetime(mjd_utc)
        dut1 = EO.getΔUT1(dt; outside_range=:error)
        xp = EO.getxp(dt; outside_range=:error)
        yp = EO.getyp(dt; outside_range=:error)
        return (dut1=Float64(dut1), xp=Float64(xp) * MS.ARCSEC, yp=Float64(yp) * MS.ARCSEC)
    catch err
        if !_WARNED[]
            @warn "MeasurementSets: IERS EOP lookup failed ($err); ΔUT1 = 0, no polar motion"
            _WARNED[] = true
        end
        return (dut1=0.0, xp=0.0, yp=0.0)
    end
end

end # module
