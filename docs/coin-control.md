# Coin control & UTXO management — design record

> **Status:** PLANNED / post-v1 — **not built**. This scopes the feature; nothing here ships yet.
> Foundations already exist: `WalletEngine.listUtxos()` works, and the send path already uses one
> coin-control primitive (`TxBuilder.unspendable` for the 0-conf spend policy). Complements
> CLAUDE.md §6 (BDK usage) and `docs/accounts-and-labels.md` (app-owned metadata).

## 1. What & why

Give users visibility into and control over the individual coins (UTXOs) a wallet holds:

- **See** every UTXO — amount, confirmations, address, which it came from.
- **Label** UTXOs/addresses (where coins came from) — app-owned metadata.
- **Freeze** specific UTXOs so they're never auto-selected for a spend.
- **Spend specific coins** — pick exactly which UTXOs fund a transaction.
- **Consolidate** many small UTXOs into one (see §5).

This is a power-user / privacy feature. It's explicitly post-v1 (CLAUDE.md §12), but the engine
already supports the hard parts, so most of the work is UI + app-side metadata.

## 2. What BDK already gives us

**Reading** — `wallet.listUnspent()` returns a `LocalOutput` per coin (already wrapped by
`WalletEngine.listUtxos()` → our `Utxo`). `LocalOutput` carries more than we currently surface:
outpoint (txid:vout), value, scriptPubKey/address, keychain (external vs. internal/change),
derivation index, chain position (confirmed height/time or unconfirmed), is_spent. `listOutput()`
adds spent outputs.

**Spending control** — `TxBuilder` exposes essentially full *manual* coin control:

| Need | BDK / TxBuilder | Notes |
|---|---|---|
| Include specific coins | `addUtxo(outpoint)` / `addUtxos([…])` | force-include |
| Spend only chosen coins | `manuallySelectedOnly()` | full manual selection |
| Freeze / exclude coins | `addUnspendable` / `unspendable([…])` | **already used** for 0-conf policy |
| Change handling | `changePolicy(ChangeSpendPolicy)` | allowed / only-change / forbidden |
| Sweep / send-max | `drainWallet()` + `drainTo(script)` | consolidation building block (§5) |
| Fees | `feeRate` / `feeAbsolute` | |

**The one limitation:** the automatic *coin-selection algorithm* isn't pluggable over the UniFFI
bindings. In Rust you can swap Branch-and-Bound / LargestFirst / OldestFirst or write a custom
`CoinSelectionAlgorithm`; through `bdk-swift`/`bdk-android` you get the default (BnB) for *automatic*
selection. This is a non-issue for coin control: `manuallySelectedOnly()` + `addUtxo` gives 100%
control when the user wants it.

> **TODO (verify):** confirm the exact UniFFI method names for `addUtxo` / `manuallySelectedOnly` /
> `changePolicy` / `drainTo` in the pinned `bdk-swift`/`bdk-android` ~2.3.x before building (we
> already call `unspendable`; the rest need a one-time check against the binding).

## 3. Data-model changes

BDK stores **no** labels or freeze state (`metadata-is-app-owned`). So:

- **Enrich `Utxo`** (`WalletService/Models.swift`) to expose what `LocalOutput` already has:
  confirmations / chain position, address, keychain, derivation index. **Bridged-surface rule:**
  signed ints only — `vout` is already `Int32`; do **not** add `UInt32`/`UInt64` properties (the
  Kotlin inline-class getter mangling crashes the JNI bridge — see the bridged-surface note in
  CLAUDE.md §5). Convert from BDK's unsigned types at the engine boundary.
- **App-owned UTXO metadata** in `WalletStore` (JSON), keyed by outpoint (`txid:vout`):
  - `label: String?` (where the coins came from)
  - `frozen: Bool`
  Survives across syncs; purged with the wallet. **BIP-329** is the backup/export format for labels.
- **Frozen set → spend path:** the engine already builds an `unspendable` set (untrusted 0-conf).
  Union the user's frozen outpoints into it on every `buildTx`, so frozen coins are never
  auto-selected. (Frozen coins can still be *manually* added if we ever want an override — decide.)

## 4. UX surfaces

- **UTXO list** (Settings → wallet, or an Activity sub-screen): rows of amount, confirmations,
  address (middle-ellipsis), label, frozen badge. Sort by amount / age. Per-row actions: label,
  freeze/unfreeze, "spend this."
- **Coin selection in Send:** an optional "choose coins" mode → multi-select UTXOs → engine builds
  with `addUtxo(…)` + `manuallySelectedOnly()`. Review screen shows selected inputs + the resulting
  change. Falls back to automatic (current behavior) when the user doesn't choose.
- **Labels:** inline edit on the UTXO row and (later) on receive addresses; app metadata only.
- **Network chip / mainnet treatment** unchanged — coin control is read/build, same broadcast gate.

## 5. UTXO consolidation

**Yes — fully supported by BDK; it's a normal self-spend.** Combine many (small) UTXOs into one
output back to an address this wallet owns.

**How:**
- Select the UTXOs to consolidate (`addUtxo` for each + `manuallySelectedOnly()`), or
  `drainWallet()` to take everything.
- `drainTo(ownAddress)` → the whole selected amount minus fee lands in a **single** output (no
  change), at a fresh receive address (or change keychain). Pick a **low fee rate** — the point of
  consolidating is to pay the input cost once, while fees are cheap, to make future spends smaller.

**Surfacing it well:**
- **Suggest** consolidation when a wallet has many small UTXOs (e.g. "N coins under X — combine them
  to save on future fees"). Threshold is a product choice.
- **Economical vs. dust:** at a given fee rate, a UTXO is "uneconomical" if it costs more to spend
  than it's worth (≈ input vsize × feeRate > value). Flag those; consolidating them at a *low* fee
  can still be worth it, but spending them later at a high fee isn't. Show the math.
- **Self-transfer UX:** it's a tx that "sends to yourself" — the review/Activity should label it as
  a consolidation, not a normal send, so the user isn't confused (net change ≈ just the fee).

**⚠️ Privacy caveat (must warn):** consolidating merges UTXOs into one transaction, which links them
under the common-input-ownership heuristic — coins from different sources become provably the same
wallet. This is the main reason consolidation is opt-in and warned, not automatic. (It's the
opposite tradeoff from coin control's usual privacy goal of *keeping* coins separate.)

> Consolidation's counterpart — automated self-spend "hops" to *muddy* a coin's lineage — is scoped
> separately in `docs/transaction-deniability.md` (the BitWindow-style "Automatic Denial" screen sits
> next to Consolidate). Both are scheduled/manual self-spends built on the primitives above.

## 6. Architecture fit

- **Watch-only build still holds.** Coin selection, freezing, and consolidation operate on
  *public* data (outpoints, scripts, amounts) — the build stays watch-only; the mnemonic is still
  only loaded at `sign` (unlike Silent Payments, which breaks this — see `docs/silent-payments.md`
  if/when written). No change to the key-storage seam.
- **Per (wallet × network)** isolation unchanged — UTXOs and their metadata are namespaced by
  `walletId`/network like everything else.
- **Engine API additions:** `listUtxos()` enrichment; `buildTx`/`send` gain optional
  `selectedOutpoints: [Outpoint]` (→ `manuallySelectedOnly` + `addUtxo`) and read the frozen set;
  a `consolidate(feeRate:, outpoints:)` convenience that wraps drain-to-own-address.

## 7. Scope & effort

- **Tier 1 — read + freeze:** UTXO list UI + freeze metadata threaded into the existing unspendable
  set. Low risk, mostly UI + a small `WalletStore` addition. Labels can ride along (BIP-329 export
  later).
- **Tier 2 — manual coin selection in Send:** the "choose coins" mode (`manuallySelectedOnly`).
- **Tier 3 — consolidation:** the self-spend flow + suggestion/economical-coin heuristics + privacy
  warning.

BDK does the cryptography and tx building throughout; the work is UI, app-owned metadata, and a few
thin engine wrappers. No forked binding needed (unlike multisig PSBT transport or BIP352).

## 8. Open questions

- Can a user *manually* spend a frozen coin (override), or is frozen absolute? (Lean: absolute;
  unfreeze first.)
- Label scope: per-UTXO only, or also per-address (so future coins to that address inherit it)?
- Consolidation: auto-suggest threshold, and whether to offer a one-tap "consolidate all economical
  coins at the slow fee rate."
- BIP-329 import/export timing (ties into the broader labels work in `docs/accounts-and-labels.md`).
