import Testing
@testable import Ristretto255

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func scalar(_ n: UInt8) -> [UInt8] { [n] + [UInt8](repeating: 0, count: 31) }

/// ℓ = 2^252 + 27742317777372353535851937790883648493, little-endian.
private let groupOrder = hex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")

@Suite struct Ristretto255Tests {
    // RFC 9496 Appendix A.1 — encodings of B·1, B·2, B·3.
    @Test func generatorMultiplesMatchRFC9496() throws {
        #expect(try Ristretto255.baseMul(scalar(1)) == hex("e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"))
        #expect(try Ristretto255.baseMul(scalar(2)) == hex("6a493210f7499cd17fecb510ae0cea23a110e8d5b901f8acadd3095c73a3b919"))
        #expect(try Ristretto255.baseMul(scalar(3)) == hex("94741f5d5d52755ece4f23f044ee27d5d1ea1e2bd196b462166b16152a9d0259"))
    }

    @Test func pointAddAndScalarMulAgree() throws {
        let b1 = try Ristretto255.baseMul(scalar(1))
        let b2 = try Ristretto255.baseMul(scalar(2))
        #expect(try Ristretto255.add(b1, b2) == Ristretto255.baseMul(scalar(3)))
        #expect(try Ristretto255.mul(scalar(3), b1) == Ristretto255.baseMul(scalar(3)))
    }

    @Test func zeroScalarIsRejected() {
        #expect(throws: Ristretto255.Error.invalidPoint) { try Ristretto255.baseMul(scalar(0)) }
    }

    // RFC 9496 Appendix A.2 — a non-canonical field element must not decode.
    @Test func nonCanonicalEncodingIsInvalid() {
        let bad = hex("00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
        #expect(!Ristretto255.isValidPoint(bad))
        #expect(throws: Ristretto255.Error.invalidPoint) { try Ristretto255.add(bad, bad) }
        #expect(Ristretto255.isValidPoint(hex("e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76")))
    }

    @Test func reductionModOrder() throws {
        #expect(try Ristretto255.reduce(groupOrder) == scalar(0))
        var lPlusOne = groupOrder
        lPlusOne[0] &+= 1
        #expect(try Ristretto255.reduce(lPlusOne) == scalar(1))
        #expect(try Ristretto255.reduce(wide: groupOrder + [UInt8](repeating: 0, count: 32)) == scalar(0))
    }

    @Test func scalarArithmetic() throws {
        #expect(try Ristretto255.scalarAdd(scalar(2), scalar(3)) == scalar(5))
        #expect(try Ristretto255.scalarMul(scalar(2), scalar(3)) == scalar(6))
    }

    @Test func wrongLengthsThrow() {
        #expect(throws: Ristretto255.Error.invalidLength) { try Ristretto255.baseMul([1]) }
        #expect(throws: Ristretto255.Error.invalidLength) { try Ristretto255.reduce(wide: [1, 2]) }
    }
}
