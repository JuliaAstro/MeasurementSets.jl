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
    # Phase 197: "M0"/"S0" are casacore's own literal unit NAMES (solar
    # mass -- `casa/Quanta/UnitMap4.cc`, `M0 := 1*S0`), not an implicit
    # exponent -- found dead (the old digit-free token regex could never
    # even SEE "M0" as a whole token to alias-substitute it) while
    # checking casacore's own unit-string grammar directly.
    @test n("M0") == "Msun" && n("S0") == "Msun"
    # casacore's OWN general grammar: a bare digit run directly after a
    # unit name (no `**`/`^`) is an implicit exponent (`UnitVal::power`,
    # `casa/Quanta/UnitVal.cc`) -- "m2" == m², "cm3" == cm³ -- a real,
    # broader gap the old regex (letters only) couldn't express at all.
    @test n("m2") == "m^2" && n("cm3") == "cm^3" && n("hm2") == "hm^2"
    @test n("m**2") == "m**2" && n("m^2") == "m^2"   # already explicit, untouched
    # the underscore-prefixed squared-angle forms are a SEPARATE, still-
    # unsupported casacore convention (`UnitMap5.cc`'s own literal
    # "deg_2"/"arcmin_2"/"arcsec_2" names) -- not touched by the new
    # digit rule (the digit here follows `_`, not a letter), pre-existing
    # behavior unchanged: `deg` alias-substitutes on its own, "_2" is
    # left for `UNITS_NO_JULIA_COUNTERPART`'s `:unsupported` handling.
    @test n("deg_2") == "°_2"
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
    # Phase 197: "M0"/"S0" (solar mass) and the implicit-exponent
    # grammar ("m2" == m², "cm3" == cm³)
    @test U.dimension(up("M0")) == U.dimension(UnitfulAstro.Msun)
    @test U.dimension(up("S0")) == U.dimension(UnitfulAstro.Msun)
    @test up("M0") == up("S0")            # M0 := 1*S0 in casacore
    @test U.dimension(up("m2")) == U.dimension(U.u"m^2")
    @test U.dimension(up("cm3")) == U.dimension(U.u"cm^3")
    @test U.dimension(up("hm2")) == U.dimension(U.u"hm^2")
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

# Phase 70: write side -- Unitful.Units -> casacore QuantumUnits string,
# and a Quantity-typed column stamps QuantumUnits automatically.
@testset "units — _ms_ustring" begin
    ext = Base.get_extension(MSv2, :UnitfulExt)
    us = MSv2._ms_ustring
    @test us(U.u"Hz") == "Hz"
    @test us(U.u"m") == "m"
    @test us(U.u"s") == "s"
    @test us(U.u"rad") == "rad"
    @test us(U.u"K") == "K"
    @test us(U.u"Jy") == "Jy"
    @test us(U.u"m/s") == "m/s"
    @test us(U.u"°") == "deg"
    @test us(U.u"arcsecond") == "arcsec"
    @test us(U.NoUnits) == ""
    # Phase 197: `UnitfulAstro.Msun` prints as the SYMBOL "M⊙"
    # (`string(Msun) == "M⊙"`), not the identifier name -- the general
    # "atomic unit" heuristic below only ever checked `_UNIT_ALIASES_INV`
    # for the STRING "Msun", so this unconditionally errored before
    # (found live: no prior test exercised writing a solar-mass column).
    @test us(UnitfulAstro.Msun) == "M0"
    @test ext._ms_uparse(us(UnitfulAstro.Msun)) == UnitfulAstro.Msun
    # every emitted string re-parses to the same unit
    for u in (U.u"Hz", U.u"GHz", U.u"m", U.u"m/s", U.u"rad", U.u"°", U.u"arcsecond", U.u"Jy")
        @test MSv2._ms_ustring(u) |> ext._ms_uparse == u
    end
    # a compound unit with no casacore spelling errors clearly
    @test_throws ErrorException us(U.u"N*m")
end

@testset "units — write from Unitful-typed columns" begin
    dir = mktempdir()
    tab = joinpath(dir, "T")
    F = [1.30, 1.42, 1.55] .* U.u"GHz"
    W = [10.0, 20.0, 30.0] .* U.u"km/s"
    CF = [collect(1.0:4.0) .* U.u"MHz" .+ i * U.u"MHz" for i in 1:3]   # array cells
    write_table(tab, "T", Pair{String,Any}["F" => F, "W" => W, "CF" => CF]; nrow = 3)
    t = readtable(tab)

    @test columnunit(t, "F") == U.u"GHz"                  # stored in its own unit
    @test column(t, "F")[:] == [1.30, 1.42, 1.55]
    @test qcolumn(t, "F")[2] == 1.42U.u"GHz"
    @test columnunit(t, "W") == U.u"km/s"
    @test columndesc(t, "W").keywords["QuantumUnits"] == ["km/s"]
    @test columnunit(t, "CF") == U.u"MHz"
    @test column(t, "CF")[1] == collect(2.0:5.0)

    # explicit `units=` wins
    tab2 = joinpath(dir, "T2")
    write_table(tab2, "T2", Pair{String,Any}["F" => F]; nrow = 3, units = Dict("F" => "Hz"))
    @test columndesc(readtable(tab2), "F").keywords["QuantumUnits"] == ["Hz"]

    # Phase 197: a Msun-typed column round-trips through write_table too
    # (end-to-end coverage of the `_ms_ustring` fix above)
    tab3 = joinpath(dir, "T3")
    MASS = [1.0, 2.5, 4.0] .* UnitfulAstro.Msun
    write_table(tab3, "T3", Pair{String,Any}["MASS" => MASS]; nrow = 3)
    t3 = readtable(tab3)
    @test columndesc(t3, "MASS").keywords["QuantumUnits"] == ["M0"]
    @test columnunit(t3, "MASS") == UnitfulAstro.Msun
    @test column(t3, "MASS")[:] == [1.0, 2.5, 4.0]
end
