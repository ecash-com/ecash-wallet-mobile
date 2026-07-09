# Org migration — Layer Two Labs → eCash

> Checklist for moving the app's **Apple Developer org** and **Google Play developer account** from
> Layer Two Labs to a new **eCash** org. Planned; not started (written 2026-07-09).
>
> **Decision already made:** we are doing a **clean start in the new orgs, not an account transfer.**
> Existing **TestFlight** (iOS) and **sideloaded APK** (Android) users will get a *separate* app and
> will NOT auto-update to the new one. Jake: "it's not that many." See §1 for why, and §7 for what
> breaks.

---

## 0. Current identity (what's tied to the orgs today)

| Thing | Current value | Where it lives |
|---|---|---|
| iOS bundle id + Android applicationId | `com.layertwolabs.mobile.ecashwallet` | `Skip.env` → `PRODUCT_BUNDLE_IDENTIFIER` (shared by both; `ANDROID_APPLICATION_ID` override is commented out) |
| Android entry-point package | `ecash.wallet.mobile` | `Android/app/src/main/kotlin/Main.kt` (`package` + SkipLogger subsystem) — separate from applicationId |
| Apple Team ID (`DEVELOPMENT_TEAM`) | `6AXPP357T2` | `Darwin/ECashWalletMobile.xcodeproj/project.pbxproj` (2×); gitignored `Darwin/DeveloperSettings.xcconfig` → `Darwin/fastlane/AppStore.xcconfig` |
| iOS signing / upload auth | ASC API key (`key_id`/`issuer_id`/`.p8`) | `Darwin/fastlane/apikey.json` (gitignored; template `apikey.json.example`) |
| Android upload keystore | `keystore.jks`, alias `upload`, `CN=Layer Two Labs` | `Android/app/keystore.jks` + `Android/app/keystore.properties` (both gitignored) |
| Firebase / FCM push | project `ecash-wallet-3b5c9`, sender/`project_number` `578435445011`, Android app id `1:578435445011:android:…`, APNs key `N3U7CSY8YT`, Apple team `6AXPP357T2` | `Android/app/google-services.json` + `Darwin/GoogleService-Info.plist` (both gitignored) |
| CI signing secrets | `GOOGLE_SERVICES_JSON_BASE64`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PROPERTIES_BASE64` | GitHub Actions repo secrets (`.github/workflows/android-debug-apk.yml`) |

**Android reality:** distribution today is **sideloaded APKs only** — the Play Console app was never
created (`docs/release.md` §2). So the "separate app" cost is basically **iOS-only** (TestFlight has
live users); on Android there's no Play listing to strand, just ad-hoc APK testers who reinstall.

---

## 1. Decisions to lock before starting

1. **Transfer vs. clean start** — *decided: clean start.* (Apple **App Transfer** and Google Play
   **app transfer** *would* preserve the bundle id, users, reviews, and TestFlight — but they keep the
   *same* identifiers, and we want a rebrand anyway. Transfer is the fallback if preserving iOS
   TestFlight users ever becomes important.)
2. **Do we rebrand the identifiers?** Almost certainly **yes** — a new Apple/Google account **cannot
   reuse** `com.layertwolabs.mobile.ecashwallet` while the old app still exists (bundle id /
   applicationId are globally unique per store). Pick the new reverse-domain now, e.g.
   **`com.ecash.wallet`** (confirm the eCash-owned domain). This changes `PRODUCT_BUNDLE_IDENTIFIER`
   in `Skip.env` (drives both platforms).
   - The Android entry-point package `ecash.wallet.mobile` (Main.kt) already reads "ecash" and is
     independent of applicationId — decide whether to also rename it for consistency (bigger blast
     radius: `namespace`, MainActivity path referenced by `docs/qr-scanning-and-adb-launch.md`, etc.).
3. **New org legal entity / D-U-N-S** — Apple Developer (Organization) enrollment needs a **D-U-N-S
   number** for the eCash entity; can take days. Start this first — it gates everything on iOS.
4. **App display name** — unchanged (eCash.com Wallet / launcher "eCash.com"). Only the *publisher*
   org name changes in the store listings.

---

## 2. Apple (App Store Connect / TestFlight)

- [ ] Enroll the **eCash org** in the Apple Developer Program (needs D-U-N-S; §1.3). Get the new **Team ID**.
- [ ] Create a new **App Store Connect app record** with the new bundle id (§1.2).
- [ ] Register the new **bundle identifier** under the new team (Certificates, IDs & Profiles).
- [ ] Generate a new **App Store Connect API key** (Users & Access → Integrations, role App Manager) →
      replace `Darwin/fastlane/apikey.json` (`key_id`, `issuer_id`, inline `.p8`).
- [ ] New **distribution certificate** + provisioning profile (fastlane can create via the API key;
      uncomment `get_certificates(...)` in the Fastfile lane on first run if it reports one missing).
- [ ] Update `DEVELOPMENT_TEAM` `6AXPP357T2` → new team id in gitignored `Darwin/DeveloperSettings.xcconfig`
      (and confirm `Darwin/fastlane/AppStore.xcconfig` pulls it). Also the two hardcoded
      `DEVELOPMENT_TEAM = 6AXPP357T2` lines in `Darwin/ECashWalletMobile.xcodeproj/project.pbxproj`.
- [ ] Update `Darwin/fastlane/Appfile` (`app_identifier`, `apple_id`/`team_id` if set).
- [ ] Re-do App Store listing metadata under the new org (`Darwin/fastlane/metadata/…` is reusable).
- [ ] First `fastlane beta` upload → new TestFlight. Re-invite testers (they install a NEW app).

## 3. Google (Play)

> Play app was never created under LTL, so there's nothing to transfer — just create it fresh in the
> eCash account. If a Play app *had* existed, prefer Play's built-in **app transfer** over recreating.

- [ ] Create/verify the **eCash Google Play developer account** (one-time $25; identity verification
      can take days).
- [ ] Keep the **existing upload keystore** (`keystore.jks`) **or** mint a new one — the keystore is
      account-independent, but the **applicationId change** already forces a separate Play listing, so
      either works. If minting new, update `keystore.properties` + the two CI secrets (§6). (Cosmetic:
      `CN=Layer Two Labs` in the cert is baked in and not worth re-issuing for.)
- [ ] Create the Play app with the new applicationId, complete the App Content / data-safety sections.
- [ ] (When Play automation is wired) create the **service-account JSON** under the new org for
      fastlane `supply`; update `Android/fastlane/Appfile` (`package_name`, `json_key_file`).

## 4. Firebase / push notifications (FCM + APNs)

> Firebase project `ecash-wallet-3b5c9` is under the LTL Google identity and its config is keyed to the
> **old** bundle id / applicationId. Changing identifiers → the config files must be regenerated.

- [ ] Decide: keep the existing Firebase project (just add new iOS/Android apps for the new bundle id)
      **or** create a fresh Firebase project under the eCash Google account. Fresh is cleaner for a full
      org move; keeping it works if the eCash team gets access to the existing project.
- [ ] Add the new **Android app** (new applicationId) → download new `google-services.json`.
- [ ] Add the new **iOS app** (new bundle id) → download new `GoogleService-Info.plist`.
- [ ] Upload a new **APNs auth key** for the new Apple team (old key `N3U7CSY8YT` is under team
      `6AXPP357T2`) in Firebase → Cloud Messaging.
- [ ] Replace the gitignored `Android/app/google-services.json` + `Darwin/GoogleService-Info.plist`,
      and refresh the `GOOGLE_SERVICES_JSON_BASE64` CI secret (§6).
- [ ] Sanity-check push end-to-end on both platforms (see `notifications` memory / `docs/notifications.md`).

## 5. Repo / code changes

- [ ] `Skip.env` → `PRODUCT_BUNDLE_IDENTIFIER` (and uncomment/set `ANDROID_APPLICATION_ID` only if the
      two must differ). This single change drives Info.plist + AndroidManifest for both platforms.
- [ ] (If renaming the Android package, §1.2) `Android/app/src/main/kotlin/Main.kt` `package` +
      SkipLogger subsystem, `namespace` in `build.gradle.kts`, and the MainActivity launch path noted in
      the `qr-scanning-and-adb-launch` memory / any `adb` scripts.
- [ ] `DEVELOPMENT_TEAM` everywhere (see §2).
- [ ] R8 keep-rules / bridge package names in `Android/app/proguard-rules.pro` reference
      `wallet.service.**` (the WalletService bridge package, *not* the applicationId) — **unaffected** by
      an applicationId change; only touch these if the WalletService Kotlin package is renamed.
- [ ] Bump `MARKETING_VERSION` / reset `CURRENT_PROJECT_VERSION` as appropriate for the new listings.
- [ ] Update `docs/release.md` (bundle id, team, status) once the new orgs are live.

## 6. CI (GitHub Actions)

- [ ] Refresh repo secrets: `GOOGLE_SERVICES_JSON_BASE64` (new `google-services.json`), and — only if a
      new Android keystore is minted — `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEYSTORE_PROPERTIES_BASE64`.
- [ ] iOS signing secrets/API key if/when iOS is added to CI (currently local fastlane only).

## 7. What breaks for existing users (accepted)

- **iOS TestFlight testers** — the new bundle id is a **new app**; the old build does not update. Testers
  must install the new TestFlight invite. The old app keeps working until its build expires but is a dead end.
- **Android APK testers** — a new applicationId (or new signing key) installs **alongside** the old app,
  not in place. They keep the old one until they manually switch.
- **Wallets are NOT lost on the device**, but they are **not migrated** either: keys live in the OS
  secure store keyed by the *app's* identity (iOS Keychain / Android Keystore), so the new app starts
  empty. **Users must back up their seed and restore into the new app.** ⇒ Communicate this loudly
  before/at cutover (in-app notice + release notes) so nobody loses funds by deleting the old app.
- No server-side account state to migrate (wallet is self-custodial; CoinNews identity is derived from
  the seed, so it follows a restored wallet).

---

## Quick reference — grep targets

```
Skip.env                                   # PRODUCT_BUNDLE_IDENTIFIER, ANDROID_PACKAGE_NAME
Darwin/DeveloperSettings.xcconfig          # DEVELOPMENT_TEAM (gitignored)
Darwin/ECashWalletMobile.xcodeproj/project.pbxproj   # DEVELOPMENT_TEAM (2×)
Darwin/fastlane/{Appfile,apikey.json}      # ASC identity + API key
Android/app/{keystore.jks,keystore.properties}       # upload signing (gitignored)
Android/app/google-services.json           # Firebase Android (gitignored)
Darwin/GoogleService-Info.plist            # Firebase iOS (gitignored)
Android/fastlane/Appfile                   # Play package + service account
.github/workflows/android-debug-apk.yml    # CI secrets
```
