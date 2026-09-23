# Toolchain upgrade — Skip, Xcode, macOS

**Planned:** 2026-09-23 against 1.2.0 (22) · **Done:** 2026-09-23 (Skip + Xcode + CI, all verified) · **macOS 27:** done 2026-09-23, verified

This started as a plan (Skip first, then Xcode, macOS last). What actually happened differed in one
important way: **the plan's central assumption, that Xcode and the Android build are independent, was
wrong.** This doc now records the result, the correction, and the rules that follow from it.

## Where we are now

| | before | **now (local)** | **now (CI, `xcode-27`)** |
|---|---|---|---|
| macOS | 26.6.2 | **27.0** (26A428) | 27.0 (preview image) |
| Xcode | 26.5 (17F42) | **27.0** (27A266a) | **27.0** (27A266a), pinned |
| Swift (Xcode) | 6.3.2 | **6.4** | 6.4 |
| Swift Android SDK | 6.3.2 | **6.4.0** (NDK r30, bundled) | **6.4.0**, pinned |
| Skip | 1.9.2 | **1.9.11** (CLI + `Package.resolved`) | 1.9.11 |
| JDK (Gradle) | Homebrew `openjdk@25` | `openjdk@25` | JDK 25 (`JAVA_HOME_25_arm64`) |

Commits: `5008254` (Skip + README), `233149f` (stale eCash test expectations), `10e190f` (CI),
`95d08dd` (swiftly on CI).

Xcode 27 was installed **in place** over 26.5 (no side-by-side copy), so there is no
`xcode-select` rollback to 26.5 short of reinstalling it.

## The correction: Xcode and the Android build are coupled

The plan said the iOS build follows Xcode and the Android cross-compile follows the swift.org
toolchain that Skip installs, so the two could move independently. **They can't.**

Skip's Android build does use its own swift.org host toolchain, but that toolchain compiles package
manifests **against Xcode's macOS SDK**. With Xcode 27 installed, the 6.3.2 toolchain failed on the
macOS 27 SDK:

```
<unknown>:0: error: unknown argument: '-target-arch-variant'
error: compile command failed due to signal 11
error: 'swift-crypto': Invalid manifest …
```

So **Xcode's major version and the Swift Android SDK version must move together.** Upgrading Xcode
alone breaks the Android build, with no change in the repo. That is also why CI now pins Xcode
(`27.0`) instead of floating `latest-stable`.

## What the upgrade took

1. **Skip 1.9.2 → 1.9.11.** `brew upgrade skip` for the CLI, then `swift package update` limited to
   the Skip core in both packages (`skip`, `skip-ui`, `skip-fuse-ui`, `skip-fuse`, `skip-bridge`,
   `skip-android-bridge`, `skip-foundation`, `skip-lib`, `skip-model`, `skip-unit`, `swift-jni`,
   `swift-android-native`). bdk-swift and the keychain/firebase/qrcode/web libraries were
   deliberately left alone. Both manifests now say `from: "1.9.11"` so the CLI and package can't
   drift apart again.
2. **Swift Android SDK 6.3.2 → 6.4.0:** `skip android sdk install --version 6.4.0`. The full
   version is required; `--version 6.4` resolves nothing. The SDK downloads NDK r30 into its own
   bundle and links it (bdk-android needs NDK 27+).
3. **Remove the old Android SDKs:** `swift sdk remove swift-6.3-RELEASE_android` and
   `swift-6.3.2-RELEASE_android`. With more than one installed, SwiftPM refuses to choose:
   *"matched multiple SDKs"*. The old ones can't build under Xcode 27 anyway, and reinstalling one
   takes about 90 seconds.
4. **CI** moved to the `xcode-27` image with Xcode and the SDK pinned (see
   `.github/workflows/android-debug-apk.yml`).
5. **CI needs swiftly.** The first `xcode-27` run failed in `skip android sdk install`:
   *"Swift 6.4.0 does not exist at URL …/swift-6.4-RELEASE/swift-6.4-RELEASE-osx.pkg"*. When swiftly
   is present, Skip installs the host toolchain through it (`swiftly install 6.4.0`), which is why it
   worked locally. Without swiftly, Skip builds the URL itself and drops the patch version; the real
   package is at `swift-6.4.0-RELEASE`. CI now installs swiftly via Homebrew. This was also the real
   cause of the 2026-09-17 CI failure, which at the time was put down to swift.org not having
   published 6.4.0 yet.

**Verified (2026-09-23):**
- `scripts/build-apk.sh`: 42 native libs incl. `libswiftCore.so`.
- iOS: the app runs on an iOS 27 simulator.
- Android emulator (`Medium_Phone_API_36.1`, arm64, release build): an existing wallet loads,
  syncs, and shows its balance and transaction history; no crashes. That wallet predates betanet
  and is on alphanet, so betanet itself wasn't exercised.
- `WalletService` tests: 215 host, 159 Robolectric, 0 failures.
- CI on `xcode-27`: [run 35896133843](https://github.com/ecash-com/ecash-wallet-mobile/actions/runs/35896133843)
  green in 37 min; its APK is 79MB with 42 native libs incl. `libswiftCore.so`, matching local.

**Not yet verified:** a betanet wallet (the current eCash network, `WalletNetwork.currentEcash`)
and a real send on either platform since the upgrade. Create or import a betanet wallet and do a
small send on it before the next release.

## Known issues after the upgrade

- **Root `swift build` / `swift test` fails** under SwiftPM 6.4: *"product 'SkipLib-product' is
  linked as a static library by … This will result in duplication of library code."* It
  reproduces with the old Skip 1.9.2 pins, so it's SwiftPM 6.4, not Skip. The Xcode iOS build and
  `skip export` are unaffected, and so is `swift test --package-path Packages/WalletService`.
- **`JAVA_HOME` must point at a real JDK** for `skip doctor` and the Robolectric tests:
  `export JAVA_HOME=/opt/homebrew/opt/openjdk@25` (plus `$JAVA_HOME/bin` on `PATH`). Homebrew's
  `openjdk@25` is keg-only and not registered with macOS, so without it nothing finds a Java
  runtime. Android Studio's bundled JDK isn't used, so updating Android Studio doesn't help.
- **Xcode 27 has no Simulator.app.** It is `Xcode.app/Contents/Applications/DeviceHub.app`. A
  simulator booted with `simctl` runs without a window until DeviceHub is opened.
- **The 1.2.0 AAB in `.build/dist/` was overwritten** by the verification build, so it is now a
  new-toolchain build, not the verified 1.2.0 (22) artifact.

## macOS 27 — done

Upgraded 26.7 → **27.0** on 2026-09-23, after the Skip + Xcode upgrade above was green, with nothing
else changed in the same sitting. Nothing broke; no repo change was needed. Re-verified on 27.0:

- Toolchain unchanged: Xcode 27.0 (27A266a), Swift 6.4, Skip 1.9.11, exactly one Android SDK
  (`swift-6.4.0-RELEASE_android`); `skip doctor` green (with `JAVA_HOME` set — see above).
- `scripts/build-apk.sh`: 79MB APK / 75MB AAB, 42 native libs incl. `libswiftCore.so`.
- iOS: `scripts/run-ios-sim.sh` builds, installs and launches on the iOS 27 simulator
  (iPhone 18 Pro, via DeviceHub).
- Android: `scripts/run-android.sh` release build runs on `Medium_Phone_API_36.1`; no app crashes
  (the emulator's own Bluetooth stack logs an unrelated native abort to the crash buffer).
- `WalletService` tests: 215 host (1 skipped), 159 Robolectric, 0 failures.

The betanet send in *Not yet verified* above is still open.

## Rules for the next upgrade

- **Move Xcode's major version and `SWIFT_ANDROID_SDK_VERSION` together.** Update both the local
  install and the CI pin in the same change.
- **Move the Skip CLI and SwiftPM package together.**
- **Keep exactly one Swift Android SDK installed** (`swift sdk list`).
- **CI must keep swiftly installed**, or `skip android sdk install` fetches a malformed URL.
- **`swift build` is not a gate.** `scripts/build-apk.sh` (check the Swift-runtime count) plus an
  emulator run is.
- **Don't overwrite a release artifact with a verification build.** Copy `.build/dist/` aside
  before rebuilding if a verified AAB there hasn't shipped yet.
- **Don't upgrade mid-release**, and never change more than one of macOS / Xcode / Skip in a
  sitting without a device check in between.

## Rollback

| piece | undo |
|---|---|
| Skip | `brew` downgrade + `git revert 5008254` |
| Swift Android SDK | `skip android sdk install --version <old>`, then `swift sdk remove` the new one |
| Xcode | reinstall the old Xcode (26.5 was replaced in place), then downgrade the Android SDK to match |
| CI | `git revert 95d08dd 10e190f` |
| macOS | none short of a reinstall |
