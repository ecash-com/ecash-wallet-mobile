# PLAN.md — eCash.com Wallet build plan

> The step-by-step plan for building **eCash.com Wallet** (v1). Complements `CLAUDE.md`
> (the architecture bible) and `DESIGN.md` (visual spec). When this plan and CLAUDE.md
> disagree on *what* to build, CLAUDE.md wins; this file owns *order* and *tracking*.
>
> Check items off as they land. Keep it current in the same PR as the work.

---

## How we're building it (decisions — do not relitigate)

- **Sequencing:** foundation first, then **vertical feature slices** — each slice goes
  engine → view model → UI → tests, end-to-end, so there's a runnable wallet early and we
  integrate continuously.
- **Network focus:** develop and test on the testnet-class networks — day-to-day on **Signet**
  (live wallets, real broadcasts), plus **Testnet4** and **regtest**. Mainnet code paths are
  built from day one (per CLAUDE.md §4) but exercised last. **L2L runs two eCash networks
  today** — those become `NetworkRegistry` entries later (§14 #6/#7); they don't block v1.
- **Backend:** **Electrum** is the default client adapter, kept swappable (Electrum/Esplora)
  and overridable per network in Settings (§6).
- **Architecture (verified):** Fuse app (single native module `ECashWalletMobile`) +
  `WalletService` as a **separate transpiled package** at `Packages/WalletService/`
  (the BDK seam). See CLAUDE.md §5 and memory `walletservice-bdk-seam-setup`.

## Guardrails that apply to every step

- **Golden Rules (CLAUDE.md §2)** are non-negotiable — BDK owns all key/consensus logic;
  seeds never leave the secure store or get logged; a wallet is a seed and network is a
  switchable view resolved via `NetworkRegistry` (`docs/wallet-and-network-model.md`); wallets
  are isolated; testnet is unmistakable; no broadcast without
  explicit confirmation; fail loud in dev, fail safe in prod.
- **Testing bar (CLAUDE.md §11/§13):** no PR touching `WalletService` or a view model merges
  without tests in the same PR. `swift build` checks Apple + transpilation; **`skip export
  --debug`** is the real Android check; real-BDK integration runs on an iOS sim **and** an
  Android emulator before release.
- **`WalletService` public API must be bridge-safe** — no `Foundation.Date` (use epoch
  `Int64`), and **no `UInt32`/`UInt64` properties on bridged types** (Kotlin inline-class
  getter mangling crashes the JNI bridge — the whole bridged surface is signed `Int32`/`Int64`
  as of 2026-06-12; convert to/from BDK's unsigned types at the engine boundary only). Explicit
  unsigned-literal casts still apply to module-internal transpiled code; Kotlin import gated on
  `#elseif SKIP`. See CLAUDE.md §5 and memory `bridged-surface-signed-types-only`.

## Definition of done for a vertical slice

1. `WalletService` engine method(s) implemented + unit tested (mock-free pure logic) and,
   where they touch BDK, integration-tested on sim + emulator.
2. View model implemented, platform-agnostic, tested against `MockWalletEngine`.
3. SwiftUI screen built on the design system (`Theme.*` tokens, Material Symbols, NetworkBadge).
4. `swift test` green (both platforms via transpilation); `skip export --debug` builds.
5. Network badge / network shown on every money-touching surface in the slice (§2.6).

---

## Current state (done)

- [x] Skip Fuse app scaffolded (`ECashWalletMobile`), builds on iOS + Android.
- [x] `WalletService` as a standalone transpiled package (`bridging: true`); builds APK + AAR
      against `bdk-android:2.3.1`; `bdk-swift` linked on Apple. Real engine running on both
      platforms (no stubs).
- [x] `WalletService` surface: `Amount`, `FeeRate`, `WalletNetwork`, `ManagedWallet`,
      `AddressInfo`, `Utxo`, `WalletTx`, `BIP21`, `AmountEntry`, `NetworkRegistry`,
      `Descriptors`, `WalletError`, `WalletManager` + engine layer behind `@nobridge`.
- [x] Decision + setup recorded in CLAUDE.md §5 and memory.

---

## Milestone 0 — Hygiene, design system, app shell, assets

Goal: a styled, navigable, empty app with the design system in place. No wallet logic yet.

**`Theme` is step 0 — it lands before everything else here, and before any screen anywhere.**

- [x] **`Theme` — the single source of truth (FIRST TASK, before screens).** One
      `enum Theme` namespace (caseless — pure static tokens, can't be instantiated) holding
      **all** colors, text styles, spacing, radius, and motion as semantic tokens. Every view
      references `Theme.*` — **no raw hex, font names, or magic numbers anywhere in the
      codebase.** Consistency is structural, not retrofitted.
  - [x] **Colors — light AND dark, both defined up front.** `Theme.Color.*` semantic palette
        (CLAUDE.md §8 table) resolving to an asset catalog where **every** color set has an
        **Any Appearance (light)** value and a **Dark** value. SwiftUI-native adaptive color
        (NO UIKit); Skip maps the catalog to a Compose `ColorScheme`. Views never branch on
        appearance — tokens adapt automatically. Placeholder hex until Jake provides real
        tokens (§14 #1).
  - [x] **Appearance override** — Settings toggle (System / Light / Dark) applies
        `.preferredColorScheme(...)` at the root (reuse the scaffold's `@AppStorage`), so the
        user can force a mode independent of the OS. (Tie-in with Settings slice §7.)
  - [x] **Type styles** — bundle JetBrains Mono (400/500/700); register the font; expose named
        `Theme` text styles (Display/Title/Body/Caption/Mono-numeric) with tabular figures for
        amounts/addresses — not ad-hoc `.font(...)` at call sites. (Type-system §14 #3.)
        *Needs the font files from Jake.*
  - [x] **Spacing / radius / motion** — 4-pt grid tokens, card/input radii, standard
        animations (§8) — also on `Theme`, used everywhere.
- [x] Remove the template demo (items/todo `ViewModel`, `ContentView` sample screens,
      `PlatformHeartView`, welcome demo).
- [x] **Icons** — create `Icons.xcassets` with Material Symbols `.symbolset` for the core
      vocabulary (send, receive, scan, settings, copy, back, add, more). Render via
      `Image("name", bundle: .module)` inside `Label { Text } icon: { Image }`. NEVER
      `Image(systemName:)`. (skip-icons)
- [x] **Logo** — vendor `ecash-logo.svg` into `Sources/ECashWalletMobile/Resources/`
      (asset catalog image set; PNG set to start, or SVG+vector-drawable per §8). One `Logo`
      view that resolves per platform. Derive the brand `accent` token from the logo (§14 #1).
- [x] **App shell** — navigation root + tab/stack scaffold using **stock SwiftUI chrome**
      (`TabView`, `NavigationStack`, `List(.insetGrouped)`, `.sheet`, system buttons) so it
      renders as native SwiftUI on iOS and native Compose/Material on Android. **Native-first:
      iOS should feel Apple-designed, Android Android-designed** — brand only via
      `.tint(accent)` + `Theme` fonts/colors + the domain views; never hand-roll chrome.
      Confirm each element is in Skip's supported subset (§8). `AppState` skeleton (no real data).
- [x] **First-launch empty state** — when there are no wallets, route to a focused
      create/import screen, not an empty home (§8).
- [x] **`NetworkBadge`** component (violet `netTestnet` chip; mainnet unmarked) — built now,
      used everywhere later (§2.6, §8).

Tests: token resolution / `Amount` formatting helpers (see M1). Exit: app launches on both
platforms showing the styled empty state; `skip export --debug` builds.

---

## Milestone 1 — WalletService foundation (pure, fully tested)

Goal: all non-BDK-runtime logic done and tested fast on both platforms; storage/manager
skeletons + mock engine ready for view models.

- [x] **Amount** math + sat↔coin formatting round-trips, max-spend calc (no float math).
- [x] **BIP21** parsing (address-only, amount, label, malformed, casing).
- [x] **Descriptors** — BIP84 path strings exact per network (coin-type 0'/1'); `wpkh` templates.
- [x] **NetworkRegistry** — each `WalletNetwork` → coin-type, HRP, unit, Electrum endpoint,
      explorer; mainnet vs testnet never collide. Electrum default; client swappable.
- [x] **WalletError** mapping scaffold + assertion that **no secret material** appears in any
      message.
- [x] **WalletEngineProtocol** finalized + **`MockWalletEngine`** (deterministic fixtures).
- [x] Add frameworks: **SkipKeychain** (KeyStore) to the `WalletService` package; **SkipQRCode**
      to the app (used in M-slices). *(No SkipSQL — BDK owns its chain store; WalletStore is JSON.)*
- [x] **KeyStore** (SkipKeychain) — per-`walletId` mnemonic CRUD + delete. API only here;
      real device storage validated in M2 integration.
- [x] **WalletStore** — JSON `FileWalletStore` for the PUBLIC wallet-list metadata (label, network,
      xpub descriptors), keyed by `walletId`; CRUD + **purge**. (BDK owns chain data via its own
      per-wallet SQLite — no SkipSQL.)
- [x] **WalletManager** — ordered `ManagedWallet` list + selected wallet; add/import/rename/
      remove/reorder/select; vends a `WalletEngine` per wallet. (Backed by mock until M2.)

Tests (fast, both platforms via `swift test`): amount math, BIP21, descriptor vectors per
network, NetworkRegistry resolution, error-no-leak, WalletManager selection/CRUD against mock.
Exit: `swift test` green; `skip export --debug` builds.

---

## Milestone 2 — Real BDK engine core (Testnet4 + regtest)

Goal: `WalletEngine` real bodies wired to BDK; multi-wallet isolation + persistence proven on
device/emulator. This is the consensus-critical milestone — integration tests are mandatory.

Engine bodies (`BDKWalletEngineFactory` + `WalletEngine`, the BDK seam) — all written; compile
on Apple (bdk-swift) **and** transpile→compile to Kotlin (bdk-android) **and** survive the Fuse
app's native-Android bridge pass. The bdk-swift⇄bdk-android binding divergences (SCREAMING_SNAKE
enums, `ChainPosition` sealed class, `List`/`Array`, the `SKIP_BRIDGE` no-BDK pass) are absorbed
in the seam — see CLAUDE.md notes + the `bdk-swift-2.3.1-api-map` / `walletservice-bdk-seam`
memories.

- [x] **create** — generate `Mnemonic` (12/24) → network-aware public BIP84 descriptors. Host-tested.
- [x] **import (restore)** — validate mnemonic checksum via BDK; `.invalidMnemonic` on bad input
      (no leak). Host-tested (valid + invalid + determinism + mnemonic round-trip).
- [x] **persistence** — BDK chain data per `walletId` via `Persister.newSqlite`; load-vs-create
      branch; cold-reload continues the persisted reveal index. Host-tested (round-trip).
- [x] **balance** + **address derivation** (next unused external; advance on demand; persists).
      Host-tested via the persistence round-trip + derivation vectors.
- [x] **transactions()** — `CanonicalTx` → `WalletTx` (epoch `Int64`, RBF flag, confirmations
      from chain tip). Compiles both platforms; empty-wallet path host-tested. *(Populated-history
      assertions need a funded/synced wallet — device.)*
- [x] **derivation vectors** — mainnet matches the **published BIP84 spec vectors**; testnet4 pinned
      (coin-type 1', `tb1`); mainnet ≠ testnet4; descriptors carry the right coin-type; no xprv/tprv
      in stored (public) descriptors. Host-tested (`BDKWalletEngineTests`, 9 tests, host-only).
- [x] **check_network** — a testnet4 wallet rejects a mainnet address before any network I/O
      (`.invalidAddress`). Host-tested.
- [x] **sync** — Electrum, off the main actor: **full scan ONLY on a wallet's first sync**
      (genesis checkpoint), **`startSyncWithRevealedSpks` on every later sync** — a full scan's
      gap limit (20 consecutive unused) silently misses funds at high revealed indices (it hid a
      real confirmed incoming tx, 2026-06-12; fixed + verified). User-visible idle/syncing/error
      state on Home. Default endpoint `ssl://mempool.space:40002`; per-network backend override
      threads through the factory (`engine(…, backendKind:backendURL:backendProxy:…)`), Electrum or
      Esplora. VERIFIED live on Signet on both platforms.
- [x] **send** — `TxBuilder`→`Psbt`→`sign`→`broadcast`; RBF signaled by BDK default; address
      validated per network. Host-tested error paths (`.invalidAddress`, `.insufficientFunds`
      via real `CreateTxError`). **VERIFIED with REAL funded-wallet Signet broadcasts in both
      directions (Android↔iOS), mined + reconciled to the satoshi (2026-06-12).** Fee tiers
      (slow/normal/fast) in the Send VM (fixed rates; live estimates TODO).
- [x] **BDK-typed-error → WalletError mapping** — token-based on BDK's UniFFI variant names
      (`InsufficientFunds`/`OutputBelowDustLimit`/`NoUtxosSelected`/`AllAttemptsErrored`/…), identical
      across bdk-swift & bdk-android so no `#if SKIP`; context-known callers (sync/broadcast/sign)
      throw directly. Secret-scrub guaranteed + host/both-platform tested.

Runtime verification: the real engine is exercised end-to-end ON the Android emulator and iOS
sim through the app itself (create, receive, sync, send/broadcast on live Signet — all
confirmed working 2026-06-12). Still TODO as *automated* suites: the instrumented
Android-emulator run of the real-BDK tests (`ANDROID_SERIAL=… swift test`), multi-wallet
isolation + remove-purges with real BDK, and regtest tx-building cases. Two engine fixes worth
noting landed alongside: the persisted PUBLIC descriptors were master-level tpubs (now built
from the same `newBip84` construction as the runtime — regression-tested in
`WalletKeysDescriptorTests`), and `nextUnusedAddress` joined the engine surface (Receive shows
it; only "New address" advances the reveal index).

---

## Vertical feature slices (each = engine + VM + UI + tests; see "Definition of done")

> Order is dependency-driven. Build the manager-first multi-wallet model from the start (§4).
> Shipped: 1 → 2 → 5 → 4 → 3, plus the wallet manager/switcher (Slice 7) and the redesigned tx
> detail with full on-chain data (Slice 6) — the daily-driver loop is live on Signet, verified on
> real devices' simulators. **Remaining (mostly Milestone F + open items):** fiat on the tx-detail
> amount, full license texts, real brand tokens, signing/CI, and v2 backends (CBF +
> embedded Tor).

### Slice 1 — Create wallet  ✅ (model: `docs/wallet-and-network-model.md`)
- [x] **No network question** — generate seed → persist → route Home as selected wallet (dev
      wallets currently created on Signet; network switchable later; first sync on Home).
      A "Wallet" = its own mnemonic/seed. **Recovery-phrase length: 12 (default) or 24 words**,
      chosen via a segmented control on the create screen → `submit(…, wordCount:)` →
      `Mnemonic(wordCount:)` (BDK `WORDS12`/`WORDS24`).
- [x] CreateViewModel (state machine); persistent "not backed up" banner/nudge. *(VM unit tests
      pending an app-module test target — engine paths covered in WalletServiceTests.)*
- [x] Create UI (Welcome → confirm → generate); wires the M0 empty state into a real first
      wallet. Verified on both platforms (survives restart).

### Slice 2 — Home + Receive  ✅ (leftovers tracked)
- [x] Home: selected-wallet balance (unit per network), network badge, sync state
      (idle/syncing/error + manual Refresh), recent-activity preview, send/receive actions.
      *(Wallet switcher in header → Slice 7 with the wallet manager.)*
- [x] Receive: **unused** address by default (reveal index advances only via the explicit
      "New address" action — per-open advancing burned indices past the scan gap), QR, copy/
      share, **network shown**. *(Optional BIP21 amount on receive: TODO.)*
- [x] State drives through `@Observable AppState` (no separate Home/Receive VMs needed yet).

### Slice 3 — Backup wallet  ✅
- [x] Gated reveal of the selected wallet's mnemonic: explicit "I understand" gate → **device
      auth** (iOS LocalAuthentication biometric-or-passcode; Android framework `BiometricPrompt`
      API 28+ incl. device-credential fallback — passes through when nothing is enrolled) →
      numbered word-chip grid. **Capture-blocked**: Android `FLAG_SECURE` via
      `PlatformBridge.setSecureScreen` + `AndroidActivityHolder` (activity tracked by `Main.kt`
      lifecycle glue; verified — adb screencap returns empty during the flow); iOS obscures via
      `obscuredWhenBackgrounded()` (scenePhase overlay). Import screen hardened the same way.
- [x] Verify step (3 random words, tap-the-right-chip; wrong answer bounces to reveal with fresh
      questions) → `isBackedUp` → Home warning clears. Entry points: Home warning + Settings
      "Security" row (shows Backed up / Not backed up status).
- [x] Verify-plan logic in `WalletService.BackupVerification` (parity-tested ×5: forced-index
      determinism, answer correctness, dupe-word phrases, bounds). Full flow emulator-verified
      end-to-end via the accessibility tree (capture is blocked, a11y isn't).

### Slice 4 — Import wallet  ✅
- [x] No network question → 12/24-word mnemonic (descriptor strings later) → BDK validates word
      list + checksum → persist → selected. Verified on a FRESH emulator against the BIP39 spec
      vector: imported descriptor matches the published BIP84 account tpub (`73c5da0a` /
      `tpubDC8msFG…`) exactly; survives restart.
- [x] ImportViewModel (phase machine; error clears on edit) + `MnemonicInput` normalization in
      WalletService (parity-tested: whitespace/newline/case tolerant, 12/24-only). Non-leaky
      rejection — invalid input surfaces only the scrubbed message, never the words.
      *(TODO with Slice 3 hardening: screenshot-block this screen like the Backup reveal.
      Duplicate-seed detection on import: TODO.)*

### Slice 5 — Send  ✅ (core; security narrowing still open)
- [x] Paste address / BIP21 URI → amount via **custom themed keypad** (`AmountEntry` rules,
      parity-tested) + Max → fee tier (fixed 1/2/5 sat/vB; live estimates TODO) → **review
      screen stating network** + recipient/amount/fee-rate → confirm → build/sign/broadcast.
      Presented as a full-screen flow. **Proven with real mined Signet sends both directions.**
      **QR scan (2026-06-15):** scan icon in the recipient field → SkipQRCode's ML Kit activity
      (Android) / AVFoundation `QRScannerView` (iOS); a live mono parsed-address confirmation shows
      under the field. Spend policy: confirmed + own change only (incoming 0-conf excluded). Success
      screen is Done-only (back hidden + swipe/system-back blocked).
      *(True max via TxBuilder drain: TODO. Exact fee preview on review needs a
      build-without-broadcast engine call: TODO.)*
- [x] Optimistic pending tx insert (replaced by BDK truth on next sync); typed error surfaces
      for insufficient funds/dust/broadcast.
- [x] SendViewModel state machine (entering→reviewing→broadcasting→sent/failed). Activity rows
      itemize recipient amount vs miner fee. **VM unit-tested (17 Swift Testing cases).**
      *(mainnet-weightier confirm deferred — no mainnet networks shipped.)*
- [x] **Watch-only + sign-on-demand (2026-06-13):** the everyday `WalletEngine` is built from the
      stored PUBLIC descriptors (no private keys, no Keychain read) — balance/addresses/sync/PSBT
      build all work watch-only. Signing goes through a factory `signPsbt` closure that, only at
      send time, loads the mnemonic, builds a TRANSIENT in-memory private-descriptor `Wallet`,
      signs, and drops it (BDK derives from the PSBT's BIP32 paths, so a fresh signer signs the
      watch-only-built PSBT). Shrinks the key's in-memory window to one signing; pairs with the
      per-send auth gate. **Validated end-to-end on real bdk-swift + live signet** (watch-only
      build → sign → accepted broadcast) and unit-tested (watch-only reads never load the secret;
      public-descriptor build derives the correct spec-vector address). `docs/key-storage.md §3`.
- [x] **Per-send device-auth gate (2026-06-13):** the review screen's Confirm-send is gated on
      `DeviceAuth` via a `SendViewModel.authorize` seam (`AppState` wires it to bio/passcode,
      bypassed only when app-lock is toggled off — the gate honors the same Settings switch).
      Restructured into separate screens (recipient → amount → review/confirm) with platform
      back/swipe-back instead of custom Back buttons.

### Slice 6 — Transaction history  🟡
- [x] List (newest first, pending on top) on the Activity tab + Home preview. Row design per
      Jake's mock (2026-06-12): direction chip, title + amber Pending tag, "Today 14:02 ·
      N conf" meta (">5 conf" collapses to "Confirmed"), recipient amount + unit. (Fiat on the
      tx amount is still TODO — the rate service now exists; Home balance already shows fiat.)
- [x] Detail SHEET on row tap: amount / fee / total (sends), status, time, RBF, txid with copy
      + open-in-explorer (`NetworkRegistry.explorerURL`).
- [x] Pull-to-refresh syncs (Activity list + Home scroll; `.refreshable` → Compose pull-refresh,
      verified on the emulator). The idle "Refresh" button is gone; spinner + tap-to-retry error
      states remain.
- [ ] HistoryViewModel + tests (app-module test target still pending).

### Slice 7 — Settings + Wallet manager  🟡
- [x] Theme (System/Light/Dark), About/version, dev "Reset all wallet data" (full purge);
      Security row → Backup flow.
- [x] **Open-source licenses screen (2026-06-13):** Settings → About → "Open-source licenses"
      pushes a native grouped list of every shipped dependency/font/icon set with its SPDX license,
      each row linking out. **Single source of truth:** `OpenSourceLicense.all` (one struct +
      array in `App/OpenSourceLicense.swift`); the screen (`LicensesScreen`) just renders it, so
      adding a credit is a one-line edit. Mirrored in the README acknowledgements table.
      *(TODO for release: bundle the full license texts/notices — MIT/Apache/OFL require them;
      currently we link out. Tracked in Milestone F.)*
- [x] **Wallet switcher + manager (2026-06-12):** Home-header pill (initial avatar + label +
      chevron, per Jake's mock) → manager sheet: per-wallet rows (avatar, label, network,
      backup state, selected check), tap-to-switch (per-wallet state fully reset — §5),
      rename sheet (device-local label, 24-char cap), **remove with confirmation (extra-loud
      when not backed up)**, New/Import reusing the existing flows, optional name field on
      import. **Selection persists across launches** (UserDefaults id, re-validated on load).
      Home redesigned to the mock: no nav title, balance + eye privacy toggle, 4-circle action
      row (Swap/Buy disabled ghosts until in scope).
- [x] App-lock toggle ("Require unlock") in Settings — see Milestone F app lock.
- [x] **Fiat pricing (2026-06-14)** — `PriceProvider` protocol + `BitfinexPriceProvider` (public
      `/v2/ticker/tBTC<FIAT>`, LAST_PRICE), bundled **per network** via `PriceProviderRegistry`
      (Bitcoin → Bitfinex; testnets → none; eCash later). `PriceService` (@Observable) holds the
      user's **display currency** (USD/EUR/GBP/JPY — Settings → Display currency) + latest quote and
      converts sats→fiat (display-only). Home balance + Activity/Home tx rows show "≈ fiat" for
      priced networks (mainnet); testnets show none (no fake placeholder). 10 host tests green.
      Android needs `import FoundationNetworking` for URLSession (see memory). TODO: fiat on the
      tx-detail sheet hero; periodic auto-refresh.
- [x] Per-network **custom endpoint (2026-06-14)** — Settings → Network: pick **Electrum or Esplora**
      + URL (Test-connection + Save + Reset), persisted (UserDefaults), resolved through
      `WalletManager` → factory → `WalletEngine` (branches client by kind). Plus an app-level
      **SOCKS5/Tor proxy** (passed to both clients → `.onion` + Orbot/local Tor). Verified: host
      build + `skip export` (both platforms) + WS tests green. Inputs use `.textFieldStyle(.plain)` +
      `fieldBoxInset()` (clean on Android). **Embedded Tor + CBF "use your own node" are v2.** Design:
      `docs/backends-and-endpoints.md`.
- [ ] Wallet reorder; per-wallet balance in the manager rows (needs cheap cached balances).
- [ ] SettingsViewModel / WalletManager UI tests (app-module test target still pending).

---

## Milestone F — Security, hardening, parity, release

- [x] **App lock** — biometric/passcode gate on launch + foreground resume, **Settings toggle**
      ("Require unlock"), default ON. `AppLockModel` (testable @Observable, injected auth+persist
      seams) → `LockScreen` root gate + scenePhase re-arm; reuses `DeviceAuth` (the same path the
      Backup reveal uses, Jake-verified with PIN). Persisted; no-lockout on credential-less devices
      (DeviceAuth passes through — verified live on iOS). **9 unit tests.** *(Per-SEND re-auth not
      added — the launch/foreground gate covers the session; revisit with the watch-only/sign-on-
      demand item below. Live Android gate re-verify pending a stable emulator — current AVD's GMS
      subsystem degraded after heavy cycling; auth mechanism already proven via Backup.
      Per-SEND re-auth has since landed — see Slice 5's per-send device-auth gate.)*
  - [x] **Background grace window (2026-06-13):** Settings → Security → **Auto-lock**
        (Immediately / 10s / 30s / 1 min / 5 min, default 10s, persisted). The foreground gate
        stamps the background time and re-locks on return only if the gap exceeded the grace — so a
        quick hop to another app (copy an address) doesn't re-prompt. `RootView`
        `markBackgrounded()` / `applyForegroundLock()`. **Privacy cover (`PrivacyCover`):** a
        full-screen brand cover (logo on `bg0`) raised instantly on `.inactive`/`.background` so the
        app-switcher snapshot never shows balances/addresses (the grace window leaves the app
        unlocked), faded out (ease 0.28s) on return so it isn't abrupt.
- [x] **UI consistency pass (2026-06-13):** every modal/sheet uses the platform-native
      dismiss/commit affordances instead of spelled-out "Cancel"/"Done" buttons — shared
      `CloseToolbarButton` (iOS `Button(role: .close)` → system X) and `ConfirmToolbarButton`
      (iOS `Button(role: .confirm)` → system checkmark), with Material equivalents on Android.
      Applied across Send, Backup, Receive, Tx detail, and the wallet manager (Done + rename).
      Text inputs standardized on `.textFieldStyle(.plain)` + `fieldBoxInset()` (no stray
      Android focus border, even inner padding on both platforms); scrollbars hidden
      (`.scrollIndicators(.hidden)`); real brand accent wired (`rgb(232,168,74)` as float
      colorset so it renders amber on Android, not black).
- [x] **Secret-scrub audit (2026-06-13)** — no seed/xprv/descriptor-with-keys in any log/error/
      analytics/crash path. **Manual pass:** the only logging in the app is lifecycle `logger.debug`
      in the app entry (no secrets); WalletService logs nothing; the only two raw-error touch points
      (`WalletEngine`/`BDKWalletEngineFactory`) both route through `WalletError.mapping(rawDescription:)`,
      which *inspects* but never echoes raw text, and `.engine(_)` is only ever constructed with a
      fixed string. **Automated assertion:** `WalletErrorTests.testMappingNeverLeaksAcrossRealisticBDKErrorShapes`
      feeds realistic BDK/Miniscript/Bip32 error strings embedding fake xprv/tprv/tpub/mnemonic/
      descriptor material and asserts none survives in the user message (both platforms).
- [ ] **Maestro smoke flow** — create → receive → see address, on both platforms
      (skip-ui-automation); `.accessibilityIdentifier()` on interactive views.
- [ ] **Real brand** — drop in real color tokens + accent, confirm fonts, finalize logo/vector
      drawable (§14 #1–4).
- [ ] **Real backends** — production Electrum/Esplora endpoints per network (§14 #5).
- [ ] **Open-source license texts** — bundle the full license/notice text for each dependency
      (MIT/Apache-2.0/OFL-1.1 require it); extend `OpenSourceLicense` with a notice + a detail
      screen. The attributions list itself already ships (Settings → Open-source licenses).
- [ ] **Release** — signing (iOS + Android), ProGuard, app icons (`skip icon`), Skip.env
      metadata, CI (skip-deployment). Performance checks on a **Release** build on-device.

---

## Parallel tracks (don't block the engine)

- **Brand/§14 open items:** colors+accent (Jake), font decision, logo vector drawable, Skip-safe
  `DESIGN.md` revision.
- **eCash networks (§14 #6/#7):** add L2L's two networks as `NetworkRegistry` entries once
  representation is decided (custom rust-bitcoin `Params` vs forked `bdk-ffi`). Testnet4 +
  mainnet need no action.
- **Future (CLAUDE.md §12):** BIP300/301 deposits/withdrawals (Rust-side, regenerate bindings),
  multisig, watch-only, address book — design for, don't build in v1.

---

## Sequencing rationale

Engine correctness leads because this is a wallet (bugs lose money), but M0 lands the design
system + shell so progress is visible immediately and every later slice has tokens/badge to
build on. M1 makes everything testable without a device (mock + pure logic). M2 proves BDK on
real runtimes once. After that, vertical slices each ship a usable, tested capability —
Create first (nothing works without a wallet), then the daily-driver loop (Home/Receive →
Send → History), with Backup early because an unbacked-up wallet is a liability.
