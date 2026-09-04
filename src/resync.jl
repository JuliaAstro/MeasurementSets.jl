# Coherent re-read after another process wrote the table.
#
# A `Table` (and the storage-manager instances cached for it in
# `_DM_CACHE`) is a snapshot taken at `readtable` time.  When another
# process appends rows / edits cells it bumps the `table.lock` sync
# blob's modify counter.  `is_stale` reports that; `resync` re-opens.
#
# `resync` returns a NEW object -- the old `Table` and its cached data
# managers are abandoned (and evicted from `_DM_CACHE`).  In-place
# per-data-manager `resync64` is deliberately not attempted.

"""
    is_stale(t) -> Bool

Whether the `table.lock` sync blob has been updated (by another process,
or by our own `edit`) since `t` was opened.
"""
function is_stale(t::Table)
    s = read_syncinfo(t.lockpath)
    s.present || return false
    return s.modifycounter != t.syncmod
end
is_stale(t::EditTable) = is_stale(t.reader)
is_stale(ms::MeasurementSet) = is_stale(getfield(ms, :data))

"""
    resync(t) -> Table / MeasurementSet

Re-open the table if [`is_stale`](@ref); otherwise return `t` unchanged.
The returned object replaces `t` -- keep it and drop the old one.
"""
function resync(t::Table)
    is_stale(t) || return t
    fresh = readtable(t.path)
    Base.@lock _REG_LOCK begin
        delete!(_DM_CACHE, t)
    end
    return fresh
end

function resync(ms::MeasurementSet)
    is_stale(ms) || return ms
    Base.@lock _REG_LOCK begin
        delete!(_DM_CACHE, getfield(ms, :data))
        for (_, sub) in getfield(ms, :tables)
            delete!(_DM_CACHE, sub)
        end
    end
    return MeasurementSet(getfield(ms, :path))
end
