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
is_stale(t::RefTable) = is_stale(t.parent)
is_stale(t::ConcatTable) = any(is_stale, t.parts)
is_stale(::GroupedTable) = false   # a materialised in-memory result

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

# A RefTable / ConcatTable is re-opened wholesale (its parent(s) too); the
# stale parent's cached data managers are evicted.
function resync(t::Union{RefTable,ConcatTable})
    is_stale(t) || return t
    Base.@lock _REG_LOCK begin
        for p in (t isa RefTable ? (t.parent,) : t.parts)
            p isa Table && delete!(_DM_CACHE, p)
        end
    end
    return readtable(t.path)
end

resync(gt::GroupedTable) = gt

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
