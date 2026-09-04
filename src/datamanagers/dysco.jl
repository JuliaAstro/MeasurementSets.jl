# DyscoStMan --- the third-party lossy-compression storage manager
# (aroffringa/dysco; vendored at `tables/Dysco/` in a casacore checkout,
# registered as data-manager type "DyscoStMan").  Full read + write: all
# three normalizations (AF/RF/Row) and all four quantization distributions
# (Gaussian/Uniform/StudentsT/TruncatedGaussian).
#
# Mirrors tables/Dysco/{header.h, serializable.h, dyscostman.{h,cc},
# threadeddyscocolumn.{h,cc}, aftimeblockencoder.{h,cc},
# rftimeblockencoder.{h,cc}, rowtimeblockencoder.{h,cc},
# weightblockencoder.h, stochasticencoder.{h,cc}, bytepacker.h}.
#
# `DyscoStMan::flush` returns `false` (`dyscostman.cc:162-165`), so
# `table.dat`'s ColumnSet carries an empty per-DM block for it -- exactly
# like a virtual engine, and `read_columnset`/`write_columnset` already
# tolerate that with no change.  All configuration lives in the private
# file's own header at `table.f<seq>` (casacore's ordinary
# `DataManager::fileName()` convention, not overridden by Dysco).  There
# is **no AipsIO framing at all** here: every field is a raw native-
# little-endian memcpy (`Serializable`, `serializable.h`) -- unlike every
# other data manager in this package.
#
# File layout:
#   [Header][per-column GenericColumnHeader+ExtraHeader, binding order]
#   [block 0][block 1]...      -- fixed `blockSize` each, no row index;
#                                  row -> block = row div rowsPerBlock.
# Each column's bytes within a block = `[metaDataFloatCount x f32][bit-
# packed symbols]`; columns are laid out back-to-back in a block per the
# *stored* per-column blockSize (a running sum in binding order gives
# each column's byte offset within the shared block -- confirmed against
# a real casacore-written file, see the phase-18/19 plan notes).  Rows
# past the last committed block read as zero -- Dysco's own documented
# behaviour for never-written trailing rows
# (`threadeddyscocolumn.cc:109-118`).

import SpecialFunctions: erf, erfinv, beta_inc
import Random

# --- primitive little-endian readers (no AipsIO framing here) --------

_dy_get(d::AbstractVector{UInt8}, ::Type{T}, off::Integer) where {T} =
    ltoh(reinterpret(T, @view d[off+1:off+sizeof(T)])[1])

# --- normalization / distribution: singleton types, not Symbol -------
#
# Continues this package's established idiom (see `virtual.jl`'s
# `EngineKind`): the on-disk byte code is the one unavoidable
# code -> Julia-type lookup (a plain `Dict`, since it's just data, not
# behavior), and everything downstream (dictionary construction, decode
# factor, encode normalization) is ordinary multiple dispatch on the
# resulting singleton instance -- no `norm === :af` / `dist in (...)`
# chains anywhere below.

abstract type DyscoNormalization end
struct AFNorm  <: DyscoNormalization end   # dysconormalization.h: 0
struct RFNorm  <: DyscoNormalization end   # 1
struct RowNorm <: DyscoNormalization end   # 2

abstract type DyscoDistribution end
struct Gaussian          <: DyscoDistribution end   # dyscodistribution.h: 0
struct Uniform            <: DyscoDistribution end   # 1
struct StudentsT          <: DyscoDistribution end   # 2
struct TruncatedGaussian  <: DyscoDistribution end   # 3

const DYSCO_NORM_CODE = Dict{Int,DyscoNormalization}(0 => AFNorm(), 1 => RFNorm(), 2 => RowNorm())
const DYSCO_DIST_CODE = Dict{Int,DyscoDistribution}(
    0 => Gaussian(), 1 => Uniform(), 2 => StudentsT(), 3 => TruncatedGaussian())

_dysco_norm_code(::AFNorm) = 0x00
_dysco_norm_code(::RFNorm) = 0x01
_dysco_norm_code(::RowNorm) = 0x02
_dysco_dist_code(::Gaussian) = 0x00
_dysco_dist_code(::Uniform) = 0x01
_dysco_dist_code(::StudentsT) = 0x02
_dysco_dist_code(::TruncatedGaussian) = 0x03

# --- Student's t inverse CDF (no direct equivalent in SpecialFunctions;
#     built from the regularized incomplete beta function, which it does
#     provide) ------------------------------------------------------
#
# F(t;nu) = 1 - 0.5*I_x(nu/2, 1/2)  (t >= 0)
# F(t;nu) =       0.5*I_x(nu/2, 1/2)  (t <  0),   x = nu/(nu+t^2)
#
# Not GSL-bit-exact (casacore's own StudentsT path uses
# `gsl_cdf_tdist_Pinv`) -- self-consistent instead: our own encode and
# decode dictionaries are always built from the same function, so a file
# this package writes always round-trips exactly regardless of any
# residual numerical difference from GSL.  Only matters for bit-exact
# decode of a StudentsT file written by real casacore, which the format's
# own docs call a non-default, uncommon choice.

function _studentt_cdf(t::Float64, nu::Float64)
    x = nu / (nu + t * t)
    p, _ = beta_inc(nu / 2, 0.5, x)
    return t >= 0 ? 1.0 - 0.5 * p : 0.5 * p
end

function _studentt_quantile(p::Float64, nu::Float64)
    p == 0.5 && return 0.0
    p < 0.5 && return -_studentt_quantile(1.0 - p, nu)
    hi = 1.0
    while _studentt_cdf(hi, nu) < p
        hi *= 2.0
    end
    lo = 0.0
    for _ in 1:100
        mid = 0.5 * (lo + hi)
        if _studentt_cdf(mid, nu) < p
            lo = mid
        else
            hi = mid
        end
    end
    return 0.5 * (lo + hi)
end

# --- quantization dictionary (stochasticencoder.cc) -------------------

_norm_cdf(x) = 0.5 * (1.0 + erf(x / sqrt(2.0)))
_norm_invcdf(p) = sqrt(2.0) * erfinv(2.0 * p - 1.0)

"""
    _dysco_quantile(dist::DyscoDistribution, p, truncation, nu) -> Float64

The quantile (inverse CDF) of `dist` at probability `p in (0,1)`, scaled
exactly as `stochasticencoder.cc` scales it (`rms` is always `1.0` in
Dysco -- the real magnitude comes entirely from the AF/RF/Row
normalization factor applied on decode/encode, not from this dictionary).
"""
function _dysco_quantile(::TruncatedGaussian, p::Float64, truncation::Float64, ::Float64)
    cdfTrunc = _norm_cdf(-truncation)
    factor = 1.0 - 2.0 * cdfTrunc
    return _norm_invcdf(p * factor + cdfTrunc)
end
_dysco_quantile(::Gaussian, p::Float64, ::Float64, ::Float64) = sqrt(3.0) * _norm_invcdf(p)
_dysco_quantile(::Uniform, p::Float64, ::Float64, ::Float64) = sqrt(3.0) * (-1.0 + 2.0 * p)
_dysco_quantile(::StudentsT, p::Float64, ::Float64, nu::Float64) = _studentt_quantile(p, nu)

"""
    _dysco_dictionary(dist, bits, truncation, nu) -> Vector{Float64}

The **decode** (centroid) dictionary for a `bits`-wide symbol: length
`2^bits`, entries `1:end-1` finite and increasing, `dict[end] = NaN` (the
reserved non-finite-value symbol).
"""
function _dysco_dictionary(dist::DyscoDistribution, bits::Integer, truncation::Float64, nu::Float64)
    quantCount = 1 << Int(bits)
    n = quantCount - 1
    dict = Vector{Float64}(undef, quantCount)
    @inbounds for i in 0:n-1
        dict[i+1] = _dysco_quantile(dist, (i + 0.5) / n, truncation, nu)
    end
    dict[quantCount] = NaN
    return dict
end

"""
    _dysco_boundaries(dist, bits, truncation, nu) -> Vector{Float64}

The **encode** (boundary) dictionary: length `2^bits - 1`, entries
`1:end-1` the interior quantization boundaries, `boundaries[end] = Inf`
(a sentinel so a `searchsortedfirst` lookup always terminates in range --
mirrors `stochasticencoder.cc`'s `*encItem = numeric_limits::max()`).
`_dysco_encode_symbol` below assumes this exact shape.
"""
function _dysco_boundaries(dist::DyscoDistribution, bits::Integer, truncation::Float64, nu::Float64)
    quantCount = 1 << Int(bits)
    n = quantCount - 1
    b = Vector{Float64}(undef, n)
    @inbounds for j in 1:n-1
        b[j] = _dysco_quantile(dist, j / n, truncation, nu)
    end
    b[n] = Inf
    return b
end

# --- generic LSB-first bit-packed symbol stream (bytepacker.h) -------

"""
    _dysco_unpack(bits, packed, n) -> Vector{UInt32}

Unpack `n` `bits`-wide symbols from a continuous LSB-first bitstream:
symbol `i` occupies bits `[i*bits, i*bits+bits)` of `packed` read low-bit-
first (byte 0 bit 0 = stream bit 0, ...).  A single generic sliding-
window unpacker, verified to reproduce casacore's hand-unrolled
`unpack4`/`unpack8`/`unpack10`/`unpack16` bit-for-bit.
"""
function _dysco_unpack(bits::Integer, packed::AbstractVector{UInt8}, n::Integer)
    bits = Int(bits)
    out = Vector{UInt32}(undef, n)
    mask = (UInt64(1) << bits) - 0x1
    bitpos = 0
    @inbounds for i in 1:n
        bytepos = bitpos >> 3
        bitoff = bitpos & 7
        nbytes = cld(bitoff + bits, 8)
        acc = UInt64(0)
        for k in 0:nbytes-1
            acc |= UInt64(packed[bytepos+k+1]) << (8k)
        end
        out[i] = UInt32((acc >> bitoff) & mask)
        bitpos += bits
    end
    return out
end

"""
    _dysco_pack(bits, syms) -> Vector{UInt8}

The exact inverse of [`_dysco_unpack`](@ref): pack `syms` (each `< 2^bits`)
into a continuous LSB-first bitstream, `bufferSize(length(syms),bits) =
cld(length(syms)*bits, 8)` bytes.
"""
function _dysco_pack(bits::Integer, syms::AbstractVector{<:Integer})
    bits = Int(bits)
    n = length(syms)
    nbytes = cld(n * bits, 8)
    out = zeros(UInt8, nbytes)
    bitpos = 0
    @inbounds for i in 1:n
        v = UInt64(syms[i])
        bytepos = bitpos >> 3
        bitoff = bitpos & 7
        nb = cld(bitoff + bits, 8)
        acc = UInt64(0)
        for k in 0:nb-1
            acc |= UInt64(out[bytepos+k+1]) << (8k)
        end
        acc |= (v << bitoff)
        for k in 0:nb-1
            out[bytepos+k+1] = UInt8((acc >> (8k)) & 0xFF)
        end
        bitpos += bits
    end
    return out
end

# --- the data manager --------------------------------------------------

mutable struct DyscoStMan
    data::Vector{UInt8}            # mmapped table.f<seq>
    nrow::Int                      # the table's row count (bounds antenna access)
    headerSize::Int
    rowsPerBlock::Int
    antennaCount::Int
    blockSize::Int
    nBlocksInFile::Int
    dataBitCount::Int
    weightBitCount::Int
    normalization::DyscoNormalization
    distribution::DyscoDistribution
    studentTNu::Float64
    distributionTruncation::Float64
    colOffset::Vector{Int}         # per bound column (binding order): byte offset in block
    colKind::Vector{Symbol}        # :data | :weight
    colShape::Vector{Tuple{Int,Int}}  # (npol, nchan) per bound column
    dict::Vector{Float64}          # decode (centroid) dictionary, length 2^dataBitCount
    ant1::Vector{Int}              # 0-based antenna ids, from the table's own ANTENNA1/2
    ant2::Vector{Int}
end

DATAMANAGERS["DyscoStMan"] = DyscoStMan

"""
    open(::Type{DyscoStMan}, t::Table, dm::DataManagerInfo) -> DyscoStMan

Parse the private `table.f<seq>` header + per-column headers.  All three
normalizations (AF/RF/Row) and all four distributions (Gaussian/Uniform/
StudentsT/TruncatedGaussian) are supported; `error`s clearly (naming the
code) only for a file-format version other than 1.0 or a genuinely
unrecognized code (forward-compatibility with a future casacore addition).
"""
function Base.open(::Type{DyscoStMan}, t::Table, dm::DataManagerInfo)
    path = joinpath(t.path, "table.f$(dm.sequ)")
    isfile(path) || error("DyscoStMan: missing file \"$path\"")
    sz = filesize(path)
    data = sz == 0 ? UInt8[] : Mmap.mmap(path, Vector{UInt8})

    length(data) >= 41 || error("DyscoStMan \"$path\": truncated header ($sz bytes)")

    headerSize         = Int(_dy_get(data, UInt32, 0))
    columnHeaderOffset = Int(_dy_get(data, UInt32, 4))
    columnCount        = Int(_dy_get(data, UInt32, 8))
    namelen            = Int(_dy_get(data, UInt32, 12))

    p = 16 + namelen
    rowsPerBlock = Int(_dy_get(data, UInt32, p)); p += 4
    antennaCount = Int(_dy_get(data, UInt32, p)); p += 4
    blockSize    = Int(_dy_get(data, UInt32, p)); p += 4
    versionMajor = Int(_dy_get(data, UInt16, p)); p += 2
    versionMinor = Int(_dy_get(data, UInt16, p)); p += 2
    dataBitCount   = Int(_dy_get(data, UInt8, p)); p += 1
    weightBitCount = Int(_dy_get(data, UInt8, p)); p += 1
    distributionCode  = Int(_dy_get(data, UInt8, p)); p += 1
    normalizationCode = Int(_dy_get(data, UInt8, p)); p += 1
    studentTNu             = _dy_get(data, Float64, p); p += 8
    distributionTruncation = _dy_get(data, Float64, p); p += 8

    (versionMajor == 1 && versionMinor == 0) ||
        error("DyscoStMan \"$path\": file format version $versionMajor.$versionMinor " *
              "is not supported (only 1.0 is)")
    normalization = get(DYSCO_NORM_CODE, normalizationCode, nothing)
    normalization === nothing &&
        error("DyscoStMan \"$path\": normalization code $normalizationCode is not recognized")
    distribution = get(DYSCO_DIST_CODE, distributionCode, nothing)
    distribution === nothing &&
        error("DyscoStMan \"$path\": distribution code $distributionCode is not recognized")

    cols = [c for c in t.desc.columns if c.sequ == dm.sequ]
    length(cols) == columnCount ||
        error("DyscoStMan \"$path\": $(length(cols)) columns bound, header declares $columnCount")

    colOffset = Vector{Int}(undef, columnCount)
    colKind   = Vector{Symbol}(undef, columnCount)
    colShape  = Vector{Tuple{Int,Int}}(undef, columnCount)
    cp = columnHeaderOffset
    running = 0
    for i in 1:columnCount
        chsize      = Int(_dy_get(data, UInt32, cp))
        colBlockSize = Int(_dy_get(data, UInt32, cp + 4))
        colOffset[i] = running
        running += colBlockSize
        c = cols[i]
        c.shape isa Dims && length(c.shape) == 2 ||
            error("DyscoStMan column \"$(c.name)\": expected a fixed 2-D cell shape, " *
                  "got $(c.shape) (DyscoStMan only supports direct, fixed-shape columns)")
        colShape[i] = (c.shape[1], c.shape[2])
        colKind[i]  = c.name == "WEIGHT_SPECTRUM" ? :weight : :data
        cp += chsize
    end

    nBlocksInFile = blockSize == 0 ? 0 : max(0, (length(data) - headerSize) ÷ blockSize)
    dict = _dysco_dictionary(distribution, dataBitCount, distributionTruncation, studentTNu)

    ant1 = Int.(column(t, "ANTENNA1")[:])
    ant2 = Int.(column(t, "ANTENNA2")[:])

    return DyscoStMan(data, t.rows, headerSize, rowsPerBlock, antennaCount, blockSize,
                      nBlocksInFile, dataBitCount, weightBitCount, normalization,
                      distribution, studentTNu, distributionTruncation,
                      colOffset, colKind, colShape, dict, ant1, ant2)
end

# --- per-normalization metadata layout + decode factor -----------------
#
# One method per normalization, dispatched on `dm.normalization` -- the
# metadata float layout and per-(channel,pol,row) scale factor each
# normalization uses (aftimeblockencoder.cc/rftimeblockencoder.cc/
# rowtimeblockencoder.cc `Decode`/`MetaDataCount`, ported to work from a
# flat `meta::Vector{Float64}` read out of the block already).

_dysco_metacount(::AFNorm, npol, nchan, rpb, nant) = npol * (nchan + nant)
_dysco_metacount(::RFNorm, npol, nchan, rpb, nant) = npol * (nchan + rpb)
_dysco_metacount(::RowNorm, npol, nchan, rpb, nant) = rpb

function _dysco_factor(::AFNorm, meta::Vector{Float64}, ch::Int, pl::Int, br::Int,
                       a1::Int, a2::Int, npol::Int, nchan::Int, nant::Int, rpb::Int)
    chRMS = meta[ch*npol+pl+1]
    antBase = npol * nchan
    f1 = meta[antBase+pl*nant+a1+1]
    f2 = meta[antBase+pl*nant+a2+1]
    return chRMS * f1 * f2
end

function _dysco_factor(::RFNorm, meta::Vector{Float64}, ch::Int, pl::Int, br::Int,
                       a1::Int, a2::Int, npol::Int, nchan::Int, nant::Int, rpb::Int)
    i = ch * npol + pl
    channelFactor = meta[i+1]
    rowBase = npol * nchan
    rowFactor = meta[rowBase+br*npol+pl+1]
    return channelFactor * rowFactor
end

_dysco_factor(::RowNorm, meta::Vector{Float64}, ch::Int, pl::Int, br::Int,
             a1::Int, a2::Int, npol::Int, nchan::Int, nant::Int, rpb::Int) = meta[br+1]

# --- block decode (aftimeblockencoder.cc:401-440, weightblockencoder.h) --

# Decode one whole block (all `rowsPerBlock` slots) for one bound column.
# `nvalid` (<= rowsPerBlock) is the number of slots that correspond to a
# real table row -- padding slots beyond it (the tail of a partially-
# filled last block) are zero-filled without touching the antenna arrays,
# which are only sized to the table's own row count.
function _dysco_decode_block(dm::DyscoStMan, colidx::Int, blockIndex::Int, nvalid::Int)
    npol, nchan = dm.colShape[colidx]
    rpb = dm.rowsPerBlock
    kind = dm.colKind[colidx]
    T = kind === :weight ? Float32 : ComplexF32
    out = Vector{Array{T,2}}(undef, rpb)

    if blockIndex >= dm.nBlocksInFile
        z = zeros(T, npol, nchan)
        @inbounds for k in 1:rpb
            out[k] = copy(z)
        end
        return out
    end

    blockstart = dm.headerSize + dm.blockSize * blockIndex
    colstart = blockstart + dm.colOffset[colidx]

    if kind === :data
        nant = dm.antennaCount
        metaN = _dysco_metacount(dm.normalization, npol, nchan, rpb, nant)
        meta = Vector{Float64}(undef, metaN)
        @inbounds for k in 0:metaN-1
            meta[k+1] = Float64(_dy_get(dm.data, Float32, colstart + 4k))
        end

        symN = rpb * nchan * npol * 2
        nbytes = cld(symN * dm.dataBitCount, 8)
        packedoff = colstart + metaN * 4
        packed = @view dm.data[packedoff+1:packedoff+nbytes]
        syms = _dysco_unpack(dm.dataBitCount, packed, symN)
        dict = dm.dict

        @inbounds for br in 0:rpb-1
            if br >= nvalid
                out[br+1] = zeros(T, npol, nchan)
                continue
            end
            row0 = blockIndex * rpb + br
            a1 = dm.ant1[row0+1]; a2 = dm.ant2[row0+1]
            cell = Matrix{ComplexF32}(undef, npol, nchan)
            base = br * (nchan * npol * 2)
            for ch in 0:nchan-1
                for pl in 0:npol-1
                    factor = _dysco_factor(dm.normalization, meta, ch, pl, br, a1, a2,
                                           npol, nchan, nant, rpb)
                    si = base + (ch*npol + pl) * 2
                    re = dict[syms[si+1] + 1]
                    im = dict[syms[si+2] + 1]
                    cell[pl+1, ch+1] = ComplexF32(re * factor, im * factor)
                end
            end
            out[br+1] = cell
        end

    else # :weight -- WeightBlockEncoder: a plain linear quantizer, no
         # dictionary, no normalization dependence
        maxv = Float64(_dy_get(dm.data, Float32, colstart))
        scale = maxv / (Float64(1 << dm.weightBitCount) - 1.0)
        symN = rpb * nchan
        nbytes = cld(symN * dm.weightBitCount, 8)
        packedoff = colstart + 4
        packed = @view dm.data[packedoff+1:packedoff+nbytes]
        syms = _dysco_unpack(dm.weightBitCount, packed, symN)

        @inbounds for br in 0:rpb-1
            if br >= nvalid
                out[br+1] = zeros(T, npol, nchan)
                continue
            end
            cell = Matrix{Float32}(undef, npol, nchan)
            base = br * nchan
            for ch in 0:nchan-1
                v = Float32(syms[base+ch+1] * scale)
                for pl in 1:npol
                    cell[pl, ch+1] = v
                end
            end
            out[br+1] = cell
        end
    end

    return out
end

"""
    getcell(dm::DyscoStMan, colidx, c, row, cols) -> Array

Decode `row`'s block and return that one cell (1-based `row`).  Re-decodes
the whole block on every call -- the same trade-off `StandardStMan`'s
`getcell` indirect-array branch already accepts.  A whole-column caller
should prefer [`getcolumn`](@ref).  `cols` is unused (see `StandardStMan`'s
`getcell` docstring for why every data manager's `getcell` shares one
signature).
"""
function getcell(dm::DyscoStMan, colidx::Int, ::ColumnDesc, row::Integer, ::Integer)
    npol, nchan = dm.colShape[colidx]
    T = dm.colKind[colidx] === :weight ? Float32 : ComplexF32
    rpb = dm.rowsPerBlock
    rpb == 0 && return zeros(T, npol, nchan)
    row0 = Int(row) - 1
    blockIndex = row0 ÷ rpb
    within = row0 % rpb
    nvalid = min(rpb, dm.nrow - blockIndex * rpb)
    block = _dysco_decode_block(dm, colidx, blockIndex, nvalid)
    return block[within+1]
end

"""
    getcolumn(dm::DyscoStMan, colidx, c, nrow, cols) -> Vector{<:Array}

Decode each block exactly once and collect all `nrow` cells -- the
efficient whole-column path `copyms`/`copytable` use via the identity-copy
fast path (Phase 16).  `cols` is unused (see [`getcell`](@ref)).
"""
function getcolumn(dm::DyscoStMan, colidx::Int, ::ColumnDesc, nrow::Integer, ::Integer)
    npol, nchan = dm.colShape[colidx]
    T = dm.colKind[colidx] === :weight ? Float32 : ComplexF32
    rpb = dm.rowsPerBlock
    out = Vector{Array{T,2}}(undef, nrow)
    if rpb == 0
        z = zeros(T, npol, nchan)
        @inbounds for i in 1:nrow
            out[i] = copy(z)
        end
        return out
    end
    nblocks = cld(nrow, rpb)
    idx = 1
    @inbounds for b in 0:nblocks-1
        nvalid = min(rpb, nrow - b * rpb)
        block = _dysco_decode_block(dm, colidx, b, nvalid)
        for k in 1:nvalid
            out[idx] = block[k]
            idx += 1
        end
    end
    return out
end

# =====================  writer  ====================================
#
# Encodes are ported directly from the casacore encode-side sources (see
# the Phase-19 plan for exact file:line citations); dithering uses
# Julia's own `Random`, not casacore's `std::mt19937` bit-for-bit -- a
# deliberate, documented departure (dithering is a statistical-bias
# tool, not a correctness requirement: the decoder is agnostic to which
# of the two neighboring symbols the encoder picked for an in-between
# value).

# little-endian byte writer into a pre-sized buffer at 0-based offset
_dy_put!(buf::Vector{UInt8}, off::Integer, x::T) where {T} =
    (buf[off+1:off+sizeof(T)] = reinterpret(UInt8, [htol(x)]); nothing)

# --- symbol quantization (stochasticencoder.h:81-123) -----------------

"""
    _dysco_encode_symbol(boundaries, value) -> UInt32

Nearest-symbol quantization (no dithering): `boundaries` from
[`_dysco_boundaries`](@ref).  Non-finite `value` -> the reserved
non-finite symbol (`length(boundaries)`, one past the largest real
symbol).
"""
function _dysco_encode_symbol(boundaries::Vector{Float64}, value)
    isfinite(value) || return UInt32(length(boundaries))
    j = searchsortedfirst(boundaries, Float64(value))
    return UInt32(j - 1)
end

"""
    _dysco_encode_symbol_dither(dict, value, rng) -> UInt32

Stochastic-rounding quantization (`EncodeWithDithering`,
`stochasticencoder.h:103-123`): `dict` is the **decode** (centroid)
dictionary from [`_dysco_dictionary`](@ref) (dithering searches
centroids, not boundaries, per casacore).  `rng` supplies the dither
draw (Julia `Random`, not `std::mt19937` -- see file header).
"""
function _dysco_encode_symbol_dither(dict::Vector{Float64}, value, rng)
    isfinite(value) || return UInt32(length(dict) - 1)
    n = length(dict) - 1                       # number of real centroids
    j = searchsortedfirst(view(dict, 1:n), Float64(value))
    j == 1 && return UInt32(0)
    j == n + 1 && return UInt32(n - 1)
    rightValue = dict[j]
    leftValue  = dict[j-1]
    mark = Float64(UInt64(1) << 31) * (value - leftValue) / (rightValue - leftValue)
    r = Float64(rand(rng, UInt32) & 0x7fffffff)
    return mark > r ? UInt32(j - 1) : UInt32(j - 2)
end

# symbols for one block's worth of one :data column, row-outer /
# (channel,pol)-middle / (re,im)-inner -- matches the decode side's
# `base = br*(nchan*npol*2); si = base + (ch*npol+pl)*2` exactly.
function _dysco_symbols_for_data(vis::Array{ComplexF64,3}, boundaries::Vector{Float64},
                                 dict::Vector{Float64}, dither::Bool, rng)
    npol, nchan, nrows = size(vis)
    syms = Vector{UInt32}(undef, nrows * nchan * npol * 2)
    idx = 1
    @inbounds for r in 1:nrows
        for ch in 0:nchan-1, pl in 0:npol-1
            v = vis[pl+1, ch+1, r]
            if dither
                syms[idx] = _dysco_encode_symbol_dither(dict, real(v), rng); idx += 1
                syms[idx] = _dysco_encode_symbol_dither(dict, imag(v), rng); idx += 1
            else
                syms[idx] = _dysco_encode_symbol(boundaries, real(v)); idx += 1
                syms[idx] = _dysco_encode_symbol(boundaries, imag(v)); idx += 1
            end
        end
    end
    return syms
end

# --- weight encode (weightblockencoder.h:40-68) ------------------------

"""
    _dysco_encode_weight_block(w, bits) -> (maxValue::Float32, syms::Vector{UInt32})

`w` is `(npol,nchan,nrows)`.  Per (row,channel), the weight is the
`min` over polarizations (matching decode's "one weight broadcast to
every polarization"); `maxValue==0` is guarded to `1.0` (matches
casacore, avoids a zero scale).
"""
function _dysco_encode_weight_block(w::Array{Float32,3}, bits::Integer)
    npol, nchan, nrows = size(w)
    quantCount = 1 << Int(bits)
    weights = Matrix{Float32}(undef, nchan, nrows)
    maxValue = 0.0f0
    @inbounds for r in 1:nrows, ch in 1:nchan
        wt = w[1, ch, r]
        for pl in 2:npol
            wt = min(wt, w[pl, ch, r])
        end
        weights[ch, r] = wt
        wt > maxValue && (maxValue = wt)
    end
    maxValue == 0.0f0 && (maxValue = 1.0f0)
    scale = Float64(quantCount - 1) / Float64(maxValue)
    syms = Vector{UInt32}(undef, nchan * nrows)
    idx = 1
    @inbounds for r in 1:nrows, ch in 1:nchan
        syms[idx] = UInt32(floor(Float64(weights[ch, r]) * scale + 0.5))  # roundf: round-half-away (weight >= 0)
        idx += 1
    end
    return maxValue, syms
end

# --- AF normalization encode (aftimeblockencoder.cc) -------------------

# calculateAntennaeRMS (aftimeblockencoder.cc:341-399): damped-Jacobi
# iterative per-antenna RMS solve from the per-antenna-pair cross-
# correlation RMS matrix (autocorrelations excluded).
function _af_calculate_antenna_rms(vis::Array{ComplexF64,3}, pl::Int,
                                   a1::Vector{Int}, a2::Vector{Int}, antennaCount::Int)
    nrows = length(a1)
    nchan = size(vis, 2)
    sumsq = zeros(Float64, antennaCount, antennaCount)
    cnt   = zeros(Int, antennaCount, antennaCount)
    @inbounds for r in 1:nrows
        A1 = a1[r]; A2 = a2[r]
        A1 == A2 && continue
        i, j = A1 < A2 ? (A1, A2) : (A2, A1)
        for ch in 1:nchan
            v = vis[pl+1, ch, r]
            sumsq[i+1, j+1] += abs2(v)
            cnt[i+1, j+1] += 1
        end
    end
    matrix = zeros(Float64, antennaCount, antennaCount)
    @inbounds for i in 0:antennaCount-1, j in i:antennaCount-1
        c = cnt[i+1, j+1]
        rms = c == 0 ? 0.0 : sqrt(sumsq[i+1, j+1] / (2c))
        matrix[i+1, j+1] = rms
        matrix[j+1, i+1] = rms
    end

    rmsPerAntenna = ones(Float64, antennaCount)
    precision = 1.0
    iter = 0
    while iter < 100 && precision > 1e-6
        iter += 1
        nextRMS = zeros(Float64, antennaCount)
        @inbounds for i in 1:antennaCount
            weightSum = 0.0
            for j in 1:antennaCount
                i == j && continue
                w = rmsPerAntenna[j]
                w == 0.0 && continue
                mv = matrix[i, j]
                isfinite(mv) || continue
                nextRMS[i] += mv
                weightSum += w
            end
            nextRMS[i] = weightSum == 0.0 ? 0.0 : nextRMS[i] / weightSum
        end
        maxVal = 0.0
        @inbounds for i in 1:antennaCount
            rmsPerAntenna[i] = nextRMS[i] * 0.8 + rmsPerAntenna[i] * 0.2
            maxVal = max(maxVal, rmsPerAntenna[i])
        end
        precision = 0.0
        @inbounds for i in 1:antennaCount
            if rmsPerAntenna[i] < maxVal * 1e-5
                rmsPerAntenna[i] = 0.0
            end
            precision = max(precision, abs(rmsPerAntenna[i] - nextRMS[i]) / maxVal)
        end
    end
    return rmsPerAntenna   # 1-based: rmsPerAntenna[a+1] = RMS for 0-based antenna a
end

# fitToMaximum (aftimeblockencoder.cc:100-263): greedy hill-climb
# alternating between boosting one channel or one antenna to use more of
# the quantizer's dynamic range, for one polarization at a time.
# Autocorrelations are excluded from the search but (via the antenna
# branch touching every row referencing that antenna) still get scaled.
function _af_fit_to_maximum!(vis::Array{ComplexF64,3}, meta::Vector{Float64}, pl::Int,
                             a1::Vector{Int}, a2::Vector{Int}, antennaCount::Int, maxQ::Float64)
    npol, nchan, nrows = size(vis)
    visPerRow = npol * nchan

    # Step 1: flat per-channel scale so the largest cross-corr component
    # hits maxQ exactly, before the greedy loop starts.
    @inbounds for ch in 0:nchan-1
        largest = 0.0
        for r in 1:nrows
            a1[r] == a2[r] && continue
            v = vis[pl+1, ch+1, r]
            lm = max(real(v), imag(v), -real(v), -imag(v))
            isfinite(lm) && lm > largest && (largest = lm)
        end
        factor = (maxQ == 0.0 || largest == 0.0) ? 1.0 : maxQ / largest
        visIndex = ch * npol + pl
        meta[visIndex+1] /= factor
        for r in 1:nrows
            vis[pl+1, ch+1, r] *= factor
        end
    end

    isProgressing = true
    while isProgressing
        bestChannelIncrease = 0.0
        channelFactor = 1.0
        bestChannel = 0
        @inbounds for ch in 0:nchan-1
            largest = 0.0
            for r in 1:nrows
                a1[r] == a2[r] && continue
                v = vis[pl+1, ch+1, r]
                lm = max(real(v), imag(v), -real(v), -imag(v))
                isfinite(lm) && lm > largest && (largest = lm)
            end
            factor = largest == 0.0 ? 0.0 : (maxQ / largest - 1.0)
            thisIncrease = 0.0
            for r in 1:nrows
                a1[r] == a2[r] && continue
                v = vis[pl+1, ch+1, r] * factor
                av = abs(real(v)) + abs(imag(v))
                isfinite(av) && (thisIncrease += av)
            end
            if thisIncrease > bestChannelIncrease
                bestChannelIncrease = thisIncrease
                bestChannel = ch
                channelFactor = factor + 1.0
            end
        end

        maxCompPerAntenna = zeros(Float64, antennaCount)
        @inbounds for r in 1:nrows
            a1[r] == a2[r] && continue
            for ch in 0:nchan-1
                v = vis[pl+1, ch+1, r]
                cm = max(real(v), imag(v), -real(v), -imag(v))
                isfinite(cm) || continue
                A1 = a1[r]; A2 = a2[r]
                cm > maxCompPerAntenna[A1+1] && (maxCompPerAntenna[A1+1] = cm)
                cm > maxCompPerAntenna[A2+1] && (maxCompPerAntenna[A2+1] = cm)
            end
        end
        increasePerAntenna = zeros(Float64, antennaCount)
        @inbounds for r in 1:nrows
            a1[r] == a2[r] && continue
            A1 = a1[r]; A2 = a2[r]
            factor1 = maxCompPerAntenna[A1+1] == 0.0 ? 0.0 : (maxQ / maxCompPerAntenna[A1+1] - 1.0)
            factor2 = maxCompPerAntenna[A2+1] == 0.0 ? 0.0 : (maxQ / maxCompPerAntenna[A2+1] - 1.0)
            for ch in 0:nchan-1
                v1 = vis[pl+1, ch+1, r] * factor1
                av1 = abs(real(v1)) + abs(imag(v1))
                isfinite(av1) && (increasePerAntenna[A1+1] += av1)
                v2 = vis[pl+1, ch+1, r] * factor2
                av2 = abs(real(v2)) + abs(imag(v2))
                isfinite(av2) && (increasePerAntenna[A2+1] += av2)
            end
        end
        bestAntenna = 0
        bestAntennaIncrease = 0.0
        @inbounds for a in 0:antennaCount-1
            if increasePerAntenna[a+1] > bestAntennaIncrease
                bestAntennaIncrease = increasePerAntenna[a+1]
                bestAntenna = a
            end
        end

        if bestAntennaIncrease > bestChannelIncrease
            factor = maxCompPerAntenna[bestAntenna+1] == 0.0 ? 1.0 :
                     (maxQ / maxCompPerAntenna[bestAntenna+1])
            if factor < 1.0
                isProgressing = false
            else
                isProgressing = factor > 1.01
                metaIndex = visPerRow + antennaCount * pl
                meta[metaIndex+bestAntenna+1] /= factor
                @inbounds for r in 1:nrows
                    count = (a1[r] == bestAntenna) + (a2[r] == bestAntenna)
                    for _ in 1:count, ch in 0:nchan-1
                        vis[pl+1, ch+1, r] *= factor
                    end
                end
            end
        else
            if channelFactor < 1.0
                isProgressing = false
            else
                isProgressing = channelFactor > 1.001
                visIndex = bestChannel * npol + pl
                meta[visIndex+1] /= channelFactor
                @inbounds for r in 1:nrows
                    vis[pl+1, bestChannel+1, r] *= channelFactor
                end
            end
        end
    end
    return nothing
end

# --- per-normalization encode: metadata + in-place vis normalization ---

function _dysco_normalize!(::AFNorm, vis::Array{ComplexF64,3}, meta::Vector{Float64},
                           a1::Vector{Int}, a2::Vector{Int}, antennaCount::Int, maxQ::Float64)
    npol, nchan, nrows = size(vis)
    # channel RMS (encode<UseDithering>, aftimeblockencoder.cc:265-330)
    @inbounds for pl in 0:npol-1, ch in 0:nchan-1
        s = 0.0
        for r in 1:nrows
            s += abs2(vis[pl+1, ch+1, r])
        end
        rms = sqrt(s / (2 * nrows))
        idx = ch * npol + pl
        meta[idx+1] = rms
        if rms != 0.0
            for r in 1:nrows
                vis[pl+1, ch+1, r] /= rms
            end
        end
    end
    antBase = npol * nchan
    for pl in 0:npol-1
        rmsA = _af_calculate_antenna_rms(vis, pl, a1, a2, antennaCount)
        @inbounds for r in 1:nrows
            mul = rmsA[a1[r]+1] * rmsA[a2[r]+1]
            fac = mul == 0.0 ? 0.0 : 1.0 / mul
            for ch in 0:nchan-1
                vis[pl+1, ch+1, r] *= fac
            end
        end
        @inbounds for a in 0:antennaCount-1
            meta[antBase+pl*antennaCount+a+1] = rmsA[a+1]
        end
        _af_fit_to_maximum!(vis, meta, pl, a1, a2, antennaCount, maxQ)
    end
    return nothing
end

function _dysco_normalize!(::RFNorm, vis::Array{ComplexF64,3}, meta::Vector{Float64},
                           a1::Vector{Int}, a2::Vector{Int}, antennaCount::Int, maxQ::Float64)
    npol, nchan, nrows = size(vis)
    visPerRow = npol * nchan
    # maximizeRows (rftimeblockencoder.cc:16-44) -- rows first, so auto-
    # and cross-correlations are on the same level before channel scaling
    # (autocorrelations are NOT excluded here, unlike AF).
    @inbounds for r in 1:nrows, pl in 0:npol-1
        maxval = 0.0
        for ch in 0:nchan-1
            v = vis[pl+1, ch+1, r]
            m = max(abs(real(v)), abs(imag(v)))
            isfinite(m) && (maxval = max(maxval, m))
        end
        factor = maxval == 0.0 ? 1.0 : maxQ / maxval
        for ch in 0:nchan-1
            vis[pl+1, ch+1, r] *= factor
        end
        meta[visPerRow+(r-1)*npol+pl+1] = maxQ == 0.0 ? 1.0 : maxval / maxQ
    end
    # maximizeChannels (rftimeblockencoder.cc:46-68)
    @inbounds for ch in 0:nchan-1, pl in 0:npol-1
        i = ch * npol + pl
        largest = 0.0
        for r in 1:nrows
            v = vis[pl+1, ch+1, r]
            m = max(abs(real(v)), abs(imag(v)))
            isfinite(m) && m > largest && (largest = m)
        end
        factor = (maxQ == 0.0 || largest == 0.0) ? 1.0 : maxQ / largest
        meta[i+1] = 1.0 / factor
        for r in 1:nrows
            vis[pl+1, ch+1, r] *= factor
        end
    end
    return nothing
end

function _dysco_normalize!(::RowNorm, vis::Array{ComplexF64,3}, meta::Vector{Float64},
                           a1::Vector{Int}, a2::Vector{Int}, antennaCount::Int, maxQ::Float64)
    npol, nchan, nrows = size(vis)
    @inbounds for r in 1:nrows
        maxval = 0.0
        for ch in 1:nchan, pl in 1:npol
            v = vis[pl, ch, r]
            m = max(abs(real(v)), abs(imag(v)))
            isfinite(m) && (maxval = max(maxval, m))
        end
        factor = maxval == 0.0 ? 1.0 : maxQ / maxval
        for ch in 1:nchan, pl in 1:npol
            vis[pl, ch, r] *= factor
        end
        meta[r] = maxQ == 0.0 ? 1.0 : maxval / maxQ
    end
    return nothing
end

# --- header + block writer ----------------------------------------------

"""
    write_dyscostman(dir, sequ, cols, coldata, nrow, endian;
                     normalization=AFNorm(), distribution=TruncatedGaussian(),
                     dataBitCount=10, weightBitCount=12,
                     distributionTruncation=2.5, studentTNu=5.0,
                     antenna1, antenna2, rowsPerBlock=nrow,
                     dither=true, rng=Random.default_rng()) -> UInt8[]

Compress `cols`/`coldata` (parallel, binding order; each a DATA-like
`ComplexF32` array column or the `WEIGHT_SPECTRUM` `Float32` column) into
a genuine `DyscoStMan` file at `table.f<sequ>`.  `antenna1`/`antenna2`
(0-based, length `nrow`) are mandatory -- every normalization scheme's
on-disk header carries an `antennaCount` field regardless of whether that
normalization actually uses it (matches real Dysco, which derives it
unconditionally too).  `rowsPerBlock` defaults to `nrow` (one block for
the whole write) since, unlike real casacore's streaming writer, this
function has no visibility into MAIN's TIME/FIELD_ID/DATA_DESC_ID columns
to infer block boundaries from -- pass it explicitly to get multiple
blocks.  Matches the `(dir, sequ, cols, coldata, nrow, endian) -> UInt8[]`
shape every other writer in this package uses; `DyscoStMan` contributes
no columnset block (matches `DyscoStMan::flush` returning `false`).
"""
function write_dyscostman(dir::AbstractString, sequ::Int, cols::Vector{<:ColumnDesc},
                          coldata::Vector, nrow::Int, endian::Symbol;
                          normalization::DyscoNormalization=AFNorm(),
                          distribution::DyscoDistribution=TruncatedGaussian(),
                          dataBitCount::Integer=10, weightBitCount::Integer=12,
                          distributionTruncation::Real=2.5, studentTNu::Real=5.0,
                          antenna1::AbstractVector{<:Integer},
                          antenna2::AbstractVector{<:Integer},
                          rowsPerBlock::Integer=nrow, dither::Bool=true,
                          rng=Random.default_rng())
    ncol = length(cols)
    ncol == length(coldata) || error("write_dyscostman: cols/coldata length mismatch")
    length(antenna1) == nrow && length(antenna2) == nrow ||
        error("write_dyscostman: antenna1/antenna2 must have length nrow ($nrow)")
    rpb = Int(rowsPerBlock)
    rpb > 0 || error("write_dyscostman: rowsPerBlock must be positive")

    antennaCount = nrow == 0 ? 0 : maximum(vcat(collect(Int, antenna1), collect(Int, antenna2))) + 1
    dataBits = Int(dataBitCount)
    weightBits = Int(weightBitCount)
    trunc_ = Float64(distributionTruncation)
    nu = Float64(studentTNu)

    boundaries = _dysco_boundaries(distribution, dataBits, trunc_, nu)
    dict = _dysco_dictionary(distribution, dataBits, trunc_, nu)
    maxQ = dict[end-1]                       # largest finite centroid

    colKind  = [c.name == "WEIGHT_SPECTRUM" ? :weight : :data for c in cols]
    colShape = [(c.shape[1], c.shape[2]) for c in cols]

    nblocks = cld(nrow, rpb)

    colBlockSize = Vector{Int}(undef, ncol)
    for i in 1:ncol
        npol, nchan = colShape[i]
        if colKind[i] === :data
            metaN = _dysco_metacount(normalization, npol, nchan, rpb, antennaCount)
            symN = rpb * nchan * npol * 2
            colBlockSize[i] = metaN * 4 + cld(symN * dataBits, 8)
        else
            symN = rpb * nchan
            colBlockSize[i] = 1 * 4 + cld(symN * weightBits, 8)
        end
    end
    blockSize = sum(colBlockSize)
    colOffset = Vector{Int}(undef, ncol)
    running = 0
    for i in 1:ncol
        colOffset[i] = running
        running += colBlockSize[i]
    end

    name = "dysco"
    columnHeaderOffset = 7 * 4 + length(name) + 2 * 2 + 4 * 1 + 2 * 8
    headerSize = columnHeaderOffset + ncol * 12

    buf = zeros(UInt8, headerSize + blockSize * nblocks)
    _dy_put!(buf, 0, UInt32(headerSize))
    _dy_put!(buf, 4, UInt32(columnHeaderOffset))
    _dy_put!(buf, 8, UInt32(ncol))
    _dy_put!(buf, 12, UInt32(length(name)))
    buf[17:16+length(name)] = codeunits(name)
    p = 16 + length(name)
    _dy_put!(buf, p, UInt32(rpb)); p += 4
    _dy_put!(buf, p, UInt32(antennaCount)); p += 4
    _dy_put!(buf, p, UInt32(blockSize)); p += 4
    _dy_put!(buf, p, UInt16(1)); p += 2                    # versionMajor
    _dy_put!(buf, p, UInt16(0)); p += 2                    # versionMinor
    _dy_put!(buf, p, UInt8(dataBits)); p += 1
    _dy_put!(buf, p, UInt8(weightBits)); p += 1
    _dy_put!(buf, p, _dysco_dist_code(distribution)); p += 1
    _dy_put!(buf, p, _dysco_norm_code(normalization)); p += 1
    _dy_put!(buf, p, nu); p += 8
    _dy_put!(buf, p, trunc_); p += 8
    p == columnHeaderOffset || error("write_dyscostman: internal header-size mismatch")

    cp = columnHeaderOffset
    for i in 1:ncol
        _dy_put!(buf, cp, UInt32(12)); cp += 4
        _dy_put!(buf, cp, UInt32(colBlockSize[i])); cp += 4
        _dy_put!(buf, cp, UInt32(antennaCount)); cp += 4
    end
    cp == headerSize || error("write_dyscostman: internal column-header-size mismatch")

    for b in 0:nblocks-1
        r0 = b * rpb                          # 0-based first row of this block
        nInBlock = min(rpb, nrow - r0)
        blockstart = headerSize + blockSize * b
        a1full = zeros(Int, rpb)
        a2full = zeros(Int, rpb)
        @inbounds for r in 1:nInBlock
            a1full[r] = Int(antenna1[r0+r])
            a2full[r] = Int(antenna2[r0+r])
        end
        for i in 1:ncol
            npol, nchan = colShape[i]
            colstart = blockstart + colOffset[i]
            if colKind[i] === :data
                vis = zeros(ComplexF64, npol, nchan, rpb)
                @inbounds for r in 1:nInBlock
                    cell = coldata[i][r0+r]
                    for ch in 1:nchan, pl in 1:npol
                        vis[pl, ch, r] = ComplexF64(cell[pl, ch])
                    end
                end
                metaN = _dysco_metacount(normalization, npol, nchan, rpb, antennaCount)
                meta = zeros(Float64, metaN)
                _dysco_normalize!(normalization, vis, meta, a1full, a2full, antennaCount, maxQ)
                syms = _dysco_symbols_for_data(vis, boundaries, dict, dither, rng)
                packed = _dysco_pack(dataBits, syms)
                @inbounds for k in 1:metaN
                    _dy_put!(buf, colstart + 4 * (k - 1), Float32(meta[k]))
                end
                off2 = colstart + metaN * 4
                buf[off2+1:off2+length(packed)] = packed
            else
                w = zeros(Float32, npol, nchan, rpb)
                @inbounds for r in 1:nInBlock
                    cell = coldata[i][r0+r]
                    for ch in 1:nchan, pl in 1:npol
                        w[pl, ch, r] = Float32(cell[pl, ch])
                    end
                end
                maxv, wsyms = _dysco_encode_weight_block(w, weightBits)
                packed = _dysco_pack(weightBits, wsyms)
                _dy_put!(buf, colstart, Float32(maxv))
                off2 = colstart + 4
                buf[off2+1:off2+length(packed)] = packed
            end
        end
    end

    _atomic_write(joinpath(dir, "table.f$sequ"), buf)
    return UInt8[]
end
