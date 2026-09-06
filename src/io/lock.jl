# Cooperative file locking + row-count synchronisation via `table.lock`,
# so MeasurementSets shares a table safely with a concurrent reader or
# writer (another Julia session, or a real casacore / python-casacore
# process).
#
# Mirrors casacore/casa/IO/LockFile.cc, casa/IO/FileLocker.cc and
# tables/Tables/TableSyncData.cc.
#
# `table.lock` on-disk layout (all fixed fields big-endian canonical):
#
#   [0 .. SIZEREQID)   int32 N  +  up to NRREQID (pid, hostid) int32 pairs
#                                  --- the "request id" list.  On a
#                                  contended acquire we announce ourselves
#                                  here (and remove ourselves once done)
#                                  so a real casacore peer in
#                                  TableLock::AutoLocking mode can see us
#                                  waiting and release cooperatively --
#                                  see `_add_reqid!`/`_remove_reqid!`.
#   [SIZEREQID .. +4)   uint32   length of the sync-info blob
#   [SIZEREQID+4 .. )   the AipsIO "sync" blob (nrow + modify counter)
#
# fcntl byte-range (POSIX advisory) locks on that file:
#   byte 0 (len 1)   the table read (F_RDLCK, shared) / write (F_WRLCK,
#                    exclusive) lock
#   byte 1 (len 1)   "in use" --- every opener holds a read lock here so
#                    `is_multiused` works
#
# Caveats:
#  * `fcntl` is a C variadic function --- Julia MUST call it through the
#    `@ccall` vararg form (`; arg::T`); a plain `ccall` mis-passes the
#    third argument on AArch64 and returns EINVAL.
#  * Closing *any* fd to `table.lock` drops *all* of this process's locks
#    on it (POSIX).  A process-wide registry keeps exactly one fd per
#    table directory, reference-counted, so nested `withlock` calls and
#    the finalizer never step on a live lock.
#  * The shared read lock `readtable` takes is released before the lazy,
#    first-access storage-manager reads --- those are guarded instead by
#    the atomic-rename SM writers (`_atomic_write`).  In-place TiledStMan
#    tile patches (`tsm_setcell!`) are only safe under the exclusive write
#    lock, which `edit`'s flush holds for its whole duration.

# --- platform constants ------------------------------------------

@static if Sys.isapple()
    const LOCK_SUPPORTED = true
    struct Flock
        l_start::Int64
        l_len::Int64
        l_pid::Int32
        l_type::Int16
        l_whence::Int16
    end
    _mkflock(ltype, start, len) = Flock(Int64(start), Int64(len), Int32(0), Int16(ltype), Int16(0))
    const F_GETLK  = Cint(7)
    const F_SETLK  = Cint(8)
    const F_SETLKW = Cint(9)
    const F_RDLCK  = Int16(1)
    const F_WRLCK  = Int16(3)
    const F_UNLCK  = Int16(2)
    const _EAGAIN  = 35            # EAGAIN / EWOULDBLOCK (BSD)
elseif Sys.islinux()
    const LOCK_SUPPORTED = true
    struct Flock
        l_type::Int16
        l_whence::Int16
        l_start::Int64
        l_len::Int64
        l_pid::Int32
    end
    _mkflock(ltype, start, len) = Flock(Int16(ltype), Int16(0), Int64(start), Int64(len), Int32(0))
    const F_GETLK  = Cint(5)
    const F_SETLK  = Cint(6)
    const F_SETLKW = Cint(7)
    const F_RDLCK  = Int16(0)
    const F_WRLCK  = Int16(1)
    const F_UNLCK  = Int16(2)
    const _EAGAIN  = 11           # EAGAIN / EWOULDBLOCK (Linux)
else
    const LOCK_SUPPORTED = false
    struct Flock; l_type::Int16; l_whence::Int16; l_start::Int64; l_len::Int64; l_pid::Int32; end
    _mkflock(ltype, start, len) = Flock(0, 0, 0, 0, 0)
    const F_GETLK = Cint(0); const F_SETLK = Cint(0); const F_SETLKW = Cint(0)
    const F_RDLCK = Int16(0); const F_WRLCK = Int16(0); const F_UNLCK = Int16(0)
    const _EAGAIN = 11
end
const _EINTR  = 4
const _EACCES = 13

# casacore LockFile.cc: SIZEREQID = (1 + 2*NRREQID) * SIZEINT
const LOCK_SIZEINT   = 4
const LOCK_NRREQID   = 32
const LOCK_SIZEREQID = (1 + 2 * LOCK_NRREQID) * LOCK_SIZEINT   # 260
const LOCK_RW_BYTE   = 0     # table read/write lock
const LOCK_USE_BYTE  = 1     # "in use" marker
const SYNC_V1        = 1     # "sync" blob: uInt32 nrow
const SYNC_V2        = 2     # "sync" blob: uInt64 nrow

# poll budget for a contended lock (a blocking `F_SETLKW` `@ccall` would
# pin the thread un-interruptibly); overridable for tests.
const SYNC_MAXWAIT_S = Ref(60.0)

# --- the lock handle -------------------------------------------

mutable struct TableLock
    dir::String
    path::String                    # <dir>/table.lock
    io::Union{IOStream,Nothing}
    state::Symbol                    # :none | :read | :write   (byte 0)
    writable::Bool
    noop::Bool                       # locking disabled -> every op succeeds
    inuse::Bool                      # holding the byte-1 "in use" read lock
    depth::Int                       # registry reference count
end

_rawfd(lk::TableLock) = Base.cconvert(Cint, fd(lk.io::IOStream))

# --- fcntl ------------------------------------------------------

# returns (rc, errno); rc == 0 on success
function _fcntl(lk::TableLock, cmd::Cint, fl::Ref{Flock})
    r = @ccall fcntl(_rawfd(lk)::Cint, cmd::Cint; fl::Ref{Flock})::Cint
    e = r == 0 ? 0 : Base.Libc.errno()
    (Int(r), e)
end

_conflict_errno(e) = e == _EAGAIN || e == _EACCES

_mypid() = Int32(getpid())

# Read/write the whole 260-byte request-id region as 65 big-endian
# Int32s: reqid[1] = count N; pair i (0-based, i=0..31) is
# (reqid[2i+2], reqid[2i+3]) = (pid, hostid).  Mirrors LockFile.cc's
# itsReqId layout (casa/IO/LockFile.cc:332-390).
function _reqid_read(lk::TableLock)
    try
        seek(lk.io, 0)
        buf = read(lk.io, LOCK_SIZEREQID)
        length(buf) == LOCK_SIZEREQID || return zeros(Int32, 65)
        return Int32[ntoh(reinterpret(Int32, @view buf[4i+1:4i+4])[1]) for i in 0:64]
    catch
        return zeros(Int32, 65)
    end
end

function _reqid_write!(lk::TableLock, reqid::Vector{Int32})
    lk.writable || return
    try
        # One single write of the whole region (matches casacore's own
        # one-shot `pwrite`) -- 65 separate small writes would let a
        # concurrent reader observe a torn, half-updated region.
        buf = reinterpret(UInt8, hton.(reqid))
        seek(lk.io, 0)
        write(lk.io, buf)
        flush(lk.io)
        ccall(:fsync, Cint, (Cint,), _rawfd(lk))
    catch
    end
end

# Announce this process as waiting for the lock (casacore
# LockFile::addReqId, LockFile.cc:332-345) -- lets a real casacore peer
# holding the table in TableLock::AutoLocking mode see a nonzero request
# count and voluntarily release early instead of us waiting out the full
# poll budget.  UserLocking peers never look at this, but writing it is
# harmless and matches what a real casacore process would do too.
function _add_reqid!(lk::TableLock)
    reqid = _reqid_read(lk)
    inx = min(Int(reqid[1]), LOCK_NRREQID - 1)
    reqid[1] = inx + 1
    reqid[2inx+2] = _mypid()
    reqid[2inx+3] = 0                      # hostid -- casacore hardcodes 0 too
    _reqid_write!(lk, reqid)
end

# Remove this process's own entry (casacore LockFile::removeReqId,
# LockFile.cc:347-364) once we've acquired the lock or given up waiting.
# Simplified to an unambiguous "erase and shift down" rather than a
# byte-for-byte port of casacore's terse shift arithmetic -- a real peer
# only ever reads the *count* to decide whether to release, so exact
# internal-shift fidelity isn't required for interop.
function _remove_reqid!(lk::TableLock)
    reqid = _reqid_read(lk)
    nr = Int(reqid[1])
    mypid = _mypid()
    i = findfirst(k -> reqid[2k+2] == mypid && reqid[2k+3] == 0, 0:nr-1)
    i === nothing && return
    for k in i:nr-2
        reqid[2k+2] = reqid[2k+4]
        reqid[2k+3] = reqid[2k+5]
    end
    reqid[2nr] = 0
    reqid[2nr+1] = 0
    reqid[1] = nr - 1
    _reqid_write!(lk, reqid)
end

# byte-0 lock; `wait` polls up to SYNC_MAXWAIT_S, else one attempt
function _acquire!(lk::TableLock, ltype::Int16; wait::Bool)
    (lk.noop || lk.io === nothing) && return true
    t0 = time()
    added = false
    fl = Ref(_mkflock(ltype, LOCK_RW_BYTE, 1))
    try
        while true
            rc, e = _fcntl(lk, F_SETLK, fl)
            rc == 0 && return true
            if e == _EINTR
                continue
            elseif _conflict_errno(e)
                wait || return false
                if !added && lk.writable
                    _add_reqid!(lk)
                    added = true
                end
                if time() - t0 > SYNC_MAXWAIT_S[]
                    @warn "table.lock: gave up waiting for a lock after $(SYNC_MAXWAIT_S[]) s; proceeding unlocked" lk.dir
                    lk.noop = true
                    return true
                end
                sleep(0.05)
            else
                # ENOLCK (no lock daemon), EINVAL/ENOTSUP (fs w/o locking), EBADF ...
                lk.noop = true
                return true
            end
        end
    finally
        added && _remove_reqid!(lk)
    end
end

function lock_read!(lk::TableLock)
    lk.state === :write && return lk       # a write lock already covers reads
    _acquire!(lk, F_RDLCK; wait=true)
    lk.state = :read
    return lk
end

function lock_write!(lk::TableLock)
    _acquire!(lk, F_WRLCK; wait=true)       # POSIX upgrades a held read lock in place
    lk.state = :write
    return lk
end

function unlock!(lk::TableLock)
    (lk.noop || lk.io === nothing || lk.state === :none) && (lk.state = :none; return lk)
    try
        _fcntl(lk, F_SETLK, Ref(_mkflock(F_UNLCK, LOCK_RW_BYTE, 1)))
    catch
    end
    lk.state = :none
    return lk
end

function close_lock!(lk::TableLock)
    lk.io === nothing && return
    try
        unlock!(lk)
        lk.inuse && _fcntl(lk, F_SETLK, Ref(_mkflock(F_UNLCK, LOCK_USE_BYTE, 1)))
    catch
    end
    try
        close(lk.io)
    catch
    end
    lk.io = nothing
    lk.inuse = false
    return
end

# --- process-wide registry (one fd per table dir) -------------

const _HELD_LOCKS = Dict{String,TableLock}()
const _REG_LOCK   = ReentrantLock()

_lockkey(dir::AbstractString) = try
    realpath(String(dir))
catch
    abspath(String(dir))
end

_noop_lock(dir, path) = TableLock(String(dir), path, nothing, :none, false, true, false, 1)

"""
    open_lock(dir; create) -> TableLock

Open (or, when `create`, create) `<dir>/table.lock` and start holding the
"in use" read lock.  Reuses a registered handle for `dir` if one is
already open (reference-counted).  Never throws; degrades to a no-op
handle when locking is unavailable.
"""
function open_lock(dir::AbstractString; create::Bool)
    key = _lockkey(dir)
    Base.@lock _REG_LOCK begin
        existing = get(_HELD_LOCKS, key, nothing)
        if existing !== nothing
            existing.depth += 1
            return existing
        end
    end

    path = joinpath(String(dir), "table.lock")
    LOCK_SUPPORTED || return _noop_lock(dir, path)

    io = nothing
    writable = false
    try
        if isfile(path)
            try
                io = open(path, "r+"); writable = true
            catch
                io = open(path, "r"); writable = false
            end
        elseif create
            io = open(path, "w+"); writable = true       # throws if the dir is not writable
            write(io, zeros(UInt8, LOCK_SIZEREQID)); flush(io)
            try; chmod(path, 0o666); catch; end
        end
    catch
        io = nothing
    end
    io === nothing && return _noop_lock(dir, path)

    lk = TableLock(String(dir), path, io, :none, writable, false, false, 1)
    finalizer(close_lock!, lk)
    # best-effort "in use" marker
    try
        rc, _ = _fcntl(lk, F_SETLK, Ref(_mkflock(F_RDLCK, LOCK_USE_BYTE, 1)))
        lk.inuse = rc == 0
    catch
    end
    Base.@lock _REG_LOCK begin
        _HELD_LOCKS[key] = lk
    end
    return lk
end

function _release!(lk::TableLock)
    key = _lockkey(lk.dir)
    Base.@lock _REG_LOCK begin
        lk.depth -= 1
        lk.depth <= 0 || return
        delete!(_HELD_LOCKS, key)
    end
    close_lock!(lk)
    return
end

"""
    withlock(f, dir, mode; create) -> f(lk)

Run `f(lk::TableLock)` with a shared (`:read`) or exclusive (`:write`)
lock on `<dir>/table.lock` held for the duration, always released
afterwards.
"""
function withlock(f, dir::AbstractString, mode::Symbol; create::Bool)
    lk = open_lock(dir; create)
    try
        mode === :write ? lock_write!(lk) : lock_read!(lk)
        return f(lk)
    finally
        _release!(lk)
    end
end

# --- the "sync" blob ------------------------------------------

"""
    read_syncinfo(x) -> (; nrow, modifycounter, present)

Read the `TableSyncData` blob from `table.lock` (`x` is a `TableLock` or a
directory / lock-file path).  `present` is false and `nrow` is `nothing`
when there is no (valid) blob.
"""
function read_syncinfo(lk::TableLock)
    lk.io === nothing && return _read_syncinfo_bytes(_maybe_read(lk.path))
    try
        seek(lk.io, 0)
        return _read_syncinfo_bytes(read(lk.io))
    catch
        return (; nrow = nothing, modifycounter = Int64(-1), present = false)
    end
end
read_syncinfo(path::AbstractString) = _read_syncinfo_bytes(_maybe_read(_lockfile_path(path)))

_lockfile_path(p) = endswith(String(p), "table.lock") ? String(p) : joinpath(String(p), "table.lock")
_maybe_read(p) = isfile(p) ? read(p) : UInt8[]

function _read_syncinfo_bytes(buf::Vector{UInt8})
    none = (; nrow = nothing, modifycounter = Int64(-1), present = false)
    length(buf) >= LOCK_SIZEREQID + 4 || return none
    bloblen = Int(ntoh(reinterpret(UInt32, buf[LOCK_SIZEREQID+1 : LOCK_SIZEREQID+4])[1]))
    (bloblen > 0 && length(buf) >= LOCK_SIZEREQID + 4 + bloblen) || return none
    try
        a = AipsIO(buf[LOCK_SIZEREQID+5 : LOCK_SIZEREQID+4+bloblen]; endian = :big)
        v = getstart(a, "sync")
        nrow = v >= SYNC_V2 ? Int(read_scalar(a, UInt64)) : Int(read_u32(a))
        read_i32(a)                                   # nrcolumn (ignored)
        mc = read_u32(a)
        return (; nrow, modifycounter = Int64(mc), present = true)
    catch
        return none
    end
end

"""
    write_syncinfo(lk, nrow; modifycounter)

Write the short-form `TableSyncData` blob (`nrcolumn = -1`, which casacore
reads as "table + all data managers changed" -> full resync) into
`table.lock`, preserving the request-id region, then `fsync`.
"""
function write_syncinfo(lk::TableLock, nrow::Integer; modifycounter::Integer)
    (lk.noop || lk.io === nothing || !lk.writable) && return
    try
        w = AipsWriter(; endian = :big)
        putstart(w, "sync", nrow > typemax(UInt32) ? SYNC_V2 : SYNC_V1)
        nrow > typemax(UInt32) ? wr_u64(w, nrow) : wr_u32(w, UInt32(nrow))
        wr_i32(w, Int32(-1))                          # nrcolumn = -1
        wr_u32(w, UInt32(modifycounter))
        putend(w)
        blob = bytes(w)

        seek(lk.io, LOCK_SIZEREQID)
        write(lk.io, hton(UInt32(length(blob))))
        write(lk.io, blob)
        flush(lk.io)
        truncate(lk.io, LOCK_SIZEREQID + 4 + length(blob))
        ccall(:fsync, Cint, (Cint,), _rawfd(lk))
    catch e
        @debug "write_syncinfo failed" lk.dir e
    end
    return
end

# --- introspection -------------------------------------------

"""
    is_multiused(dir) -> Bool

Whether another process currently has the table open (holds the byte-1
"in use" read lock).  Uses a fresh probe fd because `F_GETLK` never
reports a conflict with the calling process.
"""
function is_multiused(dir::AbstractString)
    LOCK_SUPPORTED || return false
    path = joinpath(String(dir), "table.lock")
    isfile(path) || return false
    io = try open(path, "r+") catch; try open(path, "r") catch; return false end end
    try
        fl = Ref(_mkflock(F_WRLCK, LOCK_USE_BYTE, 1))
        rfd = Base.cconvert(Cint, fd(io))
        r = @ccall fcntl(rfd::Cint, F_GETLK::Cint; fl::Ref{Flock})::Cint
        r == 0 || return false
        return fl[].l_type != F_UNLCK
    finally
        close(io)
    end
end
