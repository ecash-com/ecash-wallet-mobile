//
//  DigestContext.swift
//  Blake3
//
//  Created by Khan Winter on 8/9/25.
//

import blake3_c

/// Implements CoW for hasher state
internal final class DigestContext: @unchecked Sendable {
    var hasher: blake3_hasher

    init() {
        hasher = blake3_hasher()
        blake3_hasher_init(&hasher)
    }

    init(key: [UInt8]) {
        hasher = blake3_hasher()
        assert(key.count == BLAKE3_KEY_LEN)
        key.withUnsafeBufferPointer { bufferPtr in
            blake3_hasher_init_keyed(&hasher, bufferPtr.baseAddress)
        }
    }

    init(deriveKey: String) {
        hasher = blake3_hasher()
        deriveKey.withCString { ptr in
            blake3_hasher_init_derive_key(&hasher, ptr)
        }
    }

    init(copying: DigestContext) {
        self.hasher = copying.hasher
    }

    func update(bufferPointer: UnsafeRawBufferPointer) {
        blake3_hasher_update(&hasher, bufferPointer.baseAddress, bufferPointer.count)
    }

    func finalize() -> Blake3Digest {
        Blake3Digest { ptr in
            blake3_hasher_finalize(&hasher, ptr, Blake3Digest.byteCount)
        }
    }
}
