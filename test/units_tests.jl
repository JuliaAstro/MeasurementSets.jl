# Phase 65: physical units via the Unitful weak-dependency extension.

import Unitful, UnitfulAngles, UnitfulAstro
const U = Unitful

@testset "units — _normalize_unit" begin
    n = MSv2._normalize_unit
    @test n("Hz") == "Hz"
    @test n("m/s") == "m/s"
    @test n(" rad/s ") == "rad/s"
    @test n("%") == "percent"
    @test n("%%") == "permille"
    @test n("arcsec") == "arcsecond"
    @test n("arcmin") == "arcminute"
    @test n("K.km/s") == "K*km/s"          # casacore multiply
    @test n("Jy.m/s") == "Jy*m/s"
    @test n("") == "" && n("_") == "" && n(" ") == ""
    @test n("AE") == "AU" && n("UA") == "AU"
end

@testset "units — extension loaded" begin
    @test Base.get_extension(MSv2, :UnitfulExt) !== nothing
end

@testset "units — columnunit on the sample MS" begin
    t = readtable(SAMPLE_MS)
    ms = MeasurementSet(SAMPLE_MS)
    @test columnunit(t, "TIME") == U.u"s"
    @test columnunit(t, "UVW") == U.u"m"
    @test columnunit(t, "INTERVAL") == U.u"s"
    @test columnunit(subtable(ms, "SPECTRAL_WINDOW"), "CHAN_FREQ") == U.u"Hz"
    @test columnunit(subtable(ms, "FIELD"), "PHASE_DIR") == U.u"rad"
    @test columnunit(subtable(ms, "WEATHER"), "PRESSURE") == U.u"hPa"
    # a column with no QuantumUnits keyword
    @test columnunit(t, "ANTENNA1") === nothing
end

@testset "units — qcolumn" begin
    t = readtable(SAMPLE_MS)
    uvw = column(t, "UVW")[:]
    quvw = qcolumn(t, "UVW")
    @test U.unit(quvw[1][1]) == U.u"m"
    @test U.ustrip.(quvw[1]) == uvw[1]
    tt = column(t, "TIME")[:]
    qt = qcolumn(t, "TIME")
    @test U.ustrip.(qt) == tt && U.unit(qt[1]) == U.u"s"
    # unitless column -> plain values, unchanged
    @test qcolumn(t, "ANTENNA1") == column(t, "ANTENNA1")[:]
end

@testset "units — casacore unit vocabulary" begin
    ext = Base.get_extension(MSv2, :UnitfulExt)
    up = ext._ms_uparse
    # angles (UnitfulAngles) -- dimensionless here, unlike casacore
    @test U.dimension(up("rad")) == U.NoDims
    @test U.uconvert(up("rad"), 1 * up("arcsec")) ≈ 4.84813681109536e-6 * up("rad")
    @test up("deg") == up("°")
    # astro (UnitfulAstro)
    @test up("Jy") == U.u"Jy" || string(up("Jy")) == "Jy"
    @test string(up("pc")) == "pc"
    # dimensionless pseudo-units registered by the extension
    @test U.dimension(up("beam")) == U.NoDims
    @test up("Jy/beam") == up("Jy") / up("beam")          # `Jy·beam⁻¹`
    @test U.dimension(up("Jy/beam")) == U.dimension(U.u"Jy")   # beam is dimensionless
    @test U.dimension(up("Jy/pixel")) == U.dimension(U.u"Jy")
    # dimensionless markers
    @test up("_") == U.NoUnits && up("") == U.NoUnits
    # unsupported -> a clear, actionable error
    @test_throws ErrorException up("WU")
end

@testset "units — UNITS_NO_JULIA_COUNTERPART" begin
    d = UNITS_NO_JULIA_COUNTERPART
    @test !isempty(d)
    @test d["beam"].kind === :pseudo
    @test d["_"].kind === :nounits
    @test d["WU"].kind === :unsupported
    @test d["rad"].kind === :dimension
    ext = Base.get_extension(MSv2, :UnitfulExt)
    # every :pseudo / :nounits entry must actually parse
    for (name, info) in d
        info.kind in (:pseudo, :nounits) || continue
        @test ext._ms_uparse(name) isa Union{U.Units,typeof(U.NoUnits)}
    end
end
