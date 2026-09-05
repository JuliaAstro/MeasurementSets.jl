# Phase 13: cooperative locking + row-count synchronisation via table.lock.

const MSv2L = MeasurementSets
const _JULIA = Base.julia_cmd()
const _PROJ  = dirname(@__DIR__)

# run a snippet in a child process; returns the exit code
function _child(code::AbstractString)
    p = run(`$_JULIA --project=$_PROJ --startup-file=no -e $code`; wait=false)
    wait(p)
    p.exitcode
end

@testset "lock — TableLock basics + registry" begin
    d = mktempdir()
    lk = MSv2L.open_lock(d; create=true)
    @test isfile(joinpath(d, "table.lock"))
    @test filesize(joinpath(d, "table.lock")) == MSv2L.LOCK_SIZEREQID
    @test !lk.noop
    MSv2L.lock_write!(lk); @test lk.state === :write
    MSv2L.lock_read!(lk);  @test lk.state === :write        # keeps the stronger lock

    lk2 = MSv2L.open_lock(d; create=false)                  # same dir -> same handle
    @test lk2 === lk
    @test lk.depth == 2
    MSv2L._release!(lk2); @test lk.depth == 1 && lk.io !== nothing
    MSv2L._release!(lk);  @test lk.io === nothing
    @test isempty(MSv2L._HELD_LOCKS)
end

@testset "lock — sync blob round-trip" begin
    d = mktempdir()
    MSv2L.withlock(d, :write; create=true) do lk
        MSv2L.write_syncinfo(lk, 12345; modifycounter = 7)
    end
    raw = read(joinpath(d, "table.lock"))
    @test length(raw) >= MSv2L.LOCK_SIZEREQID + 4
    @test all(iszero, raw[1:4])                             # request-id count N = 0
    si = MSv2L.read_syncinfo(d)
    @test si.present && si.nrow == 12345 && si.modifycounter == 7
    # a huge row count uses the uInt64 form
    MSv2L.withlock(d, :write; create=true) do lk
        MSv2L.write_syncinfo(lk, Int(typemax(UInt32)) + 5; modifycounter = 8)
    end
    @test MSv2L.read_syncinfo(d).nrow == Int(typemax(UInt32)) + 5
end

if MSv2L.LOCK_SUPPORTED
    @testset "lock — cross-process contention" begin
        d = mktempdir()
        MSv2L.create_ms(joinpath(d, "x.ms"); nrow=2, nchan=2, ncorr=2, nant=2)
        ms = joinpath(d, "x.ms")
        grab = """
        import MeasurementSets as M
        lk = M.open_lock(raw"$ms"; create=false)
        ok = M._acquire!(lk, M.F_WRLCK; wait=false)
        exit(ok ? 0 : 3)
        """
        lk = MSv2L.open_lock(ms; create=false)
        MSv2L.lock_write!(lk)
        @test _child(grab) == 3                             # blocked
        MSv2L._release!(lk)
        @test _child(grab) == 0                             # now free
    end

    @testset "lock — is_multiused" begin
        d = mktempdir()
        MSv2L.create_ms(joinpath(d, "x.ms"); nrow=2, nchan=2, ncorr=2, nant=2)
        ms = joinpath(d, "x.ms")
        @test !is_multiused(ms)
        holder = """
        import MeasurementSets as M
        lk = M.open_lock(raw"$ms"; create=false)   # takes the byte-1 "in use" lock
        println("held"); flush(stdout)
        sleep(5)
        """
        p = run(pipeline(`$_JULIA --project=$_PROJ --startup-file=no -e $holder`; stdout=devnull);
                wait=false)
        try
            t0 = time()
            while !is_multiused(ms) && time() - t0 < 5; sleep(0.1); end
            @test is_multiused(ms)
        finally
            kill(p); wait(p)
        end
        sleep(0.2)
        @test !is_multiused(ms)
    end

    @testset "lock — request-id add/remove round trip" begin
        d = mktempdir()
        MSv2L.create_ms(joinpath(d, "x.ms"); nrow=2, nchan=2, ncorr=2, nant=2)
        ms = joinpath(d, "x.ms")
        lk = MSv2L.open_lock(ms; create=false)

        MSv2L._add_reqid!(lk)
        raw = read(joinpath(ms, "table.lock"))
        @test ntoh(reinterpret(Int32, raw[1:4])[1]) == 1
        @test ntoh(reinterpret(Int32, raw[5:8])[1]) == getpid()

        MSv2L._remove_reqid!(lk)
        raw2 = read(joinpath(ms, "table.lock"))
        @test all(iszero, raw2[1:MSv2L.LOCK_SIZEREQID])         # back to fully zero

        # LOCK_NRREQID slots -> the count clamps, doesn't overflow the region
        for _ in 1:40
            MSv2L._add_reqid!(lk)
        end
        raw3 = read(joinpath(ms, "table.lock"))
        @test ntoh(reinterpret(Int32, raw3[1:4])[1]) == MSv2L.LOCK_NRREQID
        MSv2L._release!(lk)
    end

    @testset "lock — cooperative hand-off announces + cleans up" begin
        d = mktempdir()
        MSv2L.create_ms(joinpath(d, "x.ms"); nrow=2, nchan=2, ncorr=2, nant=2)
        ms = joinpath(d, "x.ms")

        lk = MSv2L.open_lock(ms; create=false)
        MSv2L.lock_write!(lk)                                   # parent holds the write lock

        child = """
        import MeasurementSets as M
        M.SYNC_MAXWAIT_S[] = 10.0
        lk = M.open_lock(raw"$ms"; create=false)
        M.lock_write!(lk)                       # blocks -> announces itself, retries
        """
        p = run(`$_JULIA --project=$_PROJ --startup-file=no -e $child`; wait=false)
        childpid = getpid(p)

        # Poll the request-id region through the parent's own already-open
        # handle -- read(path) would open+close a second fd on table.lock,
        # and POSIX drops *all* of this process's fcntl locks on a file the
        # moment any fd to it is closed, which would release the very lock
        # under test.
        seen = false
        t0 = time()
        while time() - t0 < 8.0
            seek(lk.io, 0)
            raw = read(lk.io, MSv2L.LOCK_SIZEREQID)
            n = ntoh(reinterpret(Int32, raw[1:4])[1])
            if n > 0 && ntoh(reinterpret(Int32, raw[5:8])[1]) == childpid
                seen = true
                break
            end
            sleep(0.05)
        end
        @test seen                              # the child announced itself while blocked

        MSv2L._release!(lk)                     # let the child through
        wait(p)
        @test p.exitcode == 0

        raw2 = read(joinpath(ms, "table.lock"))
        @test ntoh(reinterpret(Int32, raw2[1:4])[1]) == 0   # child removed its own entry
    end
end

@testset "lock — sync blob written + tracks edits" begin
    d = mktempdir()
    write_table(joinpath(d, "t.tab"), "T", ["A" => collect(1:5)]; nrow=5)
    si = MSv2L.read_syncinfo(joinpath(d, "t.tab"))
    @test si.present && si.nrow == 5 && si.modifycounter >= 1

    p = joinpath(d, "m.ms")
    create_ms(p; nrow=4, nchan=2, ncorr=2, nant=3)
    @test MSv2L.read_syncinfo(p).nrow == 4
    @test MSv2L.read_syncinfo(joinpath(p, "ANTENNA")).nrow == 3
    @test readtable(p).rows == 4

    edit(p) do t; addrows!(t, 3) end
    @test MSv2L.read_syncinfo(p).nrow == 7
    @test readtable(p).rows == 7                            # blob nrow wins over table.dat

    if _HAVE_CASACORE
        ct = CCT.Table(p)
        @test size(ct, 1) == 7                              # casacore reads the blob nrow
    end

    # in-place cell edit still bumps the modify counter
    mc0 = MSv2L.read_syncinfo(p).modifycounter
    edit(p) do t; t[:DATA][1] = fill(ComplexF32(1), 2, 2) end
    @test MSv2L.read_syncinfo(p).modifycounter != mc0
end

@testset "lock — is_stale / resync" begin
    d = mktempdir(); p = joinpath(d, "m.ms")
    create_ms(p; nrow=4, nchan=2, ncorr=2, nant=3)
    t1 = readtable(p)
    @test !is_stale(t1)

    edit(p) do t; addrows!(t, 2) end
    @test is_stale(t1)
    t2 = resync(t1)
    @test t2 !== t1 && t2.rows == 6 && !is_stale(t2)
    @test !haskey(MSv2L._DM_CACHE, t1)
    @test resync(t2) === t2                                 # no change -> same object

    ms = MeasurementSet(p)
    @test !is_stale(ms)
    edit(p) do t; addrows!(t, 1) end
    @test is_stale(ms)
    ms2 = resync(ms)
    @test ms2 !== ms && getfield(ms2, :data).rows == 7
end

if MSv2L.LOCK_SUPPORTED
    @testset "lock — graceful degradation" begin
        d = mktempdir(); p = joinpath(d, "m.ms")
        create_ms(p; nrow=4, nchan=2, ncorr=2, nant=2)
        # unwritable table.lock -> writer still completes, write_syncinfo is skipped
        chmod(joinpath(p, "table.lock"), 0o444)
        try
            edit(p) do t; t[:SCAN_NUMBER][1] = Int32(9) end  # must not throw
            @test readtable(p) isa MSv2L.Table
        finally
            chmod(joinpath(p, "table.lock"), 0o644)
        end
        # read-only table directory -> readtable still works
        p2 = joinpath(d, "ro.ms")
        create_ms(p2; nrow=3, nchan=2, ncorr=2, nant=2)
        chmod(p2, 0o555)
        try
            @test readtable(p2).rows == 3
        finally
            chmod(p2, 0o755)
        end
    end
end

if _HAVE_TAQL
    @testset "lock — casacore-authored table still readable" begin
        old = MSv2L.SYNC_MAXWAIT_S[]
        MSv2L.SYNC_MAXWAIT_S[] = 2.0
        try
            dir = joinpath(mktempdir(), "cc.tab")
            t = _taql_create("CREATE TABLE $dir [A I4] LIMIT 3")
            for r in 1:3; t[:A][r] = Int32(r); end
            CCT.flush(t)                                    # casacore may hold a lock here
            r = @async readtable(dir)
            @test timedwait(() -> istaskdone(r), 10) === :ok
            @test fetch(r).rows == 3
            t = nothing; GC.gc()
        finally
            MSv2L.SYNC_MAXWAIT_S[] = old
        end
    end
end
