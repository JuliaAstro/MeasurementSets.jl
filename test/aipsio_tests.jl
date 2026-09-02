# Unit tests for the AipsIO primitives, using hand-built byte streams that
# mirror what casacore's CanonicalIO writes.

using MeasurementSetv2: AipsIO, getstart, getend, getnexttype, read_string,
             read_iposition, read_block, read_scalar

be(x) = collect(reinterpret(UInt8, [hton(x)]))
aipsstr(s) = vcat(be(UInt32(length(s))), Vector{UInt8}(s))

@testset "AipsIO primitives" begin
    # a minimal framed object:  magic | len | "Demo" | version=3 | UInt32 42
    body = vcat(aipsstr("Demo"), be(UInt32(3)), be(UInt32(42)))
    len = UInt32(4 + length(body))          # length counts its own slot
    bytes = vcat(be(UInt32(0xbebebebe)), be(len), body)

    a = AipsIO(bytes)
    @test getnexttype(a) == "Demo"
    a2 = AipsIO(bytes)
    @test getstart(a2, "Demo") == 3
    @test read_scalar(a2, UInt32) == 42
    getend(a2)
    @test eof(a2)

    @test_throws ErrorException getstart(AipsIO(bytes), "Nope")

    # IPosition version 1 (Int32 elements)
    ip = vcat(be(UInt32(0)), be(UInt32(0)))   # placeholder; build properly below
    ipbody = vcat(aipsstr("IPosition"), be(UInt32(1)), be(UInt32(2)),
                  be(Int32(4)), be(Int32(8)))
    iplen = UInt32(4 + length(ipbody))
    ipbytes = vcat(be(UInt32(0xbebebebe)), be(iplen), ipbody)
    @test read_iposition(AipsIO(ipbytes)) == (4, 8)

    # Block<Int32>
    blbody = vcat(aipsstr("Block"), be(UInt32(1)), be(UInt32(3)),
                  be(Int32(10)), be(Int32(20)), be(Int32(30)))
    bllen = UInt32(4 + length(blbody))
    blbytes = vcat(be(UInt32(0xbebebebe)), be(bllen), blbody)
    @test read_block(AipsIO(blbytes), Int32) == Int32[10, 20, 30]
end
