//
//  Blake3.swift
//  Blake3
//
//  Created by Khan Winter on 8/9/25.
//

#if canImport(Crypto)
import Crypto
#endif

public struct Blake3 {
    public typealias Digest = Blake3Digest

    @inlinable
    public static var blockByteCount: Int { Blake3Digest.byteCount }

    private var context: DigestContext

    public init() {
        context = DigestContext()
    }

    public init(key: [UInt8]) {
        context = DigestContext(key: key)
    }

    public init(deriveKey: String) {
        context = DigestContext(deriveKey: deriveKey)
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        if !isKnownUniquelyReferenced(&self.context) {
            self.context = DigestContext(copying: self.context)
        }
        self.context.update(bufferPointer: bufferPointer)
    }

    public func finalize() -> Blake3Digest {
        context.finalize()
    }
}

#if canImport(Crypto)
extension Blake3: HashFunction { }
#endif
