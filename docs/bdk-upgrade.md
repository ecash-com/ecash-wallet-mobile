# BDK 2.3 → 3.x upgrade

**Status:** 📋 PLANNED, NOT STARTED — noted 2026-09-29. Do it as its own change (CLAUDE.md §3:
"BDK is pre-3.0 on an ~8-week cadence — upgrade deliberately, never float").

## Why now

Sidechain deposits need a deposit's OP_RETURN to sit **immediately after** the treasury output.
bdk-ffi 2.3.1 always shuffles outputs, so `WalletEngine.prepareDeposit` rebuilds until the shuffle
comes out right (≤32 attempts, rejected builds cancelled; `docs/sidechain-deposits.md` §4a).
**bdk-ffi 3.0.0 (2026-06-09) exposes `TxBuilder.ordering(TxOrdering)`**, which removes the need
for that loop. 3.1.0 (2026-09-11) is current.

Also useful in 3.x: foreign UTXOs with an explicit `nSequence`, Electrum client timeout/retry
parameters, locked-outpoint APIs, and `Wallet.checkpoints`.

## Where we're pinned

| | Pin | File |
|---|---|---|
| bdk-swift | `.upToNextMinor(from: "2.3.1")` | `Packages/WalletService/Package.swift` |
| bdk-android | `2.3.1` | `Packages/WalletService/Sources/WalletService/Skip/skip.yml` |

Both must move together (same Rust core; the seam assumes identical APIs on both sides).

## Breaking changes that touch us (bdk-ffi 3.0.0 changelog)

1. **`DescriptorSecretKey::new` no longer adds a wildcard automatically** (#853). Anything building
   descriptors from a secret key must add it (`add_wildcard`). **This is the dangerous one:** get it
   wrong and a restored wallet derives different addresses. Call sites: the sign-on-demand signer
   in `BDKWalletEngineFactory`, `Descriptors.swift`, custom-derivation import, entropy wallets.
2. **`Descriptor` and `DescriptorSecretKey` constructors take a `NetworkKind`** instead of a
   `Network` (#986). Mechanical, but it runs through `BDKSeam.network` and every descriptor build.
3. **bdk_wallet 3.0 persistence.** Check what a 2.x SQLite store looks like when 3.x opens it.
   `Persister::get_pre_v1_wallet_keychains` exists for *pre-v1* migration, which suggests schema
   care. Existing users' chain data must load, or at worst rebuild by a rescan; never a changed
   wallet.
4. uniffi 0.30: regenerate and re-check the Kotlin side's signatures (unsigned-type mangling on the
   bridge, `List`/`Map` conversions, `Input`'s constructor used by `treasuryPsbtInput` via
   `SKIP REPLACE`).

## Gate (all green before merging)

- `BDKWalletEngineTests` spec vectors: BIP84 mainnet addresses, pinned signet vectors, WIF
  import vectors. **These are the proof that derivation didn't move.**
- Persistence round-trip across the upgrade: a store written by 2.3.1 opens under 3.x with the
  same addresses, balance and history.
- `DepositEngineTests`, with the ordering loop replaced by `.ordering(.untouched)` and the shape
  check kept.
- Full WalletService suite under Robolectric, the app suite, and `skip export` for Android.
- A real send on betanet from an existing (pre-upgrade) wallet on both iOS and Android.

## After

Delete the loop in `WalletEngine.prepareDeposit` and `depositOrderingAttempts`; keep
`Drivechain.isValidDeposit` on the unsigned and signed transaction. Update CLAUDE.md §3's version
table and the `bdk-swift 2.3.1 API map` memory.
