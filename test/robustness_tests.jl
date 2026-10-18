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


# Multi-threaded Julia does not run reliably under Rosetta, which is what an x86-64 Docker container on an Apple-silicon
# host uses (`/proc/cpuinfo` says `VirtualApple`): plain Julia code -- tasks that mmap a file, compile a Regex and allocate,
# no MeasurementSets code at all -- segfaults there with `-t 2` and more.  The thread-safety tests below are skipped
# in that environment (they run on real hardware and in CI).
_threads_usable() = !(Sys.islinux() && isfile("/proc/cpuinfo") && occursin("VirtualApple", read("/proc/cpuinfo", String)))

# Phase 392: reading the same table from many tasks at once.  `_DM_CACHE` (the opened data managers) and
# the tiled managers' lazily filled caches were plain Dicts mutated on first access, so two tasks racing to
# open the first column of a fresh table could corrupt them -- a segfault or UndefRefError under `julia -t N`
# (about one run in two at 8 threads).  The child runs with 4 threads and compares every value with the serial read.
@testset "concurrent reads of one table from many tasks (Phase 392)" begin
  if !_threads_usable()
    @info "skipping: multi-threaded Julia is unreliable under Rosetta emulation (an x86-64 container on Apple silicon)"
  else
    child = joinpath(@__DIR__, "threads_child.jl")
    out = IOBuffer()
    r = run(pipeline(ignorestatus(`$(Base.julia_cmd()) -t 4 --project=$(dirname(@__DIR__)) --startup-file=no $child 30`); stdout=out, stderr=out))
    @test r.exitcode == 0
    @test occursin("ALL OK", String(take!(out)))
  end
end

# Phase 393: parallel TaQL-lite queries.  The `regex()` / `pattern()` / `sqlpattern()` compile cache was a plain
# global Dict, so tasks evaluating queries at the same time corrupted it ("Multiple concurrent writes to Dict",
# UndefRefError -- 5 runs out of 5 at 8 threads); it is now locked, as is the one-time IERS table refresh.
@testset "parallel TaQL-lite queries (Phase 393)" begin
  if !_threads_usable()
    @info "skipping: multi-threaded Julia is unreliable under Rosetta emulation (an x86-64 container on Apple silicon)"
  else
    child = joinpath(@__DIR__, "threads_query_child.jl")
    out = IOBuffer()
    r = run(pipeline(ignorestatus(`$(Base.julia_cmd()) -t 4 --project=$(dirname(@__DIR__)) --startup-file=no $child`); stdout=out, stderr=out))
    @test r.exitcode == 0
    @test occursin("ALL OK", String(take!(out)))
  end
end

# Phase 429: the caches added in Phases 417-428 (the per-table `Column` cache and its eviction, the SOFA astrometry
# context cache -- more frames than it holds, so it is cleared while other tasks use it -- and the compiled aggregate
# arguments) under 16 tasks at once.  The aggregate cache was a global `WeakKeyDict` keyed by the column dictionary and
# threw `KeyError`s in 3 runs out of 3 at 8 threads; it now lives on the aggregate node.
@testset "parallel use of the Phase 417-428 caches (Phase 429)" begin
  if !_threads_usable()
    @info "skipping: multi-threaded Julia is unreliable under Rosetta emulation (an x86-64 container on Apple silicon)"
  else
    child = joinpath(@__DIR__, "threads_cache_child.jl")
    out = IOBuffer()
    r = run(pipeline(ignorestatus(`$(Base.julia_cmd()) -t 4 --project=$(dirname(@__DIR__)) --startup-file=no $child 3`); stdout=out, stderr=out))
    @test r.exitcode == 0
    @test occursin("ALL OK", String(take!(out)))
  end
  # the compiled aggregate argument is kept on the node and follows the column dictionary it was compiled against
  n = 3000; d = joinpath(mktempdir(), "t")
  write_table(d, "T", Pair{String,Any}["K" => Int32.(1 .+ (0:n-1) .% 3), "B" => Float64.(1:n)]; nrow = n)
  ast = MeasurementSets._taqllite_parse("gsum(B*2.0)", Set(["K", "B"]))
  c1 = Dict{String,AbstractVector}("K" => Int32.(1 .+ (0:n-1) .% 3), "B" => Float64.(1:n))
  c2 = Dict{String,AbstractVector}("K" => Int32.(1 .+ (0:n-1) .% 3), "B" => Float64.(n:-1:1) .* 10)
  g = collect(1:3:n)
  @test MeasurementSets._geval(ast, c1, g) == sum(2.0 .* c1["B"][g])
  @test MeasurementSets._geval(ast, c2, g) == sum(2.0 .* c2["B"][g])      # other columns -> recompiled, not stale
  @test MeasurementSets._geval(ast, c1, g) == sum(2.0 .* c1["B"][g])
end

# Phase 394: a table that is no longer referenced is garbage collected.  The opened data managers (with their
# mmaps and whole-file buffers) were kept in a global `IdDict{Table,...}`, so every table ever read -- and
# everything it had opened -- stayed alive for the life of the process (2000 opens leaked 1.6 GB).  The cache
# now lives on the `Table` itself.
@testset "an unreferenced table is garbage collected (Phase 394)" begin
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["I" => collect(1:300), "S" => ["s$i" for i in 1:300], "V" => [rand(Float32, 8) for _ in 1:300]]; nrow=300)
    function open_and_read()
        t = readtable(d)
        collect(column(t, "I")[:]); getcell(t, "V", 3); getcell(t, "S", 4)
        @test length(t.dmcache) == 1                       # one SSM instance serves all three columns
        return WeakRef(t)
    end
    refs = [open_and_read() for _ in 1:20]
    GC.gc(); GC.gc(); GC.gc()
    @test count(r -> r.value === nothing, refs) >= 19      # (the most recent may still sit in a register / slot)
    # resync drops the old table's managers; the new table opens its own
    t = readtable(d); column(t, "I")[1]; @test !isempty(t.dmcache)
    MSv2._evict_dms!(t); @test isempty(t.dmcache) && column(t, "I")[2] == 2 && !isempty(t.dmcache)
end

# Phase 395: nothing accumulates over many tables -- no lock-registry entries, no open file descriptors
# (written / read / edited / copied tables, separate files and MultiFile containers).  A sweep for leaks
# (descriptors, lock registry, HDF5 files, memory per table kind and operation) found none beyond Phase 394's.
@testset "no descriptors or lock entries accumulate over many tables (Phase 395)" begin
    nfd() = isdir("/dev/fd") ? length(readdir("/dev/fd")) : -1
    base = mktempdir()
    function churn(n, tag, storage)
        for i in 1:n
            d = joinpath(base, "$(tag)_$i")
            write_table(d, "T", Pair{String,Any}["I" => collect(1:20), "V" => [rand(Float32, 4) for _ in 1:20]]; nrow=20, storage)
            t = readtable(d); collect(column(t, "I")[:]); getcell(t, "V", 3)
            storage === :sepfile && edit(d) do e; e["I"][1] = 5; end
            copytable(joinpath(base, "c_$(tag)_$i"), t)
        end
    end
    churn(5, "w", :sepfile); churn(5, "m", :multifile); GC.gc(); GC.gc()          # warm up
    f0 = nfd()
    churn(60, "a", :sepfile); churn(60, "b", :multifile); GC.gc(); GC.gc()
    @test isempty(MSv2._HELD_LOCKS)
    f0 < 0 || @test nfd() <= f0 + 4
end

# Phase 399: failures found by static analysis (JET), a mutation fuzz of `taql()` and a stale-handle race.
@testset "arrays into scalar columns, cross-task flush, stale handles, insert! keywords (Phase 399)" begin
    mk(d, n=5) = write_table(d, "T", Pair{String,Any}["S" => ["s$i" for i in 1:n], "K" => Int32.(1:n), "X" => Float64.(1:n)]; nrow=n)
    d = joinpath(mktempdir(), "t"); mk(d)
    # an array into a scalar column: refused at the assignment (it used to fail at flush with a MethodError,
    # or be silently reduced), and the table is untouched
    for cmd in ("UPDATE \$1 SET S=['u','v'], K=7", "UPDATE \$1 SET K=[1,2]", "UPDATE \$1 SET X=['a']", "UPDATE \$1 SET S=[1,2]")
        err = try taql(d, cmd); nothing catch e; e end
        @test err isa ArgumentError && occursin("holds scalar cells", sprint(showerror, err))
    end
    @test column(readtable(d), "K")[:] == Int32.(1:5) && column(readtable(d), "S")[1] == "s1"
    err = try edit(d) do t; t[:K][1] = [1, 2]; end; nothing catch e; e end
    @test err isa ArgumentError
    @test isempty(MSv2._HELD_LOCKS)

    # an edit session belongs to the task that opened it: another task flushing it is refused up front
    # (it used to commit, then fail to unlock and leave the table locked for the rest of the process)
    t = edit(d)
    t[:K][2] = Int32(22)
    err = fetch(@async try flush(t); nothing catch e; e end)
    @test err isa ErrorException && occursin("flushed by the task that opened it", err.msg)
    flush(t)                                                    # the opening task can
    @test column(readtable(d), "K")[2] == 22
    @test isempty(MSv2._HELD_LOCKS)
    edit(d) do t2; t2[:K][3] = Int32(33); end                   # and the table is not left locked
    @test column(readtable(d), "K")[3] == 33

    # a table opened before another writer commits fails loudly, saying so, when read afterwards
    stale = readtable(d)
    edit(d) do t3; addrows!(t3, 2); end
    err = try column(stale, "S")[:]; nothing catch e; e end
    @test err isa ErrorException && occursin("modified after it was opened", err.msg)
    @test length(column(readtable(d), "S")[:]) == 7                    # a fresh handle reads the new table

    # insert!(target, source; keywords...) passes the keywords on
    src = joinpath(dirname(d), "src"); mk(src, 3)
    @test insert!(d, readtable(src); limit=2) == 2
    @test length(column(readtable(d), "S")[:]) == 9
    # a sub-query must return rows
    err = try taql(d, "SELECT K FROM \$1 WHERE K IN (SELECT K INTO '$(joinpath(dirname(d), "o"))')"); nothing catch e; e end
    @test err isa ArgumentError
end

# Phase 401: the element types a user's data actually has (DataFrames / CSV columns are `Union{T,Missing}`).
@testset "Union{T,Missing} columns and unsupported element types (Phase 401)" begin
    N = 6
    rt(v) = (d = joinpath(mktempdir(), "t"); write_table(d, "T", Pair{String,Any}["C" => v]; nrow=N); column(readtable(d), "C")[:])
    # nothing missing: stored as T
    for (v, T) in ((Union{Float64,Missing}[1, 2, 3, 4, 5, 6], Float64), (Union{Int32,Missing}[1, 2, 3, 4, 5, 6], Int32),
                   (Union{String,Missing}["a", "b", "c", "d", "e", "f"], String), (Union{Bool,Missing}[true, false, true, false, true, false], Bool))
        got = rt(v)
        @test eltype(got) == T && isequal(got, collect(nonmissingtype(eltype(v)), v))
    end
    # array cells with a Union element type
    cells = [Union{Float64,Missing}[i, i + 1] for i in 1:N]
    @test [collect(c) for c in rt(cells)] == [Float64[i, i + 1] for i in 1:N]
    cells[3][2] = missing
    err = try rt(cells); nothing catch e; e end
    @test err isa ArgumentError && occursin("row 3 has a missing element", err.msg)
    # a missing value: an error naming the row, for every entry point
    err = try rt(Union{Float64,Missing}[1, missing, 3, 4, 5, missing]); nothing catch e; e end
    @test err isa ArgumentError && occursin("row 2; 2 in all", err.msg) && occursin("write_table", err.msg)
    d = joinpath(mktempdir(), "t"); write_table(d, "T", Pair{String,Any}["A" => Int32.(1:4), "S" => ["a", "b", "c", "d"]]; nrow=4)
    edit(d) do t; addcolumn!(t, "B", Union{Float64,Missing}[1.0, 2, 3, 4]); end
    @test column(readtable(d), "B")[:] == [1.0, 2, 3, 4]
    err = try edit(d) do t; addcolumn!(t, "C", Union{Float64,Missing}[1.0, missing, 3, 4]); end; nothing catch e; e end
    @test err isa ArgumentError && occursin("addcolumn!", err.msg) && occursin("row 2", err.msg)
    for f in (t -> (t[:A][1] = missing), t -> (t[:S][1] = missing), t -> (t[:A][:] = Union{Int32,Missing}[1, missing, 3, 4]))
        err = try edit(f, d); nothing catch e; e end
        @test err isa ArgumentError && occursin("missing", err.msg)
    end
    @test column(readtable(d), "A")[:] == Int32.(1:4)
    err = try insert!(d; values=["A" => missing, "S" => "z"]); nothing catch e; e end
    @test err isa ArgumentError && occursin("missing value", err.msg)
    @test MSv2.nrow(readtable(d)) == 4
    # unsupported types: the message names the type and what to convert it to
    for (v, hint) in ((Int8.(1:N), "Int16"), (UInt64.(1:N), "Int64"), ([:a, :b, :c, :d, :e, :f], "String.(x)"), (collect("abcdef"), "String.(x)"),
                      ([MSv2.Dates.Date(2020, 1, i) for i in 1:N], "MEpoch"), ([1 // i for i in 1:N], "Float64"), ([(1.0, 2.0) for _ in 1:N], "array per row"))
        err = try rt(v); nothing catch e; e end
        @test err isa ErrorException && occursin("cannot store a column of element type", err.msg) && occursin(hint, err.msg)
    end
end

# Phase 402: tables from every kind of Tables.jl source; names casacore cannot hold.
import Tables
@testset "write_table sources and column names (Phase 402)" begin
    N = 5
    rows = [(A=Int32(i), B=Float64(i) / 2, S="s$i") for i in 1:N]
    wr(src; kw...) = (d = joinpath(mktempdir(), "t"); write_table(d, "T", src; kw...); readtable(d))
    # a row table (Vector{NamedTuple}) used to be written with NO columns and no error
    for src in (rows, Tables.columntable(rows), Tables.rowtable(rows), Tables.rowtable(Tables.columntable(rows)))
        t = wr(src)
        @test columnnames(t) == ["A", "B", "S"] && nrow(t) == N
        @test column(t, "A")[:] == Int32.(1:N) && column(t, "S")[:] == ["s$i" for i in 1:N]
    end
    @test columnnames(wr(Tables.table(rand(N, 3); header=[:X, :Y, :Z]))) == ["X", "Y", "Z"]
    # nrow is the first column's length unless a table has no columns
    @test nrow(wr(Dict("A" => Int32.(1:N)))) == N
    @test nrow(wr([:A => Int32.(1:3), :B => rand(3)])) == 3
    @test nrow(wr((A=Int32[], B=Float64[]))) == 0
    @test nrow(wr(NamedTuple(); nrow=0)) == 0
    for bad in (() -> wr(NamedTuple()), () -> wr(Dict("A" => 1:3, "B" => 1:4)))
        @test_throws Union{ArgumentError,ErrorException} bad()
    end
    @test_throws ArgumentError wr([:A => Int32.(1:N), :A => Int32.(1:N)])        # duplicate names were written as two columns
    @test_throws ArgumentError wr(Tables.partitioner([rows[1:2], rows[3:5]]))   # not a table: say so
    # an empty column name made both readers return another column's data
    for f in (() -> wr(["" => Int32.(1:N)]), )
        @test_throws ArgumentError f()
    end
    d = joinpath(mktempdir(), "t"); write_table(d, "T", ["A" => Int32.(1:N)])
    @test_throws ArgumentError edit(t -> addcolumn!(t, "", Float64.(1:N)), d)
    @test_throws ArgumentError edit(t -> addcolumn!(t, ""), d)
    @test_throws ArgumentError renamecolumn!(d, "A", "")
    @test columnnames(readtable(d)) == ["A"]
end

@testset "Phase 405 — opening / overwriting something that is not (or already is) a table" begin
    d = mktempdir()
    mkpath(joinpath(d, "empty"))
    for f in (readtable, MeasurementSets.MeasurementSet, p -> edit(identity, p))
        @test_throws ArgumentError f(joinpath(d, "empty"))
        @test_throws ArgumentError f(joinpath(d, "nope"))
    end
    # a directory the user created first is fine; an existing table is not overwritten
    write_table(joinpath(d, "empty"), "T", ["A" => [1, 2]]; nrow = 2)
    @test column(readtable(joinpath(d, "empty")), "A")[:] == [1, 2]
    @test_throws ErrorException write_table(joinpath(d, "empty"), "T", ["A" => [9]]; nrow = 1)
    @test column(readtable(joinpath(d, "empty")), "A")[:] == [1, 2]
end
