<p align="center">
  <a href="https://ecash.com"><img src="ecash-logo.svg" alt="eCash.com" width="120"></a>
</p>

<h1 align="center">eCash.com Wallet</h1>

<p align="center">A native, self-custodial mobile wallet for <a href="https://ecash.com">eCash</a>.</p>

---

A native mobile wallet for **eCash** — the [Layer Two Labs](https://layertwolabs.com) Bitcoin
hardfork that activates Drivechain (BIP300/301) and airdrops eCash 1:1 to BTC holders. One Swift +
SwiftUI codebase ships as a native SwiftUI app on iOS and native Jetpack Compose on Android via
[Skip](https://skip.dev). All key material, signing, and consensus logic is handled by
[BDK](https://bitcoindevkit.org) (`bdk-swift` / `bdk-android`).

Multi-wallet and multi-network from day one. v1 bundles **Bitcoin mainnet** (`0'`) and
**L2L Signet** (`1'`); eCash mainnet and L2L test networks slot in as `NetworkRegistry` entries
later.

## Contributing

We're **not accepting outside code contributions right now.** The codebase is under heavy active
development and changing quickly, and we'd like it in a more stable place before opening it up to pull
requests.

**Feature ideas are very welcome**, though — open an issue describing what you'd like to see and we'll
take it under consideration. Bug reports are appreciated too.

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

> [!WARNING]
> **Building from source isn't recommended yet.** The wallet is under **heavy active development** —
> APIs, storage layout, and screens change frequently, and it targets test networks by default. If
> you build anyway, treat it as a preview: don't put real funds in a wallet built from an
> in-development checkout. (Bitcoin mainnet is selectable but the app is pre-release.)

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

### Signing for a physical iOS device

Simulator and Android builds need no signing setup. To run on a **real iPhone**, supply your own
Apple Developer **Team ID** — it's deliberately not committed:

```bash
cp Darwin/DeveloperSettings.xcconfig.example Darwin/DeveloperSettings.xcconfig
# edit the file and set DEVELOPMENT_TEAM = <your team id>   (Xcode → Settings → Accounts)
```

That file is gitignored; the project's xcconfig includes it optionally, so signing then works in
Xcode, `xcodebuild`, and fastlane. With a device connected + trusted, you can build/install/launch
from the command line:

```bash
scripts/run-ios-device.sh          # Debug (default)
scripts/run-ios-device.sh Release  # Release
```

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
WALLETSERVICE_LIVE=1 swift test --filter testLiveSignetSync   # opt-in live L2L Signet
```

`swift build` only checks Apple + transpilation; **`skip export --debug` is the real Android check.**
No change to `WalletService` or a view model merges without tests in the same PR.

## Security model

Your keys stay on your device, and the app is built to keep them exposed as little as possible.

- **Keys never leave the device.** The recovery phrase (and *only* the phrase) is stored in the OS
  secure store — iOS **Keychain** (`WhenUnlockedThisDeviceOnly`, no iCloud sync) / Android
  **Keystore-backed encrypted storage** — keyed per wallet. Everything else (xpub descriptors,
  labels, the transaction cache) is public data.
- **BDK owns all cryptography.** Key derivation, signing, PSBT building, and coin selection are
  handled by the [Bitcoin Dev Kit](https://bitcoindevkit.org) — no hand-rolled crypto.
- **Watch-only + sign-on-demand.** Day-to-day the wallet runs **watch-only**: balance, address
  derivation, syncing, and even building a transaction use only the *public* descriptors — the
  secret store is never read. Your phrase is loaded for exactly one purpose, at one moment: to
  **sign** a transaction you've confirmed. It's pulled into a transient in-memory signer, used, and
  dropped — so the private key's lifetime in memory is a single signing operation.
- **Nothing secret on disk, nothing secret in logs.** Only public data is persisted. Errors are
  typed and scrubbed before they reach the UI or any log — a signing failure says "signing failed,"
  never the key (enforced by an automated no-leak test).
- **Device-auth gates.** Optional biometric/passcode lock on launch and on returning to the
  foreground (with a configurable grace window so a quick trip to another app doesn't re-prompt),
  plus an independent auth gate on the **confirm-send** step. On a device with no biometric/passcode
  enrolled the gate passes through rather than locking you out.
- **Guarded backup.** Revealing the phrase is behind an explicit gate + device auth, screenshots are
  blocked during the reveal (Android `FLAG_SECURE`; obscured in the iOS app switcher), and you
  confirm a few words before it's marked backed up.
- **Spendable balance (0-conf policy).** Only **confirmed coins + your own unconfirmed change** are
  treated as spendable. Coins you *received* that are still unconfirmed (0-conf) are shown separately
  as **pending** and are kept out of coin selection until they confirm — because an unconfirmed
  incoming payment can still be double-spent or RBF-replaced, which would orphan anything you tried to
  send on top of it. This mirrors Bitcoin Core's trusted/untrusted rule (BDK gives us the
  `confirmed` / `trustedPending` / `untrustedPending` split; the send path also marks untrusted
  outpoints unspendable). A configurable confirmation threshold — and potentially a **per-network**
  one (e.g. stricter on mainnet than on testnets) — is a planned option.
- **Clean removal.** Removing a wallet purges its phrase from the secure store plus all of its
  on-device data.

The decision records behind this live in `docs/key-storage.md` and `docs/key-derivation.md`; the
non-negotiable rules are CLAUDE.md §2 (Golden Rules) and §7 (Security model).

## Docs

- `CLAUDE.md` — architecture bible (the *what* and *why*; wins on conflicts).
- `PLAN.md` — full build plan + tracked checklist.
- `DESIGN.md` — visual spec (tokens, type, components, voice).
- `docs/release.md` — build / sign / ship to App Store + Google Play.
- `docs/` — decision records: key storage & derivation, wallet/network model, accounts & labels, backends & endpoints, CoinNews, and more.

## Open source & acknowledgements

eCash.com Wallet stands on these projects. The same list is shown in-app under **Settings → About →
Open-source licenses**, sourced from a single array (`OpenSourceLicense.all` in
`Sources/ECashWalletMobile/App/OpenSourceLicense.swift`) — add or edit a credit there and both the
app screen and this table should be kept in sync.

| Project | Use | License |
|---|---|---|
| [Skip](https://skip.tools) | Swift→Kotlin cross-platform toolchain + frameworks | MPL-2.0 |
| [Bitcoin Dev Kit](https://bitcoindevkit.org) (`bdk-swift` / `bdk-android`) | Wallet engine | Apache-2.0 / MIT |
| [SkipKeychain](https://source.skip.tools/skip-keychain) | Secure mnemonic storage | LGPL-3.0 |
| [swift-qrcode-generator](https://github.com/fwcd/swift-qrcode-generator) | Receive QR codes | MIT |
| [SkipQRCode](https://source.skip.tools/skip-qrcode) | Send QR scanning (Android camera) | LGPL-3.0 |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | Mono / numeric typeface | OFL-1.1 |
| [Space Grotesk](https://github.com/floriankarsten/space-grotesk) | Display typeface | OFL-1.1 |
| [Material Symbols](https://github.com/google/material-design-icons) | Icon set (`.symbolset`) | Apache-2.0 |

> Release note: bundling the **full license texts / copyright notices** (required by MIT/Apache/OFL)
> is still TODO — the in-app screen currently links out. See `PLAN.md` Milestone F.

## License

Copyright (C) 2026 LayerTwo Labs and contributors.

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software Foundation,
either version 2 of the License, or (at your option) any later version. See
[LICENSE.txt](LICENSE.txt) for the full text ([SPDX: GPL-2.0-or-later](https://spdx.org/licenses/GPL-2.0-or-later.html)).
</content>
