# Cloud seed backup — design record (iCloud / Google Drive)

> **Status:** PROPOSED / exploring — **not built**. Scopes optional, opt-in, **client-side-encrypted**
> backup of a wallet's recovery phrase to the user's own iCloud (iOS) / Google Drive (Android), so a
> user can restore without their written words. Touches the highest-stakes data in the app — read the
> security model before building. Relates to `docs/key-storage.md`, `docs/plausible-deniability.md`,
> and CLAUDE.md §2 (Golden Rules) / §7 (Security model).

## 0. Why this is a real decision, not just a feature
Most coin losses for normal users come from **lost paper backups**, so cloud backup is a genuine UX
win and many mainstream wallets offer it (Coinbase Wallet, BlueWallet, Muun, Green). But for a
**privacy-focused, self-custody** wallet it's a deliberate tradeoff:
- It **converts "security of your seed" into "security of your encryption password + your cloud
  account."** A weak password plus a phished/compelled iCloud or Google account = stolen funds.
- It puts an (encrypted) artifact on Apple/Google servers — not a direct leak, but metadata ("this
  Apple ID has a wallet") and a target.
This must be **opt-in**, loudly warned, and never the default. The written-words backup stays primary.

## 1. The non-negotiable security core
- **Never upload the raw seed.** Upload **ciphertext only**, encrypted **client-side**.
- **Key derivation:** from a **user-supplied password** via a vetted, memory-hard KDF — **Argon2id**
  (preferred) or scrypt; never a bare hash. High parameters; store the salt + params with the blob.
- **Encryption:** AES-256-GCM (or XChaCha20-Poly1305) — authenticated. Use vetted primitives, no
  hand-rolled crypto (CLAUDE.md §2).

### 1a. Crypto library reality (what's actually available cross-platform)
There is **no Skip crypto module** (`skip-keychain` is secure *storage*, not primitives). Concrete
options, split by half:

- **Encryption (AES-256-GCM, SHA, HMAC, HKDF, `SymmetricKey`): use `apple/swift-crypto`**
  (`import Crypto`). It's the open-source CryptoKit-API implementation (BoringSSL-backed) that
  compiles on Linux/Android, so in our **Fuse** app (native Swift for Android) it should provide
  these on both platforms. This half is solved.
- **Password KDF — the only real decision:**
  - **PBKDF2-HMAC-SHA256** (high iterations) is available via swift-crypto's companion
    **`_CryptoExtras`** (`KDF.Insecure.PBKDF2`). Cross-platform, defensible (BIP39 uses PBKDF2), but
    **not memory-hard**.
  - **Argon2id / scrypt are NOT in swift-crypto.** To get Argon2id (the better choice for a seed),
    the cleanest path is **Rust**: extend `bdk-ffi` (or a sibling crate) with RustCrypto's `argon2` +
    `aes-gcm` and regenerate the Swift+Kotlin bindings — the "do the crypto once in Rust" pattern of
    CLAUDE.md §12. **Recommended for this feature** given it's the highest-stakes data in the app and
    yields one audited impl for both platforms.
- **Don't assume `swift-crypto` builds under Fuse** — its BoringSSL C-interop works on server-Linux,
  but **verify with `skip export`** on the Android target before committing. (The Rust-binding route
  sidesteps this risk entirely, since the crypto compiles in the existing bdk-ffi pipeline.)
- We already pull in `swift-secp256k1` (P256K) and BDK (PBKDF2 internally for BIP39), but **neither
  exposes a general AES/KDF API**, so they don't help here.

> Net: AES-GCM is a solved cross-platform problem; pick the KDF — **PBKDF2 via `_CryptoExtras`**
> (available now, good-enough) vs. **Argon2id via a Rust binding** (better, recommended for the seed).
- **The password is everything** — enforce real strength, and **never store or upload it** (storing it
  defeats the entire scheme). Consequence to accept up front: **forgot password = no cloud restore**
  (fall back to the words). Don't add a "recover without password" path — that would mean the cloud
  account alone unlocks funds.
- **Blob contents:** the mnemonic (+ minimal metadata to rebuild the `ManagedWallet`: label, network,
  birthday/height for faster rescan). Per-wallet (each wallet = its own seed), keyed by `walletId`.
- **No private descriptors / xprv** in the blob — just the mnemonic, like `KeyStore` (re-derive on
  restore via the existing import path).

## 2. Two paths — pick deliberately

### Path A (recommended first): encrypted backup FILE export/import
We produce a password-encrypted backup file and hand it to the OS **share sheet / Files app**; the
*user* chooses where it goes (iCloud Drive, Google Drive, AirDrop, a USB drive…).
- **Pros:** most of the value (restorable encrypted backup that can live in their cloud); **zero cloud
  SDKs, no CloudKit entitlement, no Google OAuth, no CEO/account ask**; keeps us out of the
  cloud-account business; most on-brand for a privacy wallet; identical crypto to Path B.
- **Cons:** less seamless (manual file handling); no automatic "it's just there on my new phone."
- **Mechanics:** `ShareLink` / share sheet on iOS, `ACTION_CREATE_DOCUMENT` (SAF) on Android for
  export; document picker for import. Mostly app-layer + the encryption.

### Path B: native auto-sync to iCloud / Google Drive
Seamless "back up" / "restore" buttons that read & write the user's cloud directly.
- **iOS / iCloud:** store the encrypted blob in **CloudKit private DB** or the app's iCloud container.
  Requires the **iCloud capability + CloudKit container entitlement** provisioned in the Apple
  Developer account. Note this runs *against* our deliberate `ThisDeviceOnly`, no-iCloud-sync Keychain
  choice (`docs/key-storage.md`) — cloud backup is a separate, explicit, opt-in store, not a change to
  Keychain behavior.
- **Android / Google Drive:** the hidden **`AppDataFolder`** via the Drive REST API — pulls in
  **Google Sign-In + Play Services + Drive SDK**, and needs an **OAuth client + Drive API enablement
  in Google Cloud Console** (a CEO/account-level ask, like the Firebase one declined in
  `docs/notifications.md`).
- **Pros:** seamless restore on a new device.
- **Cons:** two separate, heavier platform integrations (Skip won't abstract them — `PlatformBridge`
  seam, but with big SDKs); account/entitlement setup on both stores; more attack surface; ties Android
  into GMS/Drive deps.

> Recommendation: ship **Path A** first (cheap, privacy-clean, no account asks), and only add **Path B**
> if users genuinely want zero-touch sync. The crypto is shared, so A is a strict subset of B.

## 3. Flows
- **Back up:** gate with device auth → user sets a strong encryption password (with strength meter +
  explicit "this is the only key; we can't recover it" warning) → encrypt → (A) export file / (B) write
  to cloud. Mark the wallet as cloud-backed-up (local metadata).
- **Restore:** (A) pick file / (B) sign in + list backups → user enters password → decrypt → import via
  the existing import path → rebuild `ManagedWallet`. A wrong password just fails to decrypt (AEAD tag
  mismatch) — no oracle, no hint.
- **Multi-wallet:** which wallets to include, update-on-add/remove, conflict handling (Path B).

## 4. Architecture fit
- **BDK is irrelevant** — this is purely mnemonic storage/restore; reuse the import flow.
- **Crypto** belongs in a small, testable module (KDF + AEAD), platform-agnostic Swift; spec-vector
  tested. Don't scatter it.
- **Per (wallet × network)** isolation unchanged; restore re-derives everything from the seed.
- **Capture-aversion:** the password-entry + any seed-adjacent screen should stay screenshot-averse
  (note: we *did* allow screenshots on the Backup word screens — revisit for the password step).

## 5. Caveats / risks
- **Philosophy call for a privacy wallet** — encrypted-on-their-cloud vs. self-custody purity. Decide
  intentionally; it's opt-in and warned regardless.
- **Password is the single point of failure** — both directions (weak → theft risk; forgotten → no
  restore). UX must make this unmistakable.
- **Path B account setup** is real overhead (CloudKit entitlement; Google OAuth/Drive API + a CEO ask)
  and ongoing dep weight (GMS/Drive on Android).
- **Security review required before shipping** — it's the seed. Treat like consensus code.

## 6. Effort
Medium–large, **not** BDK work: a vetted encryption module + strong-password UX + restore flow
(Path A), plus two cloud SDK integrations + account/entitlement setup (Path B). Path A alone is a
contained, lower-risk increment.
