# Phase 267: keyword sets and table info against real casacore (CASA's python `casatools`).
#
# Found: a Bool ARRAY keyword was read and written one byte per element, but casacore
# bit-packs Bool arrays (LSB first, ceil(n/8) bytes) -- so a casacore-written Bool array
# keyword read as garbage and one of ours made casacore refuse the whole table
# ("AipsIO::getend: part of object not read").  `write_table(...; keywords)` also could not
# write numeric-array or nested-record keywords (`copyms` always could), and an undefined
# variable-shape SSM/ISM cell read as a 1-D empty whatever the column's ndim.

@testset "Bool array keyword bit packing (Phase 267)" begin
    bits = [true, false, true, true, false, false, false, true, true, false, true]
    for n in (0, 1, 7, 8, 9, 11, 16, 17)
        v = [bits[mod1(i, length(bits))] for i in 1:n]
        w = MSv2.AipsWriter(; endian=:big)
        MSv2._write_aipsarray(w, v)
        b = MSv2.bytes(w)
        a = MSv2.AipsIO(b; endian=:big)
        shape, data = MSv2.read_array(a, Bool)
        @test shape == (n,) && data == v
    end
    # the exact casacore encoding of the 11 elements above: 0x8D 0x05 (LSB first)
    w = MSv2.AipsWriter(; endian=:big)
    MSv2._write_aipsarray(w, bits)
    @test MSv2.bytes(w)[end-1:end] == UInt8[0x8d, 0x05]
end

@testset "write_table keywords: arrays and nested records (Phase 267)" begin
    d = joinpath(mktempdir(), "t")
    kw = Dict{String,Any}("ai" => Int32[1, 2, 3], "ar" => [1.5, 2.5], "a2" => reshape(1.0:6.0, 2, 3),
                          "ab" => [true, false, true, true, false, false, false, true, true],
                          "ac" => ComplexF32[1 + 2im], "as" => ["x", "yz"], "sc" => Int16(3), "b" => true,
                          "i8" => Int64(5), "rec" => Dict("a" => 1, "s" => "q", "sub" => Dict("v" => [1, 2])))
    write_table(d, "T", Pair{String,Any}["X" => [1.0, 2.0]]; nrow=2, keywords=kw)
    k = MSv2.keywords(readtable(d))
    @test k["ai"] == Int32[1, 2, 3] && k["ar"] == [1.5, 2.5] && k["a2"] == reshape(1.0:6.0, 2, 3)
    @test k["ab"] == kw["ab"] && k["ac"] == ComplexF32[1 + 2im] && k["as"] == ["x", "yz"]
    @test k["sc"] === Int16(3) && k["b"] === true && k["i8"] === Int64(5)
    @test k["rec"]["a"] == 1 && k["rec"]["s"] == "q" && k["rec"]["sub"]["v"] == [1, 2]
    @test_throws ErrorException write_table(joinpath(mktempdir(), "t"), "T",
        Pair{String,Any}["X" => [1.0]]; nrow=1, keywords=Dict{String,Any}("bad" => Int8[1]))
    # and a copy keeps every one
    c = joinpath(mktempdir(), "c"); copytable(c, readtable(d))
    @test MSv2.keywords(readtable(c))["ab"] == kw["ab"]
end

@testset "undefined variable-shape cells keep the column's ndim (Phase 267)" begin
    for isms in ((), ("X",))
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => [ones(2, 2), zeros(0, 0), ones(1, 3)]]; nrow=3, ism=collect(isms))
        @test size.(column(readtable(d), "X")[:]) == [(2, 2), (0, 0), (1, 3)]
    end
    for isms in ((), ("S",))
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["S" => [["a"; "b";;], Matrix{String}(undef, 0, 0)]]; nrow=2, ism=collect(isms))
        @test size.(column(readtable(d), "S")[:]) == [(2, 1), (0, 0)]
    end
end

const _KW_CASA = get(ENV, "MEASUREMENTSETS_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")

@testset "keywords and table info vs real casacore (Phase 267)" begin
    if isfile(_KW_CASA)
        py(script, args...) = read(`$_KW_CASA -c $script $args`, String)
        mk = """
import sys, numpy as np
from casatools import table
tb = table()
tb.create(sys.argv[1], {'X': {'valueType':'double','option':0,'maxlen':0,'comment':'c','ndim':-1},
                        'V': {'valueType':'float','ndim':2,'option':0,'maxlen':0,'comment':''}}, nrow=2)
tb.putkeywords({'b': True, 'i4': 7, 'r8': 2.5, 's': 'hello', 'c8': 1+2j, 'emptystr': '', 'emptyrec': {},
  'ai': np.array([1,2,3], dtype=np.int32), 'ar': np.array([1.0,2.0]), 'as': ['a','bc'],
  'ab': np.array([True,False,True,True,False,False,False,True,True,False,True]),
  'a2': np.arange(6, dtype=np.float64).reshape(2,3), 'ac': np.array([1+2j, 3+0j]), 'ea': np.array([], dtype=np.float64),
  'rec': {'x': 1.5, 'name': 'n', 'sub': {'deep': np.array([1,2], dtype=np.int32)}}})
tb.putcolkeywords('X', {'unit': 'Hz', 'QuantumUnits': ['Hz'], 'MEASINFO': {'type':'frequency','Ref':'LSRK'}, 'arr': np.array([1.0,2.0]), 'n': 3})
tb.putcolkeyword('V', 'flagsets', {'a': 1, 'b': 2})
tb.putinfo({'type':'MyType','subType':'MySub','readme':'line1\\nline2\\n'})
tb.close()
"""
        dump = """
import sys, json, numpy as np
from casatools import table
def norm(v):
    if isinstance(v, dict): return {k: norm(x) for k,x in sorted(v.items())}
    if isinstance(v, np.ndarray): return ['arr', v.dtype.kind, list(v.shape), (np.stack([v.real, v.imag], -1) if v.dtype.kind == 'c' else v).tolist()]
    if isinstance(v, (list,tuple)): return [norm(x) for x in v]
    if isinstance(v, complex): return ['c', v.real, v.imag]
    return v
tb = table(); tb.open(sys.argv[1])
d = {k:{kk:vv for kk,vv in v.items() if kk not in ('dataManagerGroup',)} for k,v in tb.getdesc().items() if isinstance(v, dict) and 'valueType' in v}
print(json.dumps({'kw': norm(tb.getkeywords()), 'X': norm(tb.getcolkeywords('X')), 'V': norm(tb.getcolkeywords('V')),
                  'desc': norm(d), 'info': tb.info(), 'nrow': tb.nrows()}, sort_keys=True))
tb.close()
"""
        src = joinpath(mktempdir(), "kw.tab")
        py(mk, src)
        t = readtable(src)
        k = MSv2.keywords(t)
        # what casacore wrote, as we read it
        @test k["ab"] == [true, false, true, true, false, false, false, true, true, false, true]
        @test k["b"] === true && k["i4"] === Int32(7) && k["r8"] == 2.5 && k["s"] == "hello" && k["c8"] == 1 + 2im
        @test k["ai"] == Int32[1, 2, 3] && k["as"] == ["a", "bc"] && k["ac"] == ComplexF64[1 + 2im, 3] && isempty(k["ea"])
        @test k["rec"]["sub"]["deep"] == Int32[1, 2] && k["emptystr"] == "" && isempty(k["emptyrec"])
        @test t.type == "MyType" && t.subtype == "MySub" && t.readme == "line1\nline2\n"
        @test columndesc(t, "X").keywords["unit"] == "Hz"
        # a copy of ours describes the same table to casacore: keywords, column keywords, info, columns
        dst = joinpath(mktempdir(), "c.tab")
        copytable(dst, t)
        a_, b_ = py(dump, dst), py(dump, src); a_ == b_ || (println(a_); println(b_)); @test a_ == b_
        # the undefined 2-D cells of the never-written V column keep their ndim
        @test size.(column(t, "V")[:]) == [(0, 0), (0, 0)]
    else
        @info "casatools python not found; skipping the keyword cross-check" _KW_CASA
    end
end

@testset "table.info readme round trip (Phase 267)" begin
    for readme in ("", "one", "a\nb", "a\nb\n")
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", Pair{String,Any}["X" => [1.0]]; nrow=1, type="Tt", subtype="Ss", readme)
        t = readtable(d)
        @test t.type == "Tt" && t.subtype == "Ss" && t.readme == readme
        c = joinpath(mktempdir(), "c"); copytable(c, t)
        @test readtable(c).readme == readme
    end
end

# Phase 368: column keywords survive every table rewrite (edit regeneration, addcolumn!,
# removecolumn!, renamecolumn!, copytable with and without a row selection): sweep, no bug found.
@testset "column keywords survive rewrites (Phase 368)" begin
    rng = MSv2.Random.MersenneTwister(368)
    kv() = rand(rng, Any[() -> Int32(rand(rng, -9:9)), () -> rand(rng), () -> "s" * string(rand(rng, 1:99)), () -> rand(rng, Bool),
          () -> ["a", "bb", "ccc"][1:rand(rng, 1:3)], () -> rand(rng, rand(rng, 1:4)), () -> rand(rng, Bool, rand(rng, 1:5))])()
    kws(t, c) = (cd = MSv2.columndesc(t, c); Dict(String(k) => v for (k, v) in zip(cd.keywords.names, cd.keywords.values)))
    nbad = 0
    for _ in 1:12
        N = rand(rng, 5:40)
        cols = Pair{String,Any}["A" => Int32.(1:N), "B" => rand(rng, N), "S" => ["s$i" for i in 1:N], "V" => [rand(rng, rand(rng, 1:3)) for _ in 1:N]]
        d = joinpath(mktempdir(), "t")
        write_table(d, "T", cols; nrow=N, (rand(rng, Bool) ? (; ism=["B"]) : (;))...)
        want = Dict{String,Dict{String,Any}}()
        for c in ("A", "B", "S", "V"), j in 1:rand(rng, 0:3)
            v = kv(); MSv2.setkeyword!(d, "KW$j", v; column=c); get!(want, c, Dict{String,Any}())["KW$j"] = v
        end
        chk(path, mp=identity) = begin
            t = readtable(path)
            for (c, m) in want
                cn = mp(c); cn in MSv2.columnnames(t) || continue
                got = kws(t, cn)
                for (n, v) in m
                    (haskey(got, n) && got[n] == v) || (nbad += 1)
                end
            end
        end
        chk(d)
        edit(d) do e; MSv2.removerows!(e, [1, 3]); MSv2.addrows!(e, 2); end; chk(d)
        edit(d) do e; MSv2.addcolumn!(e, "Z", fill(1.5, MSv2.nrow(readtable(d)))); end; chk(d)
        d2 = joinpath(mktempdir(), "c"); copytable(d2, readtable(d)); chk(d2)
        d3 = joinpath(mktempdir(), "c"); copytable(d3, readtable(d); rows=2:4); chk(d3)
        MSv2.renamecolumn!(d, "B", "B2"); chk(d, c -> c == "B" ? "B2" : c)
        edit(d) do e; MSv2.removecolumn!(e, "S"); end; chk(d)
    end
    @test nbad == 0
end

# Phase 370: table-level metadata (keywords incl. nested records, type / subtype / readme, table
# name and comment, column order) is unchanged by `edit` regeneration, `addcolumn!` +
# `removecolumn!` and `copytable` (with and without a row selection), for tables written by us
# and for casacore-made tables with keywords set by real TaQL `ALTER TABLE`: sweep, no bug found.
@testset "table metadata survives rewrites (Phase 370)" begin
    rng = MSv2.Random.MersenneTwister(370)
    nrm(x::MSv2.Record) = Dict(n => nrm(v) for (n, v) in zip(x.names, x.values))
    nrm(x) = x
    tstate(t) = (MSv2.columnnames(t), t.type, t.subtype, t.readme, MSv2.keywords(t).names, nrm.(MSv2.keywords(t).values), t.desc.name, t.desc.comment)
    function roundtrip(d, s0)
        nbad = 0
        edit(e -> (MSv2.removerows!(e, [1]); MSv2.addrows!(e, 2)), d)
        nbad += tstate(readtable(d)) != s0
        edit(e -> MSv2.addcolumn!(e, "ZZ", fill(1.0, MSv2.nrow(readtable(d)))), d)
        edit(e -> MSv2.removecolumn!(e, "ZZ"), d)
        nbad += tstate(readtable(d)) != s0
        for rows in (nothing, 2:3)
            d2 = joinpath(mktempdir(), "c"); rows === nothing ? copytable(d2, readtable(d)) : copytable(d2, readtable(d); rows)
            nbad += tstate(readtable(d2)) != s0
        end
        nbad
    end
    nbad = 0
    for k in 1:8
        N = rand(rng, 4:30); d = joinpath(mktempdir(), "t")
        write_table(d, "T$k", Pair{String,Any}["A" => Int32.(1:N), "B" => rand(rng, N), "V" => [rand(rng, rand(rng, 1:3)) for _ in 1:N]]; nrow=N,
            type="Ty$k", subtype="Sub$k", readme="line1\nline2 é$k\n",
            keywords=Dict{String,Any}("X" => Int32(k), "S" => "s$k", "R" => Dict("a" => 1.5, "b" => ["x", "y"])),
            (rand(rng, Bool) ? (; ism=["B"]) : (;))...)
        nbad += roundtrip(d, tstate(readtable(d)))
    end
    @test nbad == 0
    if _HAVE_TAQL
        lits = ["-7", "3.25", "'str5'", "T", "F", "[1,2,3]", "[1.5,2.5]", "['a','bb']"]
        for k in 1:8
            d = joinpath(mktempdir(), "t")
            dm = rand(rng, Bool) ? " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"IS\", COLUMNS=[\"C1\"]]" : ""
            # (helper functions: a casacore handle left alive in this frame would stop the ALTER flushing)
            mk(q) = (tc = _taql_create(q); CCT.flush(tc); nothing)
            alt(j, lit) = (r = _taqlcmd("ALTER TABLE \$1 SET KEYWORD K$j = $lit", d); r = nothing; nothing)
            mk("CREATE TABLE $d [C1 I4, C2 R8, C3 S] LIMIT $(rand(rng, 5:20))$dm")
            for _ in 1:20; GC.gc(); sleep(0.05); end
            for j in 1:rand(rng, 1:4); alt(j, rand(rng, lits)); for _ in 1:20; GC.gc(); sleep(0.05); end; end
            @test length(MSv2.keywords(readtable(d)).names) >= 1
            nbad += roundtrip(d, tstate(readtable(d)))
        end
        @test nbad == 0
    end
end

# Phase 503: a `SubTable` value is a table keyword (TpTable), so `write_table(...; keywords=...)` and `setkeyword!` can link subtables
# that already exist -- a MAIN written into a directory of subtables becomes a Measurement Set (reported by a user working with LOFAR data).
@testset "SubTable keyword links existing subtables (Phase 503)" begin
    d = joinpath(mktempdir(), "new.ms"); mkpath(d)
    for nm in ("ANTENNA", "FIELD", "SPECTRAL_WINDOW")
        cp(joinpath(SAMPLE_MS, nm), joinpath(d, nm))
    end
    n = 5
    write_table(d, "MAIN", Pair{String,Any}["TIME" => collect(1.0:n), "ANTENNA1" => Int32.(0:n-1)]; nrow=n, type="Measurement Set",
        keywords=Dict("MS_VERSION" => 2.0f0, "ANTENNA" => MSv2.SubTable("././ANTENNA"), "FIELD" => MSv2.SubTable("././FIELD")))
    ms = MeasurementSet(d)
    @test sort(first.(MSv2.subtables(readtable(d)))) == ["ANTENNA", "FIELD"]
    @test nrow(subtable(ms, "ANTENNA")) == nrow(readtable(joinpath(SAMPLE_MS, "ANTENNA"))) && nrow(ms) == n
    MSv2.setkeyword!(d, "SPECTRAL_WINDOW", MSv2.SubTable("././SPECTRAL_WINDOW"))
    @test nrow(subtable(MeasurementSet(d), "SPECTRAL_WINDOW")) == nrow(readtable(joinpath(SAMPLE_MS, "SPECTRAL_WINDOW")))
    @test_throws ArgumentError MSv2.setkeyword!(d, "SPECTRAL_WINDOW", 3.0)      # a table keyword cannot become a number
    if _HAVE_CASACORE
        @test size(CCT.Table(d)[:TIME]) == (n,) && size(CCT.Table(joinpath(d, "ANTENNA"))[:NAME]) == (26,)
    end
end

# Phase 504: `write_table` of a standard MS table gives its columns the standard `QuantumUnits` / `MEASINFO` / `CATEGORY` keywords
# (casacore refuses an MS whose columns lack them -- Phase 271); only `create_ms` / `copyms` used to.  Compared with `create_ms`.
@testset "write_table stamps the standard MS column keywords (Phase 504)" begin
    ref = joinpath(mktempdir(), "ref.ms"); create_ms(ref; nrow=3, nant=2)
    kws(path, cols) = (t = readtable(path); Dict(c => repr(columndesc(t, c).keywords) for c in cols))
    d = joinpath(mktempdir(), "ant")
    write_table(d, "ANTENNA", Pair{String,Any}["NAME" => ["A", "B"], "POSITION" => [[1.0, 2, 3], [4.0, 5, 6]], "DISH_DIAMETER" => [25.0, 25.0],
                                              "OFFSET" => [[0.0, 0, 0], [0.0, 0, 0]]]; nrow=2)
    want = kws(joinpath(ref, "ANTENNA"), ["POSITION", "OFFSET", "DISH_DIAMETER"])
    @test kws(d, ["POSITION", "OFFSET", "DISH_DIAMETER"]) == want
    @test occursin("MEASINFO", want["POSITION"]) && occursin("QuantumUnits", want["DISH_DIAMETER"])
    # a MAIN: TIME / UVW measures, FLAG_CATEGORY's CATEGORY
    m = joinpath(mktempdir(), "main")
    write_table(m, "MAIN", Pair{String,Any}["TIME" => [1.0, 2], "UVW" => [[1.0, 2, 3], [4.0, 5, 6]], "FLAG_CATEGORY" => [zeros(Bool, 2, 2, 1), zeros(Bool, 2, 2, 1)]]; nrow=2)
    @test kws(m, ["TIME", "UVW"]) == kws(joinpath(ref), ["TIME", "UVW"])
    @test haskey(columndesc(readtable(m), "FLAG_CATEGORY").keywords, "CATEGORY")
    # a variable-reference column needs its reference column in the table; without it only the unit is stamped
    s = joinpath(mktempdir(), "spw")
    write_table(s, "SPECTRAL_WINDOW", Pair{String,Any}["CHAN_FREQ" => [[1e9, 2e9]]]; nrow=1)
    @test columndesc(readtable(s), "CHAN_FREQ").keywords["QuantumUnits"] == ["Hz"] && !haskey(columndesc(readtable(s), "CHAN_FREQ").keywords, "MEASINFO")
    s2 = joinpath(mktempdir(), "spw2")
    write_table(s2, "SPECTRAL_WINDOW", Pair{String,Any}["CHAN_FREQ" => [[1e9, 2e9]], "MEAS_FREQ_REF" => Int32[5]]; nrow=1)
    @test haskey(columndesc(readtable(s2), "CHAN_FREQ").keywords, "MEASINFO")
    # opt out, and an unrelated table name is untouched
    o = joinpath(mktempdir(), "o")
    write_table(o, "ANTENNA", Pair{String,Any}["POSITION" => [[1.0, 2, 3]]]; nrow=1, standard=false)
    @test isempty(columndesc(readtable(o), "POSITION").keywords)
    u = joinpath(mktempdir(), "u")
    write_table(u, "MYTABLE", Pair{String,Any}["POSITION" => [[1.0, 2, 3]]]; nrow=1)
    @test isempty(columndesc(readtable(u), "POSITION").keywords)
end

# Phase 505: the whole piecewise workflow of Phases 503-504 -- every table of a `create_ms` MS rewritten with `write_table` (standard names, so the
# standard keywords are stamped) and MAIN linked to the subtables with `SubTable` keywords -- gives a `validate`-clean MS whose column keywords
# equal `create_ms`'s on every column of every table.
@testset "an MS assembled from write_table pieces is valid (Phase 505)" begin
    ref = joinpath(mktempdir(), "ref.ms"); create_ms(ref; nrow=6, nchan=3, ncorr=2, nant=3)
    rms = MeasurementSet(ref)
    new = joinpath(mktempdir(), "new.ms"); mkpath(new)
    subs = String[]
    for nm in MSv2.subtablenames(rms)
        st = subtable(rms, nm)
        write_table(joinpath(new, nm), nm, Pair{String,Any}[c => collect(column(st, c)[:]) for c in columnnames(st)]; nrow=nrow(st))
        push!(subs, nm)
    end
    main = readtable(ref)
    kw = Dict{String,Any}("MS_VERSION" => 2.0f0)
    for nm in subs; kw[nm] = MSv2.SubTable("././" * nm); end
    write_table(new, "MAIN", Pair{String,Any}[c => collect(column(main, c)[:]) for c in columnnames(main)]; nrow=nrow(main),
                type="Measurement Set", keywords=kw)
    @test isempty(validate(MeasurementSet(new)))
    nbad = 0
    for nm in vcat(["MAIN"], subs)
        a = nm == "MAIN" ? readtable(new) : readtable(joinpath(new, nm)); b = nm == "MAIN" ? main : readtable(joinpath(ref, nm))
        for c in columnnames(a)
            nbad += repr(columndesc(a, c).keywords) != repr(columndesc(b, c).keywords)
        end
    end
    @test nbad == 0
    @test length(subs) >= 10
    _HAVE_CASACORE && @test size(CCT.Table(new)[:TIME]) == (6,)
end

# Phase 508: a `SubTable` link is stored the way casacore resolves it ("././NAME" = inside the table's directory).  "./NAME" is a SIBLING to casacore and
# a bare "NAME" is relative to the working directory, but our reader accepted both, so a sloppy link read back here and not in casacore; `SubTable("")`
# linked the table to itself.
@testset "SubTable links are stored in casacore's form (Phase 508)" begin
    stored(d, nm) = (kw = keywords(readtable(d)); kw.values[findfirst(==(nm), kw.names)].name)
    function mk(link; into=true)
        d = joinpath(mktempdir(), "n.ms"); mkpath(d)
        into && cp(joinpath(SAMPLE_MS, "ANTENNA"), joinpath(d, "ANTENNA"))
        write_table(d, "MAIN", Pair{String,Any}["TIME" => [1.0, 2.0]]; nrow=2, keywords=Dict("ANTENNA" => link))
        return d
    end
    for link in ("././ANTENNA", "./ANTENNA", "ANTENNA", "Table: ./ANTENNA", "././ANTENNA/", "  ANTENNA ")
        d = mk(MSv2.SubTable(link))
        @test stored(d, "ANTENNA") == "././ANTENNA"
        @test nrow(subtable(MeasurementSet(d), "ANTENNA")) == 26
    end
    # a genuine sibling directory keeps its "./" form; an absolute path is kept
    base = mktempdir(); main = joinpath(base, "main"); mkpath(main); cp(joinpath(SAMPLE_MS, "ANTENNA"), joinpath(base, "ANTENNA"))
    write_table(main, "MAIN", Pair{String,Any}["TIME" => [1.0]]; nrow=1, keywords=Dict("ANTENNA" => MSv2.SubTable("./ANTENNA")))
    @test stored(main, "ANTENNA") == "./ANTENNA" && nrow(subtable(MeasurementSet(main), "ANTENNA")) == 26
    ab = joinpath(base, "ANTENNA"); d = joinpath(mktempdir(), "m"); mkpath(d)
    write_table(d, "MAIN", Pair{String,Any}["TIME" => [1.0]]; nrow=1, keywords=Dict("ANTENNA" => MSv2.SubTable(ab)))
    @test stored(d, "ANTENNA") == ab
    # a link to nothing warns (the subtable may be written afterwards) and an empty one is an error
    @test_logs (:warn, r"there is no table at") mk(MSv2.SubTable("NOPE"); into=false)
    @test_throws ArgumentError mk(MSv2.SubTable(""))
    @test_throws ArgumentError mk(MSv2.SubTable("./"))
    # setkeyword! canonicalises too
    d = mk(MSv2.SubTable("././ANTENNA")); cp(joinpath(SAMPLE_MS, "FIELD"), joinpath(d, "FIELD"))
    MSv2.setkeyword!(d, "FIELD", MSv2.SubTable("FIELD"))
    @test stored(d, "FIELD") == "././FIELD" && nrow(subtable(MeasurementSet(d), "FIELD")) == 3
end

# Phase 509: data given to a column of a standard table is checked against the standard type and (fixed) shape; it used to be converted by the writer or die there
# with a bare MethodError / TypeError, and a 2-vector POSITION was written as it came (an invalid MS to casacore).
@testset "standard-table columns are checked against the standard type and shape (Phase 509)" begin
    w(name, cols; kw...) = (d = joinpath(mktempdir(), "t"); write_table(d, name, Pair{String,Any}[cols...]; nrow=length(last(first(cols))), kw...); readtable(d))
    # exact conversions are made
    t = w("MAIN", ["TIME" => [1, 2, 3], "ANTENNA1" => [0.0, 1.0, 2.0], "FLAG" => [[1.0 0.0], [0.0 1.0], [0.0 0.0]], "DATA" => [Float32[1 2; 3 4], Float32[1 2; 3 4], Float32[1 2; 3 4]]])
    @test eltype(column(t, "TIME")) == Float64 && column(t, "TIME")[:] == [1.0, 2.0, 3.0]
    @test eltype(column(t, "ANTENNA1")) == Int32 && column(t, "FLAG")[1] == [true false]
    @test eltype(first(column(t, "DATA"))) == ComplexF32 && column(t, "DATA")[2] == ComplexF32[1 2; 3 4]
    # anything else is an ArgumentError naming the column, the standard type and the row
    for (nm, col, want) in (("MAIN", "TIME" => ["a", "b"], "TIME"), ("ANTENNA", "NAME" => [1, 2], "NAME"), ("MAIN", "ANTENNA1" => [0.5, 1.0], "ANTENNA1"),
                            ("MAIN", "FLAG" => [[2.0 0.0]], "FLAG"), ("MAIN", "TIME" => [[1.0, 2.0]], "TIME"), ("ANTENNA", "POSITION" => [1.0, 2.0], "POSITION"))
        e = try w(nm, [col]); nothing catch err; err end
        @test e isa ArgumentError && occursin("\"$want\"", e.msg) && occursin("standard table \"$nm\"", e.msg)
    end
    # a fixed standard shape is enforced (the `standard` option); `standard=false` leaves the data alone
    e = try w("ANTENNA", ["POSITION" => [[1.0, 2.0], [3.0, 4.0]]]); nothing catch err; err end
    @test e isa ArgumentError && occursin("shape (3,)", e.msg) && occursin("row 1", e.msg)
    @test size(column(w("ANTENNA", ["POSITION" => [[1.0, 2.0]]]; standard=false), "POSITION")[1]) == (2,)
    @test size(column(w("ANTENNA", ["POSITION" => [[1.0, 2.0, 3.0]]]), "POSITION")[1]) == (3,)
    # other table names are not touched
    @test column(w("MYTABLE", ["TIME" => ["a", "b"]]), "TIME")[:] == ["a", "b"]
end

# Phase 513: a non-standard subtable (LOFAR's `LOFAR_ANTENNA_FIELD`, with ragged array columns) linked into a hand-assembled MS is carried by `copyms`, `copytable` and
# the query verbs like a standard one, and `validate` leaves it alone (no standard schema).
@testset "a non-standard subtable survives the whole pipeline (Phase 513)" begin
    d = joinpath(mktempdir(), "n.ms"); mkpath(d)
    for nm in ("ANTENNA", "FIELD", "SPECTRAL_WINDOW"); cp(joinpath(SAMPLE_MS, nm), joinpath(d, nm)); end
    off = [Float64.(reshape(1:12, 3, 4)), Float64.(reshape(1:18, 3, 6))]
    write_table(joinpath(d, "LOFAR_ANTENNA_FIELD"), "LOFAR_ANTENNA_FIELD",
                ["ANTENNA_ID" => Int32[0, 1], "NAME" => ["LBA", "HBA"], "ELEMENT_OFFSET" => off]; nrow=2)
    links = Dict{String,Any}(nm => MSv2.SubTable("././" * nm) for nm in ("ANTENNA", "FIELD", "SPECTRAL_WINDOW", "LOFAR_ANTENNA_FIELD")); links["MS_VERSION"] = 2.0f0
    write_table(d, "MAIN", Pair{String,Any}["TIME" => [1.0, 2.0], "ANTENNA1" => Int32[0, 1], "ANTENNA2" => Int32[1, 0]]; nrow=2, type="Measurement Set", keywords=links)
    ms = MeasurementSet(d)
    @test "LOFAR_ANTENNA_FIELD" in MSv2.subtablenames(ms) && nrow(ms.LOFAR_ANTENNA_FIELD) == 2
    @test !any(i -> occursin("LOFAR", i), validate(ms))
    o = joinpath(mktempdir(), "o.ms"); copyms(d, o; rows=1:1)
    mo = MeasurementSet(o)
    @test nrow(mo) == 1 && "LOFAR_ANTENNA_FIELD" in MSv2.subtablenames(mo)
    @test column(mo.LOFAR_ANTENNA_FIELD, "ELEMENT_OFFSET")[2] == off[2]
    c = joinpath(mktempdir(), "c"); copytable(c, ms)
    @test column(readtable(joinpath(c, "LOFAR_ANTENNA_FIELD")), "ELEMENT_OFFSET")[1] == off[1]
    s = joinpath(mktempdir(), "s.ms"); copyms(d, s; subtables=["LOFAR_ANTENNA_FIELD"])
    @test MSv2.subtablenames(MeasurementSet(s)) == ["LOFAR_ANTENNA_FIELD"]
    j = join(ms, ms.ANTENNA; on="ANTENNA1", rightcols=["NAME"])
    @test length(column(j, "NAME")[:]) == 2
    @test nrow(query(ms, "ANTENNA1 == 0")) == 1
end
