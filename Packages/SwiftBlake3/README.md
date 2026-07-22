# SwiftBlake3

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fthecoolwinter%2FSwiftBlake3%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/JoshuaBrest/blake3-swift)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fthecoolwinter%2FSwiftBlake3%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/JoshuaBrest/blake3-swift)

A Swift wrapper for the official C/Rust implementation of BLAKE3.

# What is this?

This is a fork of [JoshuaBrest's library](https://github.com/JoshuaBrest/blake3-swift) with some changes. This package is now concurrency-safe, and implements copy-on-write for the hasher. 

This fork also implements the hasher function as a `HashFunction` from the [`swift-crypto` library](https://github.com/apple/swift-crypto). This makes the `Blake3` hash function a drop-in replacement for existing hash functions like `SHA2` or `MD5`.

This package also passes all of BLAKE3's test vectors.

# Usage

Use just like any other hash function from the Crypto library.

```swift
import Blake3

let data: [UInt8] = [/* ... */]

// Create a one-off digest.
let digest = Blake3().hash(data: data)

// Stream more values
var hasher = Blake3()
for byte in data {
    hasher.update(data: [byte])
}
let digest = hasher.finalize()

// More hasher options
let keyedHasher = Blake3(key: [UInt8])
let derivedKeyHasher = Blake3(derivedKey: "Hello World")
```

### A Note For WASM

This package will not use the `swift-crypto` library on WASM platforms to avoid the `Foundation` and other cryptography library dependencies. It retains the copy-on-write functionality, however.

# Install

You can use the Swift Package Manager to download and import the library into your project:

```swift
dependencies: [
	.package(url: "https://github.com/thecoolwinter/SwiftBlake3.git", "0.0.0"..<"1.0.0"),
]
```

Then under `targets`:

```swift
targets: [
    .target(
        // ...
        dependencies: [
            .product(name: "SwiftBlake3", package: "SwiftBlake3")
        ]
    )
]
```



## License

This project is licensed under the ISC license. See the [LICENSE](LICENSE) file for details.

