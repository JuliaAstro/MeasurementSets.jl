# Phase 270: strings and tables edited by real casacore -- a sweep that found no bug, kept as
# regression tests.  Non-ASCII / long / empty strings round-trip through every string layout
# (scalar, fixed and variable arrays; StandardStMan and IncrementalStMan; both byte orders) and
# read identically in casacore (an embedded NUL is truncated by Casacore.jl's C-string
# conversion, so it is checked ours-only).  Tables that real casacore has fragmented by
# inserting, updating and deleting rows (SSM bucket splits / free lists, ISM run breaks, tiled
# hypercubes of several shapes) read the same in both, and survive our own `edit`.

_rb_copy(d) = (p = d * "_c" * string(rand(UInt16)); cp(d, p); p)

@testset "non-ASCII, long and empty strings (Phase 270)" begin
    strs = ["héllo", "日本語", "🚀x", "", "a\nb\tc", "x"^100, "é"^5000, "long"^40000, "trailing "]
    N = length(strs)
    nul = "nul\0mid"
    for (mn, kw) in ((:ssm, (;)), (:ism, (; ism=["X"]))), sh in (:scalar, :fixed, :var), endian in (:little, :big)
        col = sh === :scalar ? [strs; nul] :
              sh === :fixed ? [reshape([strs[mod1(i + k, N)] for k in 1:4], 2, 2) for i in 1:N] :
              [[strs[mod1(i + k, N)] for k in 1:(i % 3 + 1)] for i in 1:N]
        dir = joinpath(mktempdir(), "t")
        write_table(dir, "T", Pair{String,Any}["X" => col]; nrow=length(col), endian, kw...)
        got = column(readtable(dir), "X")[:]
        @test all(i -> got[i] == col[i], eachindex(col))
        if _HAVE_CASACORE
            cc = CCT.Table(dir)[:X]
            ok = sh === :scalar ? all(i -> cc[i] == strs[i], 1:N) :
                 sh === :var ? all(i -> vec(collect(cc[i])) == col[i], 1:N) :
                 all(i -> vec(collect(cc[:, :, i])) == vec(col[i]), 1:N)
            @test ok
        end
    end
    d = joinpath(mktempdir(), "k")
    write_table(d, "T", Pair{String,Any}["Ünï" => [1.0]]; nrow=1, readme="réadme\n日本",
                keywords=Dict{String,Any}("ключ" => "значение", "k2" => ["日本", "é"], "rec" => Dict("ñ" => "ü")))
    t = readtable(d)
    @test MSv2.columnnames(t) == ["Ünï"] && MSv2.keywords(t)["ключ"] == "значение"
    @test MSv2.keywords(t)["k2"] == ["日本", "é"] && MSv2.keywords(t)["rec"]["ñ"] == "ü" && t.readme == "réadme\n日本"
end

@testset "tables fragmented by real casacore (Phase 270)" begin
    if _HAVE_TAQL
        for mgr in ("ssm", "ism")
            d = joinpath(mktempdir(), "t")
            md = mgr == "ssm" ? "" : " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"ISM\", COLUMNS=[\"I\",\"R\",\"S\",\"V\"]]"
            tc = _taql_create("CREATE TABLE $d [I I4, R R8, S S, V R4 [NDIM=1]] LIMIT 3000$md"); CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            _taqlcmd("UPDATE \$1 SET I = rownumber(), R = rownumber()*0.5, S = string(rownumber()) + 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'", d)
            _taqlcmd("UPDATE \$1 SET V = array(rownumber()*1.0, [rownumber()%7+1])", d)
            _taqlcmd("DELETE FROM \$1 WHERE I % 3 == 0", d)
            _taqlcmd("INSERT INTO \$1 (I, R, S) VALUES (-1, -1.5, 'inserted')", d)
            _taqlcmd("UPDATE \$1 SET S = 'changed-to-a-much-longer-string-than-before-0123456789' WHERE I % 5 == 0", d)
            _taqlcmd("DELETE FROM \$1 WHERE I % 11 == 0", d)
            _taqlcmd("INSERT INTO \$1 (I, R, S, V) VALUES (-2, -2.5, 'ins2', [1.0,2.0,3.0])", d)
            t = readtable(d); n = MSv2.nrow(t)
            cc = CCT.Table(_rb_copy(d))
            @test n == size(cc, 1)
            @test column(t, "I")[:] == cc[:I][:] && column(t, "R")[:] == cc[:R][:] && column(t, "S")[:] == cc[:S][:]
            @test all(i -> vec(column(t, "V")[i]) == vec(cc[:V][i]), 1:n)
            edit(d) do e
                MSv2.removerows!(e, [1, 5, 100]); MSv2.addrows!(e, 2)
                e["I"][n - 2] = 777; e["S"][n - 2] = "ours-é"; e["V"][n - 2] = [9.0, 8.0]; e["I"][7] = 555
            end
            t2 = readtable(d); c2 = CCT.Table(_rb_copy(d))
            @test MSv2.nrow(t2) == n - 1 == size(c2, 1)
            @test column(t2, "I")[:] == c2[:I][:] && column(t2, "S")[:] == c2[:S][:]
            @test column(t2, "I")[7] == 555 && column(t2, "S")[n - 2] == "ours-é"
        end
        for (dm, var) in (("TiledShapeStMan", true), ("TiledShapeStMan", false), ("TiledColumnStMan", false))
            d = joinpath(mktempdir(), "t")
            spec = dm == "TiledColumnStMan" ? "TILESHAPE=[3,2,50]" : "DEFAULTTILESHAPE=[3,2,50]"
            tc = _taql_create("CREATE TABLE $d [X R8 $(var ? "[NDIM=2]" : "[SHAPE=[3,2]]"), I I4] LIMIT 500 DMINFO [TYPE=\"$dm\", NAME=\"T\", SPEC=[$spec], COLUMNS=[\"X\"]]")
            CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            _taqlcmd("UPDATE \$1 SET I = rownumber()", d)
            _taqlcmd("UPDATE \$1 SET X = " * (var ? "array(rownumber()*1.0, [rownumber()%3+2, 2])" : "array(rownumber()*1.0, [3,2])"), d)
            for k in 1:3
                _taqlcmd("INSERT INTO \$1 (I, X) VALUES ($k, array(0.5, [" * (var ? "2,2" : "3,2") * "]))", d)
            end
            t = readtable(d); n = MSv2.nrow(t); x = column(t, "X")[:]
            cc = CCT.Table(_rb_copy(d))
            @test n == 503 == size(cc, 1) && column(t, "I")[:] == cc[:I][:]
            var || @test all(i -> x[i] == cc[:X][:, :, i], 1:n)
            var && @test length(unique(size.(x))) == 3
            edit(d) do e
                MSv2.addrows!(e, 1); e["I"][n + 1] = 99; e["X"][n + 1] = ones(var ? (2, 2) : (3, 2)); e["X"][5] = fill(7.0, size(x[5]))
            end
            t2 = readtable(d)
            @test MSv2.nrow(t2) == 504 == size(CCT.Table(_rb_copy(d)), 1)
            @test column(t2, "X")[5] == fill(7.0, size(x[5])) && column(t2, "I")[:] == CCT.Table(_rb_copy(d))[:I][:]
        end
    end
end
