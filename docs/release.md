# Release & distribution (fastlane)

> How the app is built, signed, and shipped to the **App Store / TestFlight** (iOS) and **Google
> Play** (Android), via fastlane. Secrets are gitignored and supplied locally (templates committed).
>
> **Status (2026-11-10):** Version **1.5.0** (build **46**, `Skip.env`), under the **eCash orgs** (org
> migration done — §5). iOS is **connected** (App Store Connect API key in place) → push via
> `fastlane beta`. Android: the **upload keystore is wired** and produces a Play-grade **signed AAB**
> (§2b, verified `CN=Layer Two Labs`); **Play is still NOT set up** — remaining is Play Console setup
> (create app, App content section, manual first upload). Still also ships a sideload **APK** (arm64)
> for ad-hoc testers (§2a). Play automation via fastlane needs the service-account JSON (not yet
> created). *(Previous status 2026-08-13: 0.2.0 build 1, first release under the eCash orgs.)*

All fastlane commands run from the platform subdir: `cd Darwin` (iOS) / `cd Android` (Android).
Bundle id / package = `com.ecash.mobile.wallet` (from `Skip.env`, shared by both) as of the 2026-08
org migration. The Layer Two Labs identifier `com.layertwolabs.mobile.ecashwallet` still exists as a
separate, published app on both stores — the new identifiers are a NEW listing, not an update.

**Version** is centralized in `Skip.env` — `MARKETING_VERSION` (semantic, currently `1.5.0`) +
`CURRENT_PROJECT_VERSION` (build number, currently `46`), shared by iOS and Android. **Bump
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
  api_key_path:"fastlane/apikey.json" app_identifier:"com.ecash.mobile.wallet"
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
**Bump `CURRENT_PROJECT_VERSION` in `Skip.env` before each Play upload — and NEVER reset it on a
version bump.** One number feeds both stores, and they disagree about the rules: Apple scopes build
numbers *within* a version string (0.2.0(1) and 0.2.1(1) are both valid), while Play requires
`versionCode` to strictly increase for the life of the app and ignores `versionName` entirely. So a
reset-to-1 makes the next Android build unuploadable — hit for real on 2026-08-13 when 0.2.1(1)
collided with the already-uploaded 0.2.0(1). Always increment; Apple tolerates the gaps.

#### Play Console — still TODO ⬜
1. **Create the app** in Play Console, package `com.ecash.mobile.wallet`; choose
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
- **`fastlane release`** — `assemble` → `upload_to_play_store`. **Defaults to the `internal` track**
  (`Android/fastlane/Fastfile:~53` overrides fastlane's own production default so an unqualified
  `fastlane release` can't push a beta at every user); pass `track:beta` / `track:production` to
  promote deliberately.

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
- **Build-number bumping:** TestFlight/Play require a unique build number per upload. Bump
  `CURRENT_PROJECT_VERSION` **manually in `Skip.env`** before each upload and **never reset it** (§2b —
  Play's `versionCode` must increase for the life of the app). No `increment_build_number` lane; the
  number is the single source for both stores.
- **CI:** lanes are local-only today; wiring them into CI (with the secrets injected) is future.
- **Store screenshots / privacy:** store copy exists on both sides (`Darwin/fastlane/metadata/en-US/`,
  `Android/fastlane/metadata/android/en-US/` incl. `featureGraphic.png` + `icon.png`); **screenshots
  are still missing** (`Darwin/fastlane/screenshots/` absent, `…/images/phoneScreenshots/` empty —
  `docs/store-screenshots.md`), as are the privacy-nutrition / data-safety forms (2026-11-10).
- **Android first manual upload** (see §2.1) before `fastlane release` can push.

## 5. Org migration — DONE (folded in from the removed `docs/org-migration.md`, 2026-11-10)

The app moved from the Layer Two Labs orgs to the **eCash** orgs as a **clean start, not a transfer**
(2026-08). What that settled, beyond the identifiers already stated above:

- **Apple:** team **`7BQ6DL5YV9`** (Blockchain Emulation Services Ltd) — `DEVELOPMENT_TEAM` in the
  gitignored xcconfig and both `project.pbxproj` entries; App Store Connect record for
  `com.ecash.mobile.wallet` created 2026-08-13; ASC API key `LM5CG2YGN9` wired into
  `Darwin/fastlane/apikey.json`; distribution certificate installed. `Darwin/fastlane/Appfile` now
  reads `PRODUCT_BUNDLE_IDENTIFIER` only (it used to prefer `ANDROID_APPLICATION_ID`, which aimed
  TestFlight at the wrong app while Android was rebranded first).
- **Firebase / push:** project **`ecash-wallet-3b5c9`** was **kept**, with new iOS/Android apps added
  for the new bundle id (regenerated `google-services.json` / `GoogleService-Info.plist`, both
  gitignored; CI secret `GOOGLE_SERVICES_JSON_BASE64`). The APNs auth key in Firebase should belong to
  team `7BQ6DL5YV9` — **unverified from the repo** (the old key `N3U7CSY8YT` was under LTL's
  `6AXPP357T2`); check Firebase → Cloud Messaging if iOS push ever stops.
- **Google Play** (still open — the steps §2b."Play Console" doesn't already list): the **eCash
  Google Play developer account** itself must be created/verified (one-time fee; identity
  verification can take days) before the app can be created there; the existing upload keystore is
  account-independent and can be kept as-is (`CN=Layer Two Labs` is cosmetic); when automation is
  wired, the service-account JSON must be created under the eCash Google account
  (`Android/fastlane/Appfile` reads `package_name` from `Skip.env` + `fastlane/apikey.json`).
- **Old-bundle users:** the LTL app (`com.layertwolabs.mobile.ecashwallet`) is a separate, dead-end
  listing. Keys live in the OS secure store keyed by the app's identity, so the new app starts empty —
  **TestFlight/APK users of the old bundle must back up their seed and restore it into the new app**;
  nothing migrates automatically, and there is no server-side state.
