import CSodiumRistretto

/// ristretto255 (RFC 9496) group and scalar operations, backed by the vendored libsodium subset.
///
/// Byte conventions follow libsodium and curve25519-dalek: a scalar is 32 bytes, little-endian,
/// reduced mod ℓ; a point is its 32-byte canonical ristretto255 encoding.
public enum Ristretto255 {
    public static let scalarBytes = 32
    public static let pointBytes = 32
    public static let wideScalarBytes = 64

    public enum Error: Swift.Error, Equatable {
        case invalidLength
        /// The input is not a canonical ristretto255 encoding, or the result is the identity.
        case invalidPoint
    }

    /// `s mod ℓ` for a 64-byte little-endian integer (dalek's `Scalar::from_bytes_mod_order_wide`).
    public static func reduce(wide: [UInt8]) throws -> [UInt8] {
        guard wide.count == wideScalarBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: scalarBytes)
        var input = wide
        crypto_core_ristretto255_scalar_reduce(&out, &input)
        return out
    }

    /// `s mod ℓ` for a 32-byte little-endian integer (dalek's `Scalar::from_bytes_mod_order`).
    public static func reduce(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count == scalarBytes else { throw Error.invalidLength }
        return try reduce(wide: bytes + [UInt8](repeating: 0, count: scalarBytes))
    }

    public static func scalarAdd(_ a: [UInt8], _ b: [UInt8]) throws -> [UInt8] {
        guard a.count == scalarBytes, b.count == scalarBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: scalarBytes)
        var x = a, y = b
        crypto_core_ristretto255_scalar_add(&out, &x, &y)
        return out
    }

    public static func scalarMul(_ a: [UInt8], _ b: [UInt8]) throws -> [UInt8] {
        guard a.count == scalarBytes, b.count == scalarBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: scalarBytes)
        var x = a, y = b
        crypto_core_ristretto255_scalar_mul(&out, &x, &y)
        return out
    }

    /// `s·G`. Throws for `s ≡ 0` (the identity has no valid encoding here).
    public static func baseMul(_ scalar: [UInt8]) throws -> [UInt8] {
        guard scalar.count == scalarBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: pointBytes)
        var s = scalar
        guard crypto_scalarmult_ristretto255_base(&out, &s) == 0 else { throw Error.invalidPoint }
        return out
    }

    /// `s·P`. Throws if `P` is not a canonical encoding or the result is the identity.
    public static func mul(_ scalar: [UInt8], _ point: [UInt8]) throws -> [UInt8] {
        guard scalar.count == scalarBytes, point.count == pointBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: pointBytes)
        var s = scalar, p = point
        guard crypto_scalarmult_ristretto255(&out, &s, &p) == 0 else { throw Error.invalidPoint }
        return out
    }

    /// `P + Q`. Throws if either input is not a canonical encoding.
    public static func add(_ p: [UInt8], _ q: [UInt8]) throws -> [UInt8] {
        guard p.count == pointBytes, q.count == pointBytes else { throw Error.invalidLength }
        var out = [UInt8](repeating: 0, count: pointBytes)
        var a = p, b = q
        guard crypto_core_ristretto255_add(&out, &a, &b) == 0 else { throw Error.invalidPoint }
        return out
    }

    public static func isValidPoint(_ point: [UInt8]) -> Bool {
        guard point.count == pointBytes else { return false }
        var p = point
        return crypto_core_ristretto255_is_valid_point(&p) == 1
    }
}
