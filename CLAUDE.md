# CLAUDE.md — eCash.com Wallet

> Project bible for Claude (and humans). Read this fully before writing or changing code.
> Keep it current: when an architectural decision changes, update this file in the same PR.
>
> **Product name:** eCash.com Wallet (the `.com` is part of the name). The **home-screen/launcher label** is the shortened **eCash.com** (`CFBundleDisplayName` / `android:label`); the in-app name stays the full **eCash.com Wallet**.
> **Code identifiers:** `EcashWallet*` for modules/types (no dots in identifiers); use the full display name only in UI strings, app name, and store listings.

---

## 1. What this is

A native mobile Bitcoin wallet — **eCash.com Wallet** — for **eCash**, the Layer Two Labs Bitcoin hardfork that activates Drivechain (CUSF BIP300/BIP301) at block 964,000 (August 2026), airdropping eCash 1:1 to BTC holders. This wallet is the user-facing way to hold, send, and receive coins on that network.

**v1 scope (this milestone):** the fundamentals, **multi-wallet and multi-network from day one**.

- **Manage multiple wallets** — add, switch, rename, remove; **each wallet is its own seed** (its own mnemonic), independent (§4 / `docs/wallet-and-network-model.md`).
- **Network is chosen at creation** (new wallets default to **L2L Signet**), then switchable among the testnet-class set. Bundled networks: **Bitcoin mainnet** (coin-type `0'`, real money, creatable), **Testnet4**, **L2L Signet**, **regtest** (all testnet-class, coin-type `1'`, shared keys), plus **eCash-testnet/signet/mainnet** added later (design the network layer to absorb them now — see §4).
- Create wallet (generate seed → pick network — **defaults to L2L Signet**, never auto-mainnet — → Home)
- Import wallet (restore from seed / descriptor; same network picker)
- Backup wallet (reveal + verify seed) — per wallet
- Receive (addresses + QR)
- Send (build, sign, broadcast)
- Transaction history (list + detail)
- Settings — global (theme, currency, app-lock) + per-network backend endpoints + per-wallet (label, network)

**Explicitly out of scope for v1** (design for them, don't build them yet): BIP300/301 sidechain deposits & withdrawals, multisig, Lightning, watch-only, address book, fiat on-ramps. See §12.

**Decisions already made (do not relitigate):**

- Cross-platform via **Skip** (`skip.dev`) — one Swift + SwiftUI codebase, native SwiftUI on iOS, native Jetpack Compose on Android.
- Wallet engine via **BDK** (`bitcoindevkit`) — `bdk-swift` on iOS, `bdk-android` on Android, same Rust core.
- No React Native.

---

## 2. Golden rules (non-negotiable)

1. **BDK owns all key material and consensus logic.** Never hand-roll key derivation, signing, address generation, PSBT building, coin selection, or fee math. If BDK exposes it, use BDK.
2. **Seed/private keys never leave the secure store and never get logged.** No seed, xprv, or descriptor-with-private-keys in logs, analytics, crash reports, screenshots, or error messages. Mnemonics live in the OS secure enclave (see §7).
3. **The BDK seam is the only place with platform `#if`.** All `#if os(Android)` / `#else` branching for BDK lives in the `WalletService` module wrapper. UI and view models stay platform-agnostic Swift.
4. **A wallet is a seed; network is chosen at creation, switchable among the testnet-class set** (REVISED 2026-06-14 — see `docs/wallet-and-network-model.md`). "Create wallet" generates a new mnemonic; multiple wallets = multiple independent seeds. The network **is** chosen at create/import (picker defaults to **L2L Signet**, never auto-mainnet) because **Bitcoin mainnet is coin-type `0'`** — a distinct address set, so it can't be a switchable view of a testnet wallet. The testnet-class networks (Testnet4, L2L Signet, regtest, future eCash-testnet/signet) are all **coin-type `1'`, HRP `tb`**, so one mnemonic yields the **identical** addresses across them — among those, network stays a switchable view (only backend/chain differs; one descriptor set serves all; isolated balance/history per (wallet × network)). Mainnet (`0'`) is real money — deliberate (extra send confirmation, real-money warnings; marked with its own **Bitcoin-orange** chip, §6). All network details resolve through one **`NetworkRegistry`** — never hardcoded.
5. **Wallets are isolated.** Every wallet's keys, descriptors, addresses, UTXOs, transactions, and BDK chain data are namespaced by a stable `walletId`. Never mix data across wallets or networks. Removing a wallet purges all of its data.
6. **Every network must be unmistakable.** At every money-touching surface (home balance, send review, receive, history, wallet switcher) a wallet shows a persistent, high-contrast network chip **in its network's own color** — testnets in violet, **Bitcoin mainnet in its real orange** (`NetworkChipStyle`, a code-level per-network config). A user must never confuse a testnet wallet with a mainnet one. Never auto-select mainnet for a destructive/irreversible action without explicit network confirmation.
7. **Don't broadcast without explicit user confirmation** of recipient, amount, fee, **and network**.
8. **Fail loud in dev, fail safe in prod.** Surface BDK errors to the user as actionable messages; never silently swallow a signing or broadcast failure.

---

## 3. Tech stack & versions

| Layer | Choice | Notes |
|---|---|---|
| Language | Swift 6 | Shared across both platforms via Skip |
| UI | SwiftUI → Compose | Skip transpiles SwiftUI to Jetpack Compose |
| Cross-platform | Skip — **Fuse app + Lite `WalletService`** | Decided 2026-06-11; see §5 |
| Wallet engine (iOS) | `bdk-swift` (SPM, product `BitcoinDevKit`) | ~2.3.x; precompiled `xcframework` |
| Wallet engine (Android) | `bdk-android` (Maven `org.bitcoindevkit:bdk-android`) | ~2.3.x; needs **NDK 27+**, **Kotlin 2.1.10+** |
| Secure storage | SkipKeychain | iOS Keychain / Android Keystore |
| Local storage | **BDK-owned SQLite** (chain data — UTXOs/txs/derivation state, per wallet via `Persister.newSqlite`) + **JSON `FileWalletStore`** (public wallet-list metadata) | **NOT SkipSQL** (removed — BDK owns its own store). Secrets → Keychain (above). Account/address labels are app-owned metadata (post-v1; see `docs/accounts-and-labels.md`). |
| QR | **generate:** QRCodeGenerator (pure-Swift) · **scan:** SkipQRCode (Android ML Kit) / AVFoundation (iOS) | Receive QR + Send scanner; SkipQRCode is scan-only |
| Min OS | iOS 26+ (manifest `.iOS("26.0")` + `IPHONEOS_DEPLOYMENT_TARGET=26.0`; ≈75–86% of active iPhones, climbing), Android 9 (**API 28** — Skip Fuse floor; emitted `minSdkVersion=28`, ≈93.5% of active devices) | iOS-26 floor lets the iOS path use Liquid Glass without `#available`; bdk-android needs NDK 27+ / NDK target API ≥29. macOS test/transpile host stays `.v14`. |

Pin exact versions in `Package.swift` / `skip.yml`. BDK is pre-3.0 on an ~8-week cadence — upgrade deliberately, never float.

### Claude Code tooling (Skip skills)

Develop this project with the official Skip agent skills installed in **Claude Code**:

```
/plugin marketplace add skiptools/skills
/plugin install skip-app-design
/plugin install skip-testing-deployment
```

They load automatically by topic. What they cover and why it matters here:

- **`skip-app-design`** — project creation (`skip init`), SwiftUI→Compose authoring, Lite transpilation rules, Fuse, adding Skip frameworks (SQL/Keychain/etc.), localization, and **icons**. Two constraints it encodes that bind us directly:
  - **No SF Symbols.** `Image(systemName:)` does **not** transpile. Use the Material Symbols `.symbolset` workflow (see §8/§10). This is a hard rule, not a preference.
  - Lite transpilation has real Swift-subset limits — consult `skip-lite-transpilation` before reaching for advanced Swift in shared code.
- **`skip-testing-deployment`** — parity testing (XCTest/Swift Testing across both platforms), UI automation (`skip app launch` + Maestro), and release/signing/CI. Drives §11.

Defer to these skills' guidance when it's more specific than this file; if they conflict with a Golden Rule (§2), the Golden Rule wins — flag the conflict.

---

## 4. Architecture

Single Skip SwiftPM project. Module boundaries:

```
ecash-wallet-mobile/
├─ Package.swift          # the Fuse app package (mode: native). Depends on Packages/WalletService.
├─ Sources/
│  └─ ECashWalletMobile/  # the single Fuse (native) app module: app entry, UI, view models, state.
│                         #   (NOTE: the planned EcashWalletModel/UI/App split is collapsed into
│                         #    one module — Fuse apps are single-module; see §5.)
├─ Packages/
│  └─ WalletService/      # SEPARATE Skip Lite (transpiled) package — the BDK seam. See §5.
│     ├─ Package.swift     # carries bdk-swift (Apple, platform-conditioned)
│     └─ Sources/WalletService/
│        ├─ Skip/skip.yml      # mode: 'transpiled' + bridging:true (Fuse app forwards via JNI); injects bdk-android Gradle dep
│        ├─ WalletEngine.swift # per-wallet: create/import, sync, balance, build/sign/broadcast (+ #if seam)
│        ├─ WalletManager.swift   # owns the set of wallets + the selected wallet; vends engines
│        ├─ NetworkRegistry.swift # WalletNetwork -> params, coin-type, backend, explorer, unit
│        ├─ KeyStore.swift        # per-walletId mnemonic persistence via SkipKeychain
│        ├─ WalletStore.swift     # JSON FileWalletStore: per-walletId PUBLIC metadata, CRUD + purge (BDK owns chain data)
│        ├─ Descriptors.swift     # network-aware descriptor templates (BIP84; coin-type 0'/1')
│        ├─ WalletError.swift     # typed, secret-scrubbed errors -> user strings
│        └─ Models.swift          # WalletNetwork, ManagedWallet, WalletTx, Utxo, AddressInfo, Amount
├─ Android/               # generated; Compose output + any Kotlin-only glue
└─ Darwin/                # iOS app target
```

> Reality note: the v1 scaffold uses a single Fuse app module (`ECashWalletMobile`) rather than the original `EcashWalletModel`/`EcashWalletUI`/`EcashWalletApp` split, because a Fuse app is one native module (§5). The Model/UI/App separation is enforced by convention/folders within that module. Only `WalletService` is a separate (transpiled) package. `WalletManager`/`KeyStore`/`WalletStore` are built and in use.

**Dependency direction:** `App → UI → Model → WalletService`. Nothing depends upward. WalletService knows nothing about SwiftUI.

### Multi-wallet & multi-network model

The app holds **N wallets, each its own seed**; **network is a switchable view, not a pin** (REVISED 2026-06-12 — `docs/wallet-and-network-model.md`). Don't build a single-wallet app and retrofit — build the manager first.

- **`WalletNetwork`** (enum): `.bitcoin`, `.testnet4`, and future `.ecashMainnet`, `.ecashTestnet(…)`. Each case resolves through `NetworkRegistry` to: BDK chain params, **derivation coin-type** (`0'` mainnet, `1'` for all test networks), default Electrum/Esplora endpoint, explorer URL template, address HRP, and unit/display label. **Mark it non-exhaustive in spirit** — adding eCash later is a registry entry + params, not a refactor.
  - BDK support: **Testnet4** and **Signet** are first-class (`bdk_wallet`; rust-bitcoin models testnet4 as `Network::Testnet(.v4)`); Regtest for dev. **eCash needs NO custom `Params`/forked binding** (resolved — `docs/key-derivation.md`): eCash is byte-identical to Bitcoin, so eCash-testnet/signet map to `Network.testnet4`/`.signet` and eCash-mainnet to `Network.bitcoin` — they differ only by backend. `WalletNetwork` + `NetworkRegistry` remain the seam.
- **`ManagedWallet`** (value type): `id` (stable UUID/string), `label`, `network: WalletNetwork` (the **currently-selected** view — switchable, not an immutable pin), public descriptors (the shared testnet coin-type `1'` set), `isBackedUp`, `createdAt`, sort index. No private keys in this struct.
- **`WalletManager`**: owns the ordered list of `ManagedWallet` + the **selected** wallet; handles add/import/rename/remove/reorder/select; vends a `WalletEngine` per **(wallet × network)**. The selected network passes to BDK at construction (`check_network` enforced on load); each (wallet × network) keeps isolated balance/history.
- **Storage namespacing (Golden Rule §5):** mnemonics in Keychain keyed by `walletId`; the JSON `FileWalletStore` holds the public wallet list; BDK chain data is per (wallet × network). **Remove = purge** every keyed artifact.
- **Descriptors are coin-type-aware:** `Descriptors.swift` builds BIP84 with the correct coin-type — the three testnet-class networks **share** coin-type `1'` (one descriptor set serves all three); mainnet (`0'`) is a distinct set. Never reuse a mainnet (`0'`) descriptor on a testnet wallet or vice-versa.

### The BDK seam (the crux)

`WalletService` is a **Skip Lite (transpiled)** module so it can import the Kotlin BDK API directly. The wrapper presents one Swift-facing API; the bodies branch per platform. Because both bindings are UniFFI-generated from the same Rust core, the two branches are nearly identical.

`Sources/WalletService/Skip/skip.yml` (adds the Android dependency; `bdk-android` is on mavenCentral so no custom repo needed):

```yaml
build:
  contents:
    - block: 'dependencies'
      contents:
        - 'implementation("org.bitcoindevkit:bdk-android:2.3.1")'
```

`Package.swift` (adds the iOS dependency, excluded from the Android build):

```swift
dependencies: [
    .package(url: "https://github.com/skiptools/skip.git", from: "1.0.0"),
    .package(url: "https://github.com/bitcoindevkit/bdk-swift.git", from: "2.3.0"),
],
targets: [
    .target(
        name: "WalletService",
        dependencies: [
            .product(name: "BitcoinDevKit", package: "bdk-swift",
                     condition: .when(platforms: [.iOS, .macOS]))
        ],
        plugins: [.plugin(name: "skipstone", package: "skip")]
    ),
]
```

Wrapper pattern (`WalletEngine.swift`):

```swift
#if !os(Android)
import BitcoinDevKit            // bdk-swift
#else
import org.bitcoindevkit.__     // bdk-android (Kotlin); note the `.__` wildcard
#endif

// Protocol so view models depend on the behavior, not the concrete engine.
// Enables a MockWalletEngine for fast Robolectric/both-platform unit tests (§11).
public protocol WalletEngineProtocol {
    func balance() throws -> Amount
    func nextReceiveAddress() throws -> AddressInfo
    func buildTx(to address: String, amount: Amount, feeRate: FeeRate) throws -> WalletTx
    // create/import, persist, sync, sign, broadcast, history …
}

public final class WalletEngine: WalletEngineProtocol {
    private let wallet: Wallet          // same type name on both sides
    // Keep each method body's two #if branches as thin as possible.
}
```

Do **not** try to run `bdk-swift` on Android — it's an Apple-only binary; the `#else` branch is exactly why `bdk-android` exists. And don't let the real `WalletEngine` run under Robolectric (see §11) — view-model tests use the mock.

---

## 5. Skip mode: Fuse shell, Lite `WalletService` (DECIDED 2026-06-11)

The app is a **mixed Fuse + Lite** project. The decision (was "Lite first"; reversed after scaffolding in Fuse):

- **App / UI / Model modules → Skip Fuse (`mode: 'native'`).** Native Swift compiled for Android via the Swift Android SDK. We get real Swift ergonomics for the SwiftUI + `@Observable` surface with none of the Lite transpilation-subset gotchas (silent integer overflow, `Double == Int`, `.sref()` value-semantics machinery). Cost: ~60 MB Swift runtime added to the APK (fixed, doesn't grow with app size) — confirm acceptable for the Play listing.
- **`WalletService` → Skip Lite (`mode: 'transpiled'`), in its OWN package.** Stays transpiled precisely so it can `import org.bitcoindevkit.__` (Kotlin `bdk-android`) **directly and type-checked** on Android, and `import BitcoinDevKit` (`bdk-swift`) on iOS. The alternative — calling `bdk-android` from native Fuse Swift via `AnyDynamicObject` — is stringly-typed, unchecked-at-compile-time dynamic dispatch, unacceptable for security-critical key/PSBT/signing code (§2). So the BDK seam is a transpiled island consumed by the native app.

**Mechanics of the mix (VERIFIED 2026-06-11 — builds a full debug APK + `WalletService-debug.aar` against `bdk-android:2.3.1`):**
- `WalletService` is a **standalone SwiftPM package at `Packages/WalletService/`** (a `.package(path:)` dependency), **not** a target in the app package. A Skip Fuse app is a single native module; a second *local* transpiled target gets an incomplete Gradle module (missing the `android-library` plugin + Skip runtime deps). Put transpiled code in its own package — the `SkipModel`/`SkipSQL` pattern.
- Its `skip.yml` is `mode: 'transpiled'` **WITH `bridging: true`** (CORRECTED 2026-06-12 — RUNTIME-VERIFIED). `bridging: true` is what makes the Fuse app's native-Swift `WalletManager()` calls FORWARD over JNI into this module's transpiled Kotlin (real `bdk-android`) at runtime. **Without it the Fuse app ran `WalletService` as native Swift on Android — which can't do BDK — so the `notImplemented` stub executed (the cause of the "This feature isn't available yet" error on create).** (An earlier note feared `bridging: true` triggers `missing required module 'CJNI'`; it does NOT in Skip 1.9.2.)
- **Bridging splits the module into two surfaces.** With `bridging: true`, Skip generates a `*_Bridge.swift` for every `public` declaration. So: **bridged surface (public, no directive) = `WalletManager` + the value types** (`Amount`/`FeeRate`/`WalletNetwork`/`ManagedWallet`/`AddressInfo`/`Utxo`/`WalletTx`/`WalletError`/`NetworkRegistry`/`NetworkParams`) — the app calls these. **BDK-seam engine layer = `public` + `// SKIP @nobridge`** (`WalletEngineProtocol`/`WalletEngine`, the factories, `BDKSeam`, `KeyStore`+impls, `WalletStore`+impls) — `public` so sibling files' Kotlin resolves them cross-file, `@nobridge` so no bridge is generated (their BDK-typed members never hit the bridge). `@nobridge` does NOT cascade to nested public types — module-only helpers (`Descriptors`, `BIP21`) stay plain `internal`. Full recipe + gotchas in Claude's memory (`walletservice-bdk-seam-setup`).
- The seam import gates the Kotlin import on **`SKIP`**, not `os(Android)`: `#if !os(Android) import BitcoinDevKit #elseif SKIP import org.bitcoindevkit.__`. A plain `#else` feeds the Kotlin import to native swiftc in the Android pass → "no such module". And wrap all BDK-touching code in `#if !SKIP_BRIDGE` (excludes it from the native-Android bridge pass).
- Public (bridged) API must use **bridge-safe types only** — no `Foundation.Date` ("does not appear to be a bridged type"); use epoch `Int64` (see `WalletTx.timestampEpochSeconds`). **And no `UInt32`/`UInt64` PROPERTIES on bridged types** (RUNTIME-VERIFIED 2026-06-12): Kotlin compiles unsigned types as inline value classes and mangles their property getters' JVM names (`getConfirmations-pVg5ArA`), so the generated `*_Bridge.swift` JNI lookup (`getMethodID("getConfirmations", "()I")!`) finds nothing → force-unwrap crash on first access from native Swift on Android (this was the Activity-tab crash). Use `Int32`/`Int64` in bridged property surfaces. Constructors with unsigned params are SAFE (the bridge uses Kotlin's unmangled synthetic `DefaultConstructorMarker` constructor), as are methods whose signatures avoid unsigned types (`Amount.formattedCoin()`). **The entire bridged surface is signed as of 2026-06-12** (`Amount.sats: Int64`, `FeeRate.satPerVByte: Int64`, `WalletTx.confirmations: Int32`/`feeSats: Int64?`, `Utxo.vout: Int32`, `AddressInfo.index: Int32`, `NetworkParams.coinType: Int32`) — verified on the emulator. Do NOT add unsigned properties to bridged types; convert to/from BDK's `UInt64`/`UInt32` at the `WalletEngine` boundary only.
- Unsigned literals need explicit casts (`UInt32(0)`, `UInt64(...)`) or Kotlin emits `Int` and the transpile fails ("expected UInt, actual Int").
- Verify the Android side with **`skip export --debug`** (builds the APK + AARs; first run pulls `bdk-android` from Maven). `swift build` only checks Apple + transpilation, not the Kotlin/Gradle/bridge compile. Create-wallet is runtime-verified on the Android emulator (real bdk-android descriptors, persists across restart) and iOS sim.

**Testing implication (supersedes the Robolectric framing in §11):** Fuse modules use `skip android test` (CLI) / `skip android test --apk`, not the Robolectric/`XCSkipTests` harness. The Robolectric BDK-seam gotcha in §11 still applies to the *transpiled* `WalletService` tests; the Fuse app/model/UI tests run via the Fuse runner. Keep the `WalletEngineProtocol` + mock so Fuse-side view-model tests never load real BDK.

The iOS app stays pure SwiftUI, so it's always ejectable. If Skip ever becomes a blocker, the iOS app survives untouched and Android falls back to a hand-written Compose front end over the same `WalletEngine` API.

---

## 6. BDK usage rules

- **Descriptors only.** Build wallets from output descriptors. Default account: **BIP84 native segwit (`wpkh`)** with **network-aware coin-type** — `m/84'/0'/0'` on mainnet, `m/84'/1'/0'` on every test network — external `…/0/*`, internal `…/1/*`. Templates live in `Descriptors.swift` and take a `WalletNetwork`.
- **Network is a switchable view, resolved via `NetworkRegistry`** (see §4 / `docs/wallet-and-network-model.md`). A wallet's selected network passes to BDK at construction (`check_network` enforced on load), but the user can switch among the testnet-class networks (Testnet4 / eCash-testnet / eCash-signet — shared coin-type `1'`, so one descriptor set serves all three). Each network has its own backend + isolated balance/history. **eCash mainnet** (coin-type `0'`) is a later, deliberate addition. Never hardcode a network outside the registry.
- **Backend per network.** Each `WalletNetwork` has a default backend in the registry. **Implemented (Settings → Network, v1 SHIPPED 2026-06-14):** user-selectable **Electrum or Esplora** custom endpoint per network + Test-connection probe, plus a global **SOCKS5/Tor** proxy; overrides persist in UserDefaults and evict cached engines on change. CBF/own-node and embedded Tor are v2. The BDK backend analysis (no bitcoind-RPC in the binding; Electrum/Esplora/CBF only) is in `docs/backends-and-endpoints.md`. Keep the client swappable; overrides are scoped per network.
- **Sync:** explicit, user-visible, **per wallet**. Show sync state (idle / syncing / error). Persist each wallet's BDK chain data locally (SQLite, namespaced by `walletId`) so cold start is fast. Switching the selected wallet shows that wallet's cached state immediately, then refreshes. **Scan model (LEARNED 2026-06-12):** full scan (gap limit 20) ONLY on a wallet's first-ever sync; every later sync uses `startSyncWithRevealedSpks` — a full scan's gap limit SKIPS funds at high revealed indices (>20 consecutive unused below them), which silently hid a real incoming tx. Relatedly, the Receive screen shows the next **unused** address (`nextUnusedAddress`) and only advances on an explicit "New address" tap — advancing per screen-open is what inflated the index space past the gap.
- **Transactions:** build via `TxBuilder` → `Psbt` → `sign` → `broadcast`. **RBF is signaled by default in BDK** — keep it on and reflect it in the UI.
- **Fees:** fetch fee estimates from the backend; offer slow/normal/fast. Never let the user send with a zero/placeholder fee.
- **Amounts:** store and compute in **satoshis (signed Int64 — Bitcoin Core's CAmount convention)** internally; the **unit label** for display comes from the wallet's network (BTC vs eCash). Format at the edge only. Never do float math on money. Never Swift `Int` (32-bit on Android/Kotlin), and never `UInt64` in the bridged surface (§5 — Kotlin inline-class mangling crashes the bridge); convert to BDK's `UInt64` at the engine boundary.

---

## 7. Security model

- **Mnemonic generation:** BDK / its `Mnemonic` type. 12 or 24 words (default 12; offer 24).
- **Storage:** each wallet's mnemonic (and only the mnemonic) is written to **SkipKeychain**, keyed by `walletId` → iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud sync) / Android Keystore-backed `EncryptedSharedPreferences` or equivalent. Derive xprv/descriptors at runtime; never persist private descriptors. Removing a wallet deletes its Keychain entry plus all its stored data (the JSON `FileWalletStore` metadata and BDK's per-wallet chain-data store).
- **At rest (on disk):** only public data — xpub-based (watch) descriptors + wallet-list metadata in the JSON `FileWalletStore`; tx/UTXO/chain cache in BDK's own per-wallet store; labels/settings as app metadata. No private keys on disk.
- **At runtime — watch-only + sign-on-demand (IMPLEMENTED 2026-06-13, `docs/key-storage.md §3`):** the everyday `WalletEngine` is built from the **public** descriptors only — balance, address derivation, sync, and PSBT *building* all run watch-only, and the Keychain is never read for any of them. Signing is the **only** path that touches the mnemonic: `BDKWalletEngineFactory` hands the engine a `signPsbt` closure that, at send time only, loads the mnemonic, builds a **transient in-memory private-descriptor `Wallet`** (`Persister.newInMemory()`), signs the watch-only-built PSBT (BDK re-derives keys from the PSBT's BIP32 paths), and drops it. This shrinks the private key's in-memory window to a single signing operation. Never widen it — keep balance/sync/build on the watch-only engine.
- **Backup flow:** reveal seed behind an explicit "I understand" gate; require the user to re-enter / confirm a subset of words before marking backed-up. Block screenshots on the reveal screen where the platform allows (`FLAG_SECURE` on Android; obscure on iOS backgrounding).
- **No telemetry of secrets.** Scrub all error paths. A signing error reports "signing failed," never the offending key/descriptor.
- **App lock (IMPLEMENTED):** biometric/passcode gate on launch + foreground resume via `AppLockModel` → `LockScreen` root gate, with a Settings **"Require unlock"** toggle (default ON). The **Confirm-send** step is independently gated on the same `DeviceAuth` path (`SendViewModel.authorize` seam), honoring the same toggle. On devices with no credential enrolled, `DeviceAuth` passes through rather than locking the user out. Pairs with watch-only sign-on-demand above — auth and the one-shot key load happen together at send.
  - **Background grace + privacy cover:** the foreground gate has a configurable **Auto-lock** grace (Settings; default 10s) — `RootView` stamps `markBackgrounded()` on `.background` and `applyForegroundLock()` on `.active`, re-locking only past the grace (a quick hop out skips re-auth). `PrivacyCover` (logo on `bg0`) is raised on `.inactive`/`.background` so the app-switcher snapshot never shows balances — rendered **conditionally** (an always-present opacity-0 overlay swallows all touches on Compose), instant out, faded back.

---

## 8. Design system (eCash)

### Canonical visual spec: `DESIGN.md`

**`DESIGN.md`** (repo root) is the as-built, **Skip-safe** visual spec — token system, type scale, spacing/radius/motion, the real domain components/screens, and voice & copy. It was revised 2026-06-14 to match the implementation: SwiftUI-native asset-catalog colors (no UIKit), Material Symbols `.symbolset` (no SF Symbols), the **two-font** system (Space Grotesk + JetBrains Mono — IBM Plex dropped), real amber `accent`, every network chipped (Bitcoin orange), and stock chrome (no iOS-26 glass). Use `Theme.*` tokens — never hard-code colors, fonts, or spacing. On any platform-mechanics conflict, **this file (CLAUDE.md) still wins.**

---

Source of truth is **ecash.com**: dark-first, monospace-driven. **Type system (decided):** Space Grotesk (display/headings) + JetBrains Mono (body/labels/mono). (Confirm the exact ecash.com font someday.)

Tokens live as a single semantic palette in `DesignSystem/Theme.swift`, backed by an asset catalog with **Any (light) + Dark** appearances; Skip maps these to a Compose `ColorScheme`. Never use raw hex in views — only semantic tokens.

### Brand assets

- **Logo:** `ecash-logo.svg` (source: `https://ecash.com/ecash-logo.svg`), vendored as a PNG imageset at `Sources/ECashWalletMobile/Resources/Module.xcassets/logo.imageset` and rendered via the `Logo` component (resolves per platform). Brand mark for the splash/lock screens, the home header, onboarding, and the source art for the app icon.
- **Cross-platform SVG note:** SwiftUI/Xcode renders SVG via an asset catalog image set with **Preserve Vector Data** on. Compose does **not** consume SVG directly — convert the logo to an Android **vector drawable** (`ic_logo.xml`) for the Android build, or render through a Skip-supported image path. Keep a single `Logo` view in `EcashWalletUI` that resolves the correct asset per platform so call sites stay clean.
- Provide light- and dark-appropriate logo variants if the mark isn't legible on both `bg0` values (check once the real logo + palette are in).
- The logo's own fill color(s) are a likely source for the brand **accent** token — derive `accent` from the SVG once it's vendored (see §8 token table).

### ⚠️ Exact values: VERIFY against ecash.com

The hex values below are a **faithful placeholder palette**, not scraped from the live site (ecash.com renders CSS client-side and blocks automated fetch). Replace them with the real tokens. To dump the real ones, paste this in the ecash.com browser console and share the output:

```js
const out = {};
for (const ss of document.styleSheets) {
  let rules; try { rules = ss.cssRules } catch { continue }
  for (const r of rules) {
    if (!r.style || !r.selectorText) continue;
    if (r.selectorText === ':root' || /data-theme|\.dark|\.light/.test(r.selectorText)) {
      for (const p of r.style) if (p.startsWith('--')) out[`${r.selectorText} ${p}`] = r.style.getPropertyValue(p).trim();
    }
  }
}
console.log(JSON.stringify(out, null, 2));
```

### Token table (semantic → placeholder hex)

| Token | Role | Dark (placeholder) | Light (placeholder) |
|---|---|---|---|
| `bg0` | App background (base) | `#0B0D0E` | `#FFFFFF` |
| `bg1` | Elevated surface | `#141719` | `#F4F5F6` |
| `bg2` | Card / input | `#1C2023` | `#EAECEE` |
| `border` | Hairlines, dividers | `#2A2F33` | `#D7DBDF` |
| `text0` | Primary text | `#EDEFF1` | `#0B0D0E` |
| `text1` | Secondary / muted | `#9BA3A9` | `#5B636A` |
| `text2` | Faint / placeholder | `#5C656B` | `#9BA3A9` |
| `accent` | Brand / primary action | `#E8A84A` (rgb 232,168,74) | `#E8A84A` |
| `accentText` | Text on accent | `#0B0D0E` | `#0B0D0E` |
| `positive` | Received / confirmed | `#3FB67E` | `#1F8F5F` |
| `negative` | Sent / error / destructive | `#E5484D` | `#CE2C31` |
| `warning` | Caution / unconfirmed | `#E2A03F` | `#B7791F` |
| `netTestnet` | Testnet badge bg (high-contrast, NOT brand color) | `#7A4DFF` | `#6A3DF0` |
| `netTestnetText` | Text on testnet badge | `#FFFFFF` | `#FFFFFF` |

> **Every** wallet shows a network chip with the network name, colored per network via `NetworkChipStyle` (a code-level, non-user-facing config): **Bitcoin mainnet** = `netMainnet` (Bitcoin orange `#F7931A`), testnets = `netTestnet` (violet). Each network is its own knob; pick colors impossible to confuse with `accent`, `positive`, or `negative`.

> `accent` is the real eCash brand amber **`#E8A84A` (rgb 232,168,74)**, provided by Jake 2026-06-13 (colorsets written as float components — the Skip-safe form). `accentTint` = same hue at 12% alpha; `accentHover` = a darker shade (light) / lighter shade (dark). The other surface/text tokens are still the placeholder palette pending the full ecash.com token dump (§14 #1).

### Typography

- Family: **JetBrains Mono** (bundle the variable font; ship weights 400/500/700). Set as the default font for the whole app so it cascades.
- Scale (suggested): Display 28/600, Title 20/600, Body 15/400, Caption 13/400, Mono-numeric for all amounts & addresses (already mono, but tabular figures for balances).
- Addresses, txids, amounts: always monospaced with tabular figures; truncate addresses middle-ellipsis (`bc1q…k4f2`) with tap-to-copy.

### Spacing & shape

- 4-pt base grid (4/8/12/16/24/32). Corner radius 12 for cards, 8 for inputs/buttons. Generous touch targets (44pt min).
- Honor safe areas; respect Dynamic Type / font scaling.

### Icons (hard rule)

**Never use `Image(systemName:)` / SF Symbols** — they don't transpile to Android. Use the Material Symbols **`.symbolset`** workflow (per the `skip-icons` skill): add the symbol set to the asset catalog and reference it the Skip-supported way so the same icon renders as SF-style on iOS and Material on Android. Pick a consistent icon vocabulary (send, receive, scan, settings, copy, back) up front and keep it in one place.

### Multi-wallet & network UI

The app is wallet-centric: there is always a **selected wallet**, and the UI is its context. Design these in from the start (Golden Rules §4–6):

- **Wallet switcher** in the home header — shows the selected wallet's name + its network badge; tapping opens the wallet list. Switching is one tap and immediately re-roots home to the new wallet's balance/history (cached first, then sync).
- **Wallet list / manager** — all wallets with name, network badge, and balance; actions to **add**, **import**, **rename**, **remove** (with backup warning + typed/confirmed gate), and reorder. "Add wallet" and "Import wallet" both require choosing a **network** up front.
- **Network chip everywhere it matters** — home, send review, receive, history, and the switcher. Every wallet carries a persistent chip in its network's color (testnets violet, Bitcoin mainnet orange — `NetworkChipStyle`). This is a safety feature, not decoration (§6).
- **Send review must state the network** alongside recipient/amount/fee; for a mainnet send, the confirm affordance should feel weightier than a testnet one.
- **Receive screens** show the network so a user can't hand out a testnet address expecting mainnet funds (or vice-versa).
- **Address & unit formatting are network-derived** — address HRP (`bc1`/`tb1`/eCash HRP TBD) and the unit label (BTC vs eCash) come from the wallet's network, never hardcoded.
- **Empty state:** first launch has no wallets → a focused create/import screen, not an empty home.

---

## 9. Feature specs (v1)

Keep each screen thin: view → view model → `WalletManager` / `WalletEngine`. View models are platform-agnostic and unit-tested. Every screen operates on the **selected wallet** unless it's the wallet manager itself.

**Wallet manager** — list of all wallets (name, network badge, balance). Actions: add, import, rename, remove, reorder, select. **Remove** requires a confirmation gate that warns if `!isBackedUp` ("you will lose access unless backed up"), then purges the wallet's Keychain entry + all its stored data (JSON metadata + BDK chain store). Selecting a wallet re-roots the app to it.

**Create wallet** — **pick network** (`NetworkSelector`, defaults to **L2L Signet**, never auto-mainnet; picking Bitcoin swaps the testnet chip for a real-money warning): generate mnemonic (BDK), persist to secure store keyed by `walletId`, build the network-aware BIP84 descriptors (coin-type `1'` testnet / `0'` mainnet), create, and route to Home as the newly selected wallet (first sync happens on Home). Non-blocking "back up now" nudge + persistent "not backed up" banner until Backup completes.

**Import wallet** — accept 12/24-word mnemonic (and, later, descriptor strings) + the same `NetworkSelector` (defaults to L2L Signet). Validate checksum via BDK before proceeding. Same per-`walletId` persistence as create. Reject invalid input with a clear, non-leaky message.

**Backup wallet** — gated reveal of the selected wallet's mnemonic (biometric/passcode), screenshot-blocked, followed by a verify step (confirm N random words). Mark `isBackedUp` for that wallet on success; clear its banner.

**Home** — selected wallet's balance (unit per network), network badge, sync state, send/receive actions, recent history. Wallet switcher in the header.

**Receive** — derive next unused external address from the selected wallet's BDK, render QR (SkipQRCode), show address mono with copy + share, **with the network shown**. Optional amount → BIP21 URI. Advance on demand.

**Send** — scan/paste address (parse BIP21), enter amount (with max), pick fee tier, review screen (**network** + recipient, amount, fee, total), confirm → `TxBuilder`→`Psbt`→`sign`→`broadcast`. Handle insufficient-funds, dust, and broadcast errors explicitly. Optimistically insert the tx into the selected wallet's history as pending.

**Transaction history** — selected wallet's txs (BDK + local cache), newest first, sent/received styling, confirmations, amount, timestamp. Detail: txid (copy + open in that network's explorer), in/out summary, fee, confirmations, RBF state. Pull-to-refresh syncs.

**Settings** — global (theme system/light/dark, fiat display currency, app-lock) + **per-network backend endpoints** (override the registry default per network) + per-wallet info (label, network, backup status). About/version. **Open-source licenses** (About → `LicensesScreen`): a GPL app shipping third-party code, so attributions are mandatory — edit the single source `OpenSourceLicense.all` (`App/OpenSourceLicense.swift`), mirrored in the README table. (Release TODO: bundle full license texts; MIT/Apache/OFL need the notice, not just a link.)

---

## 10. Conventions

- **Error handling:** typed errors out of `WalletService` (`enum WalletError`); never throw raw BDK errors to the UI. View models map them to user strings.
- **Concurrency:** all BDK sync/broadcast off the main actor; UI updates on main. Wallet ops are serialized (one writer).
- **Money:** `Amount` value type wrapping `Int64` sats (signed, CAmount-style — see §5/§6 for why not UInt64); formatting helpers only at the view layer; support sats and eCash-unit display.
- **No force-unwraps** on anything network/BDK-derived.
- **Naming:** `EcashWallet*` for app modules; types read in plain Bitcoin terms (`Utxo`, `WalletTx`, `FeeRate`). No cute codenames in shipping code.
- **Sheet chrome:** sheets that keep a nav bar use `CloseToolbarButton` (system X) / `ConfirmToolbarButton` (system checkmark) from `Components/ToolbarButtons.swift` — never spelled-out "Cancel"/"Done". **Read-only/simple sheets (Receive, tx detail) drop the nav bar entirely** and rely on swipe-to-dismiss — a `NavigationStack` toolbar renders a grey Material top app bar on Android that tints on scroll.
- **Text inputs:** `.textFieldStyle(.plain)` + `fieldBoxInset()` (`DesignSystem/PlatformChrome.swift`) over a `Theme` box — `.plain` kills SkipUI's Material `OutlinedTextField` border on Android; applies to `TextEditor` too.
- **Localization (`skip-localization`):** author every user-facing string at a `bundle: .module` site (extracts to `Resources/Localizable.xcstrings`). Forms: `Text("…", bundle: .module, comment:)` for rendered text; a `LocalizedStringKey` param rendered via `Text(key, bundle: .module)` for component labels; `Text(verbatim:)` for non-translatable data (amounts/addresses/txids). **Never `String(localized:bundle:comment:)`** — it doesn't compile in the Fuse native-Android pass. Full rules + the date/count deferral: memory `fuse-localization-no-string-localized`.
- **Tests:** the important parts are covered — see §11. Treat WalletService logic and view models as must-cover; write tests in the same PR as the code.

---

## 11. Testing

Testing is a first-class requirement here — this is a wallet; bugs lose money. Use **Skip's parity testing** (the `skip-testing-deployment` skill) so one Swift test suite verifies both platforms.

### How Skip testing works (Lite)

Write tests in **XCTest** (or the supported subset of **Swift Testing**). In Lite mode Skip transpiles them to **JUnit** and runs them through Gradle. Running the test suite against the **macOS** destination (Xcode) or `swift test` on the CLI triggers transpilation + the Gradle run and reports JUnit results back as XCTest outcomes — **one run, both platforms**. Skip auto-generates the `XCSkipTests.swift` harness; don't hand-maintain it unless you need a custom Gradle/device target.

- **Fast loop (default):** `swift test` runs the transpiled JUnit locally on the host JVM via **Robolectric**. No emulator. Use this for everything that doesn't touch real BDK.
- **High fidelity:** `ANDROID_SERIAL=emulator-5554 swift test` runs the same tests as **instrumented** tests on a real emulator/device (needed for anything that loads BDK's native `.so`).
- iOS: run the suite on a simulator via Xcode as usual.

### The BDK-seam testing gotcha (read this)

Under Robolectric, **`#if os(Android)` is `false`** (it's the host JVM), so our `WalletEngine` wrapper's `#if !os(Android)` branch would take the **iOS path and try to load `bdk-swift` (an Apple-only binary) on the JVM** — which fails. Two consequences:

1. **Put `WalletEngine` behind a protocol** (`WalletEngineProtocol`). Unit-test all view models and pure logic against a **mock** engine — these run fast under Robolectric on both transpiled paths and never cross the BDK seam.
2. **Exercise real BDK only in integration tests** that run on a real runtime: iOS simulator (`bdk-swift` works on Apple) and Android **instrumented** emulator (`bdk-android` `.so` loads). Where Robolectric must take an Android-like path, Skip defines the `ROBOLECTRIC` symbol — use `#if os(Android) || ROBOLECTRIC` if needed.

### What to test (the important parts)

**Pure / fast (mock engine, Robolectric — both platforms):**

- **Amount math:** sats `UInt64` arithmetic, sat↔eCash-unit formatting round-trips, no float drift, max-spend calculation.
- **BIP21 parsing:** address-only, amount, label, malformed URIs, casing.
- **Descriptor templates:** BIP84 derivation-path strings are exactly correct **per network** — coin-type `0'` on mainnet, `1'` on Testnet4/signet/regtest (assert against fixed vectors).
- **NetworkRegistry:** each `WalletNetwork` resolves to the right coin-type, address HRP, unit label, and default endpoint; mainnet vs testnet never collide.
- **Error mapping:** every `BDK error → WalletError → user string` path, with an explicit assertion that **no secret material** (mnemonic, xprv, descriptor-with-keys) appears in any message.
- **View-model state machines:** send flow (idle→entering→reviewing→broadcasting→done/error), sync states, backup-verify logic, **wallet switching** (selected-wallet changes re-root state) — driven through the mock engine.

**Integration (real BDK, iOS sim + Android emulator):**

- **Address derivation vectors per network:** known test mnemonic → known first external/change addresses on **mainnet and Testnet4** (different addresses; assert they don't match).
- **Mnemonic validation:** valid vs. bad-checksum inputs via BDK.
- **`check_network` enforcement:** loading a wallet against the wrong network fails as expected.
- **Multi-wallet isolation:** two wallets on different networks coexist; balances/addresses/UTXOs never leak across them; **remove purges** the removed wallet's Keychain entry + JSON metadata + BDK chain store and leaves the other intact.
- **Transaction building** against signet/regtest: correct inputs/outputs/change, fee applied, **RBF signaled**, plus failure cases — insufficient funds, dust, no-UTXO.
- **Persistence round-trip:** create N wallets → persist (BDK chain store + JSON `FileWalletStore` + Keychain, namespaced by `walletId`) → cold-load → each wallet's balance/addresses/network intact.

UI-level flows come later via **`skip-ui-automation`** (`skip app launch` + Maestro across both platforms); not required for the v1 logic milestone but wire up at least one smoke flow (create → receive → see address) before release.

### Bar

- No PR touching `WalletService` or a view model merges without tests in the same PR.
- `swift test` (Robolectric) green is the minimum gate; the real-BDK integration suite must pass on an iOS simulator **and** an Android emulator before any release build.
- Performance checks run on a **Release** build on-device (Debug Android performance is misleading).

---

## 12. Future (design for, don't build)

- **BIP300/301 deposits & withdrawals** — the actual eCash differentiator. Plan to implement deposit/withdrawal transaction construction **once in Rust** (extend `bdk-ffi` or a sibling crate) and regenerate Swift + Kotlin bindings together, so the consensus-sensitive code isn't duplicated. Confirm the exact deposit/withdrawal tx format against L2L's sidechain spec before designing the UI.
- Multisig (BDK supports it via descriptors), watch-only, PSBT import/export, sidechain selector UI, address labeling/coin control, fiat rates.
- **Plausible deniability** — BIP39-passphrase hidden wallets (proposed; BDK's `DescriptorSecretKey(…password:)` already supports it). Design + threat model + invariant in `docs/plausible-deniability.md`.

---

## 13. Build & run

```bash
# iOS: open in Xcode, run the Darwin app target.
# Android: Skip generates the Gradle project; run from Android Studio or:
skip android run        # confirm against current Skip CLI

# Tests (see §11):
swift test                              # fast: transpiled JUnit on host JVM via Robolectric (both platforms)
ANDROID_SERIAL=emulator-5554 swift test # instrumented on a real emulator (needed for real-BDK tests)
# Verify the BDK seam on BOTH a sim and an emulator before merging anything touching WalletService.
```

**Definition of done for any WalletService / view-model change:** tests written in the same PR; `swift test` (Robolectric) green; and for anything crossing the BDK seam, the real-BDK integration suite passes on an iOS simulator *and* an Android emulator against a test network (Testnet4 / regtest, and L2L signet once eCash params land).

---

## 14. Open items to confirm

1. Brand **accent** — ✅ DONE (2026-06-13): real eCash amber `#E8A84A` (rgb 232,168,74) wired into `accent`/`accentTint`/`accentHover` colorsets. STILL PENDING: the rest of the ecash.com surface/text tokens (the `bg*`/`text*` families are still placeholders) and confirming the `netTestnet` badge color.
2. Vendor `ecash-logo.svg` into the repo and produce the Android vector-drawable variant (see §8 Brand assets).
3. **Type system — ✅ DONE:** two fonts, **Space Grotesk** (display/headings) + **JetBrains Mono** (body/labels/mono); IBM Plex dropped. CLAUDE.md + `DESIGN.md` agree. (Still confirm the actual ecash.com font someday.)
4. **Skip-safe `DESIGN.md` revision — ✅ DONE (2026-06-14):** rewritten to the as-built system (SwiftUI-native colors, Material Symbols, two fonts, real amber accent, every-network-chipped, stock chrome).
5. Default backends **per network** for `NetworkRegistry`: Testnet4 Electrum/Esplora endpoint, Bitcoin mainnet endpoint, and L2L signet / eCash endpoints for the fork.
6. **eCash network representation in BDK** — eCash is a separate chain with no rust-bitcoin `Network` variant. Decide how to model `.ecashMainnet` / `.ecashTestnet`: custom rust-bitcoin `Params`, or a forked `bdk-ffi` binding. Blocks the eCash entries in `NetworkRegistry`. (Testnet4 + Bitcoin mainnet are already first-class in BDK — no action.)
7. eCash chain params themselves (address HRP / network magic / unit naming) once the fork spec finalizes.
8. Min OS floors **resolved (2026-06)**: **iOS 26** (`.iOS("26.0")` + `IPHONEOS_DEPLOYMENT_TARGET=26.0`; ≈75–86% of active iPhones depending on measure, climbing — chosen to commit to the DESIGN.md iOS-26 design) and **Android API 28** (Skip Fuse floor, emitted `minSdkVersion=28`, ≈93.5% reach). macOS host stays `.v14`. Note: `.v26` is unavailable at `swift-tools-version: 6.1`, so the manifest uses the string form `.iOS("26.0")`.
