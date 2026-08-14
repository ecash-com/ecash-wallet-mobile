# URI Scheme Deep Links (`bitcoin:` / `ecash:`) — design

**Status:** 🟡 DESIGNED, NOT BUILT — 2026-08-14. Requested in
[issue #6](https://github.com/ecash-com/ecash-wallet-mobile/issues/6) by @nyusternie. The decisions in
§3 are made; §5 is the implementation plan; §8 lists what's still open. Nothing here is in the code
yet **except** the `req-` fix (§5.4), which shipped separately because it was a live bug in the QR
scanner.

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

| Input | Wallets offered | If the set is empty |
|---|---|---|
| `bitcoin:bc1q…` | Bitcoin | "This is a Bitcoin payment request. You don't have a Bitcoin wallet." |
| `ecash:bc1q…` | eCash | "This is an eCash payment request. You don't have an eCash wallet." |
| `ecash:qq…` / `ecash:p…` (XEC CashAddr) | none | "That's an eCash (XEC) address. This wallet is for eCash (ECX)." |
| bare `bc1…` / `1…` / `3…` | Bitcoin **+** eCash → switcher | "You don't have a Bitcoin or eCash wallet." |
| `tb1…` (any scheme) | signet | "You don't have a signet wallet." |

Notes on the messages: say **why**, not just "no wallet found" — the user has to be able to tell a
missing wallet from a wrong-chain link. A strict `bitcoin:` means an ECX request emitted by generic
tooling (which mostly emits `bitcoin:`) dead-ends; that's the accepted cost of the strictness in §3.2,
and the message is what makes it diagnosable rather than baffling.

When the switcher does appear, the network chip is the safety mechanism (Golden Rule §6) — and for
the ambiguous row it should say outright that the link didn't specify a chain.

## 5. Implementation plan

### 5.1 Android — manifest

`Android/app/src/main/AndroidManifest.xml` (tracked and editable; currently only `MAIN`/`LAUNCHER`):

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="bitcoin" />
    <data android:scheme="ecash" />
</intent-filter>
```

**`MainActivity` also needs `android:launchMode="singleTask"` (or `singleTop`).** It currently
declares no `launchMode`, so it defaults to `standard` — under which `onNewIntent` never fires and a
link tapped while the app is running stacks a *second* `MainActivity` instead of delivering to the
running one. Without this the warm-start half of the feature silently does not work. This is the one
thing missing from the issue's otherwise-correct write-up.

### 5.2 iOS — Info.plist

`Darwin/Info.plist` currently declares only `NSAppTransportSecurity`. Add:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.ecash.mobile.wallet</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>bitcoin</string>
      <string>ecash</string>
    </array>
  </dict>
</array>
```

### 5.3 Delivery — `onOpenURL`, and the Fuse gotcha

SkipUI implements the modifier in `SkipUI/System/UserActivity.swift` and it covers both cases we
need: `activity.intent` for cold start and `addOnNewIntentListener` for warm start, clearing the
intent after handling so a recompose doesn't reprocess it.

**But the bridged entry point is `onOpenURLString`, not `onOpenURL`.** Only
`onOpenURLString(perform: (String) -> Void)` carries `// SKIP @bridge`; the `URL`-taking variant does
not, so a Fuse app calling `.onOpenURL { }` may compile while leaving the Android side unwired. Expect
a seam at the call site:

```swift
#if os(Android)
.onOpenURLString { handleIncoming($0) }     // bridged SkipUI
#else
.onOpenURL { handleIncoming($0.absoluteString) }   // real SwiftUI
#endif
```

This must be verified with `skip export`, not `swift build` — the Fuse native-Android pass is the only
thing that catches this class of error (same lesson as `String(localized:)`, memory
`fuse-localization-no-string-localized`).

### 5.4 Parser — `BIP21` gains the scheme

`BIP21.parse` currently strips `bitcoin:` and *discards* which scheme it saw; it needs to report it so
the router can apply §4. `BIP21` is a **bridged public type**, so the new field must be bridge-safe —
a `String`, or an enum exposed as one. No `UInt`-family types (memory
`bridged-surface-signed-types-only`).

It must also strip `ecash:` — today an `ecash:` prefix would fall through into the address field.

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
