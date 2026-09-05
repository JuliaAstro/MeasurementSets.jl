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

using MeasurementSetv2: MultiFileContainer, MultiHDF5Container
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
    pack = MeasurementSetv2._mf_unpack_index
    @test pack(Int64[]) == Int64[]
    @test pack(Int64[5]) == Int64[5]
    @test pack(Int64[5, -2, 10, -1]) == Int64[5, 6, 7, 10, 11]
    @test pack(Int64[0, -3]) == Int64[0, 1, 2, 3]
end

@testset "MultiFile — CRC32 (unit)" begin
    # casacore's CRC32 is nonstandard (not zlib) -- a self-consistency
    # check (any nonzero input changes the checksum) is the honest amount
    # of unit coverage without a hand-computed reference vector.
    crc = MeasurementSetv2._mf_crc32
    @test crc(UInt8[]) != crc(UInt8[0x00])
    @test crc(UInt8[1, 2, 3]) != crc(UInt8[1, 2, 4])
    @test crc(UInt8[1, 2, 3]) == crc(UInt8[1, 2, 3])
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
