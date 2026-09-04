# Phase 18: DyscoStMan (read).  Scope: AF normalization + TruncatedGaussian
# quantization only (the real-world default combo) -- see src/datamanagers/
# dysco.jl for the on-disk format.

# A CASA install with Dysco compiled into libcasa_tables (confirmed via
# `nm -gU` on this machine) gives a genuine interop oracle: casatools'
# table.create(...; dminfo=...) writes a real DyscoStMan-backed column, and
# its own getcol() decode is the ground truth to compare against.  Skipped
# cleanly wherever that CASA install isn't present (e.g. CI).
const _CASA_PYTHON = get(ENV, "MEASUREMENTSETV2_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")
const _HAVE_CASA = isfile(_CASA_PYTHON)
_HAVE_CASA || @info "CASA python3 not found; skipping Dysco real-interop test" _CASA_PYTHON

@testset "dysco -- bit-packer (generic LSB-first bitstream)" begin
    # Hand-derived byte-exact case: pack4 packs 2 symbols/byte, low nibble
    # first (bytepacker.h:447-459) -- [1,2,3,5] -> [0x21, 0x53].
    @test MSv2._dysco_unpack(4, UInt8[0x21, 0x53], 4) == UInt32[1, 2, 3, 5]

    # Independent reference packer (LSB-first bit concatenation via
    # BigInt), cross-checked against the package's unpacker over the test
    # vector + sweep from tables/Dysco/tests/testbytepacking.cc.
    function ref_pack(bits, vals)
        acc = big(0)
        for (i, v) in enumerate(vals)
            acc |= big(UInt64(v)) << ((i - 1) * bits)
        end
        nbytes = cld(length(vals) * bits, 8)
        return UInt8[UInt8((acc >> (8 * (k - 1))) & 0xFF) for k in 1:nbytes]
    end

    src = UInt32[1, 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31]
    for bits in (2, 3, 4, 6, 8, 10, 12, 16)
        mask = UInt32((1 << bits) - 1)
        for s in 0:length(src)
            m = [v & mask for v in src[1:s]]
            packed = ref_pack(bits, m)
            @test MSv2._dysco_unpack(bits, packed, s) == m
        end
        allset = fill(mask, 15)
        @test MSv2._dysco_unpack(bits, ref_pack(bits, allset), 15) == allset
    end
end

@testset "dysco -- quantization dictionary" begin
    Φinv(p) = sqrt(2) * MSv2.erfinv(2p - 1)
    @test isapprox(Φinv(0.5), 0.0; atol=1e-12)
    @test isapprox(Φinv(0.8413447460685429), 1.0; atol=1e-6)

    for bits in (4, 8, 10, 12)
        d = MSv2._dysco_dictionary(bits, 2.5)
        @test length(d) == 2^bits
        @test isnan(d[end])
        finite = @view d[1:end-1]
        @test issorted(finite)
        @test isapprox(finite[1], -finite[end]; atol=1e-9)   # symmetric around 0
    end
end

@testset "dysco -- unsupported format/distribution/normalization" begin
    dir = mktempdir()
    cdesc = ColumnDesc("DATA", "", "DyscoStMan", "dysco", MSv2.TpComplex,
                       "ArrayColumnDesc<Complex>", (2, 4), Int32(5), UInt32(0),
                       Record(), nothing, 0)
    td = TableDesc("T", "2", "", Record(), Record(), [cdesc])
    dm = MSv2.DataManagerInfo("DyscoStMan", 0, UInt8[])
    tbl = MSv2.Table(dir, "", "", "", 2, 1, :little, td, [dm],
                     Int64(-1), joinpath(dir, "table.lock"))

    # A minimal, otherwise-valid header + one zero-filled block; only the
    # field under test is varied.  Column-count / column-header bytes stay
    # fixed so the version/distribution/normalization checks (which run
    # before the column-count check and before any ANTENNA1/2 read) are
    # what actually fires.
    function write_header(path; version=(1, 0), distribution=3, normalization=0)
        name = "dysco"
        buf = UInt8[]
        append!(buf, reinterpret(UInt8, [htol(UInt32(0))]))     # headerSize (patched)
        append!(buf, reinterpret(UInt8, [htol(UInt32(0))]))     # columnHeaderOffset (patched)
        append!(buf, reinterpret(UInt8, [htol(UInt32(1))]))     # columnCount
        append!(buf, reinterpret(UInt8, [htol(UInt32(length(name)))]))
        append!(buf, codeunits(name))
        append!(buf, reinterpret(UInt8, [htol(UInt32(1))]))     # rowsPerBlock
        append!(buf, reinterpret(UInt8, [htol(UInt32(1))]))     # antennaCount
        append!(buf, reinterpret(UInt8, [htol(UInt32(0))]))     # blockSize (patched)
        append!(buf, reinterpret(UInt8, [htol(UInt16(version[1]))]))
        append!(buf, reinterpret(UInt8, [htol(UInt16(version[2]))]))
        push!(buf, UInt8(10))                                    # dataBitCount
        push!(buf, UInt8(12))                                    # weightBitCount
        push!(buf, UInt8(distribution))
        push!(buf, UInt8(normalization))
        append!(buf, reinterpret(UInt8, [htol(Float64(0.0))]))   # studentTNu
        append!(buf, reinterpret(UInt8, [htol(Float64(2.5))]))   # distributionTruncation
        columnHeaderOffset = length(buf)
        colblocksize = 264
        append!(buf, reinterpret(UInt8, [htol(UInt32(12))]))     # columnHeaderSize
        append!(buf, reinterpret(UInt8, [htol(UInt32(colblocksize))]))
        append!(buf, reinterpret(UInt8, [htol(UInt32(1))]))      # column antennaCount
        headerSize = length(buf)
        buf[1:4] = reinterpret(UInt8, [htol(UInt32(headerSize))])
        buf[5:8] = reinterpret(UInt8, [htol(UInt32(columnHeaderOffset))])
        append!(buf, zeros(UInt8, colblocksize))                 # one padding block
        write(path, buf)
    end

    path = joinpath(dir, "table.f0")
    _try(f) = try; f(); nothing; catch e; e; end

    write_header(path; version=(2, 0))
    e1 = _try(() -> open(MSv2.DyscoStMan, tbl, dm))
    @test e1 isa ErrorException && occursin("2.0", e1.msg)

    write_header(path; distribution=0)
    e2 = _try(() -> open(MSv2.DyscoStMan, tbl, dm))
    @test e2 isa ErrorException && occursin("distribution code 0", e2.msg)

    write_header(path; normalization=1)
    e3 = _try(() -> open(MSv2.DyscoStMan, tbl, dm))
    @test e3 isa ErrorException && occursin("normalization code 1", e3.msg)
end

if _HAVE_CASA
    @testset "dysco -- real interop (CASA.app casatools)" begin
        dir = mktempdir()
        nant, ntime, nchan, npol = 4, 5, 4, 2
        dbits, wbits, seed = 10, 12, 42
        script = joinpath(@__DIR__, "dysco_fixture.py")
        # run with cwd = the scratch dir -- casatools writes its own
        # "casa-<timestamp>.log" into the current directory otherwise.
        cmd = Cmd(`$_CASA_PYTHON $script $dir $nant $ntime $nchan $npol $dbits $wbits $seed`;
                  dir)
        out = read(cmd, String)
        @test occursin("DYSCO_FIXTURE_OK", out)

        meta = parse.(Int, split(strip(read(joinpath(dir, "meta.txt"), String))))
        nant2, nbl, ntime2, nr, nchan2, npol2 = meta
        @test (nant2, ntime2, nchan2, npol2) == (nant, ntime, nchan, npol)

        tab = joinpath(dir, "dysco.tab")
        t = readtable(tab)
        @test nrow(t) == nr
        @test "DyscoStMan" in [m.name for m in t.managers]

        data_c = reinterpret(ComplexF32, read(joinpath(dir, "data_decoded.bin")))
        weight_c = reinterpret(Float32, read(joinpath(dir, "weight_decoded.bin")))
        casa_data(p, ch, r)   = data_c[(p - 1) * nchan * nr + (ch - 1) * nr + r]
        casa_weight(p, ch, r) = weight_c[(p - 1) * nchan * nr + (ch - 1) * nr + r]

        data_col = column(t, "DATA")
        weight_col = column(t, "WEIGHT_SPECTRUM")

        maxerr_d = maxerr_w = 0.0
        for r in 1:nr
            cd = data_col[r]
            cw = weight_col[r]
            @test size(cd) == (npol, nchan)
            @test size(cw) == (npol, nchan)
            for ch in 1:nchan, p in 1:npol
                maxerr_d = max(maxerr_d, abs(cd[p, ch] - casa_data(p, ch, r)))
                maxerr_w = max(maxerr_w, abs(cw[p, ch] - casa_weight(p, ch, r)))
            end
        end
        @test maxerr_d < 1e-3     # float32 quantization/rounding-level agreement
        @test maxerr_w == 0.0     # WEIGHT is a plain linear quantizer -- exact

        # whole-column fast path agrees with the per-cell path, and with CASA
        data_all = data_col[:]
        weight_all = weight_col[:]
        maxerr_d2 = 0.0
        for r in 1:nr
            @test data_all[r] == data_col[r]
            @test weight_all[r] == weight_col[r]
            for ch in 1:nchan, p in 1:npol
                maxerr_d2 = max(maxerr_d2, abs(data_all[r][p, ch] - casa_data(p, ch, r)))
            end
        end
        @test maxerr_d2 < 1e-3

        if _HAVE_CASACORE
            cct = CCT.Table(tab)
            @test size(cct, 1) == nr
        end

        # "rows past the last committed block read as zero" -- truncate the
        # real private file so only the first `nBlocksInFile - 1` blocks
        # remain, and check the tail reads back as exact zero (real bytes,
        # not a synthetic fixture).
        inst = data_col.inst
        @test inst isa MSv2.DyscoStMan
        if inst.nBlocksInFile > 1
            dyscopath = joinpath(tab, "table.f$(only(m.sequ for m in t.managers if m.name == "DyscoStMan"))")
            keep = inst.nBlocksInFile - 1
            newlen = inst.headerSize + inst.blockSize * keep
            raw = read(dyscopath)
            write(dyscopath, raw[1:newlen])

            t2 = readtable(tab)
            dcol2 = column(t2, "DATA")
            wcol2 = column(t2, "WEIGHT_SPECTRUM")
            cutoff = keep * inst.rowsPerBlock     # 0-based; rows > cutoff should be zero
            for r in (cutoff + 1):nr
                @test all(iszero, dcol2[r])
                @test all(iszero, wcol2[r])
            end
        end
    end
end
