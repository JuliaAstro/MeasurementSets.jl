# DyscoStMan (read only) --- the third-party lossy-compression storage
# manager (aroffringa/dysco; vendored at `tables/Dysco/` in a casacore
# checkout, registered as data-manager type "DyscoStMan").  Scope: **AF
# normalization + TruncatedGaussian quantization only** (the real-world
# default combo, `dyscostman.h:106-107`); any other distribution/
# normalization code is a clear `error`, not a silent misdecode.
#
# Mirrors tables/Dysco/{header.h, serializable.h, dyscostman.{h,cc},
# threadeddyscocolumn.{h,cc}, aftimeblockencoder.{h,cc},
# weightblockencoder.h, stochasticencoder.{h,cc}, bytepacker.h}.
#
# `DyscoStMan::flush` returns `false` (`dyscostman.cc:162-165`), so
# `table.dat`'s ColumnSet carries an empty per-DM block for it -- exactly
# like a Phase-12 virtual engine, and `read_columnset` already tolerates
# that with no change.  All configuration lives in the private file's own
# header at `table.f<seq>` (casacore's ordinary `DataManager::fileName()`
# convention, not overridden by Dysco).  There is **no AipsIO framing at
# all** here: every field is a raw native-little-endian memcpy
# (`Serializable`, `serializable.h`) -- unlike every other data manager in
# this package.
#
# File layout:
#   [Header][per-column GenericColumnHeader+ExtraHeader, binding order]
#   [block 0][block 1]...      -- fixed `blockSize` each, no row index;
#                                  row -> block = row div rowsPerBlock.
# Each column's bytes within a block = `[metaDataFloatCount x f32][bit-
# packed symbols]`; columns are laid out back-to-back in a block per the
# *stored* per-column blockSize (a running sum in binding order gives
# each column's byte offset within the shared block -- confirmed against
# a real casacore-written file, see the phase-18 plan notes).  Rows past
# the last committed block read as zero -- Dysco's own documented
# behaviour for never-written trailing rows
# (`threadeddyscocolumn.cc:109-118`).

import SpecialFunctions: erf, erfinv

# --- primitive little-endian readers (no AipsIO framing here) --------

_dy_get(d::AbstractVector{UInt8}, ::Type{T}, off::Integer) where {T} =
    ltoh(reinterpret(T, @view d[off+1:off+sizeof(T)])[1])

# --- quantization dictionary (stochasticencoder.cc:146-171) ----------

"""
    _dysco_dictionary(bits, truncation) -> Vector{Float64}

The TruncatedGaussian decode dictionary for a `bits`-wide symbol: length
`2^bits`, entries `1:end-1` finite and increasing, `dict[end] = NaN` (the
reserved non-finite-value symbol).  `rms` is always `1.0` here -- the
magnitude comes from the AF normalization factor applied on decode, not
from this dictionary (`dyscodatacolumn.cc:44-48`).
"""
function _dysco_dictionary(bits::Integer, truncation::Float64)
    quantCount = 1 << Int(bits)
    n = quantCount - 1
    cdfTrunc = 0.5 * (1.0 + erf(-truncation / sqrt(2.0)))     # Phi(-truncation)
    factor = 1.0 - 2.0 * cdfTrunc
    dict = Vector{Float64}(undef, quantCount)
    @inbounds for i in 0:n-1
        val = (i + 0.5) / n
        cdfVal = val * factor + cdfTrunc
        dict[i+1] = sqrt(2.0) * erfinv(2.0 * cdfVal - 1.0)    # Phi^-1(cdfVal)
    end
    dict[quantCount] = NaN
    return dict
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
    distributionTruncation::Float64
    colOffset::Vector{Int}         # per bound column (binding order): byte offset in block
    colKind::Vector{Symbol}        # :data | :weight
    colShape::Vector{Tuple{Int,Int}}  # (npol, nchan) per bound column
    dict::Vector{Float64}          # length 2^dataBitCount, dict[end] = NaN
    ant1::Vector{Int}              # 0-based antenna ids, from the table's own ANTENNA1/2
    ant2::Vector{Int}
end

DATAMANAGERS["DyscoStMan"] = DyscoStMan

"""
    open(::Type{DyscoStMan}, t::Table, dm::DataManagerInfo) -> DyscoStMan

Parse the private `table.f<seq>` header + per-column headers.  `error`s
clearly (naming the unsupported code) for any file-format version,
distribution, or normalization outside the supported AF +
TruncatedGaussian, version-1.0 combo.
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
    distribution   = Int(_dy_get(data, UInt8, p)); p += 1
    normalization  = Int(_dy_get(data, UInt8, p)); p += 1
    _studentTNu             = _dy_get(data, Float64, p); p += 8
    distributionTruncation  = _dy_get(data, Float64, p); p += 8

    (versionMajor == 1 && versionMinor == 0) ||
        error("DyscoStMan \"$path\": file format version $versionMajor.$versionMinor " *
              "is not supported (only 1.0 is)")
    distribution == 3 ||
        error("DyscoStMan \"$path\": distribution code $distribution is not supported " *
              "(only TruncatedGaussian(3) is)")
    normalization == 0 ||
        error("DyscoStMan \"$path\": normalization code $normalization is not supported " *
              "(only AF(0) is)")

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
    dict = _dysco_dictionary(dataBitCount, distributionTruncation)

    ant1 = Int.(column(t, "ANTENNA1")[:])
    ant2 = Int.(column(t, "ANTENNA2")[:])

    return DyscoStMan(data, t.rows, headerSize, rowsPerBlock, antennaCount, blockSize,
                      nBlocksInFile, dataBitCount, weightBitCount,
                      distributionTruncation, colOffset, colKind, colShape,
                      dict, ant1, ant2)
end

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
        metaN = npol * (nchan + nant)
        meta = Vector{Float64}(undef, metaN)
        @inbounds for k in 0:metaN-1
            meta[k+1] = Float64(_dy_get(dm.data, Float32, colstart + 4k))
        end
        antBase = npol * nchan

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
                    chRMS = meta[ch*npol + pl + 1]
                    f1 = meta[antBase + pl*nant + a1 + 1]
                    f2 = meta[antBase + pl*nant + a2 + 1]
                    factor = chRMS * f1 * f2
                    si = base + (ch*npol + pl) * 2
                    re = dict[syms[si+1] + 1]
                    im = dict[syms[si+2] + 1]
                    cell[pl+1, ch+1] = ComplexF32(re * factor, im * factor)
                end
            end
            out[br+1] = cell
        end

    else # :weight -- WeightBlockEncoder: a plain linear quantizer, no dictionary
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
