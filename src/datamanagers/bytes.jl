# Low-level, allocation-free primitives for reading raw on-disk values out
# of a table's private storage-manager files (`table.f<seq>`, `table.f<seq>i`,
# `table.f<seq>_TSM<m>`) -- shared by every data manager (`standard.jl`,
# `tiled.jl`, `incremental.jl`, `arrayfile.jl`), so this file is included
# first among `datamanagers/*.jl`.
#
# The one thing every one of them needs and used to duplicate (with the
# SAME real bug, independently discovered and fixed three times --
# Phases 68/234, 237, 238 -- before finally being centralised here): a
# scalar/array on-disk value load. `reinterpret(T, ::Vector{UInt8})`
# (typically via a `view`) is an allocating slow path in Julia whenever
# `sizeof(T) > 1` -- a pinned-pointer `unsafe_load` is not.

# host-endian conversion that also covers `Complex` (Base's `ntoh`/`ltoh`
# are Real-only).
_hostconv(x::Real, big::Bool)    = big ? ntoh(x) : ltoh(x)
_hostconv(z::Complex, big::Bool) = Complex(_hostconv(real(z), big), _hostconv(imag(z), big))

# Single on-disk `T` value at 0-based byte offset `off` of `bytes`
# (a real `Vector{UInt8}` or a contiguous `view` -- Phase-20 container --
# both give a valid `pointer`), endian-corrected. Callers needing a
# specific output element type (e.g. a narrowing `astype` conversion, or
# storing into an `Any`-eltype array-of-arrays entry) still `convert`/store
# the result themselves -- this primitive only ever returns a genuine `T`.
@inline function _ld(::Type{T}, bytes::AbstractVector{UInt8}, off::Int, big::Bool) where {T}
    GC.@preserve bytes begin
        p = Ptr{T}(pointer(bytes) + off)
        return _hostconv(unsafe_load(p), big)
    end
end

# Copy `n` contiguous on-disk `T` values from byte offset `b` (0-based) of
# `bytes` into `dest[doff+1 : doff+n]` (converted to `eltype(dest)`),
# endian-corrected.
@inline function _rd_run!(dest::AbstractVector, doff::Int, ::Type{T},
                          bytes::AbstractVector{UInt8}, b::Int, n::Int, big::Bool) where {T}
    D = eltype(dest)
    GC.@preserve bytes begin
        p = Ptr{T}(pointer(bytes) + b)
        @inbounds for k in 1:n
            dest[doff + k] = convert(D, _hostconv(unsafe_load(p, k), big))
        end
    end
    return dest
end

# Bit-packed (`Bool`) counterpart of `_rd_run!` -- unpacks `n` consecutive
# LSB-first bits starting at 0-based bit offset `bitoff` within byte range
# `bytes[base+1:...]`, into `dest[doff+1:doff+n]`. `unsafe_load` on a
# pinned pointer avoids the bounds-checked `bytes[...]` indexing AND the
# per-element `CartesianIndex`/`_colmajor_offset` tuple recomputation the
# original doubly-nested-`CartesianIndices` loop (`tiled.jl`, pre-Phase
# 234) paid on every bit -- ~3,100 allocations / ~90 KiB per `getcell` for
# a 4x64 `FLAG` plane before that fix, live-measured, vs. 32 allocs /
# ~3.4 KiB for the equal-size `DATA` cell via `_rd_run!` -- a 111x
# wall-clock gap against a real casacore (Casacore.jl) cross-check on the
# same MS.
@inline function _rd_bits!(dest::AbstractVector{Bool}, doff::Int,
                           bytes::AbstractVector{UInt8}, base::Int, bitoff::Int, n::Int)
    n == 0 && return dest
    GC.@preserve bytes begin
        p = pointer(bytes) + base
        bytei = bitoff >> 3
        biti = bitoff & 7
        byte = unsafe_load(p, bytei + 1)
        @inbounds for k in 1:n
            # lazy reload, only on the iteration that actually needs the
            # next byte -- never fetches a byte past what `n` requires
            # (an eager prefetch on every 8th bit could read one byte
            # past a mmap/array that ends exactly on a byte boundary).
            if biti == 8
                biti = 0
                bytei += 1
                byte = unsafe_load(p, bytei + 1)
            end
            dest[doff + k] = (byte >> biti) & 0x01 == 0x01
            biti += 1
        end
    end
    return dest
end


# What casacore reads for a variable-shape array cell that was never written: an empty
# array with the column's number of axes (1 when the description does not know).
function _empty_cell(c::ColumnDesc)
    nd = c.shape isa VariableShape ? max(c.shape.ndim, 1) : 1
    return Array{c.type == TpString ? String : juliatype(c.type)}(undef, ntuple(_ -> 0, nd))
end
