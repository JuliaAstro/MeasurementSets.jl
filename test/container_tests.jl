# Phase 20: MultiFile / MultiHDF5 container read support.
#
# MultiFile: verified against a REAL casacore-authored fixture (TaQL
# `CREATE TABLE ... AS [storage="multifile", blocksize=...] ...`, the
# same `_taql_create` helper `tsm_multicol_tests.jl` already defines) --
# genuine interop proof, not just self-consistency.
#
# MultiHDF5: NO real oracle is available on this machine for this format
# specifically -- confirmed by trying both Casacore.jl's bundled
# `casacorecxx_jll` (`TaQL storage="multihdf5"` -> "HDF5 support is not
# compiled into this casacore version") and the real CASA.app install
# used as the Dysco oracle (same error via `casatools.table.taql`).
# So MultiHDF5 is verified via a self-authored fixture built directly
# with HDF5.jl, byte-for-byte following the documented format (header
# group + attributes, one group+"FileData" dataset per virtual file) --
# this proves our own reader correctly implements the documented wire
# format and is internally self-consistent, but is not independent
# cross-implementation proof the way the MultiFile tests are.  Flagged
# as a known verification gap (see the Phase 20 plan's Risks section).

using MeasurementSets: MultiFileContainer, MultiHDF5Container
import HDF5

# Pack an already-written plain table's per-DM files into a hand-built
# `table.mfh5`, deleting the originals -- mirrors what a real MultiHDF5
# writer would produce, per the documented format (MultiHDF5.cc:128-209,
# HDF5Record.cc).  `files` are basenames already present in `dir`.
function _pack_multihdf5!(dir::AbstractString, files::Vector{String}; blocksize::Int=4096)
    path = joinpath(dir, "table.mfh5")
    sizes = Int64[filesize(joinpath(dir, f)) for f in files]
    HDF5.h5open(path, "w") do fid
        hdr = HDF5.create_group(fid, "__MultiHDF5_Header__")
        HDF5.attributes(hdr)["blockSize"] = Int64(blocksize)
        HDF5.attributes(hdr)["hdrCounter"] = Int64(1)
        HDF5.attributes(hdr)["names"] = files
        HDF5.attributes(hdr)["sizes"] = sizes
        for (f, sz) in zip(files, sizes)
            g = HDF5.create_group(fid, f)
            nblk = cld(sz, blocksize)
            data = read(joinpath(dir, f))
            padded = vcat(data, zeros(UInt8, nblk * blocksize - length(data)))
            buf = Array{UInt8}(undef, nblk, blocksize)
            for b in 1:nblk
                s = (b - 1) * blocksize
                buf[b, :] = padded[s+1:s+blocksize]
            end
            d = HDF5.create_dataset(g, "FileData", HDF5.datatype(UInt8),
                                    HDF5.dataspace((nblk, blocksize)))
            d[:, :] = buf
        end
    end
    for f in files
        rm(joinpath(dir, f))
    end
    return path
end

if _HAVE_TAQL
    @testset "MultiFile — real casacore fixture, our reader" begin
        dir = joinpath(mktempdir(), "g.tab")
        q = """CREATE TABLE $dir AS [storage="multifile", blocksize=2048] """ *
            """[A I4, B R8, C S, D C4 [NDIM=2]] LIMIT 20 DMINFO [""" *
            """TYPE="TiledShapeStMan", NAME="tsmD", SPEC=[DEFAULTTILESHAPE=[2,3,4]], """ *
            """COLUMNS=["D"]]"""
        t = _taql_create(q)
        a = collect(Int32, 0:19)
        b = collect(0.0:0.5:9.5)
        c = ["s$i" for i in 0:19]
        D = [ComplexF32.(reshape(1:6, 2, 3)) .+ i for i in 1:20]
        for r in 1:20
            t[:A][r] = a[r]; t[:B][r] = b[r]; t[:C][r] = c[r]; t[:D][r] = D[r]
        end
        CCT.flush(t); t = nothing; GC.gc()

        @test isfile(joinpath(dir, "table.mf"))
        @test !any(startswith("table.f"), readdir(dir))    # every DM file packed away

        r = readtable(dir)
        @test r.container isa MultiFileContainer
        @test Set(m.name for m in r.managers) == Set(["StandardStMan", "TiledShapeStMan"])
        @test column(r, "A")[:] == a
        @test column(r, "B")[:] == b
        @test column(r, "C")[:] == c
        @test [column(r, "D")[i] for i in 1:20] == D

        if _HAVE_CASACORE
            ct = CCT.Table(dir)
            @test [ct[:A][i] for i in 1:20] == a
            @test [ct[:B][i] for i in 1:20] == b
            @test [ct[:C][i] for i in 1:20] == c
            @test [ct[:D][i] for i in 1:20] == D
        end

        @testset "edit() refuses a container-backed table" begin
            @test_throws ErrorException edit(dir)
        end

        @testset "copytable un-packs cleanly" begin
            dst = joinpath(mktempdir(), "plain.tab")
            copytable(dst, r)
            @test !isfile(joinpath(dst, "table.mf"))
            @test any(startswith("table.f"), readdir(dst))
            r2 = readtable(dst)
            @test r2.container === nothing
            @test column(r2, "A")[:] == a
            @test [column(r2, "D")[i] for i in 1:20] == D
        end
    end

    @testset "MultiFile — multi-block (small blocksize forces >1 block/file)" begin
        dir = joinpath(mktempdir(), "small.tab")
        q = """CREATE TABLE $dir AS [storage="multifile", blocksize=64] [A I4] LIMIT 200"""
        t = _taql_create(q)
        a = collect(Int32, 1:200)
        for r in 1:200
            t[:A][r] = a[r]
        end
        CCT.flush(t); t = nothing; GC.gc()

        r = readtable(dir)
        @test r.container isa MultiFileContainer
        mfc = r.container::MultiFileContainer
        # a table.f0 of length 200*4=800 bytes over 64-byte blocks needs >1 block
        entry = only(values(mfc.entries))
        @test length(entry.blocknrs) > 1
        @test column(r, "A")[:] == a
    end
else
    @info "TaQL (Casacore.jl + CxxWrap) unavailable; skipping MultiFile container tests"
end

@testset "MultiFile — unpack-index round trip (unit)" begin
    pack = MeasurementSets._mf_unpack_index
    @test pack(Int64[]) == Int64[]
    @test pack(Int64[5]) == Int64[5]
    @test pack(Int64[5, -2, 10, -1]) == Int64[5, 6, 7, 10, 11]
    @test pack(Int64[0, -3]) == Int64[0, 1, 2, 3]
end

# Phase 213 (src/datamanagers sweep, continued): `_mf_pack_index` --
# `_mf_unpack_index`'s write-side mirror -- was only ever exercised with
# an already-contiguous block list (the only shape our own writer ever
# produces, since a virtual file's blocks are always allocated
# sequentially). Its "close the current run, start a new one" branch (a
# genuinely different code path for a FRAGMENTED block list) had zero
# coverage anywhere. Confirmed correct, not buggy: it's the exact inverse
# of `_mf_unpack_index` for every fragmented case below.
@testset "MultiFile — pack-index, fragmented blocks (unit, Phase 213)" begin
    unpack = MeasurementSets._mf_unpack_index
    pack = MeasurementSets._mf_pack_index
    for blocknrs in (Int64[5, 6, 7, 10, 11], Int64[1, 3, 4, 5, 9],
                     Int64[0, 1, 2, 3], Int64[2, 4, 6, 8], Int64[7])
        packed = pack(blocknrs)
        @test unpack(packed) == blocknrs
    end
    @test pack(Int64[5, 6, 7, 10, 11]) == Int64[5, -2, 10, -1]
    @test pack(Int64[1, 3, 4, 5, 9]) == Int64[1, 3, -2, 9]
    @test pack(Int64[]) == Int64[]
end

@testset "MultiFile — CRC32 (unit)" begin
    # casacore's CRC32 is nonstandard (not zlib) -- a self-consistency
    # check (any nonzero input changes the checksum) is the honest amount
    # of unit coverage without a hand-computed reference vector.
    crc = MeasurementSets._mf_crc32
    @test crc(UInt8[]) != crc(UInt8[0x00])
    @test crc(UInt8[1, 2, 3]) != crc(UInt8[1, 2, 4])
    @test crc(UInt8[1, 2, 3]) == crc(UInt8[1, 2, 3])
end

# Phase 213 (src/datamanagers sweep, continued): `open_multifile`'s
# `useCRC` header-verification branch (`container.jl:313-318`) had zero
# coverage -- there is no TaQL/`StorageOption` knob to make real casacore
# ever WRITE a `useCRC=true` container (confirmed in the Phase 21 plan),
# so no available fixture -- our own writer, correctly, also never sets
# it. Hand-patch a real container this package wrote (`blocksize=512` so
# the header fits in block 0 with no continuation chain, keeping the
# patch simple) to flip on `useCRC` with a correctly-computed CRC, and
# separately with a deliberately wrong one -- confirms both the
# accept-when-correct and reject-when-corrupted paths, live.
@testset "MultiFile — useCRC header verification (Phase 213)" begin
    dir = joinpath(mktempdir(), "mfcrc.tab")
    A = collect(Int32, 1:20)
    write_table(dir, "T", ["A" => A]; nrow=20, storage=:multifile, blocksize=512)
    path = joinpath(dir, "table.mf")
    buf = read(path)
    headerSize = Int(ntoh(reinterpret(Int64, buf[33:40])[1]))
    blocksize  = Int(ntoh(reinterpret(Int64, buf[41:48])[1]))
    @test headerSize <= blocksize   # header fits in block 0 -- no continuation chain

    hdr = copy(buf[1:headerSize])
    hdr[57] = 0x01                                    # useCRC = true
    chk = copy(hdr); chk[29:32] .= 0x00                # zero headerCRC field during calc
    hdr[29:32] = reinterpret(UInt8, [hton(UInt32(MeasurementSets._mf_crc32(chk)))])
    goodbuf = copy(buf); goodbuf[1:headerSize] = hdr
    write(path, goodbuf)
    r = readtable(dir)
    @test column(r, "A")[:] == A

    badbuf = copy(goodbuf)
    badbuf[60] ⊻= 0xFF                                 # flip a spare header byte, not the CRC
    write(path, badbuf)
    @test_throws ErrorException readtable(dir)
end

@testset "MultiHDF5 — self-authored fixture (documented format), our reader" begin
    dir = joinpath(mktempdir(), "h.tab")
    write_table(dir, "T", ["A" => collect(1:10), "B" => collect(1.0:10.0),
                          "C" => ["s$i" for i in 1:10]]; nrow=10)
    r0 = readtable(dir)
    dmfiles = [f for f in readdir(dir) if startswith(f, "table.f")]
    @test !isempty(dmfiles)
    a0, b0, c0 = column(r0, "A")[:], column(r0, "B")[:], column(r0, "C")[:]

    _pack_multihdf5!(dir, dmfiles; blocksize=32)
    @test isfile(joinpath(dir, "table.mfh5"))
    @test isempty([f for f in readdir(dir) if startswith(f, "table.f")])

    r = readtable(dir)
    @test r.container isa MultiHDF5Container
    @test column(r, "A")[:] == a0
    @test column(r, "B")[:] == b0
    @test column(r, "C")[:] == c0

    @test_throws ErrorException edit(dir)

    dst = joinpath(mktempdir(), "plain.tab")
    copytable(dst, r)
    @test !isfile(joinpath(dst, "table.mfh5"))
    r2 = readtable(dst)
    @test r2.container === nothing
    @test column(r2, "A")[:] == a0
end

@testset "no container — regression safety" begin
    dir = joinpath(mktempdir(), "plain.tab")
    write_table(dir, "T", ["A" => collect(1:5)]; nrow=5)
    r = readtable(dir)
    @test r.container === nothing
    @test column(r, "A")[:] == collect(1:5)
end

# ======================================================================
# Phase 21: MultiFile / MultiHDF5 container WRITE support
# ======================================================================

@testset "MultiFile — our writer, our reader round trip" begin
    dir = joinpath(mktempdir(), "w.tab")
    A = collect(Int32, 1:40)
    B = collect(0.0:0.25:9.75)
    C = ["str$i" for i in 1:40]
    D = [ComplexF32.(reshape(1:6, 2, 3)) .+ i for i in 1:40]
    write_table(dir, "T", ["A" => A, "B" => B, "C" => C, "D" => D]; nrow=40,
                tsm=[["D"]], storage=:multifile, blocksize=128)
    @test isfile(joinpath(dir, "table.mf"))
    @test !any(startswith("table.f"), readdir(dir))

    r = readtable(dir)
    @test r.container isa MultiFileContainer
    mfc = r.container::MultiFileContainer
    @test length(mfc.entries) == 3     # one SSM file (A,B,C) + one TSM file (D)
    @test column(r, "A")[:] == A
    @test column(r, "B")[:] == B
    @test column(r, "C")[:] == C
    @test [column(r, "D")[i] for i in 1:40] == D

    if _HAVE_CASACORE
        # genuine write-direction interop: real casacore reads OUR container.
        # D (a single-column TSM group) is skipped here -- the installed
        # Casacore.jl 0.4.1's Column.size() throws a MethodError for ANY
        # single-column-group TSM table regardless of container use (a
        # pre-existing Casacore.jl interop gap noted since Phase 15;
        # unrelated to this package's writer, which is why the plain-SSM
        # columns A/B/C -- and the real-fixture "D" test in the previous
        # testset above, sourced from TaQL not Casacore.jl's own Column
        # wrapper -- cross-check fine).
        ct = CCT.Table(dir)
        @test [ct[:A][i] for i in 1:40] == A
        @test [ct[:B][i] for i in 1:40] == B
        @test [ct[:C][i] for i in 1:40] == C
    end
end

@testset "MultiFile — header-overflow (continuation blocks)" begin
    # tiny blocksize + several DM files forces the header itself past one
    # block -- exercises the fixed-point convergence loop end to end.
    dir = joinpath(mktempdir(), "w2.tab")
    cols = Pair{String,Any}[]
    for i in 1:8
        push!(cols, "V$i" => collect(Int32, 1:20))
    end
    write_table(dir, "T", cols; nrow=20,
                ism=["V1", "V2"], storage=:multifile, blocksize=64)
    r = readtable(dir)
    @test r.container isa MultiFileContainer
    mfc = r.container::MultiFileContainer
    @test length(mfc.entries) >= 2     # >=1 SSM + >=1 ISM file
    for i in 1:8
        @test column(r, "V$i")[:] == collect(Int32, 1:20)
    end
end

@testset "MultiFile — unit: header bytes exceed one block for a tiny blocksize" begin
    # sanity-check the header-building block against a hand-sized 2-file case
    infos = [MeasurementSets.MultiFileRawInfo("a", 300, false),
             MeasurementSets.MultiFileRawInfo("b", 50, false)]
    packed = [MeasurementSets._mf_pack_index(Int64[1, 2, 3, 4, 5]),
              MeasurementSets._mf_pack_index(Int64[6])]
    h0 = MeasurementSets._mf_header_bytes(infos, packed, 64, 7, Int64[])
    @test length(h0) > 64   # this tiny blocksize always overflows one block
end

@testset "MultiHDF5 — our writer, our reader round trip" begin
    dir = joinpath(mktempdir(), "wh.tab")
    A = collect(Int32, 1:30)
    D = [Float64.(reshape(1:4, 2, 2)) .+ i for i in 1:30]
    write_table(dir, "T", ["A" => A, "D" => D]; nrow=30,
                tsm=[["D"]], storage=:multihdf5, blocksize=64)
    @test isfile(joinpath(dir, "table.mfh5"))
    @test !any(startswith("table.f"), readdir(dir))

    r = readtable(dir)
    @test r.container isa MultiHDF5Container
    @test column(r, "A")[:] == A
    @test [column(r, "D")[i] for i in 1:30] == D
end

@testset "storage= reaches every write entry point" begin
    # create_ms
    dir = joinpath(mktempdir(), "ms.ms")
    create_ms(dir; nrow=6, nchan=3, ncorr=2, nant=3, storage=:multifile, blocksize=4096)
    @test isfile(joinpath(dir, "table.mf"))
    @test isfile(joinpath(dir, "ANTENNA", "table.mf"))
    ms = MeasurementSet(dir)
    @test getfield(ms, :data).container isa MultiFileContainer
    @test isempty(validate(ms))

    # copytable
    dst = joinpath(mktempdir(), "copy.tab")
    copytable(dst, getfield(ms, :data); storage=:multihdf5, blocksize=4096)
    @test readtable(dst).container isa MultiHDF5Container
    @test [column(readtable(dst), "DATA")[i] for i in 1:6] ==
          [getfield(ms, :data)[:DATA][i] for i in 1:6]

    # write_ms / copyms — every table (MAIN + each subtable) gets its own container
    dst2 = joinpath(mktempdir(), "copy.ms")
    copyms(dir, dst2; storage=:multifile, blocksize=4096)
    @test isfile(joinpath(dst2, "table.mf"))
    @test isfile(joinpath(dst2, "ANTENNA", "table.mf"))
    @test isfile(joinpath(dst2, "SPECTRAL_WINDOW", "table.mf"))
    ms2 = MeasurementSet(dst2)
    @test isempty(validate(ms2))
    @test [ms2[:DATA][i] for i in 1:6] == [ms[:DATA][i] for i in 1:6]
end

@testset "no container created when nothing buffers into the sink" begin
    dir = mktempdir()
    MeasurementSets.with_container_sink(dir, :multifile, 4096) do
        # no _dmfile_write! call at all
    end
    @test !isfile(joinpath(dir, "table.mf"))
    MeasurementSets.with_container_sink(dir, :multihdf5, 4096) do
    end
    @test !isfile(joinpath(dir, "table.mfh5"))
end

@testset "edit() refuses a table written by our own container writer" begin
    dir = joinpath(mktempdir(), "e.tab")
    write_table(dir, "T", ["A" => collect(1:5)]; nrow=5, storage=:multifile, blocksize=4096)
    @test_throws ErrorException edit(dir)
end

@testset "storage= bad value errors clearly" begin
    dir = joinpath(mktempdir(), "bad.tab")
    @test_throws ArgumentError write_table(dir, "T", ["A" => collect(1:5)]; nrow=5,
                                           storage=:nonsense)
end

# Phase 199: found live -- the ONLY place `storage=` was actually
# checked was deep inside `with_container_sink`, called partway through
# the per-DM-writer section of `_write_table_core` -- well AFTER
# `_write_table_core`/`write_ms`/`create_ms` had already `mkpath`'d the
# destination directory. Worse: `write_ms`'s subtable loop wraps each
# subtable's `_copy_table` call in a broad `catch e; @warn "skipping
# subtable ... (unsupported source)"` -- which caught this
# `ArgumentError` too, mischaracterizing a caller's own typo as 18
# separate per-subtable data problems before the true cause finally
# surfaced (only for MAIN, which has no such catch). Fixed with a
# shared `_check_storage(storage)` called first thing, before any
# directory is created or any subtable is touched, in every entry
# point that accepts `storage=`.
@testset "storage= bad value: no stray directory, no misleading warnings (Phase 199)" begin
    # write_table (already covered above for the error itself; add the
    # "no directory left behind" check)
    dir0 = joinpath(mktempdir(), "wt.tab")
    @test_throws ArgumentError write_table(dir0, "T", ["A" => collect(1:5)]; nrow=5,
                                           storage=:nonsense)
    @test !ispath(dir0)

    # create_ms
    dir1 = joinpath(mktempdir(), "cm.ms")
    @test_throws ArgumentError create_ms(dir1; storage=:nonsense)
    @test !ispath(dir1)

    # write_ms / copyms -- the important case: no misleading per-subtable
    # "unsupported source" warnings, just the one real error, and (since
    # `_check_storage` now runs before `mkpath`) no partial directory tree
    src = joinpath(mktempdir(), "src.ms")
    create_ms(src; nrow=4, nchan=2, ncorr=1, nant=2)
    dst = joinpath(mktempdir(), "dst.ms")
    local caught = nothing
    records, _ = Test.collect_test_logs() do
        try
            write_ms(dst, MeasurementSet(src); storage=:nonsense)
        catch e
            caught = e
        end
    end
    @test caught isa ArgumentError
    @test !ispath(dst)
    @test isempty(records)   # no per-subtable "skipping ... (unsupported source)" warnings

    # copytable
    dir2 = joinpath(mktempdir(), "ct.tab")
    @test_throws ArgumentError copytable(dir2, readtable(src); storage=:nonsense)
    @test !ispath(dir2)

    # reference_copy
    dir3 = joinpath(mktempdir(), "rc.tab")
    @test_throws ArgumentError reference_copy(dir3, readtable(src); storage=:nonsense)
    @test !ispath(dir3)
end

@testset "container_mmap — non-contiguous block fallback (Phase 158)" begin
    # A freshly-written container always allocates blocks sequentially
    # (`MultiFile::extendVF`), so no test anywhere else in this file (or
    # this package's own writer) ever produces a virtual file whose
    # `blocknrs` are non-contiguous -- the `container_mmap` fallback to
    # `container_read` (src/datamanagers/container.jl:326-332) has never
    # actually been exercised by any test. Build a fabricated container
    # directly to close that gap: two virtual files sharing one physical
    # file, block 0 = "AAAA", block 1 = "BBBB", block 2 = "CCCC" (4-byte
    # blocksize); "v1" is stored contiguously at blocks [0,1] (exercises
    # the mmap fast path), "v2" is deliberately non-contiguous at
    # blocks [2,0] (exercises the materializing fallback).
    dir = mktempdir()
    path = joinpath(dir, "raw.mf")
    write(path, vcat(collect(codeunits("AAAA")), collect(codeunits("BBBB")),
                     collect(codeunits("CCCC"))))
    entries = Dict("v1" => MSv2.MultiFileEntry(8, Int64[0, 1]),
                   "v2" => MSv2.MultiFileEntry(8, Int64[2, 0]))
    c = MSv2.MultiFileContainer(path, 4, entries)

    v1 = MSv2.container_mmap(c, "v1")
    @test String(collect(v1)) == "AAAABBBB"
    @test v1 isa SubArray                       # the contiguous fast path -> a real mmap view

    v2 = MSv2.container_mmap(c, "v2")
    @test String(collect(v2)) == "CCCCAAAA"     # block 2 then block 0, NOT a naive contiguous slice
    @test v2 isa Vector{UInt8}                  # the fallback path -> a materialized copy

    # `container_mmap`/`container_read` must agree exactly for the
    # fallback case (the whole point of falling back is correctness)
    @test v2 == MSv2.container_read(c, "v2")
end
