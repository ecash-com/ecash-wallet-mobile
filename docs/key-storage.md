# Key Storage — security decision record

How the wallet persists and protects private key material. Complements `CLAUDE.md` §7 (security
model) and the Golden Rules (§2). Keep in sync with `KeyStore.swift` / `WalletStore.swift`.

---

## 1. What we persist

**One secret per wallet: the BIP39 mnemonic phrase** (the words, as a `String`) — or, for a wallet
imported from a legacy private key, the **WIF** in the same slot (`WalletManager.importPrivateKey`,
`keyType: .wif`).

- Stored via `KeychainKeyStore` (`KeyStore.swift`), key `ecashwallet.mnemonic.<walletId>`. A wallet
  the seed-container migration merged may also list `orphanKeychainIds` — the merged copies' entries,
  left in place (`WalletManager.mnemonic(for:)` falls back to them; see §7 for removal).
- We do **NOT** persist the seed bytes, the `xprv`, or any private descriptor. BDK **derives**
  those from the mnemonic at runtime (to build descriptors / sign) and they are dropped — never
  written to disk.
- `WalletStore` (a JSON file) holds **public data only**: label, the wallet's `WalletAccount`s (one
  per network × scriptType × accountIndex, each with its xpub-based descriptors and BDK store name),
  `selectedAccountId`, backup flag, order (`Models.swift`). No key material.

Rationale: the mnemonic is the minimal, standard, human-restorable secret; everything else is
either derivable from it or public. Storing the phrase (not seed/xprv) is what the backup/reveal
and cross-wallet-import flows need.

## 2. Where it lives (SkipKeychain, per platform)

| | iOS | Android |
|---|---|---|
| Backing | native **Keychain** (`SecItem…`) | **EncryptedSharedPreferences** (Jetpack Security), file `tools.skip.SkipKeychain` |
| At rest | Keychain class keys protected by the **Secure Enclave** | values **AES-256-GCM**, keys AES-256-SIV, under a **master key in the Android Keystore** (hardware-backed where a TEE/StrongBox exists) |
| Our access flag | `.unlockedThisDeviceOnly` → `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (decryptable only while unlocked; **no iCloud sync**; does not migrate to a new device) | ⚠️ **the access flag is iOS-only** — on Android it's a no-op; EncryptedSharedPreferences encrypts at rest but does not bind to device-unlock/biometric |

Both platforms give **encryption at rest with a hardware-protected key**. The master key is
device-bound on both, so the secret cannot be decrypted on another device.

## 3. Core principle: the mnemonic must be readable for normal operation

Originally every sync / balance / send re-derived keys from the mnemonic. Since the watch-only engine
(below, 2026-06-13) only **signing** reads it — BDK signing at send, and Thunder signing
(`ThunderService` loads the mnemonic transiently to sign, then drops the derived wallet). A per-read
biometric prompt would still land in the middle of every send, so:

- The mnemonic is stored at **device-unlocked** readability (not per-read auth-gated).
- Protection of **sensitive actions** is an **app-level gate**, not a per-read Keychain ACL — see §5.

This is the standard mobile-wallet pattern. The consequence to accept: on an unlocked device with
the app running, the mnemonic is readable by the app process. Mitigations are the app-lock (§5) and,
optionally, auth-bound keys (§6).

**Engine shape — watch-only tracking, sign-on-demand (SHIPPED 2026-06-13).** Only *signing* needs
the private keys; balance/addresses/sync/history/PSBT-build need only the **public** (xpub)
descriptor. So the everyday `WalletEngine` is built from the **public** descriptors (watch-only,
**no mnemonic read at all**). `BDKWalletEngineFactory` hands it a `signPsbt` closure that — only at
send time — loads the mnemonic, builds a **transient in-memory private-descriptor `Wallet`**
(`Persister.newInMemory()`), signs the watch-only-built PSBT (BDK re-derives keys from the PSBT's
BIP32 paths), and drops it. The secret's in-memory window is a single signing op; it pairs with the
per-send auth gate (§5). (Aside: a wallet whose *stored* public descriptors predate the
master-tpub-derivation fix can't be loaded watch-only — re-import or reset it.)

## 4. Backup handling (DECIDED + shipped)

Android `allowBackup` is `true` (Skip default) and useful for the harmless public data (wallet-list
metadata, chain cache). But the encrypted mnemonic prefs must **not** be backed up: the Keystore
master key is device-bound, so a backed-up copy is undecryptable elsewhere **and** triggers
SkipKeychain's silent-wipe-on-restore path (`AEADBadTagException`).

**Shipped:** targeted exclusion of `tools.skip.SkipKeychain` from both backup paths —
`Android/app/src/main/res/xml/backup_rules.xml` (API ≤30 `fullBackupContent`) and
`data_extraction_rules.xml` (API 31+ `cloud-backup` + `device-transfer`), referenced from
`AndroidManifest.xml`. Verified building via `skip export --debug`.

iOS needs no equivalent: `WhenUnlockedThisDeviceOnly` already excludes the item from iCloud and
device migration.

## 5. App-lock & action gates (SHIPPED)

The protection layer (CLAUDE.md §7). Lives in the **app module** (Fuse), platform-bridged; gates the
UI/flows, **not** the KeyStore read (which stays device-unlock readable so sync works).

- **Launch / resume gate:** biometric-or-passcode on cold launch and on foreground return, with a
  configurable background **grace** (Settings → Auto-lock; default 10s) so a quick hop out doesn't
  re-prompt. Settings toggle; default on. Failure → locked screen, no wallet data shown. A
  `PrivacyCover` hides balances from the app-switcher snapshot while backgrounded.
- **Per-action gate — reveal seed:** biometric/passcode → reveal words → confirm N random words →
  mark `isBackedUp`. **Screenshots are no longer blocked** (decided 2026-06-25 — the
  `PlatformBridge.setSecureScreen`/`FLAG_SECURE` capability remains but has no callers); only the
  app-switcher snapshot is obscured (`PrivacyCover` on iOS, `setRecentsScreenshotEnabled(false)` on
  Android API 33+).
- **Per-action gate — send:** biometric/passcode confirm immediately before broadcast (honors the
  same toggle). In addition to the explicit recipient/amount/fee/**network** review.
### Mechanism — two complementary primitives (don't conflate them)

There are **two different** auth mechanisms; we use both, for different jobs:

- **(b) Standalone auth prompt — used by THIS section (app-lock + action gates).** Just asks "is it
  you?" and returns a **boolean**. Gates things that are *not* reading a stored secret: launch/resume
  lock, the Send confirm, a sensitive settings change, re-revealing in-memory data.
  ⚠️ This is a **UX gate, not a cryptographic boundary** — on a rooted/jailbroken device the boolean
  can be subverted. Use it freely for UX; do **not** rely on it to protect the seed itself.
- **(a) Auth-*bound* key — §6, used to protect the seed at rest.** Cryptographically ties *using* the
  stored secret to a fresh auth (the data is undecryptable without it). Stronger; reserved for the
  mnemonic. See §6.

**There is no first-party Skip biometric API** (verified: SkipKeychain is storage-only; no
`SkipLocalAuthentication`). So (b) is a **bridge seam** in the app module, à la the BDK seam.

**As built** (`enum DeviceAuth`, `Platform/DeviceAuth.swift`; `static func authenticate(reason:) async -> Bool`):
- **iOS** (`#if os(iOS)`, native): `LAContext().evaluatePolicy(.deviceOwnerAuthentication, …)` —
  `.deviceOwnerAuthentication` includes the **passcode fallback** (`…WithBiometrics` is bio-only).
- **Android**: `PlatformBridge.authenticateUser` (transpiled glue in `WalletService/Platform.swift`)
  → the **framework** `android.hardware.biometrics.BiometricPrompt` (API 28+, no `androidx.biometric`
  dependency) with `BIOMETRIC_WEAK | DEVICE_CREDENTIAL` for the PIN/pattern/password fallback, its
  callback bridged to Swift `async`.
- **Availability/enrollment:** `canEvaluatePolicy` / `BiometricManager.canAuthenticate(...)` are
  checked first; when **nothing is enrolled the gate passes through** (a credential-less device has
  no credential to verify — the flows behind it keep their explicit confirmation steps). This differs
  from the original plan's "block the gate (don't silently pass)".
- The view models take the auth as a seam (`SendViewModel.authorize`) so app-lock / reveal / send
  test on both platforms without real biometrics.

## 6. Optional hardening — auth-bound keys (deferred; evaluate before mainnet/funds)

Stronger than §5: bind the secret itself to user authentication, so even a compromised-but-unlocked
device can't read it without a recent auth.

- **iOS:** `SecAccessControl` with `.userPresence` / `.biometryCurrentSet`. Naive use prompts on
  every read; mitigate with the **envelope pattern** — wrap the mnemonic with an Enclave/auth-bound
  key, unwrap **once per authenticated session** into memory.
- **Android:** a Keystore key with `setUserAuthenticationRequired(true)` + a short validity window,
  used to wrap the mnemonic. (SkipKeychain's default master key is NOT auth-bound, so this is a
  custom path beyond SkipKeychain.)

Tradeoff: real UX friction and added complexity. Decision: ship §5 first; revisit §6 specifically
before eCash mainnet / real funds. *(2026-11-10: eCash mainnet has been live since 2026-10-29 with §5
only — auth-bound keys remain an open item, not a gate that was met.)*

## 7. Other exposure notes

- **Process memory:** the mnemonic is a managed `String` during derivation; Swift/Kotlin strings
  aren't zeroed, so it lingers in memory transiently. Hard to fully mitigate in a managed runtime;
  keep the live window short (derive → use → drop references) and don't log it (Golden Rule §2).
- **Remove = purge:** `WalletManager.removeWallet` deletes the Keychain entry + WalletStore rows +
  the BDK chain-data SQLite (Golden Rule §5). A merged copy's orphan Keychain entry
  (`orphanKeychainIds`) is deleted **only if byte-identical** to the wallet's own entry; a
  non-matching or unreadable orphan is left in the Keychain — never a secret deleted on a guess.

## 8. Status / to-dos

- [x] Persist only the mnemonic; public-only `WalletStore`; no seed/xprv on disk.
- [x] Encryption at rest both platforms (Keychain / EncryptedSharedPreferences).
- [x] iOS `WhenUnlockedThisDeviceOnly` (no iCloud, device-only).
- [x] **Android backup exclusion** of the keychain prefs (§4) — shipped + build-verified.
- [x] **Watch-only + sign-on-demand** engine (§3) — everyday engine reads no mnemonic; signing only.
- [x] **App-lock + reveal/send gates** (§5) — incl. background grace + privacy cover. (Screenshot
      blocking was dropped 2026-06-25.)
- [x] **Secret-scrub audit** across logs/errors/analytics (CLAUDE.md §7) — manual pass + automated no-leak test.
- [ ] **Auth-bound keys** (§6) — still open; mainnet went live 2026-10-29 without them.
