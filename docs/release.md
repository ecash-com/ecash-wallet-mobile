# Release & distribution (fastlane)

> How the app is built, signed, and shipped to the **App Store / TestFlight** (iOS) and **Google
> Play** (Android), via fastlane. Secrets are gitignored and supplied locally (templates committed).
>
> **Status (2026-06-24):** Version **0.1.1** (build 2). iOS is **connected** (App Store Connect API
> key in place) → push via `fastlane beta`; 0.1.1(2) uploaded to TestFlight. Android: the **upload
> keystore is wired** and produces a Play-grade **signed AAB** (§2b, verified `CN=Layer Two Labs`);
> remaining is Play Console setup (create app, App content section, manual first upload). Still also
> ships a sideload **APK** (arm64) for ad-hoc testers (§2a). Play automation via fastlane needs the
> service-account JSON (not yet created).

All fastlane commands run from the platform subdir: `cd Darwin` (iOS) / `cd Android` (Android).
Bundle id / package = `com.layertwolabs.mobile.ecashwallet` (from `Skip.env`, shared by both).

**Version** is centralized in `Skip.env` — `MARKETING_VERSION` (semantic, currently `0.1.1`) +
`CURRENT_PROJECT_VERSION` (build number, currently `2`), shared by iOS and Android. **Bump
`CURRENT_PROJECT_VERSION` before each repeat TestFlight/Play upload** (build numbers must be unique).

---

## 1. iOS — App Store / TestFlight ✅ connected

### Lanes (`Darwin/fastlane/Fastfile`)
- **`fastlane assemble`** — archive/build the iOS app only (`build_app`, scheme "ECashWalletMobile App").
- **`fastlane beta`** — `assemble` → **upload to TestFlight** (no review submission). Use this first.
- **`fastlane release`** — `assemble` → **upload to App Store + submit for review** (Deliverfile).

### Auth — App Store Connect API key (the key secret)
`Darwin/fastlane/apikey.json` (gitignored; template `apikey.json.example`) holds the **ASC API key**:
`key_id`, `issuer_id`, and the `.p8` private key (inline). Generate at App Store Connect → Users and
Access → Integrations → App Store Connect API (Team Key, role App Manager); download the `.p8` once.
Every lane authenticates via `api_key_path: "fastlane/apikey.json"` — no Apple-ID password / 2FA.

### Signing
Automatic signing during archive, using `DEVELOPMENT_TEAM` from the gitignored
`Darwin/DeveloperSettings.xcconfig` (also pulled into `Darwin/fastlane/AppStore.xcconfig`). The API
key lets fastlane fetch/create the App Store provisioning profile. If a first run reports a missing
**distribution certificate**, uncomment `get_certificates(api_key_path: "fastlane/apikey.json")` in
the relevant lane — it creates one via the API key.

### Verify auth without building
```
cd Darwin && fastlane run latest_testflight_build_number \
  api_key_path:"fastlane/apikey.json" app_identifier:"com.layertwolabs.mobile.ecashwallet"
```
"Could not find a build upload … Result: 1" = auth OK + app found, no builds yet (the healthy
fresh-app state).

---

## 2. Android — distribution

### 2a. Pass-around APK (current method) ✅
Share a signed release **APK** with testers — no Play needed:
```
scripts/build-apk.sh            # arm64 → .build/dist/eCashWallet-<version>-aarch64.apk
ARCH=all scripts/build-apk.sh   # every ABI (much bigger; only for x86/armv7 devices)
```
- **arm64 (aarch64) by default** — covers ~all modern phones. The Swift runtime makes each ABI
  ~170 MB, so we don't ship `all` unless needed.
- **Signing:** falls back to the **debug keystore** (no `keystore.properties`) → sideload-installable
  (testers enable "install unknown apps"), **not** Play-grade. Set up an upload keystore (§2b.3) only
  when going to Play. (Nothing's published, so switching to a proper key later is still safe.)
- Under the hood: `skip export --release --no-ios --arch aarch64` — skips the iOS archive and the
  armv7/x86_64 native compiles (~7 min → ~1–2 min; flags in `scripts/run-android.sh` +
  `Android/gradle.properties`). `scripts/run-android.sh` is the same build but installs to a device.

### 2b. Google Play — signed AAB

> ⚠️ **No system Java on this Mac.** `/usr/bin/keytool` / `/usr/bin/jarsigner` are stubs that error
> with "Unable to locate a Java Runtime." Use the JDK bundled with Android Studio:
> `/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/{keytool,jarsigner}`
> (or `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` for the session).

#### Upload key — DONE (2026-06-24) ✅
Enrolled in **Play App Signing** (Google manages the *app signing* key; we sign uploads with an
*upload* key — recoverable via a Play Console reset if lost, but still back it up). The upload key
lives at `Android/app/keystore.jks` (gitignored), alias `upload`, referenced by
`Android/app/keystore.properties` (gitignored: `keyAlias`/`keyPassword`/`storeFile`/`storePassword`).
`build.gradle.kts` auto-loads that file and signs the release build with it (falls back to the debug
key only when the file is absent — that's the sideload-APK path in §2a).

How it was generated (only redo if the key is ever rotated — keep `keystore.jks` + password backed up):
```
"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" -genkeypair -v \
  -keystore Android/app/keystore.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Layer Two Labs, O=Layer Two Labs, C=US"
# prompts for a keystore password (min 6 chars); press RETURN at the key-password prompt to reuse it.
# DN fields are cosmetic for an upload key — Google ignores them.
```

#### Build the signed AAB
```
scripts/build-apk.sh   # skip export --release; signs with keystore.properties when present
# → .build/Android/app/outputs/bundle/release/app-release.aab   ← upload THIS to Play (not the §2a APK)
```
Verify it's signed with the upload key (not the debug key) before uploading:
```
"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/jarsigner" -verify -verbose -certs \
  .build/Android/app/outputs/bundle/release/app-release.aab | grep -E "CN=|jar verified"
# expect: "jar verified." + signer "CN=Layer Two Labs"  (NOT "CN=Android Debug")
```
**Bump `CURRENT_PROJECT_VERSION` in `Skip.env` before each Play upload** — versionCode must strictly
increase (0.1.1 used versionCode 2).

#### Play Console — still TODO ⬜
1. **Create the app** in Play Console, package `com.layertwolabs.mobile.ecashwallet`; choose
   **"Let Google manage and protect your app signing key"** (Play App Signing — matches the upload-key
   model above).
2. **App content section** (required before ANY testing track goes live): privacy-policy URL, Data
   safety form, content rating, target audience, ads declaration, and the **Financial features**
   declaration (non-custodial crypto/blockchain wallet).
3. **First AAB upload is MANUAL** via the Console UI (Google blocks API uploads until one AAB has been
   uploaded by hand). Use the **Internal testing** track first (≤100 testers, no review wait — the
   Play analog of TestFlight).
4. **Play service-account JSON** (only needed to automate later uploads via fastlane) →
   `Android/fastlane/apikey.json` (gitignored). Play Console → Setup → API access → link a Google
   Cloud project → create service account → grant release permissions → download JSON. Verify:
   `cd Android && fastlane run validate_play_store_json_key json_key:"fastlane/apikey.json"`.

`targetSdkVersion` is **36** and `minSdkVersion` **28** (emitted automatically — both satisfy Play's
current new-app requirement of target ≥ 35).

### Lanes (`Android/fastlane/Fastfile`), once the above exist
- **`fastlane assemble`** — gradle `bundleRelease` → `.build/Android/app/outputs/bundle/release/app-release.aab`.
- **`fastlane release`** — `assemble` → `upload_to_play_store` (defaults to the production track;
  add `track: "internal"` for an internal-testing first push, the Play analog of TestFlight).

### Note: AAB vs APK
Play wants an **`.aab`** (App Bundle); the `adb install` debug flow we use for on-device testing uses
the debug **APK** (`skip export --debug`). Different artifacts — the release path is the AAB.

---

## 3. Secrets (all gitignored — never committed)

| File | Platform | What |
|---|---|---|
| `Darwin/fastlane/apikey.json` | iOS | App Store Connect API key (`.p8` inline) |
| `Darwin/DeveloperSettings.xcconfig` | iOS | `DEVELOPMENT_TEAM` |
| `Android/fastlane/apikey.json` | Android | Play service-account JSON |
| `Android/app/keystore.properties` | Android | release keystore alias + passwords + path |
| `Android/app/keystore.jks` | Android | the upload keystore itself (alias `upload`) — back this up |

Committed **templates**: `Darwin/fastlane/apikey.json.example`, `Darwin/DeveloperSettings.xcconfig.example`.

## 4. TODO / open
- **Build-number bumping:** TestFlight/Play require a unique build number per upload. Build 1 is fine
  now; add `increment_build_number` (or a timestamp) before the second upload.
- **CI:** lanes are local-only today; wiring them into CI (with the secrets injected) is future.
- **Store metadata / screenshots / privacy:** `fastlane/metadata/` + Deliverfile exist but need real
  copy, screenshots, and the privacy-nutrition / data-safety forms filled before public release.
- **Android first manual upload** (see §2.1) before `fastlane release` can push.
