# Store screenshots — shot list

**For:** App Store Connect + Google Play · **Written:** 2026-09-09 · **App version:** 0.2.2 (17)

The copy is done (`Darwin/fastlane/metadata/`, `Android/fastlane/metadata/`). This is the shooting
script for the images, which are the last thing standing between us and a submittable listing.

---

## 0. Decide this first: are we shipping an iPad app?

`Darwin/ECashWalletMobile.xcodeproj` sets `TARGETED_DEVICE_FAMILY = "1,2"` — iPhone **and** iPad. That
has a cost at submission: App Store Connect requires a **separate 13" iPad screenshot set**, and Apple
review will run the app on an iPad and reject layout that breaks there. Nothing in this project has
ever been laid out or tested for iPad.

Two ways out, and it's worth picking before shooting rather than after:

- **Set `TARGETED_DEVICE_FAMILY = 1`** (iPhone only). One screenshot set, one form factor to defend.
  Almost certainly right for now; an iPad build can come back later as a deliberate piece of work.
- **Keep "1,2"** and budget for shooting every shot below twice, plus an iPad layout pass first.

Everything below assumes iPhone-only.

---

## 1. One size covers everything: 1320 × 2868

**Shoot every shot once, at 1320 × 2868 (the 6.9" iPhone), and that single set serves the App Store.**

Apple used to demand a set per display size. It no longer does: upload **only the 6.9" set** and App
Store Connect scales it down for every smaller iPhone automatically. 6.9" is therefore the largest and
the *only* iPhone size you have to produce — and because it's the biggest, everything derived from it
is a downscale, which stays sharp.

Play is far more permissive than Apple — it has no per-device sets at all, just 2–8 phone images with
each side between 320px and 3840px. So **Apple's requirement is the binding one**; satisfy it and Play
is satisfied by anything reasonable.

| | App Store | Play |
|---|---|---|
| Count | 3–10 (first 3 show in search) | 2–8 (first 3 show on the listing) |
| Size | **1320 × 2868**, and nothing else | anything 320–3840px per side |
| Also required | — | **Feature graphic 1024 × 500** and **icon 512 × 512** |

Shoot on **iPhone 17 Pro Max** or **16 Pro Max** — `simctl` writes 1320 × 2868 natively, so there's no
resizing step and no resampling blur.

> **Don't confuse this with 1290 × 2796.** That is the 6.7" size (iPhone 14/15 Pro Max). App Store
> Connect accepts *either* in the 6.9" slot, but the 17 Pro Max captures at 1320 × 2868 — verified on
> the booted sim — so take what the device gives you and never resize.

**Two things that size does not cover:**

- **iPad**, if we keep `TARGETED_DEVICE_FAMILY = "1,2"` — that needs its own 13" set at 2064 × 2752.
  This is the strongest practical argument for §0's iPhone-only option: it's the difference between one
  set and two.
- **The Play feature graphic** (1024 × 500), which is a landscape *design* — logo, wordmark, one line on
  a `bg0` field — not a capture of anything. It has no App Store counterpart and Play won't publish
  without it.

**Play gets its own captures (DECIDED 2026-09-09).** Reusing the iOS set would mean Android users
browse a listing showing an iOS status bar and iOS-styled controls, while Skip renders genuinely native
Compose on the device — a real mismatch, and the whole point of building on Skip is that the Android
app *isn't* a port. So the seven shots below get taken twice: once on the 17 Pro Max simulator, once on
the Saga.

The shot list is identical for both. What changes is only what the platform itself renders — Material
controls, the Android status bar, the system back affordance — which is exactly the difference worth
showing. Play's own size rules are permissive (320–3840px a side), so the Saga's native 1080 × 2400 is
fine as captured; no resizing.

## 2. Before the first shot

**Build a burner wallet, and treat it as disposable.**

- Create a fresh wallet on **eCash** — the network the app exists for, and it keeps real BTC balances
  out of the frame.
- Fund it from the faucet (`FaucetSheet`) and make **4–6 transactions**: a couple in, a couple out, one
  self-send so a "Sent to yourself" row appears. History that is one row deep reads as a demo.
- Aim for a balance that looks like a person's, not a test's — something around **0.0247 ECX**.
  `0.00000001` and `1,000` both read as fake.
- Name it something plausible — "Spending" — not "test1".

> **This wallet's recovery phrase is going in a public screenshot (shot 4). Delete the wallet when the
> shoot is done and never send real coins to it.** Nothing else in the shoot needs a real secret.

**Then set the frame up:**

```sh
D=$(xcrun simctl list devices booted | grep -oE '[0-9A-Fa-f-]{36}' | head -1)

# Dark appearance — the design is dark-first
xcrun simctl ui "$D" appearance dark

# Clean, Apple-convention status bar. Survives until the sim reboots.
xcrun simctl status_bar "$D" override \
  --time "9:41" --batteryState discharging --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
  --dataNetwork wifi
```

Two things learned setting this up, both of which cost a re-shoot if you get them wrong:

- **`discharging`, not `charged`.** `charged` draws a *green battery with a charging bolt*; `discharging`
  at level 100 gives the clean white full battery Apple's own marketing uses. (`unplugged` isn't a valid
  value — the three are `charging`, `charged`, `discharging`.)
- **Give the override a second before capturing.** Screenshotting in the same breath as setting it
  catches the old status bar; the first capture here came out with the bolt still showing.

**Android — the same frame, on the emulator.** Use the **Medium Phone API 36.1** AVD: 1080 × 2400,
arm64, Android 16, which is Play's native phone size as captured with no resizing. (`emulator-34-medium_phone`
is the same resolution on Android 14 if you need an older look.)

```sh
A="$HOME/Library/Android/sdk/platform-tools/adb"
E="$HOME/Library/Android/sdk/emulator/emulator"
"$E" -avd Medium_Phone_API_36.1 &          # then wait for sys.boot_completed

"$A" shell cmd uimode night yes            # dark, to match the iOS set

# Demo mode is Android's answer to simctl status_bar — it must be allowed first.
"$A" shell settings put global sysui_demo_allowed 1
D() { "$A" shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
D enter
D clock -e hhmm 0941
D battery -e level 100 -e plugged false
D network -e wifi show -e level 4
D network -e mobile show -e datatype none -e level 4
D notifications -e visible false           # clears the debris of notification icons
```

`D exit` returns the status bar to normal. Demo mode does **not** survive a reboot, and neither does
`sysui_demo_allowed` on some images — re-run the block if the clock stops reading 9:41.

**What demo mode does and doesn't cover on Android 16** (measured on this AVD, not assumed):

- **Works:** clock at 9:41, battery full with no charging bolt, wifi at full bars.
- **Doesn't:** `notifications -e visible false` no longer clears the status bar's *left* side. This AVD
  ships two persistent Safety Center notifications — a ⓘ and a shield ("no screen lock", "identity
  check" — visible via `adb shell cmd notification list`) — and they sit in every capture.
- The mobile-signal icon also stays hidden regardless of the `network -e mobile` command. That reads as
  a wifi-only phone, which is fine and arguably more natural than full LTE bars.

If the two left-hand icons bother you, setting an actual screen lock on the AVD clears the first of
them. Otherwise accept them: they're small, they're on the far left, and Play has no status-bar
convention the way Apple's marketing does. **Don't crop them out** — Play wants the full frame, and a
cropped image is more conspicuous than two grey glyphs.

And while shooting:

- **Stay in dark mode for the whole set** (the command above sets it). The design is dark-first, and a
  set that mixes appearances looks accidental rather than considered.
- **Same wallet, same balance in every shot.** A balance that changes between images is the kind of
  detail nobody can name but everybody notices.
- **No keyboard visible** unless the shot is about typing.
- Check the status bar is still overridden if the sim has rebooted — the override doesn't survive one.

---

## 3. The shots, in listing order

Order is the pitch. Shots 1–3 are what a browsing user actually sees, so they carry it: **what nobody
else does**, **that it's a real wallet**, **that it's safe**. The rest reward a swipe.

**Seven required, one optional.** Seven is comfortably above both stores' minimums and every one of
them earns its place — which matters more than filling the slots.

### 1 — Entropy pad, mid-swipe · *"You generate the randomness"*

`EntropyInputScreen`. Create wallet → Continue → Swipe.

Our one genuinely unique screen, so it leads. Swipe for **15–20 seconds before capturing** so the shot
shows the feature working, not sitting empty:

- progress bar **filled or nearly** — a bar at 5% says "this will be tedious"
- the input field carrying several lines of accumulated characters
- the live 12-word preview visible underneath, so the connection between swipe and words is legible
- capture **with a finger still down** if you can, so the pad reads as interactive

### 2 — Wallet home · *"Your keys, on your device"*

`WalletHomeScreen`, the burner wallet.

Balance, the **eCash network chip**, Send/Receive, and two or three history rows below the fold. This
is the "is this a real wallet or a toy" shot — it must look calm and finished. No sync spinner, no
"not backed up" banner (complete the backup on the burner first).

### 3 — Send review · *"Nothing is signed until you say so"*

`SendScreen` at `.reviewing`. Send → address → amount → Normal fee → Review.

Recipient, amount, fee, **and network** on one screen. Everything our security pitch claims is visible
here at once, and it is the screen a sceptical user most wants to see before installing. Use a
recipient address that isn't one of ours.

### 4 — Words derived from the swipe · *"Twelve words, from your own hand"*

`EntropySeedPreviewScreen` — the step after the pad.

Closes the loop shot 1 opened: the swipe produced *these* words. Burner phrase only (see §2).

*If showing a phrase at all feels wrong, swap in `BackupFlowView`'s verify step instead — it makes the
same point with the words masked. Slightly weaker as an image, zero risk of a user misreading it.*

### 5 — Wallet switcher · *"As many wallets as you need"*

`WalletManagerSheet`, with **three wallets across two networks** — the burner on eCash, one on Bitcoin,
one on Signet, each showing its coloured chip.

Carries multi-wallet and multi-network in one frame, and the chips make the safety argument visually
without a word of copy. Give the Bitcoin wallet a zero or near-zero balance.

### 6 — Receive · *"Get paid in seconds"*

`ReceiveScreen`. QR, address, network label, copy/share. Note this screen has no nav bar by
convention — that's correct, not a missing element.

### 7 — Activity · *"Every payment, accounted for"*

`ActivityScreen`, scrolled to the top, showing mixed sent/received/self-send rows with confirmations.
This is where the 4–6 transactions from §2 pay off.

### 8 (optional) — Settings · *"Tuned the way you want it"*

`SettingsScreen`, showing the "Require unlock" toggle and the per-network endpoint rows. Speaks to the
audience that reads settings before installing — the same people most likely to care that this wallet
is self-custodial. The App Store allows 10 images and Play 8, so there's room for it either way.

*Split coins was considered for this slot and cut: the screen only appears when
`splitSummary.needsSplitCount > 0`, so it needs a pre-fork UTXO on the burner wallet to show at all,
and a contrived version of it would be the weakest image in the set.*

## 4. Capturing and filing

```sh
# iOS — writes 1290 x 2796 with no resizing
xcrun simctl io booted screenshot ~/Desktop/shots/01_entropy.png

# Android — Saga or emulator
adb exec-out screencap -p > ~/Desktop/shots/01_entropy.png
```

`fastlane deliver` and `supply` upload in **alphabetical order**, so the `01_`…`07_` prefixes are what
fix the listing order. Keep the same numbering on both platforms.

```
Darwin/fastlane/screenshots/en-US/                                   # 01_….png … 07_….png
Android/fastlane/metadata/android/en-US/images/phoneScreenshots/     # 01_….png … 07_….png
Android/fastlane/metadata/android/en-US/images/featureGraphic.png    # 1024 x 500, designed
Android/fastlane/metadata/android/en-US/images/icon.png              # 512 x 512
```

Neither directory exists yet — `mkdir -p` both.

## 5. Raw captures, or framed?

Raw device captures are entirely acceptable and cost nothing extra. Framed shots — the caption headline
above a device bezel — convert better, because captions carry the pitch to someone who never reads the
description. **Shoot the raw captures either way**; framing is a layer applied on top and can follow
later without re-shooting. The captions above are written to be used as those headlines.

## 6. Localisation

Metadata is en-US only; the app ships **en, es, fr, ja, zh-Hans**. Localised listings are optional and
a separate piece of work — but note it's the *screenshots* that dominate that effort, since each locale
wants its own set with the UI in that language. If we localise the listings later, that's the reason to
have automated the capture first.
