# Script types on demand (seed-container phase 2) — design

**Status:** 🔵 DESIGN — 2026-11-11. Nothing built. This is phase 2 of
`docs/seed-container-model.md` (§3.3 and §8 there sketch it; this doc is the full plan). Decisions
Jake made 2026-11-11 are marked **DECIDED**; open questions are in §9.

**In one line:** the address type is chosen on the **Receive screen**, a wallet gets a script-type
account the first time one is asked for, legacy is never offered unless the wallet was imported at
it, and a send spends from one account at a time until phase 2b lets it combine them.

---

## 1. Why

A seed derives a different, unrelated wallet under every standard derivation path: BIP44 (`1…`),
BIP49 (`3…`), BIP84 (`bc1q…`), BIP86 (`bc1p…`). Coins at one path are invisible from another.
Today every account is **bip84** unless the Advanced import picked another, so:

- a user cannot get a taproot address from a wallet created here;
- a wallet imported at bip44 (to recover old coins) can only ever receive at legacy addresses;
- a seed that was used at two types elsewhere shows only one of them after import (phase 3's
  problem, but it needs the same account machinery).

The reference point is **Sieve** (Jake's compact-block-filter wallet,
github.com/Galaxoid-Labs/sieve, `src/wallet/accounts.rs`): one seed is a *portfolio* of one BDK
wallet per script type, each with its own SQLite file, summed into one balance and one history; a
`primary` type decides what Receive offers; legacy is watched but never handed out
(`ScriptType::can_receive`); a send is built and signed inside one account. §7 lists where we
differ and why.

## 2. What already exists (phase 1 left the slots)

| Piece | State today |
|---|---|
| `ScriptType` (`Models.swift`) | all four cases, `purpose`, `displayName`, `creatable = [.bip84, .bip86]` |
| `WalletAccount` | keyed `(network, scriptType, accountIndex)`, own `storeName`, public descriptors only |
| `Descriptors.swift` | BIP44/49/84/86 templates with network-aware coin type |
| `WalletManager.enableNetwork` | derives a missing account on first tap: one DeviceAuth-gated phrase read, persists, never touches the Keychain again |
| Engine cache | per `storeName`, so two accounts of one wallet are two engines already |
| Import → Advanced | script type + account index picker, live address preview |
| v2 wallet store | additive: a new account is a new record in `accounts`, no migration |

So the model needs **no schema change**. The work is (a) a derive-by-script-type entry point next
to `enableNetwork`, (b) the Receive control, (c) `AppState` aggregating several engines of one
network, and (d) the Send account choice.

## 3. Rules (DECIDED 2026-11-11)

1. **The address type is chosen on Receive.** No picker at create, none at import beyond the
   existing Advanced section. Create stays bip84-only (decided 2026-11-04).
2. **Offered types: Native SegWit (default) and Taproot.** Picking a type the wallet has no account
   for *derives it on the spot* (same gated path as opening a new network), syncs it, and shows its
   first unused address.
3. **Legacy and Nested SegWit appear only where the wallet already holds that account** — an
   Advanced import at bip44/bip49, or (phase 3) auto-discovery finding history there. A fresh
   wallet or a segwit import never sees them. (Same asymmetry as `ScriptType.creatable` and
   `WalletNetwork.selectable`: what you may hold is wider than what you may start.)
4. **The last chosen type is the wallet's primary.** It is what Receive opens on next time and what
   Send spends from by default. Per wallet, not per network (seed-container §10 Q5).
5. **Home balance is the sum of that network's accounts.** Activity merges their transactions,
   deduplicated by txid. The unconfirmed share (`unconfirmedBalance`) sums the same way.
6. **A send spends from one account** (phase 2a). Cross-account sends are phase 2b (§6).

## 4. Model and engine changes

### 4.1 `WalletManager`

- `enableScriptType(walletId:network:scriptType:) throws -> WalletAccount` — sibling of
  `enableNetwork`: returns the existing account or derives one (`makeAccount` already takes a
  script type), persists, and sets `selectedAccountId` to it. Throws `needsSecret` → the app gates
  the call behind `DeviceAuth` exactly as the network switch does.
- `accounts(walletId:network:) -> [WalletAccount]` — the accounts of one network, for the Receive
  control and for aggregation.
- `offeredScriptTypes(walletId:network:) -> [ScriptType]` — `[.bip84, .bip86]` plus any
  bip44/bip49 account the wallet already holds on that network, in BIP order. Rule 3 lives here,
  tested, not in a view.
- `primaryScriptType` on `ManagedWallet` (new stored field, default `.bip84`; a wallet imported at
  another type starts there). Decodes absent as `.bip84` so v2 records load unchanged.
- The selected account stays the one money surfaces read **for sending**; Receive and Home read
  across `accounts(walletId:network:)`.

### 4.2 Per-account engines, aggregated in `AppState`

`AppState` today holds one balance / pending / unconfirmed / transactions / sync state for "the
selected account". Phase 2a makes those **per network**: a sync runs every account of the selected
network in turn (sequentially — one writer, CLAUDE.md §10), then sums. Concretely:

- `sync()` → for each account of the selected network: `walletOps.sync(walletId:accountId:)`;
  balance, pending, unconfirmed = sums; transactions = merged, deduped by txid, sorted newest
  first. Sync state is one indicator (any failure = failed, with the first message).
- `loadCachedStateIfNeeded` does the same over on-disk state.
- `SyncFreshness` key stays `(walletId, network)`: one timestamp for the group.
- The `WalletOps` protocol gains `accountId`-scoped variants of `balance` / `transactions` /
  `nextUnusedAddress` / `sync` (the Thunder implementation returns the single-account answer).

Cost: one extra Electrum/Esplora round trip per extra account on every sync. With accounts derived
lazily this is zero for a wallet that never opened Taproot, and one for one that did. See §7.

### 4.3 Receive

`ReceiveScreen` gets a segmented control above the QR: the offered types (§4.1), the current one
selected. Selecting:

1. if the account exists → switch the address shown to that account's `nextUnusedAddress`
   (never `nextReceiveAddress`; browsing must not burn index space — CLAUDE.md §6);
2. if it does not → `DeviceAuth` (when app-lock is on) → `enableScriptType` → sync that account
   in the background → show its first address;
3. either way, record it as the wallet's primary.

"New address" keeps advancing only the account being shown. The network chip stays; the address
HRP already tells the type apart (`bc1q` vs `bc1p`).

### 4.4 Send (phase 2a)

`makeSendViewModel` captures an **account**, not just a wallet:

- default: the primary account;
- if the primary's spendable balance is below the amount at review time, and another single
  account of the same network covers it, the dry run (`previewSend`) is re-run on that account and
  the review states "Spending from your Taproot coins" (the account's `displayName`);
- if no single account covers it but the sum does → `.insufficientFunds` is mapped to a specific
  message: "Your balance is split across address types. Send up to X from Native SegWit or Y from
  Taproot, or combine them in two sends." This is the trap §7 describes; phase 2b removes it.
- Max / sweep drains the chosen account only; the review says so.
- The signer: `BDKWalletEngineFactory.signPsbt` must rebuild the private descriptor **for the
  account's script type and coin type** (seed-container §9 already requires this test).

CoinNews `publishData` and sidechain deposits use the primary account.

### 4.5 Import and the claim

Unchanged. An Advanced import at bip44/49 produces that account on every mainchain as today; the
Receive control then also offers Native SegWit and Taproot, so the user can move coins forward
with an ordinary send to themselves. The investor claim is WIF → `.wif` wallet → `pkh` only; no
script-type control on a `.wif` wallet (one key, one script).

## 5. Phase 3 — import auto-discovery (unchanged, noted for shape)

On a seed import with no Advanced choice: derive all four types on the default network, run one
sync each, keep the accounts with history (always keep bip84), set primary to the type with the
most recent activity. Needs §4.1's entry points and nothing else. ~3 days.

## 6. Phase 2b — cross-account sends

bdk-ffi 2.3.1 exposes `TxBuilder.addForeignUtxo(outpoint:psbtInput:satisfactionWeight:)`
(verified in the checked-out `BitcoinDevKit.swift`), the same primitive the sidechain deposit
already uses for the treasury input. A cross-account send is:

1. build in the primary account with the other account's UTXOs added as foreign inputs (their
   `psbtInput` from that account's wallet, weight by script type);
2. sign with the primary's transient signer, then the other account's (both from the same phrase,
   two sequential one-shot key loads — the key-storage model is unchanged);
3. finalize and broadcast as today; `applyBroadcast` into **both** wallets so neither reselects
   spent coins.

Coin selection across two wallets is ours to do (BDK's selector sees one wallet): simplest is
"primary first, then the largest foreign coins until covered", which is the two-pass spirit of
`buildPreferringConfirmed`. Recommended to follow 2a quickly rather than stay optional, because the
Receive control is precisely what creates split balances.

## 7. Where we differ from Sieve

| Sieve | Us | Why |
|---|---|---|
| Opens all four paths on restore | Derive lazily on Receive; phase 3 scans once on import | Compact block filters cost the same for four paths as for one; Electrum/Esplora cost one round trip per path per sync |
| Never hands out a new legacy address, even on a legacy import | Legacy offered where the wallet already holds it | Jake's call 2026-11-11; revisit if legacy receives turn out to be a mistake users make |
| Per-path balances shown prominently | One summed balance, split explained at Send | Mobile Home has one number; the split-balance message (§4.4) and phase 2b carry the burden |
| Single-key import watched under all four script types | WIF stays `pkh` | The claim is legacy coins only |
| Primary = Taproot for new wallets | Primary = Native SegWit | `bc1q` is the address form nothing refuses (Sieve's own receive-page comment says the same) |

## 8. Tests (CLAUDE.md §11 bar)

**Pure:** `offeredScriptTypes` per wallet shape (fresh → [84, 86]; bip44 import → [44, 84, 86];
`.wif` → none); `primaryScriptType` decodes absent as bip84; `AppState` aggregation sums balances
and merges/dedupes transactions across two mock engines; Send picks primary, falls back to the
covering account, and maps the split-balance error; `SyncFreshness` key unchanged.

**Real BDK:** bip84 and bip86 on one network → different descriptors, same fingerprint, first
addresses match the published vectors (Sieve pins the same `abandon…about` vectors); a PSBT built
from the bip86 account signs with a signer rebuilt for bip86 (not the wallet default); phase 2b: a
PSBT with one foreign bip86 input finalizes after both signers.

**Flows:** Receive → Taproot on a fresh wallet → device auth → `bc1p` address shown → appears in
the switcher's account list; "New address" advances only that account.

## 9. Open questions

1. Should an imported-legacy wallet be nudged to move coins to segwit (a Home card like the split
   nudge), given legacy inputs cost more to spend?
2. Does the Receive control also live in the wallet-list ⋯ menu, or Receive only? (Lean: Receive
   only.)
3. Phase 2b coin selection: primary-first, or by confirmation status first (so an unconfirmed
   primary coin loses to a confirmed foreign one)? Lean: confirmed-first across both, matching the
   two-pass policy.
4. `ScriptType.creatable` becomes unused once create is bip84-only and Receive owns the choice —
   rename to `receivable` and let it carry rule 3?

## 10. Size

Phase 2a ≈ 1 week (most of it §4.2 aggregation and §4.4), phase 2b ≈ 1 week, phase 3 ≈ 3 days.
Same estimates as seed-container §8.
