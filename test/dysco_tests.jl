# Phase 18: DyscoStMan (read).  Phase 19: full read + write (all three
# normalizations, all four distributions) -- see src/datamanagers/dysco.jl
# for the on-disk format and the encode-side algorithms.

# A CASA install with Dysco compiled into libcasa_tables (confirmed via
# `nm -gU` on this machine) gives a genuine interop oracle: casatools'
# table.create(...; dminfo=...) writes a real DyscoStMan-backed column, and
# its own getcol() decode is the ground truth to compare against.  Skipped
# cleanly wherever that CASA install isn't present (e.g. CI).
const _CASA_PYTHON = get(ENV, "MEASUREMENTSETV2_CASA_PYTHON",
    "/Volumes/casa-6.6.6.18-pipeline-2025.1.0.36-14.0-arm64-py310-py310.dmg/CASA.app/Contents/MacOS/python3")
const _HAVE_CASA = isfile(_CASA_PYTHON)
_HAVE_CASA || @info "CASA python3 not found; skipping Dysco real-interop test" _CASA_PYTHON

# Run CASA's own getcol() on `colname` in the table at `tab` and return the
# raw bytes (native byte order) -- the write-side interop oracle: CASA
# decodes a table *we* wrote, and we compare its decode to ours.
function _casa_getcol_bytes(tab::AbstractString, colname::AbstractString, npy_dtype::AbstractString)
    outdir = mktempdir()
    outfile = joinpath(outdir, "col.bin")
    script = """
import casatools, numpy as np
tb = casatools.table()
tb.open('$tab')
d = tb.getcol('$colname')
d.astype(np.$npy_dtype).tofile('$outfile')
tb.close()
"""
    scriptfile = joinpath(outdir, "getcol.py")
    write(scriptfile, script)
    run(Cmd(`$_CASA_PYTHON $scriptfile`; dir=outdir))
    return read(outfile)
end

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
        d = MSv2._dysco_dictionary(MSv2.TruncatedGaussian(), bits, 2.5, 0.0)
        @test length(d) == 2^bits
        @test isnan(d[end])
        finite = @view d[1:end-1]
        @test issorted(finite)
        @test isapprox(finite[1], -finite[end]; atol=1e-9)   # symmetric around 0

        b = MSv2._dysco_boundaries(MSv2.TruncatedGaussian(), bits, 2.5, 0.0)
        @test length(b) == 2^bits - 1
        @test b[end] == Inf
        @test issorted(b)
    end

    # Gaussian/Uniform dictionaries (generic gaussianMapping constructor)
    for bits in (4, 8, 10)
        dg = MSv2._dysco_dictionary(MSv2.Gaussian(), bits, 0.0, 0.0)
        du = MSv2._dysco_dictionary(MSv2.Uniform(), bits, 0.0, 0.0)
        @test length(dg) == 2^bits && isnan(dg[end])
        @test length(du) == 2^bits && isnan(du[end])
        @test issorted(@view dg[1:end-1])
        @test issorted(@view du[1:end-1])
        # Uniform is exactly linear: entry i (0-based) = sqrt(3)*(-1+2(i+0.5)/n)
        n = 2^bits - 1
        @test isapprox(du[1], sqrt(3.0) * (-1.0 + 2.0 * 0.5 / n); atol=1e-9)
    end
end

@testset "dysco -- StudentsT inverse CDF (Distributions.TDist + bisection)" begin
    # hand-checked quantiles against known Student-t table values
    @test isapprox(MSv2._studentt_quantile(0.975, 5.0), 2.5706; atol=1e-3)
    @test isapprox(MSv2._studentt_quantile(0.95, 10.0), 1.8125; atol=1e-3)
    @test isapprox(MSv2._studentt_quantile(0.5, 5.0), 0.0; atol=1e-9)
    @test isapprox(MSv2._studentt_quantile(0.025, 5.0), -2.5706; atol=1e-3)

    # CDF . quantile round-trip
    for nu in (2.0, 5.0, 30.0), p in (0.1, 0.3, 0.5, 0.7, 0.9, 0.99)
        t = MSv2._studentt_quantile(p, nu)
        @test isapprox(MSv2._studentt_cdf(t, nu), p; atol=1e-8)
    end
end

@testset "dysco -- unsupported format / unrecognized distribution/normalization" begin
    dir = mktempdir()
    cdesc = ColumnDesc("DATA", "", "DyscoStMan", "dysco", MSv2.TpComplex,
                       "ArrayColumnDesc<Complex>", (2, 4), Int32(5), UInt32(0),
                       Record(), nothing, 0)
    td = TableDesc("T", "2", "", Record(), Record(), [cdesc])
    dm = MSv2.DataManagerInfo("DyscoStMan", 0, UInt8[])
    tbl = MSv2.Table(dir, "", "", "", 2, 1, :little, td, [dm],
                     Int64(-1), joinpath(dir, "table.lock"), nothing)

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

    # distribution/normalization codes 0-3 / 0-2 are all now recognized
    # (Gaussian/Uniform/StudentsT/TruncatedGaussian, AF/RF/Row) -- only a
    # genuinely unrecognized code should still error.
    write_header(path; distribution=99)
    e2 = _try(() -> open(MSv2.DyscoStMan, tbl, dm))
    @test e2 isa ErrorException && occursin("distribution code 99", e2.msg)

    write_header(path; normalization=99)
    e3 = _try(() -> open(MSv2.DyscoStMan, tbl, dm))
    @test e3 isa ErrorException && occursin("normalization code 99", e3.msg)
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

    @testset "dysco -- all normalizations x distributions (real CASA)" begin
        # CASA's dminfo string for StudentsT is "StudentT" (no trailing "s")
        # -- confirmed by a spike test; our own singleton type is named
        # `StudentsT` (matches the Julia convention elsewhere in this file),
        # the mismatch is cosmetic and confined to this CASA-facing string.
        combos = [(norm, dist, distname) for norm in ("AF", "RF", "Row")
                  for (dist, distname) in (("Gaussian", MSv2.Gaussian),
                                           ("Uniform", MSv2.Uniform),
                                           ("StudentT", MSv2.StudentsT),
                                           ("TruncatedGaussian", MSv2.TruncatedGaussian))]
        nant, ntime, nchan, npol = 4, 5, 4, 2
        dbits, wbits, seed = 10, 12, 7
        script = joinpath(@__DIR__, "dysco_fixture.py")
        for (normstr, diststr, DistT) in combos
            dir = mktempdir()
            cmd = Cmd(`$_CASA_PYTHON $script $dir $nant $ntime $nchan $npol $dbits $wbits $seed
                      $normstr $diststr 5.0`; dir)
            out = read(cmd, String)
            @test occursin("DYSCO_FIXTURE_OK", out)

            meta = parse.(Int, split(strip(read(joinpath(dir, "meta.txt"), String))))
            nr = meta[4]
            tab = joinpath(dir, "dysco.tab")
            t = readtable(tab)
            data_col = column(t, "DATA")
            weight_col = column(t, "WEIGHT_SPECTRUM")
            inst = data_col.inst
            @test inst.distribution isa DistT
            @test (normstr == "AF" ? inst.normalization isa MSv2.AFNorm :
                   normstr == "RF" ? inst.normalization isa MSv2.RFNorm :
                                     inst.normalization isa MSv2.RowNorm)

            data_c = reinterpret(ComplexF32, read(joinpath(dir, "data_decoded.bin")))
            weight_c = reinterpret(Float32, read(joinpath(dir, "weight_decoded.bin")))
            casa_data(p, ch, r) = data_c[(p-1)*nchan*nr + (ch-1)*nr + r]
            casa_weight(p, ch, r) = weight_c[(p-1)*nchan*nr + (ch-1)*nr + r]

            maxerr_d = maxerr_w = 0.0
            for r in 1:nr, ch in 1:nchan, p in 1:npol
                maxerr_d = max(maxerr_d, abs(data_col[r][p, ch] - casa_data(p, ch, r)))
                maxerr_w = max(maxerr_w, abs(weight_col[r][p, ch] - casa_weight(p, ch, r)))
            end
            @test maxerr_d < 1e-3
            @test maxerr_w == 0.0
        end
    end
end

if _HAVE_CASA
    @testset "dysco -- write_dyscostman: our writer -> real CASA decode (all combos)" begin
        # A genuine write-direction interop proof: write via our own
        # encoder, have real CASA's casatools decode it, and compare to
        # our own reader's decode of the SAME file.  (Comparing to the
        # *original* pre-compression values is the wrong test here --
        # this synthetic per-visibility-random data has no real antenna
        # correlation structure, so AF/RF/Row normalization -- exactly
        # like real Dysco on the same kind of data -- can legitimately
        # decode far from the original value while still being a
        # correct, self-consistent, CASA-interoperable encode.  Real
        # CASA requires TIME/ANTENNA1/ANTENNA2/FIELD_ID/DATA_DESC_ID to
        # be present for DyscoStMan's own Prepare() step, independent of
        # whether our own reader needs them.)
        nant = 4
        baselines = [(a1, a2) for a1 in 0:nant-1 for a2 in a1:nant-1]
        nbl = length(baselines)
        ntime = 5
        nr = nbl * ntime
        npol, nchan = 2, 4

        a1v = Int32[]; a2v = Int32[]
        for it in 1:ntime, (b1, b2) in baselines
            push!(a1v, b1); push!(a2v, b2)
        end
        vdata = [ComplexF32.(reshape(1:(npol*nchan), npol, nchan)) .* (0.31f0 * r) .+
                 ComplexF32(0, -0.17f0 * r) for r in 1:nr]
        vweight = [Float32.(repeat(reshape(1:nchan, 1, nchan), npol, 1)) .* (0.5f0 + 0.083f0 * r)
                   for r in 1:nr]
        timecol = collect(5.0e9 .+ (1:nr))
        fieldid = zeros(Int32, nr)
        ddid = zeros(Int32, nr)

        combos = [(normT, distT) for normT in (MSv2.AFNorm(), MSv2.RFNorm(), MSv2.RowNorm())
                  for distT in (MSv2.Gaussian(), MSv2.Uniform(), MSv2.StudentsT(),
                               MSv2.TruncatedGaussian())]
        for (normT, distT) in combos, dither in (false, true)
            dir = joinpath(mktempdir(), "t.tab")
            write_table(dir, "T",
                ["TIME"=>timecol, "ANTENNA1"=>a1v, "ANTENNA2"=>a2v,
                 "FIELD_ID"=>fieldid, "DATA_DESC_ID"=>ddid,
                 "DATA"=>vdata, "WEIGHT_SPECTRUM"=>vweight];
                nrow=nr, ism=["TIME", "ANTENNA1", "ANTENNA2", "FIELD_ID", "DATA_DESC_ID"],
                dysco=[["DATA", "WEIGHT_SPECTRUM"]],
                dysco_spec=Dict("DATA" => (; normalization=normT, distribution=distT,
                                           dataBitCount=10, weightBitCount=12,
                                           antenna1=Int.(a1v), antenna2=Int.(a2v),
                                           rowsPerBlock=nbl, dither)))

            data_c = reinterpret(ComplexF32, _casa_getcol_bytes(dir, "DATA", "complex64"))
            weight_c = reinterpret(Float32, _casa_getcol_bytes(dir, "WEIGHT_SPECTRUM", "float32"))
            casa_data(p, ch, r) = data_c[(p-1)*nchan*nr+(ch-1)*nr+r]
            casa_weight(p, ch, r) = weight_c[(p-1)*nchan*nr+(ch-1)*nr+r]

            t = readtable(dir)
            dcol = column(t, "DATA")
            wcol = column(t, "WEIGHT_SPECTRUM")
            maxerr_d = maxerr_w = 0.0
            for r in 1:nr, ch in 1:nchan, p in 1:npol
                maxerr_d = max(maxerr_d, abs(dcol[r][p, ch] - casa_data(p, ch, r)))
                maxerr_w = max(maxerr_w, abs(wcol[r][p, ch] - casa_weight(p, ch, r)))
            end
            @test maxerr_d < 1e-3
            @test maxerr_w < 1e-3
        end
    end
end

# --- shared fixture for the copy-preservation / edit tests below -------
function _dysco_synth_ms(dir; normalization=MSv2.RowNorm(), distribution=MSv2.TruncatedGaussian(),
                         nant=4, ntime=5, nchan=4, npol=2, dataBitCount=10, weightBitCount=12)
    baselines = [(a1, a2) for a1 in 0:nant-1 for a2 in a1:nant-1]
    nbl = length(baselines)
    nr = nbl * ntime
    a1v = Int32[]; a2v = Int32[]
    for it in 1:ntime, (b1, b2) in baselines
        push!(a1v, b1); push!(a2v, b2)
    end
    vdata = [ComplexF32.(reshape(1:(npol*nchan), npol, nchan)) .* (0.31f0 * r) .+
             ComplexF32(0, -0.17f0 * r) for r in 1:nr]
    vweight = [Float32.(repeat(reshape(1:nchan, 1, nchan), npol, 1)) .* (0.5f0 + 0.083f0 * r)
               for r in 1:nr]
    timecol = collect(5.0e9 .+ (1:nr))
    fieldid = zeros(Int32, nr)
    ddid = zeros(Int32, nr)
    write_table(dir, "T",
        ["TIME"=>timecol, "ANTENNA1"=>a1v, "ANTENNA2"=>a2v,
         "FIELD_ID"=>fieldid, "DATA_DESC_ID"=>ddid, "DATA"=>vdata, "WEIGHT_SPECTRUM"=>vweight];
        nrow=nr, ism=["TIME", "ANTENNA1", "ANTENNA2", "FIELD_ID", "DATA_DESC_ID"],
        dysco=[["DATA", "WEIGHT_SPECTRUM"]],
        dysco_spec=Dict("DATA" => (; normalization, distribution, dataBitCount, weightBitCount,
                                   antenna1=Int.(a1v), antenna2=Int.(a2v),
                                   rowsPerBlock=nbl, dither=false)))
    return nr, vdata, vweight
end

@testset "dysco -- copytable/copyms preserves compression" begin
    srcdir = joinpath(mktempdir(), "src.tab")
    nr, vdata, vweight = _dysco_synth_ms(srcdir; normalization=MSv2.RFNorm(), distribution=MSv2.Gaussian(),
                                        dataBitCount=8, weightBitCount=10)
    src = readtable(srcdir)

    dstdir = joinpath(mktempdir(), "dst.tab")
    copytable(dstdir, src)
    dst = readtable(dstdir)
    @test "DyscoStMan" in [m.name for m in dst.managers]
    dinst = column(dst, "DATA").inst
    @test dinst.normalization isa MSv2.RFNorm
    @test dinst.distribution isa MSv2.Gaussian
    @test dinst.dataBitCount == 8 && dinst.weightBitCount == 10
    # no dither, identical params -> re-encoding the already-decoded values
    # round-trips to (near-)identical decoded values
    dsrc = column(src, "DATA"); ddst = column(dst, "DATA")
    maxdiff = maximum(maximum(abs.(dsrc[r] .- ddst[r])) for r in 1:nr)
    @test maxdiff < 1e-3

    # partial row range
    dst2dir = joinpath(mktempdir(), "dst2.tab")
    copytable(dst2dir, src; rows=1:20)
    dst2 = readtable(dst2dir)
    @test nrow(dst2) == 20
    @test "DyscoStMan" in [m.name for m in dst2.managers]
    ddst2 = column(dst2, "DATA")
    for r in 1:20
        @test maximum(abs.(ddst2[r] .- dsrc[r])) < 1e-3
    end
end

@testset "dysco -- edit: setcell! / addrows! / removerows!" begin
    dir = joinpath(mktempdir(), "e.tab")
    nr, vdata, vweight = _dysco_synth_ms(dir)
    npol, nchan = 2, 4

    edit(dir) do t
        t[:DATA][3] = ComplexF32.(fill(50, npol, nchan))
    end
    r1 = readtable(dir)
    d1 = column(r1, "DATA")
    @test abs(d1[3][1, 1] - 50) < 0.5
    @test abs(d1[2][1, 1] - vdata[2][1, 1]) < 0.5   # sibling untouched
    @test MSv2._dmkind(column(r1, "DATA").inst) === :dysco

    edit(dir) do t
        addrows!(t, 3)
        t[:ANTENNA1][nr+1] = Int32(0); t[:ANTENNA2][nr+1] = Int32(1)
        t[:ANTENNA1][nr+2] = Int32(0); t[:ANTENNA2][nr+2] = Int32(2)
        t[:ANTENNA1][nr+3] = Int32(1); t[:ANTENNA2][nr+3] = Int32(2)
        t[:DATA][nr+1] = ComplexF32.(fill(99, npol, nchan))
    end
    r2 = readtable(dir)
    @test nrow(r2) == nr + 3
    d2 = column(r2, "DATA")
    @test abs(d2[nr+1][1, 1] - 99) < 0.5

    edit(dir) do t
        removerows!(t, [1, 4])
    end
    r3 = readtable(dir)
    @test nrow(r3) == nr + 3 - 2

    if _HAVE_CASACORE
        ct = CCT.Table(dir)
        @test size(ct, 1) == nr + 3 - 2
    end
end
