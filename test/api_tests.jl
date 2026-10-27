# Phase 5: lazy Column type + indexing sugar.

@testset "Column API" begin
    t = readtable(SAMPLE_MS; precision=:full)   # exact eltype / value checks below

    tc = column(t, "TIME")
    @test tc isa AbstractVector{Float64}
    @test length(tc) == nrow(t)
    @test size(tc) == (nrow(t),)
    @test tc[1] == getcell(t, "TIME", 1)
    @test tc[3:6] == [getcell(t, "TIME", i) for i in 3:6]
    @test tc[:] == getcolumn(t, "TIME")
    @test collect(tc) == tc[:]
    @test_throws BoundsError tc[nrow(t) + 1]

    # indexing sugar returns a Column, not a description
    @test t[:TIME] isa Column
    @test t["TIME"] isa Column
    @test eltype(t[:UVW]) == Vector{Float64}
    @test size(t[:UVW][7]) == (3,)

    d = column(t, "DATA")
    @test eltype(d) == Matrix{ComplexF32}
    @test size(d[42]) == (4, 64)

    ms = MeasurementSet(SAMPLE_MS; precision=:full)
    @test ms[:DATA][10] == d[10]
    @test ms["ANTENNA1"][100] == column(t, "ANTENNA1")[100]

    # spot cross-check per storage manager (SSM / TSM / ISM)
    if _HAVE_CASACORE
        ct = CCT.Table(SAMPLE_MS)
        @test column(t, "ANTENNA1")[500] == ct[:ANTENNA1][500]        # SSM
        @test column(t, "TIME")[500] == ct[:TIME][500]                # ISM
        @test column(t, "UVW")[500] == collect(ct[:UVW][:, 500])      # TSM
    end
end

# Phase 374: a `MeasurementSet` acts as its MAIN table for the table verbs (it used to support only
# `ms[:COL]` / `ms.SUBTABLE` / Tables.jl).
@testset "MeasurementSet acts as its MAIN table (Phase 374)" begin
    ms = MeasurementSet(SAMPLE_MS); t = readtable(SAMPLE_MS)
    @test MSv2.nrow(ms) == MSv2.nrow(t) && MSv2.columnnames(ms) == MSv2.columnnames(t)
    @test MSv2.columndesc(ms, "TIME").name == "TIME" && MSv2.keywords(ms).names == MSv2.keywords(t).names
    @test length(subtables(ms)) == length(subtables(t))
    @test column(ms, "TIME")[:] == column(t, "TIME")[:] && getcolumn(ms, "ANTENNA1") == getcolumn(t, "ANTENNA1")
    @test getcell(ms, "TIME", 3) == getcell(t, "TIME", 3)
    # the existing subtable forms are unchanged
    @test length(column(ms, "ANTENNA", "NAME")) == MSv2.nrow(subtable(ms, "ANTENNA"))
    @test getcell(ms, "ANTENNA", "NAME", 1) == getcell(subtable(ms, "ANTENNA"), "NAME", 1)
    @test MSv2.nrow(query(ms, "ANTENNA1 == 0")) == MSv2.nrow(query(t, "ANTENNA1 == 0"))
    @test MSv2.nrow(query(r -> r.ANTENNA1 == 0, ms; cols=["ANTENNA1"])) == MSv2.nrow(query(t, "ANTENNA1 == 0"))
    g = groupby(ms, "ANTENNA1"; select=["A" => :ANTENNA1, "N" => "gcount()"])
    @test sum(column(g, "N")[:]) == MSv2.nrow(t)
    @test groupby(ms, "ANTENNA1") do g; (; N = length(g)); end isa GroupedTable
    j = join(ms, subtable(ms, "ANTENNA"); on="ANTENNA1", rightcols=["NAME"])
    @test MSv2.nrow(j) == MSv2.nrow(t)
    @test MSv2.measinfo(ms, "TIME").kind === :epoch && size(MSv2.rawblock(ms, "UVW"), 1) == 3
    d = joinpath(mktempdir(), "c.ms"); copyms(SAMPLE_MS, d; rows=1:40)
    c = MeasurementSet(d)
    d2 = joinpath(mktempdir(), "t"); copytable(d2, c); @test MSv2.nrow(readtable(d2)) == 40
    r = joinpath(mktempdir(), "r"); write_reftable(r, c, [1, 5]); @test MSv2.nrow(readtable(r)) == 2
    @test MSv2.update!(c; set=["EXPOSURE" => "EXPOSURE + 1"], where="ANTENNA1 == 0") > 0
    @test taql(c, "UPDATE t SET SCAN_NUMBER = 7 WHERE ANTENNA1 == 0") > 0
    edit(c) do e; e["FIELD_ID"][1] = 0; end
    edit(c) do e; MSv2.removerows!(e, [1, 2]); end
    @test MSv2.nrow(readtable(d)) == 38 && MSv2.nrow(MeasurementSet(d)) == 38
    n0 = MSv2.nrow(readtable(d))
    @test MSv2.insert!(c; values=["SCAN_NUMBER" => 9]) == 1 && MSv2.nrow(readtable(d)) == n0 + 1
    @test MSv2.delete!(c; where="ANTENNA1 == 0") > 0
    @test MSv2.nrow(taql(MeasurementSet(d), "SELECT TIME WHERE ANTENNA1 == 1")) > 0
end

# Phase 389: a column is an AbstractVector -- indexing with a Bool mask selects the `true` rows, like
# any Vector (Bool <: Integer, so `col[mask]` used to index by `true` / `false` and fail).  The
# contract (ranges, vectors, masks, `end`, iteration, views) also holds for every column kind.
@testset "columns obey the AbstractVector indexing contract (Phase 389)" begin
    N = 12
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["I" => collect(1:N), "S" => ["s$i" for i in 1:N], "V" => [Float32[i, 2i] for i in 1:N]]; nrow=N)
    d2 = joinpath(mktempdir(), "t2")
    write_table(d2, "T", Pair{String,Any}["I" => collect(101:100+N), "S" => ["u$i" for i in 1:N], "V" => [Float32[-i, 0] for i in 1:N]]; nrow=N)
    t = readtable(d)
    cd = joinpath(mktempdir(), "c"); MSv2.write_concattable(cd, [t, readtable(d2)])
    views = (t, query(t, "I % 2 == 1"), query(t, "I > 0 ORDER BY I DESC"), readtable(cd), MSv2.MeasurementSet(joinpath(@__DIR__, "data", "sample.ms")))
    mask(L) = [isodd(i * i + 1) for i in 1:L]
    for v in views, nm in (v === views[end] ? ("ANTENNA1", "TIME") : ("I", "S", "V"))
        col = column(v, nm); full = collect(col[:]); L = length(col)
        m = mask(L)
        @test isequal(collect(col[m]), full[m])
        @test isequal(collect(col[BitVector(m)]), full[m])
        @test isequal(collect(col[findall(m)]), full[m])
        @test isequal(collect(col[2:3:L]), full[2:3:L]) && isequal(collect(col[[L, 1, 2]]), full[[L, 1, 2]])
        @test isequal(col[end], full[end]) && isequal(collect(col), full)
        @test_throws BoundsError col[trues(L + 1)]
        @test isempty(col[falses(L)])
    end
end

# Phase 391: verb x table-kind symmetry.  Every verb that works on a Table works on a MeasurementSet
# (its MAIN table) too: `length`, `for row in ms` and `edit(table)` were missing.
import Tables
@testset "MeasurementSet iterates like its MAIN table; edit(::Table) (Phase 391)" begin
    p = joinpath(@__DIR__, "data", "sample.ms")
    ms = MSv2.MeasurementSet(p); main = MSv2.readtable(p)
    @test length(ms) == MSv2.nrow(ms) == length(main)
    @test eltype(ms) === eltype(main) && Base.IteratorSize(typeof(ms)) == Base.HasLength()
    n = 0
    for r in ms
        n += 1
        n == 1 && @test Tables.getcolumn(r, :ANTENNA1) == Tables.getcolumn(first(main), :ANTENNA1)
        n >= 5 && break
    end
    @test n == 5 && first(ms).TIME == first(main).TIME
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["A" => [1, 2, 3], "B" => [1.5, 2.5, 3.5]]; nrow=3)
    t = MSv2.readtable(d)
    edit(t) do e; e["A"][2] = 20; end                     # edit(f, ::Table)
    e = edit(t); e["B"][1] = 9.5; flush(e)                 # edit(::Table)
    @test column(MSv2.readtable(d), "A")[:] == [1, 20, 3] && column(MSv2.readtable(d), "B")[1] == 9.5
end

# Phase 403: whole-MS workflows -- append rows from another MS, select into a new MS, add the calibration columns.
@testset "MeasurementSet workflows (Phase 403)" begin
    base = mktempdir()
    a = joinpath(base, "a.ms"); copyms(SAMPLE_MS, a; rows=1:200)
    b = joinpath(base, "b.ms"); copyms(SAMPLE_MS, b; rows=201:400)
    full = readtable(SAMPLE_MS; precision=:full)
    # append another MS's rows: by object, by path, with a limit, and as TaQL `INSERT INTO t SELECT FROM 'path'`
    @test insert!(a, MeasurementSet(b)) == 200
    x = readtable(a; precision=:full)
    @test column(x, "TIME")[:] == column(full, "TIME")[1:400]
    @test column(x, "DATA")[400] == column(full, "DATA")[400] && column(x, "UVW")[250] == column(full, "UVW")[250]
    @test isempty(validate(MeasurementSet(a)))
    c = joinpath(base, "c.ms"); copyms(SAMPLE_MS, c; rows=1:50)
    @test insert!(c, b) == 200                                    # a path
    @test nrow(MeasurementSet(c)) == 250
    @test_throws ArgumentError insert!(c, joinpath(base, "no-such-table"))
    c2 = joinpath(base, "c2.ms"); copyms(SAMPLE_MS, c2; rows=1:50)
    @test insert!(c2, MeasurementSet(b); limit=10) == 10
    c3 = joinpath(base, "c3.ms"); copyms(SAMPLE_MS, c3; rows=1:50)
    n3 = taql(c3, "INSERT INTO \$1 SELECT FROM '$b' WHERE ANTENNA1 == 3")
    @test n3 > 0 && nrow(MeasurementSet(c3)) == 50 + n3
    @test taql(c3, "INSERT INTO \$1 SELECT * FROM '$b' LIMIT 4") == 4
    # copyms takes an opened MeasurementSet, and a row selection from a query
    m = MeasurementSet(SAMPLE_MS)
    r = query(m, "ANTENNA1 == 3 AND ANTENNA2 == 5")
    d = joinpath(base, "sel.ms"); copyms(m, d; rows=getfield(r, :rows))
    @test nrow(MeasurementSet(d)) == nrow(r) && isempty(validate(MeasurementSet(d)))
    # MODEL_DATA / CORRECTED_DATA are standard optional columns, added with DATA-shaped cells
    e = joinpath(base, "e.ms"); copyms(SAMPLE_MS, e; rows=1:10)
    edit(MeasurementSet(e)) do t
        addcolumn!(t, "CORRECTED_DATA")
        addcolumn!(t, "MODEL_DATA")
    end
    y = readtable(e; precision=:full)
    @test size(column(y, "CORRECTED_DATA")[3]) == size(column(y, "DATA")[3]) == (4, 64)
    @test eltype(column(y, "MODEL_DATA")[1]) == ComplexF32 && all(iszero, column(y, "MODEL_DATA")[10])
    @test isempty(validate(MeasurementSet(e)))
    edit(e) do t; t[:CORRECTED_DATA][2] = fill(1f0 + 2f0im, 4, 64); end
    @test column(readtable(e; precision=:full), "CORRECTED_DATA")[2] == fill(1f0 + 2f0im, 4, 64)
end

@testset "Phase 412 — assigning into a read-only column says how to edit" begin
    d = mktempdir(); p = joinpath(d, "t")
    write_table(p, "T", ["A" => [1, 2, 3]]; nrow = 3)
    t = readtable(p)
    for c in (column(t, "A"), column(query(t, "A > 1"), "A"),
              column(readtable(write_concattable(joinpath(d, "cc"), [t, t])), "A"))
        e = try; c[1] = 5; nothing; catch x; x; end
        @test e isa ArgumentError && occursin("edit", e.msg)
        @test_throws ArgumentError fill!(c, 0)
    end
    @test column(t, "A")[:] == [1, 2, 3]
end

# Phase 481: cells handed out by reads must be independent -- no two cells of one `col[:]` / selection share memory
# (Phase 480 found run-length ISM cells that did) and changing a returned cell never changes a later read.  Identical
# cells in every column kind: SSM / ISM fixed and ragged, the three tiled managers, engines, VirtualTaQL, forwarded,
# a RefTable repeating rows, a ConcatTable.
@testset "returned cells are independent (Phase 481)" begin
    bad = String[]; N = 6
    same = [fill(1.5f0, 3) for _ in 1:N]          # identical cells => run-length / repeated data
    function chk(name, d, col; narrow=false)
        t = readtable(d); c = column(t, col)
        truth = [deepcopy(c[i]) for i in 1:N]
        a = c[:]
        # alias among returned cells
        for i in 1:N, j in i+1:N
            a[i] isa AbstractArray && a[j] isa AbstractArray && Base.mightalias(a[i], a[j]) && (push!(bad, "alias [:] $name"); return)
        end
        # mutate every cell of [:]; later reads must be unchanged
        for x in a; x isa AbstractArray && (x .= zero(eltype(x))); end
        b = column(readtable(d), col)[:]
        all(i -> b[i] == truth[i], 1:N) || push!(bad, "MUTATION LEAKS into later [:] $name")
        # getcell mutation
        x = c[1]; x isa AbstractArray && (x .= zero(eltype(x)))
        c[1] == truth[1] || push!(bad, "MUTATION LEAKS into later getcell $name")
        # getcell twice not aliased
        c[2] === c[2] && push!(bad, "getcell returns same object $name")
        # selection
        s = c[[1, 1, 2]]; s[1] isa AbstractArray && Base.mightalias(s[1], s[2]) && push!(bad, "ALIAS in selection [1,1,2] $name")
    end
    mk(f; kw...) = (d = joinpath(mktempdir(), "t"); f(d); d)
    specs = Dict(
     "ssm-fixed" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N),
     "ssm-ragged" => d -> write_table(d, "T", Pair{String,Any}["V" => vcat([Float32[1,2], Float32[1,2]], [fill(1f0, 3) for _ in 1:N-2])]; nrow=N),
     "ism-fixed" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N, ism=["V"]),
     "ism-ragged" => d -> write_table(d, "T", Pair{String,Any}["V" => vcat([Float32[1,2], Float32[1,2]], [fill(1f0, 3) for _ in 1:N-2])]; nrow=N, ism=["V"]),
     "tsm" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N, tsm=[["V"]]),
     "tcm" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N, tcm=[["V"]]),
     "tcell" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N, tcell=[["V"]]),
     "scaled" => d -> write_table(d, "T", Pair{String,Any}["V" => [fill(1.5, 3) for _ in 1:N]]; nrow=N, engines=Dict("V" => (; kind=MSv2.ScaledArray(), scale=0.5, offset=0.0, stored_type=MSv2.TpInt))),
     "compress" => d -> write_table(d, "T", Pair{String,Any}["V" => same]; nrow=N, engines=Dict("V" => (; kind=MSv2.CompressFloat(), scale=0.01f0, offset=0f0))),
     "bitflags" => d -> write_table(d, "T", Pair{String,Any}["V" => [trues(3) for _ in 1:N]]; nrow=N, engines=Dict("V" => (; kind=MSv2.BitFlags(), stored_type=MSv2.TpInt))),
     "virtualtaql" => d -> write_table(d, "T", Pair{String,Any}["W" => same, "V" => same]; nrow=N, virtualtaql=Dict("V" => "W * 2.0")),
    )
    for nm in sort(collect(keys(specs))); chk(nm, mk(specs[nm]), "V"); end
    # forward
    src = mk(specs["ssm-fixed"]); fw = joinpath(mktempdir(), "f"); reference_copy(fw, readtable(src)); chk("forward", fw, "V")
    # RefTable with repeated rows, ConcatTable
    rd = joinpath(mktempdir(), "r"); write_reftable(rd, readtable(src), [1,1,1,2,2,3]); chk("reftable-repeat", rd, "V")
    cd_ = joinpath(mktempdir(), "c"); write_concattable(cd_, [readtable(src), readtable(mk(specs["ssm-fixed"]))]); 
    t = readtable(cd_); c = column(t, "V"); a = c[:]; Base.mightalias(a[1], a[2]) && push!(bad, "ALIAS concat")

    @test isempty(bad)
end

# Phase 482: `keywords(t)` and `stdcolumns(name)` returned the table's / the global schema's own containers, so changing an
# array inside a keyword (or the returned vector) silently changed the table (or the MS schema for the whole process).
@testset "keywords() and stdcolumns() return copies (Phase 482)" begin
    d = joinpath(mktempdir(), "t")
    write_table(d, "T", Pair{String,Any}["A" => Int32.(1:3)]; nrow=3,
                keywords=Dict{String,Any}("KA" => [1, 2, 3], "KS" => ["x", "y"], "KR" => Dict("a" => [1.0, 2.0])))
    t = readtable(d)
    keywords(t)["KA"][1] = 99; keywords(t)["KS"][1] = "zz"; keywords(t)["KR"]["a"][1] = 99.0
    @test keywords(t)["KA"] == [1, 2, 3] && keywords(t)["KS"] == ["x", "y"] && keywords(t)["KR"]["a"] == [1.0, 2.0]
    @test keywords(query(t, "A > 1"))["KA"] == [1, 2, 3]
    n = length(stdcolumns("MAIN")); first = stdcolumns("MAIN")[1].name
    v = stdcolumns("MAIN"); push!(v, v[1]); v[1] = v[2]
    @test length(stdcolumns("MAIN")) == n && stdcolumns("MAIN")[1].name == first
end
