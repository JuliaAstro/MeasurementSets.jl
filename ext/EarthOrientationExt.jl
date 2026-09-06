# IERS Earth-orientation parameters for the measure conversions.
# Loaded when the caller has BOTH `SOFA` and `EarthOrientation` imported;
# `SOFAExt._eop` calls `_eop_lookup` here instead of its
# ΔUT1 = 0 / no-polar-motion fallback.

module EarthOrientationExt

import EarthOrientation as EO
import MeasurementSets as MS
using Dates: DateTime, Millisecond

const _MJD_EPOCH = DateTime(1858, 11, 17)
const _ARCSEC = deg2rad(1 / 3600)
const _READY = Ref(false)
const _WARNED = Ref(false)

_datetime(mjd::Float64) = _MJD_EPOCH + Millisecond(round(Int, mjd * 86_400_000))

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
        return (dut1=Float64(dut1), xp=Float64(xp) * _ARCSEC, yp=Float64(yp) * _ARCSEC)
    catch err
        if !_WARNED[]
            @warn "MeasurementSets: IERS EOP lookup failed ($err); ΔUT1 = 0, no polar motion"
            _WARNED[] = true
        end
        return (dut1=0.0, xp=0.0, yp=0.0)
    end
end

end # module
