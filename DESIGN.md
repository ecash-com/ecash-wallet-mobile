# eCash.com Wallet — Design Spec (DESIGN.md)

> The visual language of the app **as built** — cross-platform via Skip (SwiftUI on iOS → Jetpack
> Compose on Android). This supersedes the original iOS-first draft: colors are SwiftUI-native
> (no UIKit), icons are Material Symbols (no SF Symbols), and the chrome reflects the real screens.
>
> `Theme` (in `Sources/ECashWalletMobile/DesignSystem/`) is the single source of truth — every view
> references `Theme.*`; there is no raw hex, font name, spacing number, or radius anywhere else.
> On any platform-mechanics conflict, **CLAUDE.md wins** (§8 carve-outs).
>
> Voice: dark-first, self-custody seriousness, one warm amber accent. Money is precise (mono,
> tabular figures, full 8-dp), copy is calm, and a non-mainnet network is **never** mistakable for
> mainnet.

---

## ★ Core principle — native-first, theme don't rebuild

**Lean on stock SwiftUI chrome so it renders as native SwiftUI on iOS and native Compose/Material on
Android. Brand only through `.tint`, the `Theme` fonts/colors, and a small set of domain views.**
Confirm every chrome element is in Skip's supported subset before relying on it.

- **Tabs** → stock `TabView` + `.tabItem` (native bottom bar / Material navigation). The selected
  tab uses the **filled** Material Symbol variant, unselected the outlined one (swapped on selection,
  both platforms). No custom bar,
  no floating FAB, no search-role tab. (iOS-26 Liquid Glass is *not* used — it has no Compose
  mapping; if ever added it must be `#if os(iOS)`-gated and off the shared path.)
- **Navigation** → `NavigationStack` + `.navigationTitle` + `.toolbar` for multi-step flows.
- **Lists / settings** → `List` + `.groupedListStyle()`, `Section`, `Toggle`, `Picker`,
  `NavigationLink` (system supplies chevrons, dividers, insets).
- **Sheets** → `.sheet` (system grabber + scrim). Simple read-only sheets are **chromeless**
  (no nav bar) and dismissed by swipe — see §5.
- **Brand globally**: `.tint(Theme.Colors.accent)` once at the root; appearance via
  `.preferredColorScheme` from the Settings toggle.

The domain views that have no system equivalent live in `Components/`: `WalletButton`,
`NetworkBadge`, `TxRow`, `TxDetailSheet`, `WalletSwitcherPill`, `Keypad`, `QRCodeView`,
`PrivacyCover`, `Logo`, `PlaceholderScreen`, `ToolbarButtons`.

---

## 0. Setup

**Fonts — two families, both OFL/free** (bundled in `Resources/Fonts` for iOS **and**
`Android/app/src/main/res/font` for Android; registered in `FontRegistration.swift`):
- **Space Grotesk** — display, balances, headings (Regular / Medium / SemiBold / Bold).
- **JetBrains Mono** — body, labels, addresses, amounts, seeds (Regular / Medium / SemiBold).

(IBM Plex from the original draft was dropped — two fonts only.) Every piece of text uses these via
`.textStyle(...)`; no system fonts anywhere. Fonts fail *silently* if a face is missing — verify by
screenshot on both platforms.

**Icons — Material Symbols `.symbolset`, never SF Symbols** (`Image(systemName:)` does not transpile
to Android). See §4.

**Colors — SwiftUI-native asset catalog** (`Resources/Module.xcassets`), Any (light) + Dark
appearances. No UIKit `UIColor { traitCollection }`. Skip maps the catalog to a Compose
`ColorScheme`, so light/dark works on both with no view-level branching. Colorset components must be
**float 0–1**, not hex (hex silently renders black on Android).

---

## 1. Color tokens

Dark is the default; every surface/text token is **adaptive**. Reference only the semantic names
below (`Theme.Colors.*`); the resolved values live in the asset catalog (and the full hex table is in
CLAUDE.md §8).

| Token | Role |
|---|---|
| `bg0` | app background (base) |
| `bg1` | elevated surface (cards) |
| `bg2` | card / input fill |
| `border` | hairlines, dividers |
| `text0` / `text1` / `text2` | primary / secondary / faint |
| `accent` | **the** primary-action color — real eCash amber **`#E8A84A`** (rgb 232,168,74) |
| `accentText` | text/icon on accent |
| `accentHover` | pressed/hover accent |
| `accentTint` | ~12% accent wash behind chips |
| `brandAmber` | the logo mark color (same amber family as `accent`) |
| `positive` / `negative` / `warning` | received·confirmed / sent·error·destructive / unconfirmed·caution |
| `positiveTint` / `negativeTint` / `warningTint` | ~12% washes behind status chips |
| `netTestnet` / `netTestnetText` | high-contrast **violet** testnet chip (impossible to confuse with accent) |
| `netMainnet` / `netMainnetText` | **Bitcoin orange** (`#F7931A`) mainnet chip + dark text |
| `netEcash` / `netEcashTest` | reserved for the eCash fork (placeholder amber/teal) |

**Status (real vs. placeholder):** `accent`/`accentTint`/`accentHover` are the **real brand amber**.
The `bg*`/`text*` families are still the placeholder palette pending the ecash.com token dump
(CLAUDE.md §14).

**Rules**
- App background `bg0`; cards/inputs sit on `bg1`/`bg2` separated by a 1px `border` hairline — prefer
  the surface-step + hairline over heavy shadows.
- `accent` is the **single** action color (buttons, active tab, links, focus). Don't add accents.
- Status colors are reserved for meaning only; their tints back badges/icon chips.
- **Every network shows a chip, colored per network** — `NetworkBadge` always renders, resolving its
  color from `NetworkChipStyle` (a code-level, non-user-facing config): testnets violet (`netTestnet`),
  **Bitcoin mainnet orange** (`netMainnet`, `#F7931A`). This is a safety feature (CLAUDE.md §6), not
  decoration. Each network is an independent color knob (future eCash → `netEcash`/`netEcashTest`).

---

## 2. Typography

Two helpers in `Typography.swift`: `Font.grotesk(size, weight)` (Space Grotesk) and
`Font.jbMono(size, weight)` (JetBrains Mono). Headings are Grotesk; everything else is JetBrains
Mono. Apply via `.textStyle(.h1)` etc. so font + tracking + case all come from one place.

| Token | Resolves to | Usage |
|---|---|---|
| `display` | `grotesk(40, .bold)`, tracking −0.8 | hero balance |
| `h1` | `grotesk(28, .semibold)`, tracking −0.5 | screen titles |
| `h2` | `grotesk(22, .semibold)` | section heads |
| `h3` | `grotesk(18, .semibold)` | row titles |
| `button` | `jbMono(16, .semibold)` | button labels |
| `body` | `jbMono(15, .regular)` | default copy |
| `sm` | `jbMono(13, .regular)` | secondary UI |
| `xs` | `jbMono(12, .medium)` | captions |
| `overline` | `jbMono(11, .semibold)`, tracking 0.9, UPPERCASE | labels / section overlines (`text2`) |
| `mono` | `jbMono(14, .regular)` | addresses, txids, seeds |

**Numerals.** JetBrains Mono is fixed-width already; for Grotesk numbers add `.monospacedDigit()` so
balances don't jitter. Show full **8-dp** precision in detail views; fiat estimates are a `$0.00`
placeholder until the rate service lands.

```swift
Text(app.balance.formattedCoin()).font(.jbMono(36, .medium))   // home balance
Text("Received", bundle: .module, comment: "…").textStyle(.h3)
```

---

## 3. Spacing, radius, motion

From `Theme` (`Space` / `Radius` / `Motion`):

- **Spacing** — 4-pt grid: `x1`=4 … `x6`=24, `x8`=32, `x10`=40, `x12`=48. `gutter`=20 (screen side
  padding outside a `List`), `tap`=44 (min hit target).
- **Radius** — `xs`=6, `sm`=10, **`md`=14 (default card/input)**, `lg`=20 (grouped cards/sheets),
  `xl`=28, `pill`=999.
- **Motion** — `fast`=0.12, `base`=0.20, `slow`=0.32; `Motion.ease` (easeOut base), `Motion.press`
  (easeOut fast). Quick, no bounce; honor Reduce Motion at call sites (drop scales/spinners to a
  fade). Most separation comes from the hairline, not shadow.

---

## 4. Iconography — Material Symbols (`.symbolset`)

**Never `Image(systemName:)` / SF Symbols** — they don't transpile to Android. Each glyph is a
Material Symbols `.symbolset` in `Resources/Icons.xcassets`, referenced through the typed `Icon`
vocabulary and the `Image(icon:)` helper (renders identically on both platforms):

```swift
Image(icon: Icon.send).resizable().scaledToFit().frame(width: 16, height: 16)
```

| Concept | `Icon.*` | Material Symbol |
|---|---|---|
| wallet (tab) | `wallet` | `account_balance_wallet` |
| activity (tab) | `activity` | `format_list_bulleted` |
| settings | `settings` | `settings` |
| send / outgoing | `send` | `north_east` |
| receive / incoming | `receive` | `south_west` |
| swap · buy | `swap` · `buy` | `swap_horiz` · `credit_card` |
| scan · qr | `scan` · `qr` | `qr_code_scanner` · `qr_code` |
| copy · share · refresh | `copy` · `share` · `refresh` | `content_copy` · `share` · `refresh` |
| check · close · add · more | `check` · `close` · `add` · `more` | `check` · `close` · `add` · `more_horiz` |
| back · disclosure · expand | `back` · `disclosure` · `expand` | `chevron_left` · `chevron_right` · `expand_more` |
| pending · caution · info | `pending` · `caution` · `info` | `schedule` · `warning` · `info` |
| backup · key · lock | `backup` · `key` · `lock` | `verified_user` · `key` · `lock` |
| reveal · hide | `reveal` · `hide` | `visibility` · `visibility_off` |
| remove · rename · import | `remove` · `rename` · `importWallet` | `delete` · `edit` · `download` |
| dark · light · search · backspace | `dark` · `light` · `search` · `backspace` | `dark_mode` · `light_mode` · `search` · `backspace` |

Direction/status glyphs sit in a tinted circle (`positiveTint` for received, `bg2` for sent). **No
emoji.** Unicode allowed: `·` separator, `…` truncation, `−`/`+` signs.

---

## 5. Components (as built)

Native chrome (§7) does the heavy lifting; these are the domain views in `Components/`.

- **`WalletButton`** — full-width rounded-rect (`Radius.md`) button; `primary` = filled `accent`,
  `secondary` = `bg2` + hairline. **Custom, not `.borderedProminent`/`.glass`** — native button
  styles render as full pills/capsules on Android. Title is a `LocalizedStringKey` rendered via
  `Text(_, bundle: .module)`.
- **`ToolbarButtons`** — `CloseToolbarButton` (iOS `Button(role:.close)` → system X) and
  `ConfirmToolbarButton` (iOS `Button(role:.confirm)` → checkmark), Material equivalents on Android.
  Used on sheets/flows that keep a nav bar; never spelled-out "Cancel"/"Done".
- **`NetworkBadge`** — a capsule with the network name, colored per network via `NetworkChipStyle`
  (testnets violet, Bitcoin mainnet orange). Shown on every money-touching surface (home, send
  review, receive, switcher).
- **`WalletSwitcherPill`** — home-header pill: initial avatar + wallet label + chevron → opens the
  wallet manager.
- **`TxRow`** — list/preview row: tinted direction circle + "Received/Sent" (+ amber "Pending" tag) +
  meta line (`Today 14:02 · N conf`, ">5 conf" → "Confirmed") + signed amount/unit + `$0.00` fiat
  placeholder. Recipient amount is net-of-fee for sends.
- **`TxDetailSheet`** — chromeless sheet (no nav bar/title/close — swipe to dismiss): hero (direction
  glyph, big amount, colored status pill, date) → grouped details card (amount / network fee / total /
  fee rate / confirmations / block height / size / network / RBF — fee fields only for sends) →
  txid card with copy → full-width **"View on block explorer"** accent button.
- **`Keypad`** — custom numeric keypad for Send amount entry.
- **`QRCodeView`** — receive QR rendered as a grid of `Rectangle`s from `QRCodeGenerator` (SkipUI has
  no `Canvas`, and SkipQRCode is scan-only).
- **`PrivacyCover`** — full-screen brand cover (logo on `bg0`) raised when the app isn't active so
  balances don't show in the app-switcher snapshot (rendered conditionally — see CLAUDE.md §7).
- **`PlaceholderScreen`** / **`Logo`** — empty-state heading+note; per-platform brand mark.

**Shared field/card patterns** (not components):
- **Cards:** `bg1` fill + `border` hairline + `Radius.md`/`lg`, via an inline `.cardStyle()`-style
  modifier (see `TxDetailSheet`).
- **Text inputs:** `.textFieldStyle(.plain)` + `fieldBoxInset()` over a `bg2` box (`PlatformChrome`)
  — `.plain` kills SkipUI's Material `OutlinedTextField` border on Android. Applies to `TextEditor`.

---

## 6. Voice & copy

- Speak as **"you,"** never "I." **Sentence case** everywhere except tiny uppercase overlines.
  Buttons are **verbs**, no trailing punctuation (*Send*, *Create new wallet*, *Review*,
  *I've written them down*).
- Security copy is matter-of-fact, one sentence, paired with `warning` + the caution glyph — never
  alarmist (*"Anyone who sees them can take your coins."*).
- Tie self-custody to the eCash airdrop as the user benefit; reference block **964,000** / Drivechain
  only in technical/footer contexts, not primary CTAs.
- Numbers: full 8-dp precision in detail; the unit label comes from the network (`sBTC` on signet,
  `BTC`/`eCash` later) and **never implies real value** on a test network. **No emoji.**

---

## 7. Screen conventions

The shell is a stock `TabView` (Wallet · Activity · Settings); multi-step flows use a
`NavigationStack`. Top-level screens own their own layout (no large-title nav bar on Home).

- **Onboarding (`Welcome`)** — first launch with no wallets: logo + Create / Import. (No "choose
  network" step — new wallets default to Testnet/Signet; network is a switchable view, not asked at
  creation, per `docs/wallet-and-network-model.md`.)
- **Home (`WalletHomeScreen`)** — switcher pill (top-left) · `NetworkBadge` · balance + eye privacy
  toggle · 4-circle action row (**Send/Receive** live, **Swap/Buy** disabled ghosts) · "not backed
  up" nudge · recent activity. No nav title, no FAB.
- **Receive** — **chromeless sheet**: `NetworkBadge` · QR · mono address · "only send X on Y" · Copy /
  Share · "New address" (advances on demand). Swipe to dismiss.
- **Send (`SendScreen`)** — full-screen `NavigationStack` flow: recipient → amount (`Keypad` + Max +
  fee tier) → review (states the **network** + recipient/amount/fee) → confirm (device-auth gated) →
  broadcast → sent/failed. System back/swipe between steps.
- **Activity / Tx detail** — `List` of `TxRow`s; tap → chromeless `TxDetailSheet`. Pull-to-refresh.
- **Backup** — gated reveal → device auth → numbered word grid (capture-blocked) → 3-word verify.
- **Settings** — grouped `List`: Security (backup, Require-unlock toggle, Auto-lock grace) ·
  Appearance (theme) · About (version, **Open-source licenses**) · Developer (reset). App-lock +
  `LockScreen` gate the whole app; `PrivacyCover` hides the snapshot.

Let `List`/`ScrollView` own safe-area insets; use `Space.gutter` (20pt) only outside a `List`. Give
the hero balance room, show the network on every money surface, and honor Reduce Motion.
