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
# These loads go through raw pointers, so a bad offset (a corrupt file, or a layout we
# misread) would read outside the array and crash the whole process (Phase 268: a casacore
# ISM string array did exactly that) -- every entry point checks its byte range first.
# An element count taken from a (possibly corrupt) file must fit the bytes that exist -- check it BEFORE
# allocating the output, or one bad word makes a read allocate (and zero) gigabytes.
@noinline _toobig(n, what) = error("corrupt $what: $n elements cannot fit the data")
@inline _chk_count(n::Int, elbytes::Int, nbytes::Int, what) = (0 <= n && n * elbytes <= nbytes) || _toobig(n, what)

@noinline _oob(bytes, lo, hi) = throw(BoundsError(bytes, lo:hi))
@inline _chk(bytes, off::Int, nbytes::Int) =
    (off >= 0 && nbytes >= 0 && off + nbytes <= length(bytes)) || _oob(bytes, off + 1, off + nbytes)

@inline function _ld(::Type{T}, bytes::AbstractVector{UInt8}, off::Int, big::Bool) where {T}
    _chk(bytes, off, sizeof(T))
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
    _chk(bytes, b, n * sizeof(T))
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
const _BITLUT_OK = Base.ENDIAN_BOM == 0x04030201
const _BITLUT = UInt64[sum(UInt64((b >> j) & 1) << (8j) for j in 0:7) for b in 0:255]

@inline function _rd_bits!(dest::AbstractVector{Bool}, doff::Int,
                           bytes::AbstractVector{UInt8}, base::Int, bitoff::Int, n::Int)
    n == 0 && return dest
    _chk(bytes, base, (bitoff + n + 7) >> 3)
    GC.@preserve bytes begin
        p = pointer(bytes) + base
        bytei = bitoff >> 3
        biti = bitoff & 7
        k = 0                                          # bits written so far
        if biti != 0                                   # the rest of a partly used first byte
            byte = unsafe_load(p, bytei + 1)
            m = min(8 - biti, n)
            @inbounds for j in 0:m-1
                dest[doff + k + 1 + j] = (byte >> (biti + j)) & 0x01 == 0x01
            end
            k += m; bytei += 1
        end
        # whole bytes, eight bits at a time (a byte is only fetched when `n` needs it, so nothing past the
        # end of a mmap/array that stops on a byte boundary is read)
        nfull = (n - k) >> 3
        if nfull > 0 && _BITLUT_OK && dest isa Vector{Bool}
            # eight Bools per store: a lookup table maps a byte to the eight 0/1 bytes it unpacks to
            # (little-endian lane order, hence the `_BITLUT_OK` guard)
            checkbounds(dest, doff + k + 1:doff + k + 8 * nfull)
            GC.@preserve dest begin
                q = Ptr{UInt64}(pointer(dest, doff + k + 1))
                @inbounds for i in 0:nfull-1
                    unsafe_store!(q, _BITLUT[Int(unsafe_load(p, bytei + 1 + i)) + 1], i + 1)   # unaligned store: fine on x86-64 / ARM64
                end
            end
            k += 8 * nfull; bytei += nfull
        else
            @inbounds for _ in 1:nfull
                byte = unsafe_load(p, bytei + 1)
                for j in 0:7
                    dest[doff + k + 1 + j] = (byte >> j) & 0x01 == 0x01
                end
                k += 8; bytei += 1
            end
        end
        r = n - k                                      # the leading bits of a last, partly used byte
        if r > 0
            byte = unsafe_load(p, bytei + 1)
            @inbounds for j in 0:r-1
                dest[doff + k + 1 + j] = (byte >> j) & 0x01 == 0x01
            end
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
