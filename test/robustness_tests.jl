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

# Phase 364: real-casacore tables created with random storage-manager SPEC parameters (bucket
# size / rows, cache sizes, tile shapes), filled by TaQL, then edited by us.  Found: a
# fixed-shape column bound to a tiled shape manager lost its FixedShape option bit (casacore
# writes option 4) whenever `edit` regenerated it (removerows!, ...), and our own uniform
# tiled columns were written with option 0 -- Casacore.jl then typed the column as 1-D.
@testset "tiled fixed-shape columns keep FixedShape (Phase 364)" begin
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["A" => [fill(Float64(i), 3) for i in 1:30], "B" => Int32.(1:30)]; nrow=30, tsm=[["A"]])
    @test MSv2.columndesc(readtable(d), "A").option == MSv2.COLOPT_FIXEDSHAPE
    edit(d) do e; MSv2.removerows!(e, [3, 4]); end
    @test MSv2.columndesc(readtable(d), "A").option == MSv2.COLOPT_FIXEDSHAPE
    @test column(readtable(d), "A")[3] == fill(5.0, 3)
    if _HAVE_TAQL
        @test size(CCT.Table(_rb_copy(d))[:A]) == (3, 28)
        d2 = joinpath(mktempdir(), "t")
        tc = _taql_create("CREATE TABLE $d2 [A R8 [SHAPE=[3]], B I4] LIMIT 30 DMINFO [TYPE=\"TiledShapeStMan\", NAME=\"T1\", SPEC=[DEFAULTTILESHAPE=[3,7]], COLUMNS=[\"A\"]]")
        CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
        _taqlcmd("UPDATE \$1 SET A = array(rownumber()*1.0, [3])", d2)
        @test MSv2.columndesc(readtable(d2), "A").option == MSv2.COLOPT_FIXEDSHAPE
        edit(d2) do e; MSv2.removerows!(e, [3, 4]); MSv2.addrows!(e, 2); end
        @test MSv2.columndesc(readtable(d2), "A").option == MSv2.COLOPT_FIXEDSHAPE
        cc = CCT.Table(_rb_copy(d2))[:A]
        @test size(cc) == (3, 30)
        @test [Array(cc[:, i]) for i in 1:5] == [fill(1.0, 3), fill(2.0, 3), fill(5.0, 3), fill(6.0, 3), fill(7.0, 3)]
    end
end

# Phase 369: column descriptions of casacore-made tables (shape, option, comment, keywords) are
# unchanged by our `edit` regeneration and `copytable`.  Found: a casacore-made fixed-shape
# SSM/ISM array column is stored INDIRECT (option 4); we rewrote it as direct (option 5).
@testset "column descriptions survive rewrites (Phase 369)" begin
    if _HAVE_TAQL
        rng = MSv2.Random.MersenneTwister(369)
        types = ["I2", "I4", "R4", "R8", "S", "B", "C8", "U1", "U2", "I8"]
        sig(t, c) = (cd = MSv2.columndesc(t, c); (cd.name, cd.type, cd.shape, cd.option, cd.comment, cd.keywords.names, cd.keywords.values))
        nbad = 0
        for _ in 1:12
            nc = rand(rng, 2:5); specs = String[]; names = String[]
            for i in 1:nc
                nm = "C$i"; push!(names, nm); opts = String[]; r = rand(rng)
                r < .3 ? push!(opts, "NDIM=$(rand(rng, 1:3))") : r < .6 ? push!(opts, "SHAPE=[" * join(rand(rng, 1:4, rand(rng, 1:3)), ",") * "]") : nothing
                rand(rng) < .3 && push!(opts, "UNIT=\"m\"")
                rand(rng) < .3 && push!(opts, "COMMENT=\"c$i\"")
                push!(specs, nm * " " * rand(rng, types) * (isempty(opts) ? "" : " [" * join(opts, ", ") * "]"))
            end
            dm = rand(rng, Bool) ? " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"IS\", COLUMNS=[\"C1\"]]" : ""
            d = joinpath(mktempdir(), "t")
            tc = _taql_create("CREATE TABLE $d [" * join(specs, ", ") * "] LIMIT $(rand(rng, 3:20))$dm")
            CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            s0 = [sig(readtable(d), c) for c in names]
            edit(d) do e; MSv2.removerows!(e, [2]); MSv2.addrows!(e, 1); end
            d2 = joinpath(mktempdir(), "c"); copytable(d2, readtable(d))
            nbad += count(c -> sig(readtable(d), c) != s0[findfirst(==(c), names)], names)
            nbad += count(c -> sig(readtable(d2), c) != s0[findfirst(==(c), names)], names)
        end
        @test nbad == 0
        # the data of a rewritten casacore-made indirect fixed-shape array still reads in casacore
        for ty in ("I4", "R8", "B", "C8"), dm in ("", " DMINFO [TYPE=\"IncrementalStMan\", NAME=\"IS\", COLUMNS=[\"X\"]]")
            d = joinpath(mktempdir(), "t")
            tc = _taql_create("CREATE TABLE $d [X $ty [SHAPE=[2,2]], K I4] LIMIT 20$dm")
            CCT.flush(tc); tc = nothing; GC.gc(); GC.gc()
            ex = ty == "B" ? "rownumber()%3==0" : ty == "C8" ? "complex(rownumber()*1.0, 2.0)" : "rownumber()"
            _taqlcmd("UPDATE \$1 SET X = array($ex, [2,2])", d)
            before = [Array(c) for c in column(readtable(d), "X")[:]]
            edit(d) do e; MSv2.removerows!(e, [2, 7]); end
            got = [Array(c) for c in column(readtable(d), "X")[:]]
            @test got == before[setdiff(1:20, [2, 7])]
            cc = CCT.Table(_rb_copy(d))[:X]; arr = cc[:, :, :]
            @test all(i -> vec(arr[:, :, i]) == vec(got[i]), 1:18)
        end
    end
end

# Phase 380: API misuse.  A fuzz of the Julia API with invalid arguments (out-of-range / non-integer / huge row numbers
# and counts, unknown columns, wrong value types) found: addrows!(t, 2^40) and create_ms(nrow=2^40) got the process
# killed (out of memory); copytable(rows=[out of range]) wrote a table with NO columns and only a warning;
# removerows!(Inf), assigning Inf / 1.5 / 3e9 to an Int32 cell, and insert! of a range into a scalar column surfaced as
# InexactError from the writer.  All are ordinary ArgumentErrors now.
@testset "API misuse raises ordinary errors (Phase 380)" begin
    N = 6
    mk() = (d = joinpath(mktempdir(), "t");
            write_table(d, "T", Pair{String,Any}["I" => Int32.(1:N), "S" => string.(1:N), "B" => isodd.(1:N)]; nrow=N); d)
    d = mk(); t = readtable(d)
    # copy rows must be integers within 1:nrow
    for rows in (Int[N + 1], [0], 1:N+3, -1:2, [1.5], "x")
        @test_throws ArgumentError copytable(joinpath(mktempdir(), "c"), t; rows)
    end
    @test MSv2.nrow(readtable(copytable(joinpath(mktempdir(), "c"), t; rows=[3, 3, 1]))) == 3
    @test MSv2.nrow(readtable(copytable(joinpath(mktempdir(), "c"), t; rows=Int[]))) == 0
    # absurd row counts are refused up front
    edit(d) do e
        @test_throws ArgumentError addrows!(e, 2^40)
        @test_throws ArgumentError addrows!(e, typemax(Int))
        @test_throws ArgumentError removerows!(e, [Inf])
        @test_throws ArgumentError removerows!(e, [NaN])
        @test_throws ArgumentError removerows!(e, ["1"])
        @test_throws ArgumentError e["I"][1] = Inf
        @test_throws ArgumentError e["I"][1] = 1.5
        @test_throws ArgumentError e["I"][1] = 3_000_000_000
        e["I"][1] = 7.0                                            # whole-valued floats are fine
        removerows!(e, [N])
    end
    @test column(readtable(d), "I")[:] == Int32[7, 2, 3, 4, 5] && MSv2.nrow(readtable(d)) == N - 1
    for kw in ((nrow=2^40,), (nrow=-1,), (nchan=0,), (ncorr=0,), (nant=-2,), (nchan=2^40,))
        p = joinpath(mktempdir(), "ms")
        @test_throws ArgumentError create_ms(p; kw...)
        @test !ispath(p)
    end
    # insert! of a non-scalar / unconvertible value into a scalar column
    d = mk()
    @test_throws ArgumentError insert!(d; values=["I" => 1:3])
    @test_throws ArgumentError insert!(d; values=["B" => typemin(Int)])
    @test_throws ArgumentError insert!(d; values=["S" => 5])
    @test MSv2.nrow(readtable(d)) == N                          # nothing was added
end

# Phase 384: the query verbs (query/groupby/join/update!/delete!/insert!) given a column name,
# expression or collection of the wrong Julia type raise an ArgumentError naming the argument
# (was a MethodError from a `String(x)` deep inside); a string into a numeric column and a
# number into a String column are refused where assigned (was a MethodError at flush).
@testset "query verbs refuse wrongly-typed arguments (Phase 384)" begin
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["I" => collect(1:4), "K" => Int32[1, 1, 2, 2], "X" => [1.5, 2.5, 3.5, 4.5], "S" => ["a", "b", "c", "d"]]; nrow=4)
    t = readtable(d)
    # groupby: keys, select, where/having, orderby, cols, grouping sets
    for g in (3, nothing, missing, (1, 2), ["I" => "K"], x -> x)
        @test_throws ArgumentError groupby(t, g; select=["n" => "gcount()"])
    end
    @test_throws ArgumentError groupby(t, "K"; select=["n" => 3])
    @test_throws ArgumentError groupby(t, "K"; select=["n" => nothing])
    @test_throws ArgumentError groupby(t, "K"; select=[3 => "gcount()"])
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], where=5)
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], where=:I)
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], having=3)
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], orderby=[3])
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], orderby=[(1, 2) => :desc])
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], grouping_sets=x -> x)
    @test_throws ArgumentError groupby(t, "K"; select=["n" => "gcount()"], grouping_sets=[3])
    @test groupby(t, "K"; cols="X") do g; (; n=length(g)); end.n == [2, 2]       # a single name for `cols`
    # query: select entries, orderby entries
    @test_throws ArgumentError query(t, "I > 1"; select=["a" => 3])
    @test_throws ArgumentError query(t, "I > 1"; select=[3 => "I"])
    @test_throws ArgumentError query(t, "I > 1"; select=[("a", 3) => "I"])
    @test_throws ArgumentError query(t; orderby=[3]) do r; true; end
    @test_throws ArgumentError query(t; cols=[(1, 2) => "I"]) do r; true; end
    # join: column selectors, output names
    @test_throws ArgumentError join(t, t; on="I", rightcols=[3])
    @test_throws ArgumentError join(t, t; on="I", rightcols=[("I", "K") => "X"])
    # update! / delete! / insert!
    @test_throws ArgumentError MSv2.update!(d; set=["X" => 3.0])
    @test_throws ArgumentError MSv2.update!(d; set=["X" => ["I", "K"]])
    @test_throws ArgumentError MSv2.update!(d; set=[3 => "I"])
    @test_throws ArgumentError MSv2.update!(d; set=["X" => "I"], where=5)
    @test_throws ArgumentError MSv2.update!(d; set=["X" => "I"], where=["I"])
    @test_throws ArgumentError delete!(d; where=5)
    @test_throws ArgumentError delete!(d; where=["I > 1"])
    @test_throws ArgumentError delete!(d; where="I > 99", orderby=[3])
    @test_throws ArgumentError insert!(d; values=[3 => 1])
    @test_throws ArgumentError insert!(d; values=[("a", "b") => 1])
    # a string into a numeric column / a number into a String column
    @test_throws ArgumentError MSv2.update!(d; set=["X" => "S"])
    @test_throws ArgumentError MSv2.update!(d; set=["I" => "S"])
    @test_throws ArgumentError MSv2.update!(d; set=["S" => "I"])
    @test_throws ArgumentError insert!(d; values=["X" => "s"])
    edit(d) do e
        @test_throws ArgumentError e["X"][1] = "s"
        @test_throws ArgumentError e["S"][1] = 5
        @test_throws ArgumentError e["I"][1] = "5"
    end
    # nothing above changed the table; ordinary writes still work
    @test column(readtable(d), "X")[:] == [1.5, 2.5, 3.5, 4.5] && MSv2.nrow(readtable(d)) == 4
    @test MSv2.update!(d; set=["X" => "I * 2.0"], where="I > 2") == 2
    @test column(readtable(d), "X")[:] == [1.5, 2.5, 6.0, 8.0]
end

# Phase 388: unusual column names (non-ASCII, spaces, dots, quotes, brackets, colons, percent, emoji)
# survive the whole pipeline -- write, read, real casacore, copytable, edit, addcolumn!, rename,
# and TaQL via backslash escapes -- a fuzz of ~800 random names found no bug; kept as a fixed list.
@testset "unusual column names (Phase 388)" begin
    names = ["é", "日本", "a b", "a.b", "a-b", "x:y", "q'r", "ü(1)", "🚀", "A\"B", "p%q", "a[1]", "_u", "a,b", "c=d", "e<f>", "h\\i", "j*k"]
    N = 4
    d = joinpath(mktempdir(), "t")
    cols = Pair{String,Any}[nm => (isodd(j) ? collect(1:N) .* j : Float64.(1:N) ./ j) for (j, nm) in enumerate(names)]
    write_table(d, "T", cols; nrow=N)
    t = readtable(d)
    @test columnnames(t) == names
    for (nm, v) in cols
        @test collect(column(t, nm)[:]) == v
    end
    if _HAVE_CASACORE
        ct = CCT.Table(d)
        for (nm, v) in cols
            @test collect(ct[Symbol(nm)][:]) == v
        end
    end
    c = joinpath(mktempdir(), "c")
    copytable(c, t)
    @test columnnames(readtable(c)) == names
    edit(d) do e
        e[names[1]][1] = 77
        addcolumn!(e, "new col.é", collect(1:N))
    end
    @test column(readtable(d), names[1])[1] == 77 && "new col.é" in columnnames(readtable(d))
    MSv2.renamecolumn!(d, "a b", "a  b ü")
    @test "a  b ü" in columnnames(readtable(d)) && !("a b" in columnnames(readtable(d)))
    t = readtable(d)
    esc(s) = replace(s, r"([^\w])" => s"\\\1")
    for nm in columnnames(t)
        r = query(t, "rownumber() >= 1"; select=["x" => esc(nm)])
        @test collect(column(r, "x")[:]) == collect(column(t, nm)[:])
    end
    @test MSv2.update!(d; set=[esc("é") => esc("é") * " * 2"], where="rownumber() > 1") == N - 1
    @test column(readtable(d), "é")[2:end] == (2:N) .* 2
end
