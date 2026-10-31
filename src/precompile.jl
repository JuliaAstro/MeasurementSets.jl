# Precompile workload (Phase 502).  Without it the first `query` / `groupby` / `taql` call of a session compiled the
# TaQL-lite parser, evaluator and dispatcher: 2-7 s each, 19 s for the first `taql(..., "... GROUP BY ... INTO ...")`.
# The workload writes a small table in a temporary directory and runs the common verbs on it; the lock registry and
# the pattern cache it fills are emptied again so no file descriptor or temporary path ends up in the package image.
function _precompile_workload(dir::AbstractString)
    p = joinpath(dir, "t")
    n = 24
    write_table(p, "T", Pair{String,Any}[
        "A" => Int32.(mod.(1:n, 5)), "B" => collect(range(0.5, step=0.25, length=n)),
        "S" => ["s$(i % 4)" for i in 1:n], "F" => isodd.(1:n),
        "V" => [Float32[i, i + 1] for i in 1:n], "W" => [Float32[i i; 1 2] for i in 1:n]]; nrow=n, tsm=[["W"]])
    t = readtable(p)
    column(t, "A")[:]; column(t, "B")[3]; column(t, "V")[2]; column(t, "W")[2]; getcolumn(t, "S"); keywords(t); columndesc(t, "A")
    query(t, "A > 1 AND B < 5.0 ORDER BY B DESC")
    query(t, "S LIKE 's1%' OR F"; select=["A" => "A", "X" => "B * 2 + A"])
    query(t, "sqrt(B) + A > 2 AND A IN [1, 2, 3] AND any(V > 3)")
    groupby(t, "A"; select=["A" => :A, "N" => "gcount()", "M" => "gmean(B)"], having="gcount() > 1", orderby=["A"])
    join(t, t; on="A" => "A", rightcols=["B" => "B2"], multi=true)
    taql(p, "SELECT A, B WHERE A > 1 ORDER BY B LIMIT 5 INTO '$(joinpath(dir, "q"))'")
    taql(p, "SELECT A, gcount() AS N, gsum(B) AS S GROUP BY A HAVING gcount() > 1 INTO '$(joinpath(dir, "g"))'")
    taql(p, "UPDATE t SET B = B + 1 WHERE A = 2")
    taql(p, "INSERT INTO t (A, B, S, F) VALUES (1, 2.5, 'z', T)")
    taql(p, "DELETE FROM t WHERE A = 4")
    e = edit(p)
    e[:A][1] = Int32(3); flush(e)
    copytable(joinpath(dir, "c"), readtable(p); rows=1:5)
    c = joinpath(dir, "c.ms")
    create_ms(c; nrow=8, nchan=2, ncorr=2, nant=3)
    ms = MeasurementSet(c)
    validate(ms); column(ms, "DATA")[1]; subtable(ms, "ANTENNA"); query(ms, "any(FLAG) OR ANTENNA1 == 0")
    copyms(c, joinpath(dir, "o.ms"); rows=1:4)
    return nothing
end

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    @compile_workload begin
        dir = mktempdir()
        try
            _precompile_workload(dir)
        catch
            # a failing workload must never break installation
        finally
            for lk in collect(values(_HELD_LOCKS)); close_lock!(lk); end
            empty!(_HELD_LOCKS)
            empty!(_TQL_PATTERN_CACHE)
            rm(dir; recursive=true, force=true)
        end
    end
end
