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

# Phase 296 sweep of ext/UnitfulExt.jl (first dedicated fresh read of this
# file; only ever touched piecemeal before by 65/70/160/197, and 197's own
# fixes landed in the core src/tables/units.jl file, not here).
@testset "units — Phase 296 sweep findings" begin
    ext = Base.get_extension(MSv2, :UnitfulExt)
    up = ext._ms_uparse

    # klambda's `@unit` scale factor (1000) ties back to `lambda`'s own
    # dimensionless base correctly -- verified independently, not assumed
    # from the macro call alone.
    @test U.uconvert(up("lambda"), 1 * up("klambda")) == 1000 * up("lambda")
    @test U.dimension(up("klambda")) == U.NoDims

    # `m/s^2` (the one non-`m/s` compound `_MS_USTRING_KNOWN` carries)
    # round-trips end to end, exercising the Phase-197 digit-implicit-
    # exponent rule inside a compound (not just an atomic) unit string.
    @test up("m/s2") == U.u"m/s^2"
    @test MSv2._ms_ustring(U.u"m/s^2") == "m/s2"
    dir = mktempdir()
    tab = joinpath(dir, "MS2")
    write_table(tab, "MS2", Pair{String,Any}["A" => [1.0, 2.0, 3.0] .* U.u"m/s^2"]; nrow = 3)
    r = readtable(tab)
    @test columndesc(r, "A").keywords["QuantumUnits"] == ["m/s2"]
    @test columnunit(r, "A") == U.u"m/s^2"
    @test column(r, "A")[:] == [1.0, 2.0, 3.0]

    # `_tql_write_strip`'s `u isa Tuple` guard (added for consistency with
    # its two siblings, `_tql_unit_attach`/`qcolumn`, both of which already
    # had it) -- currently unreachable via `update!`'s own call site (see
    # the function's own comment), pinned directly so a future refactor
    # that DOES reach it some other way still gets a clear error.
    mixed = (U.u"m", U.u"s")
    @test_throws ErrorException MSv2._tql_write_strip(1.0 * U.u"m", mixed)
    @test_throws ErrorException MSv2._tql_write_strip(1.0 * U.u"m", nothing)
    @test MSv2._tql_write_strip(2.0 * U.u"km", U.u"m") == 2000.0   # unaffected
end

# Phase 292 finding: `columnunit`/`qcolumn`'s own "load Unitful" fallback
# (`units.jl`'s varargs stubs, overridden by `UnitfulExt` once loaded) had
# NEVER been exercised by any test -- this file's own `import Unitful,
# UnitfulAngles, UnitfulAstro` above loads the extension for the whole
# process before a single `@test` runs, and once loaded it stays loaded,
# so the fallback genuinely cannot be reached in-process. Spawn a real
# child process that never imports Unitful, reusing `lock_tests.jl`'s
# `_JULIA`/`_PROJ` cross-process machinery (already in scope), the same
# pattern Phase 225 used for the analogous `EarthOrientationExt` gap.
@testset "units — no-Unitful fallback (child process, Phase 292)" begin
    child_code = """
        using MeasurementSets
        @assert Base.get_extension(MeasurementSets, :UnitfulExt) === nothing
        d = mktempdir()
        p = joinpath(d, "t")
        write_table(p, "T", ["A" => Float64[1.0, 2.0]]; nrow=2)
        t = readtable(p)
        ok1 = try columnunit(t, "A"); false catch e; e isa ErrorException &&
            occursin("import Unitful", e.msg) end
        ok2 = try qcolumn(t, "A"); false catch e; e isa ErrorException &&
            occursin("import Unitful", e.msg) end
        println(ok1 && ok2)
        """
    out = read(`$_JULIA --project=$_PROJ --startup-file=no -e $child_code`, String)
    @test strip(out) == "true"
end


# Phase 324: every casacore unit NAME (from casacore's UnitMap) that parses was compared against
# casatools' own canonical SI value (`qa.canonical(qa.quantity(1, name))`).  This found casacore
# names that Unitful reads as a DIFFERENT unit -- `h` (hour -> Planck's constant), `a` (annum -> the
# are), `G` (gauss -> the gravitational constant), `R` (roentgen -> the gas constant) -- plus `min`
# not parsing, and write-direction spellings casacore rejects (`hr`, `minute`, `Gauss`, `Å`).
# The table below is a static snapshot of those casatools values; a few names use older constants in
# casacore than in Unitful (AU 2.7e-10, M0/S0 2.6e-4, u 3e-4, cal 1e-3) and get a looser tolerance.
const _CASACORE_CANON = Dict{String,Float64}(
    "%" => 0.01,
    "%%" => 0.001,
    "AE" => 149597870659.18134,
    "AU" => 149597870659.18134,
    "Angstrom" => 1e-10,
    "Bq" => 1.0,
    "C" => 1.0,
    "F" => 1.0,
    "G" => 0.0001,
    "Gal" => 0.01,
    "Gy" => 1.0,
    "H" => 1.0,
    "Hz" => 1.0,
    "J" => 1.0,
    "Jy" => 1e-26,
    "L" => 0.0010000000000000002,
    "M0" => 1.9889194440735207e+30,
    "Mx" => 1e-08,
    "N" => 1.0,
    "Oe" => 79.57747154594767,
    "Ohm" => 1.0,
    "Pa" => 1.0,
    "S" => 1.0,
    "S0" => 1.9889194440735207e+30,
    "St" => 0.0001,
    "Sv" => 1.0,
    "T" => 1.0,
    "Torr" => 133.32236842105263,
    "UA" => 149597870659.18134,
    "V" => 1.0,
    "W" => 1.0,
    "Wb" => 1.0,
    "a" => 31557600.0,
    "ac" => 4046.8564223999992,
    "adu" => 1.0,
    "arcmin" => 0.0002908882086657216,
    "arcsec" => 4.84813681109536e-06,
    "as" => 4.84813681109536e-06,
    "atm" => 101325.0,
    "bar" => 100000.0,
    "beam" => 1.0,
    "cal" => 4.1868,
    "count" => 1.0,
    "d" => 86400.0,
    "deg" => 0.017453292519943295,
    "dyn" => 1e-05,
    "eV" => 1.60217733e-19,
    "erg" => 1e-07,
    "ft" => 0.30479999999999996,
    "g" => 0.001,
    "h" => 3600.0,
    "ha" => 10000.0,
    "in" => 0.025400000000000002,
    "l" => 0.0010000000000000002,
    "lambda" => 1.0,
    "lb" => 0.45359237,
    "lm" => 1.0,
    "lx" => 1.0,
    "ly" => 9460730470000000.0,
    "m" => 1.0,
    "mile" => 1609.3439999999998,
    "min" => 60.0,
    "oz" => 0.028349523125,
    "pc" => 3.085677580649422e+16,
    "pixel" => 1.0,
    "u" => 1.661e-27,
    "yd" => 0.9144,
    "yr" => 31557600.0,
)
@testset "units — every parseable casacore unit name matches casacore's canonical value (Phase 324)" begin
    up = Base.get_extension(MSv2, :UnitfulExt)._ms_uparse
    loose = Dict("M0" => 1e-3, "S0" => 1e-3, "u" => 1e-3, "cal" => 1e-2, "AE" => 1e-6, "AU" => 1e-6, "UA" => 1e-6)
    for (name, cv) in _CASACORE_CANON
        u = up(name)
        q = 1.0 * u
        v = U.ustrip(U.uconvert(U.upreferred(U.unit(q)), q))
        @test isapprox(v, cv; rtol = get(loose, name, 1e-6))
    end
    # the names that used to be read as a different unit entirely
    @test U.uconvert(U.u"s", 1 * up("h")) == 3600 * U.u"s"
    @test U.uconvert(U.u"s", 1 * up("min")) == 60 * U.u"s"
    @test U.uconvert(U.u"s", 1 * up("a")) == 3.15576e7 * U.u"s"
    @test U.dimension(up("G")) == U.dimension(U.u"T")
    # no Unitful counterpart: refuse rather than silently return a different quantity
    @test_throws ErrorException up("R")
    @test_throws ErrorException up("Gb")
    # write direction: the strings must be casacore unit names
    us = MSv2._ms_ustring
    @test us(U.u"hr") == "h"
    @test us(U.u"minute") == "min"
    @test us(U.u"Gauss") == "G"
    @test us(U.u"Å") == "Angstrom"
    @test us(U.u"yr") == "yr"
    # and a round trip through a table
    for u in (U.u"hr", U.u"minute", U.u"Gauss", U.u"yr")
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => [1.5, 2.5] .* u]; nrow=2)
        t = readtable(d)
        @test columnunit(t, "X") == u
        @test qcolumn(t, "X") == [1.5, 2.5] .* u
    end
end
