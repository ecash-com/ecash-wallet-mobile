# Security Assessment: ecash-com/ecash-wallet-mobile

**Date:** August 1, 2026  
**Scope:** Static code review of the public GitHub repository (README, architecture docs, core WalletService source files, tests). This is a **read-only code review**, not a dynamic penetration test or formal audit.  
**Assessor:** Kimi Chat (AI-assisted analysis)  
**Project context:** Pre-release native mobile wallet for eCash (LayerTwo Labs Bitcoin hardfork). Built with Skip (Swift → Kotlin/Compose cross-platform), BDK 2.3.x for Bitcoin operations, in heavy active development. Not yet accepting external contributions.

---

## ✅ Strengths (Well-Designed Security)

| Area | Assessment |
|------|------------|
| **Key storage architecture** | **Watch-only + sign-on-demand.** The everyday `WalletEngine` runs from public (xpub) descriptors only — balance, sync, address derivation, and PSBT building never touch the mnemonic. Private keys are loaded transiently, in-memory, for exactly one signing operation, then dropped. This is a best-practice design that minimizes the secret's memory lifetime. |
| **Secure storage** | Mnemonics stored via SkipKeychain → iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **no iCloud sync**) / Android Keystore-backed AES-256-GCM encrypted storage. No xprv or private descriptors ever persisted. |
| **Error scrubbing** | `WalletError.mapping()` classifies raw BDK errors by token-matching UniFFI variant names, then returns **fixed, pre-scrubbed user messages**. Raw error strings (which can embed descriptors/xprvs) are never echoed to the UI. This is backed by an **automated no-leak test suite** (`WalletErrorTests.swift`) that injects fake secret material into synthetic BDK errors and asserts nothing leaks through. |
| **Spend policy** | Conservative: only **confirmed coins + your own unconfirmed change** are spendable. Incoming 0-conf payments are shown as "pending" and excluded from coin selection, mitigating double-spend/RBF-replacement risks. |
| **Replay protection** | eCash transactions are stamped with `nLockTime = 499,999,999` (opt-in eCash replay marker) + explicit `nSequence = 0xFFFFFFFD`, preventing eCash spends from replaying onto the Bitcoin chain. |
| **Network/wallet isolation** | Every wallet's keys, descriptors, UTXOs, and chain data are namespaced by `walletId`. Removing a wallet purges the Keychain entry, JSON metadata, and BDK SQLite store. |
| **App lock & privacy** | Biometric/passcode gate on launch, foreground resume (with configurable grace period), and send confirmation. App-switcher snapshot is obscured when backgrounded. |
| **Android backup hardening** | Keychain prefs file explicitly excluded from `fullBackupContent` and `data_extraction_rules` (cloud + device-transfer), preventing encrypted mnemonic backups that would be undecryptable on other devices. |
| **No telemetry of secrets** | Explicit policy: no seed, xprv, or descriptor-with-keys in logs, analytics, crash reports, or screenshots. |

---

## ⚠️ Findings (Issues & Risks)

### 1. Deterministic zero BIP-340 aux randomness — Medium Risk, Documented TODO
**Location:** `WalletManager.swift` (`zeroAux`), `CoinNewsMessage.swift`

```swift
private static let zeroAux = Data([UInt8](repeating: UInt8(0), count: 32))
```

The CoinNews BIP-340 Schnorr signing uses **all-zero 32-byte aux randomness**. The code acknowledges this is a TODO: *"Zero is valid + deterministic; TODO: secure-random for fault-attack protection."*

While BIP-340 permits zero aux randomness and the signed data is public (so determinism doesn't leak the key directly), removing aux randomness eliminates **fault-attack protection**. In a fault-attack scenario (e.g., rowhammer, voltage glitching, or compromised device), deterministic nonce derivation can leak the private key. This should be fixed before mainnet or any real-funds usage.

**Recommendation:** Replace `zeroAux` with `SecRandomCopyBytes` / `java.security.SecureRandom` per signing operation.

---

### 2. No auth-bound keys (deferred hardening) — Medium Risk, Acknowledged Gap
**Location:** `docs/key-storage.md` §6

The mnemonic is stored at **device-unlocked** accessibility, not bound to per-use biometric authentication. The docs explicitly state this is **deferred** until before mainnet/funds:

> *"Decision: ship §5 first; revisit §6 specifically before eCash mainnet / real funds."*

For a testnet-only pre-release wallet this is acceptable. For production, auth-bound keys (iOS `SecAccessControl` with `.userPresence`, Android Keystore with `setUserAuthenticationRequired`) should be implemented using the envelope pattern (unwrap once per session).

**Recommendation:** Schedule §6 implementation before any mainnet release.

---

### 3. Custom crypto outside BDK for CoinNews/Thunder — Medium Risk
**Location:** `CoinNewsMessage.swift`, `CoinNewsIdentity.swift`, `CoinNewsCrypto` (implied)

CoinNews messages use **custom BIP-340 Schnorr signing** built on `swift-crypto` (Apple's open-source CryptoKit), not BDK. The README notes: *"The one exception is the in-development Thunder sidechain engine — a non-BDK chain, not yet user-facing — which uses swift-crypto + BLAKE3."*

Custom cryptographic implementations carry higher risk than battle-tested libraries. The BIP-340 signing here is relatively simple (tagged hash + schnorr sign), but any custom crypto path deserves extra scrutiny.

**Recommendation:** Ensure CoinNews crypto has dedicated unit tests against published BIP-340 test vectors, and consider a focused audit of this module before it becomes user-facing.

---

### 4. Remote endpoint configuration fetch — Low-Medium Risk
**Location:** `WalletManager.swift` (`setRemoteBackendDefault`), `NetworkRegistry.swift`

The app fetches "last-known-good" backend endpoints from a remote config service (`drivechain.dev/config`). While user overrides take precedence and bundled defaults are offline-safe fallbacks, a compromised remote config domain could redirect users to malicious Electrum/Esplora servers (MITM, censorship, or false balance attacks).

**Mitigation in place:** User overrides are highest precedence; the app validates addresses against the wallet's network before sending; and the network chip makes the active network visible.

**Recommendation:** Consider pinning the remote config signing key or using certificate pinning for the config endpoint.

---

### 5. Pre-release status / no formal audit — Risk Factor
The repository states: *"Building from source isn't recommended yet"* and *"The wallet is under heavy active development — APIs, storage layout, and screens change frequently."* No formal third-party security audit is mentioned.

**Recommendation:** Commission an independent security audit before mainnet launch, focusing on:
- The BDK seam (WalletService transpilation correctness)
- Key storage and sign-on-demand flow
- Custom CoinNews/Thunder crypto
- Skip framework bridge security

---

## 📋 Additional Observations (Not Vulnerabilities)

| Observation | Context |
|-------------|---------|
| **WIF keys stored as secrets** | Single-key WIF imports store the WIF string in the same KeyStore as mnemonics. This is necessary but means WIF users have the same storage profile as mnemonic users. |
| **Screenshots not blocked on backup** | Intentional UX decision: *"capturing one's own recovery phrase is the user's call."* The app-switcher snapshot is still obscured. |
| **Firebase Cloud Messaging** | Used only for manual announcements. Introduces a third-party trust assumption for push delivery. |
| **Skip framework complexity** | Mixed Fuse (native Swift) + Lite (transpiled Kotlin) architecture adds build-time and runtime complexity. The bridge (`bridging: true`) is a non-trivial trust boundary. |
| **Hardcoded default endpoints** | Standard practice for wallet defaults; all are overridable in Settings. |

---

## 📊 Overall Verdict

| Category | Rating | Notes |
|----------|--------|-------|
| **Key management** | ⭐⭐⭐⭐⭐ | Watch-only + sign-on-demand is excellent. |
| **Storage security** | ⭐⭐⭐⭐☆ | Strong, but auth-bound keys deferred. |
| **Error handling / leak prevention** | ⭐⭐⭐⭐⭐ | Automated no-leak tests are a standout. |
| **Custom crypto** | ⭐⭐⭐☆☆ | Outside BDK; needs more scrutiny. |
| **Maturity / audit status** | ⭐⭐⭐☆☆ | Pre-release, no formal audit yet. |

**Bottom line:** This is a **thoughtfully architected wallet** with strong security foundations — particularly the watch-only engine, secure storage, and error-scrubbing discipline. The primary gaps are the **deterministic BIP-340 aux randomness** (fixable), **deferred auth-bound keys** (scheduled), and the **custom crypto paths** for CoinNews/Thunder. These are all acknowledged by the developers and documented as pre-mainnet TODOs. Before handling real funds, a formal audit and resolution of the TODOs in `docs/key-storage.md` §6 and `WalletManager.swift` `zeroAux` should be prioritized.

---

*This assessment is based solely on publicly available source code and documentation. It does not constitute a formal security audit and should not be the sole basis for trust decisions involving real funds.*
