# The IGRF-14 geomagnetic field model.
#
# `earthfield(pos, epoch)` evaluates the field at an ITRF position and an
# epoch and returns an `MEarthMagnetic{ITRF}` (nano-tesla).  The
# spherical-harmonic synthesis in `_earthfield_itrf` is a direct port of
# casacore's `EarthField::calcField` (`measures/Measures/EarthField.cc`);
# the epoch interpolation matches `MeasTable::IGRF`.  The Gauss
# coefficients are bundled in `igrf14_data.jl` (IAGA / NOAA IGRF-14).
#
# Pure arithmetic -- no `SOFA`.  Converting the resulting measure to a
# celestial frame (`measconvert(bf, J2000; frame)`) does need `import
# SOFA` (like every other measure conversion).

# MJD -> decimal year.  Linear over a 5-year IGRF interval, so a few
# hours of error (UTC vs the TDB casacore uses) is far below the model.
_mjd_to_year(mjd::Real) = 1858.87885 + mjd / 365.25

"""
    _igrf_gh(mjd) -> Vector{Float64}

The 195 Schmidt semi-normalised Gauss coefficients (nT) for the epoch
`mjd`, linearly interpolated between the bundled IGRF-14 5-year models
(extrapolated with the 2025-2030 secular variation past 2025).
"""
function _igrf_gh(mjd::Real)
    y = _mjd_to_year(mjd)
    t = (y - _IGRF_YEAR0) / _IGRF_DYEAR
    i = clamp(floor(Int, t), 0, length(_IGRF_COEF) - 1)
    dy = y - (_IGRF_YEAR0 + i * _IGRF_DYEAR)
    _IGRF_COEF[i + 1] .+ _IGRF_DCOEF[i + 1] .* dy
end

const _PQ_LEN = 104

"""
    _earthfield_itrf(gh, r, lon, lat) -> (bx, by, bz)

IGRF field (nT) in ITRF Cartesian coordinates at geocentric radius `r`
(m), east longitude `lon` and latitude `lat` (rad).  Port of casacore
`EarthField::calcField` (the `lp == 0` pass; the derivative passes are a
position-cache optimisation this package does not need).
"""
function _earthfield_itrf(gh::AbstractVector{<:Real}, r::Real, lon::Real, lat::Real)
    p = zeros(Float64, _PQ_LEN)
    q = zeros(Float64, _PQ_LEN)
    cl = zeros(Float64, 2 * _PQ_LEN)
    sl = zeros(Float64, 2 * _PQ_LEN)

    colat = pi / 2 - lat
    slat = cos(colat)          # = sin(lat)   (casacore's names)
    clat = sin(colat)          # = cos(lat)
    slong = sin(lon)
    clong = cos(lon)
    cl[1] = clong
    sl[1] = slong
    ratio = 6_371_200.0 / r

    p[1] = 2.0 * slat
    p[2] = 2.0 * clat
    p[3] = 4.5 * slat * slat - 1.5
    p[4] = 5.1961524 * clat * slat
    q[1] = -clat
    q[2] = slat
    q[3] = -3.0 * clat * slat
    q[4] = 1.7320508 * (slat * slat - clat * clat)

    x = 0.0; y = 0.0; z = 0.0
    l = 0; m = 0; n = 0
    fn = 0; rr = 0.0

    for k in 0:(_PQ_LEN - 1)
        if n - m - 1 < 0
            m = -1
            n += 1
            rr = ratio^(n + 2)
            fn = n
        end
        fm = m + 1
        if k - 4 >= 0
            if m + 1 - n == 0
                one = sqrt(1.0 - 0.5 / fm)
                j = k - n - 1
                p[k + 1] = (1.0 + 1.0 / fm) * one * clat * p[j + 1]
                q[k + 1] = one * (clat * q[j + 1] + slat / fm * p[j + 1])
                sl[m + 1] = sl[m] * cl[1] + cl[m] * sl[1]
                cl[m + 1] = cl[m] * cl[1] - sl[m] * sl[1]
            else
                one = sqrt(Float64(fn * fn - fm * fm))
                two = sqrt((fn - 1.0) * (fn - 1.0) - fm * fm) / one
                three = (2.0 * fn - 1.0) / one
                ii = k - n
                j = k - 2 * n + 1
                p[k + 1] = (fn + 1.0) * (three * slat / fn * p[ii + 1] -
                                        two / (fn - 1.0) * p[j + 1])
                q[k + 1] = three * (slat * q[ii + 1] - clat / fn * p[ii + 1]) -
                           two * q[j + 1]
            end
        end

        one = gh[l + 1] * rr
        if m == -1
            x += one * q[k + 1]
            z -= one * p[k + 1]
            l += 1
        else
            two = gh[l + 2] * rr
            three = one * cl[m + 1] + two * sl[m + 1]
            x += three * q[k + 1]
            z -= three * p[k + 1]
            if clat > 0
                y += (one * sl[m + 1] - two * cl[m + 1]) * fm * p[k + 1] /
                     ((fn + 1.0) * clat)
            else
                y += (one * sl[m + 1] - two * cl[m + 1]) * q[k + 1] * slat
            end
            l += 2
        end
        m += 1
    end

    bx = x * slat * clong + z * clat * clong + y * slong
    by = -x * slat * slong + z * clat * slong - y * clong
    bz = -x * clat + z * slat
    return (bx, by, bz)
end

"""
    earthfield(pos::MPosition, epoch::MEpoch) -> MEarthMagnetic{ITRF}

The IGRF-14 geomagnetic field vector (nano-tesla, ITRF Cartesian) at
`pos` and `epoch`.  Model accuracy is ~arcminute-of-arc in direction /
~150 nT; the epoch is used as given (the ~1 minute UTC/TDB difference is
negligible for the 5-year-interpolated model).
"""
function earthfield(pos::MPosition, epoch::MEpoch)
    r = hypot(pos.x, pos.y, pos.z)
    lon = atan(pos.y, pos.x)
    lat = asin(clamp(pos.z / r, -1.0, 1.0))
    MEarthMagnetic{ITRF}(_earthfield_itrf(_igrf_gh(epoch.mjd), r, lon, lat)...)
end
