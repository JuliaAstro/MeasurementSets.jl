# Shared casacore / real-TaQL cross-check helpers (Phase 32 consolidation).
#
# `_HAVE_TAQL` gates every real-TaQL cross-check testset (needs Casacore.jl
# *and* CxxWrap).  `_taqlcmd` runs one `tableCommand` with zero or more
# parent tables bound to $1, $2, …; `_taql_create` is the no-parent form
# (CREATE TABLE …).  Previously each of tsm_multicol / reftable / query /
# write_command / lock / container tests carried its own copy of the
# StdVector / ConstCxxPtr / GC.@preserve boilerplate.

# Phase 446: the seeded random-fuzz loops against real TaQL are the bulk of the suite (about 20 of its 41 minutes).
# `MS_TEST_FUZZ_SCALE` (0.05 .. 1, default 1) scales their iteration counts; CI runs the full counts on one Julia
# version and a fraction on the others, where the same seeds have already passed.
const _FUZZ_SCALE = clamp(something(tryparse(Float64, get(ENV, "MS_TEST_FUZZ_SCALE", "1")), 1.0), 0.05, 1.0)
_fz(n::Integer) = max(1, round(Int, n * _FUZZ_SCALE))

# Phase 466: whether real IERS Earth-orientation data can be had (EarthOrientation downloads `finals2000A` on first
# use).  datacenter.iers.org rejected every request on 2026-10-25 (HTTP 400, from a laptop and a container alike), which
# made three tests that compare against values computed with real dUT1 / polar motion fail for a reason outside the
# package.  Those assertions run only when a 2024 date returns real values.
const _HAVE_EOP = try
    @eval import SOFA, EarthOrientation
    ext = Base.get_extension(MSv2, :EarthOrientationExt)
    r = ext._eop_lookup(60454.0)
    !(r.dut1 == 0.0 && r.xp == 0.0 && r.yp == 0.0)
catch
    false
end
_HAVE_EOP || @info "No IERS Earth-orientation data; skipping the assertions that need real dUT1 / polar motion"

const _HAVE_TAQL = _HAVE_CASACORE && try
    @eval import CxxWrap
    true
catch
    false
end

if _HAVE_TAQL
    _tc_astable(x::AbstractString) = CCT.Table(x)
    _tc_astable(x) = x                       # already an open CCT.Table

    """
        _taqlcmd(cmd, parents...) -> CCT.Table

    Run TaQL `cmd` with `parents` (table paths or open `CCT.Table`s) bound
    to `\$1`, `\$2`, …  Returns the result table; runs `GC.gc()` twice
    afterwards so casacore drops its write lock before our reader opens
    the output.
    """
    function _taqlcmd(cmd::AbstractString, parents...)
        tabs = map(_tc_astable, parents)
        v = CxxWrap.StdVector{CxxWrap.CxxWrapCore.ConstCxxPtr{Casacore.LibCasacore.Table}}()
        for tb in tabs
            push!(v, Ref(CxxWrap.CxxWrapCore.ConstCxxPtr(tb.tableref)))
        end
        result = GC.@preserve tabs CCT.Table(
            Casacore.LibCasacore.tableCommand(cmd, v))
        GC.gc()
        GC.gc()
        return result
    end

    _taql_create(q) = _taqlcmd(q)
end
