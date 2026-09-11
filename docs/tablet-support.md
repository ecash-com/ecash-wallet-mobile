# Tablet support — a plan for later

**Status:** deliberately deferred 2026-09-10. `TARGETED_DEVICE_FAMILY = 1` (iPhone only).
**Written:** 2026-09-10 · against 1.0.0 (19)

## Why it's deferred, and why that's cheap to undo

We set the Xcode project to iPhone-only right before the first App Store submission. Declaring iPad
support obliges us to a **separate 13" screenshot set** (App Store Connect scales *within* a device
family but never across one, so the iPhone shots don't carry over) and puts the app in front of a
reviewer running it on an iPad — where nothing has ever been laid out.

**Re-enabling is one line**, and the direction matters:

- **iPhone-only → iPad later is free.** Flip `TARGETED_DEVICE_FAMILY` back to `"1,2"` in
  `Darwin/ECashWalletMobile.xcodeproj/project.pbxproj` (two sites: Debug and Release), add the iPad
  screenshot set, ship.
- **iPad → iPhone-only after shipping is NOT.** Removing iPad support once App Store iPad users have
  the app takes it away from them, which Apple treats as a downgrade. We only ever put iPad-capable
  builds (≤18) on TestFlight, never the store, so nothing is stranded. Keeping it that way is the
  whole reason to flip *now* rather than after launch.

**Android needs the same decision, but takes it elsewhere (CORRECTED 2026-09-11).** An AAB has no
device-family concept, so there is nothing to set at build time — but that does **not** mean Play is
indifferent. Play Console asks for **tablet screenshots** because the bundle advertises the tablet
screen buckets by default:

```
supports-screens: 'small' 'normal' 'large' 'xlarge'     # aapt2 dump badging, build 19
```

Nothing in `AndroidManifest.xml` declares that — `large`/`xlarge` are Android's implied default. The
lever is therefore in the **Play Console, not the build**: *Reach and devices → Form factors* (back out
of the tablet form factor, and its screenshot requirement goes with it) or *Reach and devices → Device
catalog → Device exclusion rules* (exclude by screen size = `large` + `xlarge`). On some Console
versions the exclusion rules sit under *Release → Setup → Advanced settings* instead. It is an
**app-level** setting, not per-release, and fully reversible.

Two manifest-level alternatives, both rejected: `<supports-screens android:largeScreens="false" …>` is
deprecated and modern Android largely ignores it for filtering, so you would likely get a restriction
you did not want and not the one you did; and
`<uses-feature android:name="android.hardware.telephony" android:required="true"/>` works but is
semantically false for a wallet and excludes Wi-Fi-only tablets along with devices we want.

Worth noting the asymmetry in cost: Android tablet screenshots are *cheap* to produce compared with
iPad's, because the app is portrait-locked (`android:screenOrientation="portrait"`) and Compose
reflows — booting a tablet AVD and re-shooting the same seven shots is about half an hour with no
layout work. They would simply look like an inflated phone app, for the reasons below. Restricting to
phones is the choice consistent with the iPad decision; revisit both together once the width cap lands.

## What the code actually looks like today

Measured, not assumed (2026-09-10):

| | count |
|---|---|
| `.frame(maxWidth: .infinity)` — stretch to fill | **19** |
| `maxWidth: <number>` — content width caps | **0** |
| `horizontalSizeClass` / size-class awareness | **0** |

So the app has **no large-canvas adaptation of any kind**. Every element that stretches, stretches the
whole way. On a 13" iPad that means a "Create new wallet" button roughly 2000pt wide, a balance
marooned in the centre of an enormous field, and list rows whose text sits at one end of a very long
line. Nothing *breaks* — it's all `VStack`s and `List`s, which reflow fine — it just looks like a phone
app inflated, which is exactly what a reviewer means by "not designed for iPad".

The shell is a stock `TabView` with no `NavigationStack` at the root (`MainTabView` — Home presents
sheets and covers rather than pushing). That's good news: there's no navigation architecture to unpick,
because there's barely any.

## The work, in order of value

**1. Cap content width — this is ~80% of the result for ~5% of the effort.**

One modifier applied at each screen's root: constrain content to a readable measure (~500–600pt) and
centre it. A phone is narrower than the cap, so it's unaffected — the change is invisible on iPhone and
transforms the iPad. Do this before anything else and re-evaluate; it may well be enough to ship.

Best done as a single `Theme`-level modifier (e.g. `readableWidth()`) rather than 19 edits, so there's
one place to tune the number and one place to make it size-class-aware later.

**2. Audit the 19 stretch sites.** Some *should* still fill (list rows, dividers); others (primary
buttons, the amount keypad, the entropy pad) want the cap. This is judgement per site, not mechanical.

**3. The entropy pad specifically.** `EntropyGridView` is a 12×8 grid sized to the available space —
it's the one screen where more canvas is arguably *better* (a bigger swipe surface genuinely collects
more input), but a grid stretched across 13" makes each cell enormous and the swipe adjacency model
assumes cells are roughly finger-sized. Decide deliberately: cap it, or re-derive the grid density from
the available width. **Do not let it silently scale** — the accumulator's bit-rate assumptions
(`bitsPerMidDragTransition`) are calibrated to how many cells a stroke crosses.

**4. Only then consider a split layout.** `NavigationSplitView` (wallet list ⟷ detail) is the genuinely
iPad-native shape, and it's the expensive one — it changes navigation structure, not just metrics. Very
likely not worth it for a wallet whose primary screen is a single balance.

**5. Landscape.** Currently untested. A width cap makes landscape mostly work by default, which is
another reason to do step 1 first.

## Skip / cross-platform notes

- `horizontalSizeClass` is a SwiftUI concept. Before relying on it in shared code, check it transpiles
  — the Compose equivalent is a `WindowSizeClass`, and Skip's mapping needs verifying. A plain
  `maxWidth` cap needs no size-class knowledge at all, which is a further argument for step 1.
- Android tablet layout comes free with the same width cap: it's the identical problem (a phone UI on a
  large canvas) and the identical fix.
- Test on **both** a 13" iPad simulator and a large Android emulator. `Medium_Phone_API_36.1` won't
  show any of this.

## When it's worth doing

Not before the first release. The honest trigger is either (a) tablet users asking, or (b) wanting the
iPad listing for reach. Step 1 alone is maybe half a day and would make an iPad build presentable; the
full treatment including a split layout is a week and probably never justified for this app.

When we do pick it up: flip the flag, do step 1, then shoot the 13" iPad set (2064 × 2752) following
`docs/store-screenshots.md` — same seven shots, same burner-wallet prep.
