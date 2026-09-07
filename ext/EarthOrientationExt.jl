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
one warning) if the table has no coverage for the date.
"""
function _eop_lookup(mjd_utc::Float64)
    _ensure!()
    dt = _datetime(mjd_utc)
    try
        dut1 = EO.getΔUT1(dt; outside_range=:nothing)
        xp = EO.getxp(dt; outside_range=:nothing)
        yp = EO.getyp(dt; outside_range=:nothing)
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
