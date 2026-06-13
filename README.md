# eCash.com Wallet

A native mobile wallet for **eCash** — the [Layer Two Labs](https://layertwolabs.com) Bitcoin
hardfork that activates Drivechain (BIP300/301) and airdrops eCash 1:1 to BTC holders. One Swift +
SwiftUI codebase ships as a native SwiftUI app on iOS and native Jetpack Compose on Android via
[Skip](https://skip.dev). All key material, signing, and consensus logic is handled by
[BDK](https://bitcoindevkit.org) (`bdk-swift` / `bdk-android`).

Multi-wallet and multi-network from day one. v1 develops on the testnet-class networks
(**Signet / Testnet4 / regtest**); eCash mainnet and L2L test networks slot in as
`NetworkRegistry` entries later.

## Stack

| Layer | Choice |
|---|---|
| Language / UI | Swift 6 · SwiftUI → Compose (Skip) |
| Wallet engine | BDK 2.3.x (`bdk-swift` on iOS, `bdk-android` on Android) |
| Secure storage | SkipKeychain (iOS Keychain / Android Keystore) — mnemonics only |
| Local storage | BDK-owned SQLite (chain data) + JSON wallet-list metadata (no SkipSQL) |
| Min OS | iOS 26+ · Android 9+ (API 28) |

## Project layout

```
ECashWalletMobile/             ← the Skip Fuse app (native Swift): UI, view models, state
  Sources/ECashWalletMobile/     App/ · DesignSystem/ · Screens/ · Components/ · Resources/
Packages/WalletService/        ← the BDK seam, a SEPARATE transpiled (Skip Lite) package
  Sources/WalletService/         WalletEngine, BDKWalletEngineFactory, NetworkRegistry,
                                 WalletManager, KeyStore, WalletStore, Descriptors, Models…
Darwin/                        ← iOS app target
Android/                       ← generated Compose output + Kotlin glue
```

The app is **Fuse** (native Swift compiled for Android); `WalletService` is **Lite** (transpiled to
Kotlin) so it can call `bdk-android` directly. This split is the one architectural subtlety — see
`CLAUDE.md` §5.

## Prerequisites

- **macOS** with **Xcode** (Swift 6 toolchain, iOS Simulator).
- **Android Studio** + Android SDK/NDK, with an **emulator** created (Device Manager) and running
  before you launch the Android app.
- **Skip CLI**: `brew install skiptools/skip/skip`, then verify the toolchain with `skip checkup`.

## Build & run

```bash
# Both platforms at once (iOS Simulator + running Android emulator):
skip app launch

# iOS: open the workspace in Xcode and run the "ECashWalletMobile App" target.
open Project.xcworkspace

# Android only (quick): build the debug APK and install to the running emulator:
skip export --debug
adb install -r .build/skip-export/ECashWalletMobile-debug.apk
```

iOS logs appear in the Xcode console; Android logs in Android Studio's Logcat or `adb logcat`.

## Testing

```bash
# Fast: Swift host tests + transpiled JUnit on the JVM (Robolectric) — both platforms, one run.
swift test

# Just the wallet engine package:
swift test --package-path Packages/WalletService

# Verify the Android build actually transpiles + compiles (the real Android gate):
skip export --debug

# Real-BDK integration on a device runtime:
ANDROID_SERIAL=emulator-5554 swift test          # Android instrumented
WALLETSERVICE_LIVE=1 swift test --filter testLiveTestnet4Sync   # opt-in live Testnet4
```

`swift build` only checks Apple + transpilation; **`skip export --debug` is the real Android check.**
No change to `WalletService` or a view model merges without tests in the same PR.

## Roadmap

Abbreviated — see `PLAN.md` for the detailed, tracked checklist.  ✅ done · 🟡 in progress · ⬜ not started

- ✅ **M0 — Foundation:** design system (`Theme`), app shell + navigation, icons, logo, network badge.
- ✅ **M1 — WalletService core (pure, fully tested):** Amount/BIP21/Descriptors/NetworkRegistry/
  WalletError + KeyStore/WalletStore/WalletManager + mock engine.
- ✅ **M2 — Real BDK engine:** create/import, balance, addresses, transactions, UTXOs, send, sync,
  typed error mapping. Runtime-verified on iOS sim + Android emulator, including real Signet
  broadcasts in both directions. Sync = full scan once, then revealed-address sync (no gap-limit
  blind spots).
- ✅ **Slice 1 — Create wallet** (generate → home on a test network; no network question at create)
- ✅ **Slice 2 — Home + Receive** (balance, sync state, activity preview; unused address + QR —
  "New address" advances on demand)
- ✅ **Slice 5 — Send** (paste address/BIP21 → custom keypad amount → fee tier → review w/ network →
  sign → broadcast → optimistic pending row; full-screen flow)
- 🟡 **Slice 6 — Transaction history** (mock-styled rows + tap-for-detail sheet with explorer link ✅;
  pull-to-refresh + fiat values ⬜)
- 🟡 **Slice 7 — Settings + Wallet manager** (theme, dev reset, backup row, wallet switcher pill +
  manager sheet with switch/rename/add/import/remove + persistent selection ✅; endpoints, fiat, app-lock ⬜)
- ✅ **Slice 4 — Import wallet** (12/24-word restore, BDK-validated, non-leaky errors; verified
  against the BIP39/BIP84 spec vectors)
- ✅ **Slice 3 — Backup wallet** (explicit gate → biometric/passcode → word chips → 3-word verify;
  capture-blocked: FLAG_SECURE on Android, obscured-when-backgrounded on iOS; clears the Home warning)
- 🟡 **Milestone F — Hardening & release:** app-lock ✅ (biometric/passcode gate on launch +
  foreground, Settings toggle, default ON); secret-scrub audit, UI smoke flows, real brand, signing/CI ⬜.
- 🧪 **Tests:** WalletService parity suite (Robolectric, both platforms) + 47 app view-model tests
  (Swift Testing, host `swift test`): Send, Backup, Import, Create, AppLock state machines.

## Docs

- `CLAUDE.md` — architecture bible (the *what* and *why*; wins on conflicts).
- `PLAN.md` — full build plan + tracked checklist (the *order*).
- `DESIGN.md` — visual spec (tokens, type, components, voice).
- `docs/wallet-and-network-model.md` — what a "Wallet" is (a seed) + network as a switchable view (decided; revises Golden Rule §4).
- `docs/key-derivation.md` — key-derivation decision record (BIP84, coin-types, eCash params).
- `docs/key-storage.md` — key-storage / secrets decision record (what's persisted, Keychain/Keystore, backup, app-lock).
- `docs/accounts-and-labels.md` — design record for multi-account-per-seed (savings/checking) + per-key-pair labels/metadata (post-v1; app-owned, not BDK).

## License

Copyright (C) 2026 LayerTwo Labs and contributors.

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software Foundation,
either version 2 of the License, or (at your option) any later version. See
[LICENSE.txt](LICENSE.txt) for the full text ([SPDX: GPL-2.0-or-later](https://spdx.org/licenses/GPL-2.0-or-later.html)).
</content>
