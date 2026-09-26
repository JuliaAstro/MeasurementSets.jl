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
