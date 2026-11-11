# URI Scheme Deep Links (`bitcoin:` / `ecash:`) — design

**Status:** 🟢 BUILT 2026-08-26, verified on an iPhone 17 Pro simulator and a Solana Saga. Requested
in [issue #6](https://github.com/ecash-com/ecash-wallet-mobile/issues/6) by @nyusternie. §3 records
the decisions; §4a documents three Android traps that cost several build cycles and are worth reading
before touching this again.

Related: `docs/key-derivation.md` (eCash = Bitcoin params — the root of the whole problem),
CLAUDE.md Golden Rules §2 / §6 / §7 and §9 (Send).

---

## 1. What this is

Register the app as a handler for `bitcoin:` and `ecash:` URIs so a payment link tapped in a browser,
messaging app, or external QR scanner opens the wallet with the Send flow pre-filled. Standard
BIP-21: address in the path, `amount` / `label` / `message` as query params.

Cold start (app not running) and warm start (app already running) both have to work.

## 2. The problem this design exists to solve

**eCash is byte-identical to Bitcoin.** Same address format, same `bc` HRP, same coin-type `0'`
(`docs/key-derivation.md`). So a `bc1q…` address is *simultaneously* a valid Bitcoin address and a
valid eCash address, and no amount of parsing can tell you which chain a request means.

This is a money-safety problem, not a UX one. A user holding both BTC and ECX wallets — which is the
expected case, since ECX is an airdrop to BTC holders — who taps a real Bitcoin invoice and picks an
eCash wallet sends real value to a chain the payee will never watch. It is irreversible, and nothing
on screen looks wrong, because the addresses are identical. This is the same hazard CLAUDE.md §9
already guards in the send-to-my-wallets picker ("same-network is a safety filter, not a
convenience"), and a deep link is a worse version of it: the URI arrives from an untrusted app or web
page rather than from our own UI.

The address does narrow things, but only by *class*:

| Address form | Tells you |
|---|---|
| `bc1…` / `1…` / `3…` | mainnet-class — Bitcoin **or** eCash. Genuinely ambiguous. |
| `tb1…` | testnet-class — signet (and future eCash testnets). |

**The URI scheme is therefore the only channel through which a sender can state the chain.** That is
the entire reason to support `ecash:` at all: `ecash:bc1q…` is unambiguous where `bitcoin:bc1q…`
never can be.

## 3. Decisions

1. **Register both `bitcoin:` and `ecash:`.**
2. **Scheme selects the network, strictly.** `bitcoin:` offers only Bitcoin wallets; `ecash:` offers
   only eCash wallets. No cross-offering — a scheme is a statement about the chain and we honor it.
3. **A bare address (no scheme) is ambiguous and asks.** This is our own Receive QR (§5.6) and most
   pasted addresses, so it's the common path, not an edge case.
4. **The XEC collision is accepted.** eCash/XEC (the Bitcoin ABC fork) has used `ecash:` with CashAddr
   since 2021, so on Android both apps appear in a chooser and on iOS the winner between two apps
   claiming a scheme is undefined. We take it: the clash is symmetric, and an XEC address is trivially
   distinguishable from ours (§5.5), so we can fail with an honest message instead of misbehaving.
   **We do not support XEC** — BTC and ECX only.
5. **Never auto-send.** A deep link pre-fills; the user confirms on the Send review, behind the app
   lock and the existing send auth (Golden Rule §7).
6. **Nothing renders before unlock.** A pending link must not leak a wallet name, address, or amount
   onto the lock screen.

## 4. Routing rules

| Input | Candidates offered | If the set is empty |
|---|---|---|
| `bitcoin:bc1q…` | Bitcoin accounts | "This is a Bitcoin payment request. You don't have a Bitcoin wallet." |
| `ecash:bc1q…` | eCash accounts (`PaymentLink.ecashNetworks` = `[.ecashMainnet, .ecashBeta]`; alphanet absent) | "This is an eCash payment request. You don't have an eCash wallet." |
| `ecash:qq…` / `ecash:p…` (XEC CashAddr) | none | "That's an eCash (XEC) address. This wallet is for eCash (ECX)." |
| bare `bc1…` / `1…` / `3…` | Bitcoin **+** eCash accounts → picker | "You don't have a Bitcoin or eCash wallet." |
| `tb1…` (any scheme) | signet accounts | "You don't have a signet wallet." |

Since the seed-container model (2026-11-05) a wallet holds one account per network, so the candidates
are **(wallet × account) pairs**, not wallets: one seed wallet can appear once per payable chain in the
picker (`PaymentLinkWalletPicker`, keyed by `selectedAccount.storeName`; `AppState.paymentLinkChoices`).

Notes on the messages: say **why**, not just "no wallet found" — the user has to be able to tell a
missing wallet from a wrong-chain link. A strict `bitcoin:` means an ECX request emitted by generic
tooling (which mostly emits `bitcoin:`) dead-ends; that's the accepted cost of the strictness in §3.2,
and the message is what makes it diagnosable rather than baffling.

When the switcher does appear, the network chip is the safety mechanism (Golden Rule §6) — and for
the ambiguous row it should say outright that the link didn't specify a chain.

## 4a. As built — the Android traps

iOS was straightforward: `CFBundleURLTypes` plus SwiftUI's `onOpenURL`, working first try. Android
needed three separate fixes, each of which **compiled cleanly and silently did nothing**.

**1. `onOpenURL` is a no-op on Fuse-Android.** SkipUI implements it under `#if SKIP`; the Fuse app
compiles against the native-Swift declaration whose body is `return self`. `onOpenURLString` IS
bridged, but only onto the bridged `any View`, which a `some View` modifier chain can't reach. So the
intent has to be read outside SwiftUI entirely. (skip-kit doesn't help — its `urlSchemes` is
read-only and iOS-only.)

**2. The read belongs in `Main.kt`, before `setContent`.** Reading VIEW intents needs
`androidx.activity` for `addOnNewIntentListener`, which isn't on WalletService's classpath but is
already imported in `Main.kt` — the same place `AndroidActivityHolder` is set. It must run *before*
`setContent`, because Compose runs the root inline: RootView's `.onAppear`, which drains the value,
executes during `onCreate` and would otherwise always run first and find nothing. `onNewIntent` also
calls `setIntent`, or a warm-start link is lost.

**3. `.onChange` never fires for a value set before the view mounts.** With the link handled during
RootView's `.onAppear`, `pendingPaymentLink` is already non-nil by the time Home appears, and
`onChange` only reports *subsequent* changes. Home therefore consumes it from `.task` as well. iOS
masked this entirely, because there the URL arrives after the UI is up — a genuine change.

The through-line: on this stack, "it compiles" says nothing about whether an Android path is wired.
Only running it on a device does. Each of these was found by logging to logcat at every stage, not by
reasoning about the code.

## 4b. As built — the wallet picker

`PaymentLinkWalletPicker` appears when **more than one** wallet could pay the link, and only then.
One candidate opens Send directly, even for a link that names no chain — there's nothing to choose
between, and Send still shows the network before anything is broadcast.

With several candidates we never pick, not even the currently-selected wallet: on an ambiguous link
the wrong choice sends real value to a chain the payee will never watch, and on a named chain the
user knows better than we do which wallet should pay. Each row carries the network chip, and the
ambiguous case says outright that the link didn't specify a chain.

## 5. As built (updated 2026-11-10)

The plan below was built; this section records what differs from it.

### 5.1 Android — manifest

`Android/app/src/main/AndroidManifest.xml` declares the `VIEW` / `DEFAULT` / `BROWSABLE` intent filter
for `bitcoin` and `ecash` **and `android:launchMode="singleTask"`** on `MainActivity` — the latter is
load-bearing: under the default `standard` mode `onNewIntent` never fires and a link tapped while the
app is running stacks a *second* `MainActivity`, so the warm-start half silently fails.

### 5.2 iOS — Info.plist

`Darwin/Info.plist` declares `CFBundleURLTypes` with `CFBundleURLName` `com.ecash.mobile.wallet` and
the two schemes `bitcoin` / `ecash`.

### 5.3 Delivery — `onOpenURL` on iOS, the intent on Android

The plan expected a bridged `onOpenURLString` seam. What was built instead: `RootView` calls plain
`.onOpenURL { app.handlePaymentLink($0.absoluteString) }`, which is real SwiftUI on iOS and compiles to
a **no-op** on Fuse-Android (SkipUI's non-SKIP branch returns self — verified on device). Android reads
the `VIEW` intent in Kotlin instead: `Android/app/src/main/kotlin/Main.kt` captures it in `onResume`
(cold start, `getIntent()`) and `onNewIntent` (warm start, after `setIntent`) and hands it to
`WalletService`; the Swift side drains it via `PlatformBridge.takePaymentLink()` from
`RootView.onAppear` → `app.checkAndroidPaymentLink()`. Consuming clears it, so a link fires once.

### 5.4 Parser — scheme handling lives in `PaymentLink`, not `BIP21`

`BIP21.parse` **still strips only `bitcoin:`** and discards the scheme. The scheme is handled one layer
up in `WalletService`'s `PaymentLink` (`Packages/WalletService/Sources/WalletService/PaymentLink.swift`):
`PaymentLink.scheme(of:)` reports `.bitcoin` / `.ecash` / `.none`, `PaymentLink.body(of:)` strips
either prefix before `BIP21.parse`, and `isXECCashAddr` does §5.5. `ecashNetworks` =
`[.ecashMainnet, .ecashBeta]`.

Already done: `req-` params reject the whole URI, per BIP-21's rule that a client not implementing a
`req-` variable MUST treat the URI as invalid. That fix is live and shipped with tests.

### 5.5 XEC detection

XEC CashAddr payloads are lowercase base32 (bech32 charset) starting `q` (P2PKH) or `p` (P2SH), and
cannot collide with our `bc1…`, `1…`, or `3…`. So detection is a cheap prefix/charset check, and the
right response is the explicit message in §4 — never a silent failure, and never an attempt to parse.

### 5.6 Receive emits bare addresses (don't assume otherwise)

`ReceiveScreen.swift:38` encodes `QRCodeView(content: info.address)` — a **bare address**, no scheme —
and `ShareLink` shares the same. Two consequences:

- Strict scheme routing breaks nothing already in the wild. QRs from 0.2.2 and earlier carry no
  scheme, so they take the bare-address row, not a wrong one.
- **Doc drift:** CLAUDE.md §9 claims Receive does "Optional amount → BIP21 URI". It does not; there is
  no URI builder in the app. If that gets built, it's where the scheme choice starts to matter — an
  eCash wallet should emit `ecash:`, which is what makes §3.2's disambiguation actually reach other
  wallets instead of only working for links from outside our ecosystem.

### 5.7 App-lock interaction

The link has to survive the gate: hold the pending URI, run the normal unlock, *then* present the
switcher. `AppLockModel` / `RootView` already own the foreground-lock path (CLAUDE.md §7). Nothing
about the pending link renders before unlock (§3.6), and the existing send auth still applies at
confirm.

## 6. Security requirements

- **Treat the URI as hostile input.** It originates from any app or web page that can form a link.
- **Pre-fill only; never pre-confirm.** Land on the Send review with recipient, amount, fee and
  **network** shown (Golden Rule §7).
- **No silent coercion of `amount`.** The parser already rejects a malformed amount by failing the
  whole URI rather than dropping the field — keep that.
- **No secrets in any error path** (Golden Rule §2). "That's an XEC address" is fine; echoing wallet
  internals is not.
- A link must not be able to select a wallet the user didn't pick, or bypass the lock.

## 7. Testing

Per the CLAUDE.md §11 bar — tests land in the same PR.

**Pure (Robolectric, both platforms):**
- Scheme parsing: `bitcoin:`, `ecash:`, bare address, mixed case, no scheme with query params.
- Routing: each row of §4's table resolves to the expected candidate set, including the empty cases.
- XEC detection: CashAddr forms rejected with the XEC message; `bc1…`/`1…`/`3…` never misclassified.
- `req-` rejection (done).
- The ambiguity invariant: a bare `bc1…` never auto-selects a wallet when both a BTC and an ECX
  wallet exist.

**Integration / manual (both platforms):**
- Cold start and warm start, on Android with the `launchMode` change in place.
- Locked app: link held, nothing rendered pre-unlock, flow resumes after.
- Android chooser behavior with an XEC wallet installed; iOS behavior when another `bitcoin:` handler
  is present (undefined by the OS — record what actually happens).

## 8. Open questions

1. **Should Receive emit URIs?** Required for §3.2 to help anyone outside our own app. Ties into the
   §5.6 doc drift and the unbuilt "optional amount" feature.
2. **`ecash:` for the fork long-term.** Our HRP/unit naming is still open (CLAUDE.md §14 #7). If the
   fork ever gets its own address format, this design's ambiguity problem largely disappears and the
   strict mapping becomes trivial — worth raising with L2L rather than settling here.
3. **Signet/testnet schemes.** `tb1…` routes by address class today; no separate scheme is proposed.
4. **Thunder.** Out of scope — different address format entirely, no BIP-21 analog yet.

## 9. References

- **Issue #6** — <https://github.com/ecash-com/ecash-wallet-mobile/issues/6> — the original request
  by @nyusternie, plus Jake's reply outlining the wallet-selector approach this design builds on. Its
  Android/iOS snippets and file paths are accurate; the `launchMode` point (§5.1) is what it misses,
  and its `ecash:qpexampleaddress` example is an XEC CashAddr (§5.5), not one of ours.
- `Packages/WalletService/Sources/WalletService/BIP21.swift` — parser, bridged.
- `Sources/ECashWalletMobile/Screens/ReceiveScreen.swift:38` — bare-address QR.
- `Android/app/src/main/AndroidManifest.xml`, `Darwin/Info.plist` — both tracked and editable.
- `.build/checkouts/skip-ui/Sources/SkipUI/SkipUI/System/UserActivity.swift:33,73` — `onOpenURL` /
  `onOpenURLString`.
- `docs/key-derivation.md` — eCash = Bitcoin params.
