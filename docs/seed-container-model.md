# One wallet, many networks — the seed-container model

> **Status:** 🟡 DESIGN — not built. Requested by Paul (via Jake, 2026-11-04): a wallet should not
> be tied to a network at creation. You create a wallet, it opens on eCash mainnet, and you switch
> to Bitcoin, L2L Signet, or a sidechain from inside it. Script type should default to native segwit
> with taproot (etc.) addresses available on demand, not fixed at creation.
>
> Supersedes `docs/network-switching.md` (the 2026-06 plan, whose §4.2 store namespacing is reused)
> and retires `docs/copy-wallet-to-network.md` (copy becomes "switch"). Complements
> `docs/wallet-and-network-model.md` (a wallet is a seed — still true, now structurally),
> `docs/key-derivation.md` (eCash = Bitcoin params), `docs/key-storage.md` (mnemonic-only
> persistence, sign-on-demand), `docs/custom-derivation-path-import.md` (script types),
> `docs/thunder-sidechain-support.md` (Thunder keys from the same phrase).
>
> **This is a data-model migration on a shipping wallet. Nothing here deletes a secret or a chain
> store. Read §6 before touching persistence.**

---

## 0. Fund-safety invariants (read first)

Funds are lost only if the **phrase** is lost or the user can no longer **find** the coins. Everything
else in this migration is a cache that re-derives from the phrase and the chain. So the whole design
reduces to these rules, each with the check that enforces it:

| # | Invariant | How it's enforced |
|---|---|---|
| I1 | **The migration never writes, rewrites, or deletes a Keychain entry.** | The migration code has no reference to `KeyStore`. Phase 1 ships with **no automatic orphan purge at all** — duplicate entries from old copies stay until the user removes a wallet (§6.2.6). |
| I2 | **Every legacy record survives as a wallet or an account. None is dropped, hidden, or re-labelled beyond the documented merge.** | The planner asserts `legacy.count == wallets.flatMap(accounts).count` and that every legacy id is either a wallet id or in some wallet's `mergedFrom`. A record the planner can't classify becomes a **standalone** wallet unchanged — never merged, never skipped. |
| I3 | **A chain store is only ever attached to the seed it belongs to.** | Merges require an exact master-fingerprint match from *our own* persisted descriptors. After each move the applier calls BDK `Wallet.load` on the moved store with the primary's descriptors — BDK refuses to load a store whose descriptors differ (`check_descriptor`/`check_network`), so a mis-attached store **fails loud** and the move is reverted. |
| I4 | **Balances are identical before and after.** | The applier reads every account's cached balance before the move and after reopening; any difference reverts that move and leaves the record standalone. The manual upgrade matrix (§9) repeats this on real devices. |
| I5 | **Every file move is reversible.** | `wallets.json` is frozen (and copied to `wallets.json.pre-v2`), and the applied plan is written to `migration-v2.log.json` (old path → new path), so a rollback is a scripted reverse of the log. Moves check the destination first (idempotent on retry). |
| I6 | **A receive address always comes from the engine of the selected account**, never from a reconstructed path. | `nextUnusedAddress(walletId:accountId:)` routes through that account's BDK wallet; there is no address derivation outside BDK/Thunder (Golden Rule §1). A coin paid to an address the wallet *can* derive but isn't *watching* is still recoverable from the phrase, but that is a rescan, not a design we accept. |
| I7 | **Signing honours the account**, not a wallet default. | The sign closure rebuilds the private descriptor from the **account's** `(network, scriptType, accountIndex)`; a real-BDK test signs from a non-default account (§9). |
| I8 | **Network is never switched implicitly.** Only a user tap in the switcher changes `selectedAccountId`; a send review carries the account it opened on. | §5 "wrong-network broadcast"; `SendViewModel` captures the account; the nav lock covers a switch attempt mid-flow. |
| I9 | **The merge is a last resort only where the data proves identity.** Thunder and WIF records (no key origin) are never auto-merged. | §6.2. |

**What can still go wrong, and what it costs:** a moved store that fails I3/I4 is reverted, costing
nothing. A missed file on rollback costs a re-sync. A bug that selects the wrong account for the
Home view costs confusion, not coins, because every money surface still shows the chip of the
account it reads from. There is **no path in this plan that destroys a phrase**, which is the only
thing that destroys funds.

---

## 1. The ask, in one paragraph

Today `ManagedWallet` = one seed **pinned** to one `(network, scriptType)`. The same phrase on a
second chain is a second `ManagedWallet` with its own `walletId` and its own Keychain copy of the
phrase (`copyWallet`). That is what Paul finds restrictive: the wallet list fills with "Wallet 1",
"Wallet 1 (Bitcoin)", "Wallet 1 (Thunder)", each backed up separately, each selected separately.
The new model: a **Wallet is the seed**, and inside it the user switches **which network** (and
which script type) they're looking at. One list entry, one phrase, one backup flag.

## 2. What is already true (facts the design leans on)

- **One BIP39 phrase serves every chain we have.** Bitcoin and every eCash generation derive BIP84
  at coin-type `0'` (identical addresses); L2L Signet at `1'`; Thunder derives ristretto255/FROST keys
  from the same phrase in the Fuse-native `ThunderWallet` (its `ManagedWallet` stores **empty**
  descriptors and relies on the Keychain phrase). The only non-HD case is a **WIF** wallet: one
  secp256k1 key, usable only on the coin-type `0'` chains, no Signet, no Thunder.
- **BDK chain data is already namespaced per `(walletId × network)`**:
  `BDKWalletEngineFactory.makePersister` writes `<walletId>-<network>.sqlite`, and `purgeChainData`
  removes every `<walletId>-*` file. Built 2026-06-14 for exactly this feature.
- **Every persisted HD descriptor carries its key origin**, `wpkh([fingerprint/84'/0'/0']xpub…/0/*)`.
  The **master fingerprint** is the same for one seed on any coin-type / script type. That is the
  handle the migration uses to recognise copies of one seed **without reading a single mnemonic**.
- **Per-`walletId` app stores**, all keyed by the id string: Keychain (`ecashwallet.mnemonic.<id>`),
  BDK stores, `ThunderAccountKeyStore` / `ThunderAddressIndexStore` / `ThunderFirstSeenStore`,
  `SplitCheckStore`, `isBackedUp`, `sortIndex`. CoinNews identity is derived from the phrase (per
  seed, not per record). CoinNews feeds / topic subscriptions / sidechain lists are keyed per
  **network**, not per wallet.
- `WalletNetwork.selectable` is `[ecashMainnet, bitcoin, signet]` since 2026-10-30 (betanet and
  Thunder betanet retired from the picker; cases kept so old records load).
- `AppState` mirrors ONE `balance` / `pendingBalance` / `transactions` / `syncState` /
  `splitSummary` for the selected wallet, re-rooted on `select`.

## 3. The model

```
Wallet (= seed)                         one list entry, one Keychain entry, one backup flag
 ├─ id, label, keyType (mnemonic | wif), isBackedUp, sortIndex, createdAt
 ├─ selectedAccountId                   remembered per wallet
 └─ accounts: [Account]                 created lazily; never removed by a switch
      Account = (network, scriptType, accountIndex)
       ├─ id            "<network>-<scriptType>-<accountIndex>"   e.g. "ecashMainnet-bip84-0"
       ├─ externalDescriptor / internalDescriptor   public; "" for a sidechain account
       ├─ storeName     the BDK sqlite file name (explicit, so legacy names survive — §6)
       └─ lastSyncedEpochSeconds
```

### 3.1 Mainchains and sidechains are a hierarchy, not two lists

Each `WalletNetwork` gets a `kind`: `.mainchain` or `.sidechain(parent: WalletNetwork)`. The
switcher shows the mainchains (**eCash mainnet, Bitcoin, L2L Signet** — the `selectable` list), and
under the mainchain you're on, its sidechains (Thunder-on-eCash once a Thunder mainnet node exists;
today only a wallet that already *has* a Thunder-betanet account sees that one). Bitcoin has none.
This is the natural home for deposits (parent account → its sidechain account) and keeps
"Thunder-on-betanet" and "Thunder-on-mainnet" from ever being confused: they are different accounts
with different parents.

**Decided 2026-11-04 (Jake): nested.** The switcher lists the mainchains; the one you're on expands
to show its sidechains. A flat list was the alternative; the data model is the same either way.

### 3.2 What an account *is* per key family

| Family | Networks | Account derives | Needs the phrase to create? |
|---|---|---|---|
| coin-type `0'` | eCash mainnet, Bitcoin (+ retired alphanet/betanet for old records) | BIP84/86/44/49 public descriptors at `m/<purpose>'/0'/<acct>'` | yes, once (xpub) |
| coin-type `1'` | L2L Signet | same at `…/1'/…` | yes, once |
| Thunder | `.thunder` (per parent chain) | ristretto account public key (already cached in `ThunderAccountKeyStore`) | yes, once |
| WIF | eCash mainnet, Bitcoin only | the single `pkh(<pubkey>)` descriptor, same on both | no (pubkey is in the record) |

**At create and import we already hold the phrase in memory, so we derive every mainchain
account's default-script-type descriptors right then** (`0'` bip84, `1'` bip84, Thunder account key).
Switching a new wallet between networks therefore never touches the Keychain. Only a **migrated**
wallet that lacks a family (e.g. an eCash-only wallet switching to Signet for the first time), or
adding a **new script type**, needs one `DeviceAuth`-gated phrase read to derive the missing xpub,
after which it's cached in the record forever. The engine stays watch-only; signing remains the
only other Keychain read (`docs/key-storage.md §3`).

### 3.3 Script types (phase 2 — see §8)

An account is `(network, scriptType)`, so "give me a taproot receive address" = enable the
`<network>-bip86-0` account, sync it, derive from it. BDK's `Wallet` holds one descriptor pair, so
each script type is its own BDK wallet, own sqlite store, own sync. Consequences:

- **Balance on Home = sum over that network's enabled accounts**; Activity merges their tx lists
  (dedupe by txid — a tx can touch two of them).
- **Receive** defaults to the primary script type (bip84 unless the wallet was imported at another)
  with a secondary "address type" control. Switching address type there is what enables the account.
- **Send** (phase 2a) spends from **one** account at a time: the primary, or the one that holds the
  funds if the primary is short — with the review screen stating which. A single `TxBuilder` cannot
  coin-select across two BDK wallets. **Phase 2b** (optional): cross-account sends via foreign UTXOs
  (`add_foreign_utxo` + sign the PSBT with each account's transient signer). Both signers come from
  the same phrase, so the key-storage model is unchanged; it's just more code. Decide after 2a.
- Legacy/nested (bip44/49) stay import-or-recovery only, never offered on a fresh wallet (same
  reasoning as `ScriptType.creatable`).

### 3.4 Everything else per account vs per wallet

| Per **wallet** (seed) | Per **account** |
|---|---|
| label, `isBackedUp`, `sortIndex`, keyType, Keychain entry, CoinNews identity, `selectedAccountId` | descriptors, BDK store, sync state, balance, tx list, Thunder address index / first-seen, split-check state (eCash accounts only), last-synced |

## 4. Behaviour, screen by screen

- **Create:** no network picker and **no script-type picker** (Jake, 2026-11-04): every new
  mainchain account is native segwit (bip84). Taproot comes back as an on-demand address type on
  Receive in phase 2, never as a creation decision. **The "New wallet" screen itself goes** (Jake,
  2026-11-05): with both pickers gone it held only an explainer paragraph and Continue, so "Create
  wallet" (onboarding and the wallet list) pushes the **entropy grid directly** — no explainer
  paragraph above it either (Jake, 2026-11-05: the grid's own copy is enough). Flow: entropy grid → seed preview → generate → derive the `0'`, `1'` and Thunder
  account keys → persist with `selectedAccountId = ecashMainnet-bip84-0` → Home. The 12/24-word
  choice stays in Settings; labels and the backup nudge are unchanged.
- **Import:** phrase → same derivation. The **Advanced** section keeps script type + account index
  (recovery-correctness, `docs/custom-derivation-path-import.md`), applied to the accounts created at
  import. Phase 3 (§8): scan all four script types on the default network and keep those with
  history, so the Advanced section becomes optional.
- **WIF import:** creates a WIF wallet whose switchable set is `{eCash mainnet, Bitcoin}`.
- **Home header / switcher:** the wallet switcher pill stays the *wallet* picker; a **network chip
  becomes tappable** and opens the network/sidechain switcher for the selected wallet. Switching:
  persist `selectedAccountId` → evict that wallet's cached engine → swap `AppState` to the target
  account's cached state → `sync()` → `refreshPrice()`. The chip colour, unit label, explorer, HRP,
  and the real-money send confirm all keep resolving from `NetworkRegistry` by the **selected
  account's** network, so Golden Rule §6 holds without per-screen work.
- **Receive / Send / Activity / tx detail:** operate on the selected account. "Send to one of my
  wallets" lists other **wallets'** accounts on the **same network** (not other wallets on any
  network) and fills from that account's `nextUnusedAddress`.
- **Backup:** one phrase per wallet; `isBackedUp` is seed-level (a copy no longer needs re-verifying).
- **Remove wallet:** purges the Keychain entry, **every** account's store (`<id>-*` already), every
  per-`walletId` app store, and any orphan Keychain ids recorded by the migration (§6.4).
- **Copy to network…:** removed from the ⋯ menu and Settings; the row becomes "Switch network".
- **Claims:** `ClaimNetwork.target(selected:)` reads the selected account's network — unchanged rule.
- **Split coins:** runs per eCash account; the Home nudge shows for the selected account only.
- **CoinNews / Sidechains / Dashboard:** already keyed per network; they follow the selected
  account's network exactly as they follow the selected wallet's network today.
- **Settings → Network:** lists `selectable` plus any network that **any account** is on (so a
  retired chain's endpoint stays editable).
- **Hide retired networks** (Settings → Network toggle, **on by default** — Jake, 2026-11-09;
  `RetiredNetworks`, `WalletNetwork.isRetired` = not in `selectable` and not a sidechain of an
  offered mainchain: alphanet, betanet, Thunder betanet). Display only — nothing is deleted,
  re-keyed, or stops syncing. With it on: retired entries leave the switcher (the account the wallet
  is open on always stays), retired balance lines leave the wallet rows, and a wallet whose accounts
  are **all** retired leaves the list and is never auto-selected (if the selected wallet becomes
  hidden, selection moves to the first visible one). Two guard rails: **the list is never empty** —
  if every wallet is retired-only nothing is hidden, and the list says so (the welcome screen is for
  people with no wallets); and the list footer states how many wallets are hidden. Home shows a
  nudge on a retired account — "open this wallet on eCash" — which is just `switchNetwork` to
  `currentEcash` (deriving the account on first use, behind the device-auth gate).

### 4.1 Flows that must survive unchanged (non-negotiable — Jake, 2026-11-04)

These exist for investors and are not casualties of the refactor. Each is re-stated here in the
new model's terms so nobody "simplifies" it away:

- **WIF private-key import.** Import → Advanced → *Private key* stays. A WIF becomes a **wallet with
  `keyType = .wif`** whose only possible accounts are the coin-type `0'` mainchains (eCash mainnet,
  Bitcoin); both carry the same `pkh(<pubkey>)` descriptor, so switching between them needs no
  secret. No Signet, no sidechains, no script type (`availableNetworks` enforces this). The live
  address preview on the import screen keeps working (it previews on the default network).
- **"Claim your ECX."** The prominent card at the top of the wallet list (`WalletManagerSheet`)
  still opens the import screen in **claim mode**: private-key input only, no network picker, no
  Advanced, the explainer copy ("nothing moves until you choose to send"), default name from
  `nextClaimWalletName`. It creates a WIF wallet whose **selected account is the claim network**
  from `ClaimNetwork.target(selected:)` — the selected wallet's eCash chain, else eCash mainnet —
  exactly today's rule, now reading the selected *account's* network. The Home **claim-sweep nudge**
  (gated on `keyType == .wif` holding funds, never on the label) and its jump into Send with the
  full balance preselected are unchanged; "send to one of my wallets" lists the user's seed wallets'
  accounts on that same network, which is the whole point of the claim.
- Both flows get a real-BDK test and a line in the manual upgrade matrix (§9).

## 5. Security

- **No new secret handling.** The phrase is read at create/import (already), at sign (already), at
  reveal (already), and — new — once when a migrated wallet enables a key family it lacks, behind
  the same `DeviceAuth` gate as reveal. Descriptors persisted are public; `Wallet.load` stays
  watch-only with `check_network` enforced.
- **Replay between Bitcoin and eCash mainnet.** The 2026-06 plan forbade grouping them. That rule
  was about *one store shared by two chains*; stores are per account now, and copy-to-network has
  let one seed hold both chains since 2026-09-24 anyway. Replay is a property of the chains, not of
  how the app files the keys: a plain BTC spend of a pre-fork coin replays onto eCash regardless.
  The mitigations stay what they are — the eCash `nLockTime` replay marker on eCash sends (compiled
  in), **split coins** for shared UTXOs, the orange/real-money chip and heavier confirm on *both*
  mainnets. Switching between them must be visually loud: the chip flips colour, and the send
  review states the network (Golden Rule §7). **Never** auto-switch a wallet's network for the user.
- **Wrong-network broadcast.** The switch is atomic (persist → evict → swap state → sync) and the
  send flow reads the network from the account it was opened on, carried in `SendViewModel`, so a
  switch mid-flow cannot retarget a review that's already on screen (we lock navigation during
  authorize already — extend the lock to a network switch).
- **Merged records (migration)** only ever merge on an exact master-fingerprint match read from our
  own persisted descriptors; a record without an origin (WIF, Thunder, hand-edited) never merges.
  The merge moves/renames public chain-cache files only. Worst case of a wrong merge is a chain store
  attached to the wrong id → a re-sync, never a lost key.

## 6. Migration (the careful part)

**Principle: the legacy `walletId` becomes the wallet id.** Then the Keychain key, every
`<walletId>-<network>.sqlite`, and every per-`walletId` UserDefaults key stay valid with **no
rename and no re-sync** for a wallet that isn't merged. Each legacy record becomes a wallet with
exactly one account, `(record.network, record.scriptType, record.accountIndex)`, selected.

### 6.1 Storage

- New file `wallets.v2.json` beside `wallets.json`. `wallets.json` is **left in place, frozen** (never
  written again) so a downgrade still boots with pre-migration state. `UserDefaults` flag
  `wallets.migration.v2.done` prevents re-running. The manager loads v2 if present, else migrates.
- Each account record carries `storeName` explicitly. Migrated accounts get the file they already
  have (`<id>-<network>.sqlite`, whatever their script type); new accounts get
  `<id>-<network>-<scriptType>-<acct>.sqlite`. No naming heuristics anywhere.

### 6.2 Merging copies of one seed

Group HD records by the master fingerprint parsed from `externalDescriptor`'s key origin
(`ManagedWallet.keyOriginPath` already parses the origin; add a fingerprint accessor). Within a
group:

1. **Primary** = lowest `sortIndex` (the original). Its id, label and Keychain entry survive.
2. Every other record becomes an **account** of the primary: `(network, scriptType, accountIndex)`.
   Its chain store `<secondaryId>-<network>.sqlite` (+`-wal`/`-shm`) is **moved** to
   `<primaryId>-<network>-<scriptType>-<acct>.sqlite` and recorded as that account's `storeName`.
   Two records on the same `(network, scriptType, acct)` (shouldn't exist — `existingCopy` blocks
   it), or a destination file that already exists: the later record is **kept as its own wallet**,
   untouched, and listed in `keptStandalone` for the report. Nothing is dropped, nothing guessed.
3. `isBackedUp` = OR of the group. The label of a secondary (`"Wallet 1 (Bitcoin)"`) is dropped.
4. If the secondary was the **selected** wallet, selection moves to the primary with that account
   selected — the user lands on the same balance they left.
5. Per-`walletId` app stores of a secondary (`SplitCheckStore`, Thunder stores): re-key to the
   primary id where the store is per account (Thunder index/first-seen become per account anyway —
   §3.4); `SplitCheckStore` is per eCash account — re-key likewise. Pending CoinNews posts are
   transient and keyed per network; nothing to do.
6. The secondary's **Keychain entry is NOT deleted — by the migration or by anything automatic in
   phase 1** (invariant I1). Its id goes into the wallet's `orphanKeychainIds` and is purged only by
   **remove-wallet** of the merged wallet (the user is deleting that seed anyway). A later release
   may add proof-on-first-use purging (after a successful sign/reveal from the surviving entry); it
   is deliberately not in scope now. Deleting a phrase is the one irreversible step in here.

Thunder records have no descriptor, so a Thunder record stays a **separate wallet** after migration
(one account, `.thunder`). A Settings action "Merge into…" can fold it into its sibling later with a
`DeviceAuth`-gated phrase comparison. Acceptable for v1 of this; most Thunder betanet wallets will
be removed by their owners as betanet winds down.

### 6.3 Dry run and failure handling

**As built (step 3, 2026-11-05):** `WalletMigrationV2Applier` in WalletService. `WalletManager.load`
runs it before reading the list; it has no `KeyStore` reference and no logging of its own. Order:
`store.beginV2Migration()` (copies `wallets.json` → `wallets.json.pre-v2`, once) → plan → for each
merged record with a store: open its legacy store with its own descriptors **load-only** and read
the balance → move the `.sqlite` (+`-wal`/`-shm` if present) → reopen at the account name, same
descriptors, compare the balance → on any failure move it back, record the exclusion
(`load-before` / `move` / `load-after`), re-plan with that id pinned standalone, continue → write
`migration-v2.log.json` (ids, store names, counts, exclusions, selection — never a label or
descriptor; a test scans for canaries) → `store.commitV2`. An empty legacy list is committed as an
empty v2 list so a fresh install writes v2 from its first wallet. A destination already present
with its source gone is an interrupted earlier run: the record is still merged and the store is
verified in place, never moved twice. The app's persisted selection goes INTO `load(savedSelectedId:)`
so it can be mapped to the wallet a merged copy now lives in (`migratedWalletId(forLegacy:)`).
The per-`walletId` app-store re-keys (`SplitCheckStore`) are in the report's `rekeys` and are
applied app-side in step 5.

- The migration is **computed fully in memory first** (plan: wallets, moves, re-keys), then applied:
  copy `wallets.json` → `wallets.json.pre-v2` → file moves, each followed by the BDK reopen +
  balance check (I3/I4; a failing move is reverted and that record stays standalone) → write
  `migration-v2.log.json` → write `wallets.v2.json` → set the flag. A failure before the flag leaves `wallets.json`
  authoritative and the next launch retries; a move that already happened is idempotent (check the
  destination first).
- Log the plan's shape (counts, ids) — never descriptors or labels.
- Ship with a hidden Settings → Advanced "Show migration report" for the first release so a tester
  can confirm what was merged.

### 6.4 Rollback

A downgrade reads the frozen `wallets.json`: every pre-migration wallet still loads from its old
store name **unless it was a merged secondary** (its store was moved). Those re-sync from scratch on
the old version — watch-only, re-derivable, no fund risk. Wallets created after the migration are
invisible to the old version (their phrases remain in the Keychain; a later upgrade sees them again).
Document this in the release notes for the build that ships it.

## 7. Code shape

`WalletService` (bridged surface — signed types only, no `Date`):

```swift
public struct WalletAccount: Equatable, Hashable, Sendable {      // bridged value type
    public let id: String                 // "<network>-<scriptType>-<acct>"
    public let network: WalletNetwork
    public let scriptType: ScriptType
    public let accountIndex: Int32
    public var externalDescriptor: String // "" for a sidechain account
    public var internalDescriptor: String
    public let storeName: String
}

public struct ManagedWallet {            // becomes the container
    public let id: String
    public var label: String
    public let keyType: WalletKeyType
    public var isBackedUp: Bool
    public var sortIndex: Int
    public var selectedAccountId: String
    public var accounts: [WalletAccount]
    public var selectedAccount: WalletAccount { … }
    /// The selected account's network — the official read-through (kept, see §11 step 5).
    public var network: WalletNetwork { selectedAccount.network }
}
```

`WalletManager`:
- `createWallet(label:wordCount:scriptType:)` / `importWallet(label:mnemonic:scriptType:accountIndex:)`
  / `importPrivateKey(label:wif:)` — **no `network:` parameter**; they derive all mainchain accounts.
- `switchAccount(walletId:to:)` — target must be in `availableAccounts(for:)`; creates the account
  if its key family is already derivable from stored data; otherwise throws
  `WalletError.needsSecret` and the app repeats the call through `withSecret` after `DeviceAuth`.
- `availableNetworks(for walletId:)` → the mainchains in `selectable` (filtered by key type) plus any
  network an account is already on, plus the sidechains of the selected mainchain.
- `engine(for: wallet, account:)`; engine cache keyed by `account.storeName`.
- `copyTargets` / `copyWallet` / `existingCopy` **deleted**.
- Migration lives in its own file, `WalletStoreMigrationV2.swift`, pure function
  `plan(legacy: [LegacyRecord], files: [String]) -> MigrationPlan` so it's unit-testable without
  BDK or a filesystem, plus a thin applier.

`WalletNetwork` gains `kind` (`.mainchain` / `.sidechain(parent:)`) and `keyFamily` goes public
(it already exists, internal). `NetworkRegistry` unchanged.

App: `AppState` keys its mirrored state by `(walletId, accountId)`; `selectedWallet.network`
call sites (~140 across ~45 files) move to `selectedAccount.network` via the shim, then the shim
goes. `NetworkBadge` becomes tappable on Home. New `NetworkSwitcherSheet` (mainchains, then
sidechains of the current one). `NetworkSelector` and `CopyWalletSheet` are deleted.

## 8. Phasing

| Phase | Scope | Rough size |
|---|---|---|
| **1 — containers + network switch** | model + v2 store + migration + switch sheet + create without network or script-type pickers (bip84 fixed; import keeps Advanced) + AppState per account + copy-to-network removed | ~2 weeks incl. tests, both platforms |
| **2a — script types** | per-`(network, scriptType)` accounts, Receive address-type control, summed balance, merged Activity, single-account sends | ~1 week |
| **2b — cross-account sends** | foreign-UTXO PSBT across accounts of one seed, double-sign | ~1 week, optional |
| **3 — import auto-discovery** | scan bip84/86/49/44 on import, keep accounts with history | ~3 days |

Phase 1 ships alone as **1.5.0**. Bump `CURRENT_PROJECT_VERSION` as usual (never reset).

## 9. Tests (CLAUDE.md §11 bar)

**Pure (Robolectric, both platforms):**
- Migration planner: one record → one wallet/one account, no moves; two records same fingerprint →
  one wallet/two accounts, one move, primary = lowest sortIndex, selection follows; WIF and Thunder
  records never merge; records with identical `(network, scriptType, acct)` keep the newer; the plan
  is idempotent on re-run; descriptors and labels never appear in the plan's log string.
- `availableNetworks` per key type (WIF ⇒ no Signet, no Thunder); sidechains listed under parent only.
- `switchAccount` rejects an unknown target; throws `needsSecret` when the family isn't derivable.
- `AppState`: switching network swaps balance/tx/sync state to the target account's cached values,
  never shows the previous network's numbers, triggers one sync.
- `storeName` is explicit and stable across encode/decode; v2 JSON decodes with unknown future fields.

**Real BDK (sim + emulator):**
- One phrase → `0'` and `1'` accounts have different descriptors, same master fingerprint;
  `bip84`/`bip86` on one network have different descriptors, same fingerprint.
- Create → three mainchain accounts persisted with correct paths (vectors), no Keychain read on switch.
- Migrated secondary's store moved; its UTXOs/balance identical after the move (no re-sync).
- `check_network`: loading an account's store with another network fails loud.
- Remove wallet purges every account store + orphan Keychain ids.
- Sign from an account other than the first created (private descriptor rebuilt per account's
  script type/coin type — the sign path must honour the **account**, not the wallet default).

**Flows (both platforms):** WIF import creates a `.wif` wallet with exactly the `0'` mainchain
accounts and the same descriptor on each; the claim path (claim mode → WIF wallet → selected
account = `ClaimNetwork.target`) ends on Home with the sweep nudge visible and Send prefilled with
the full balance; a `.wif` wallet's switcher never offers Signet or a sidechain.

**Manual before release:** upgrade a device with (a) one eCash wallet, (b) eCash + its Bitcoin
copy, (c) a Thunder betanet wallet, (d) a WIF wallet; verify balances identical pre/post, then
downgrade and confirm (a)/(c)/(d) still load. Then on the upgraded build run a fresh **investor
claim** end to end (paste key → balance shown → sweep to a seed wallet) on eCash mainnet with a
small real amount.

## 10. Open questions

1. ~~Switcher UX: nested vs flat~~ — **decided nested** (Jake, 2026-11-04; §3.1).
2. **Should the chip itself be the switch control**, or a separate row/button? A tappable chip is
   discoverable but a mis-tap next to the balance is a network change; recommend the chip opens a
   sheet with the current network highlighted and an explicit tap to switch (no swipe/segmented).
3. **Orphan Keychain entries — UNDECIDED (Jake, 2026-11-04: "not sure").** Phase 1 never purges
   them automatically (I1), so this does not block starting. What an orphan is: after a merge, the
   secondary record's Keychain entry still holds the *same phrase* the surviving entry holds — a
   duplicate, not a different key. Options, to decide before phase 1 ships:
   - **(a) Leave them until remove-wallet** (phase 1 default). Cost: a stale duplicate of a phrase the
     user still has; remove-wallet purges both. Zero risk of deleting the only copy.
   - **(b) Proof-on-first-use purge**: delete the orphan only after the surviving entry has been
     loaded and used successfully (a sign or a reveal). Safe in principle; it is still the one place
     in the design that deletes a phrase, which is why it is not in phase 1.
   - **(c) Purge during migration** — rejected (violates I1).
   Recommendation: (a) for 1.5.0; revisit (b) only if duplicate entries cause a concrete problem.
4. **Thunder mainnet**: there's no `NetworkRegistry` entry yet; phase 1 ships the sidechain level
   with only migrated Thunder-betanet accounts visible. Fine?
5. **Default script type for the whole wallet** vs per network: per wallet (recommended), so a
   bip86-imported wallet's eCash and Bitcoin accounts both start at bip86. Fresh wallets are always
   bip84 (decided 2026-11-04).
6. **Phase 2b** cross-account sends: worth it, or is "send from the account that holds the funds"
   enough? Decide after 2a is in hand.

## 11. Getting started (how to begin phase 1)

Branch `seed-container` off `main`. Work in this order — each step is a reviewable PR on its own,
and nothing user-visible changes until step 5.

1. ✅ **Migration planner, pure and tested first** (DONE 2026-11-05, branch `seed-container`).
   `Packages/WalletService/.../WalletStoreMigrationV2.swift`:
   `LegacyRecord` (today's `StoredWallet` DTO), `MigrationPlan` (wallets, accounts, file moves,
   re-keys, standalone ids), and `plan(legacy:files:)` with no BDK, no filesystem, no Keychain
   reference (I1). Add `ManagedWallet.masterFingerprint` (parse the key origin next to
   `keyOriginPath`). Write the §9 planner tests before the planner. Transpiles under Skip, so keep it
   in the Lite subset (no `Set` parameters — see `SplitSummary.classify`).
2. ✅ **Model** (DONE 2026-11-05). `WalletAccount` (bridged), `WalletNetwork.parentChain` /
   `isSidechain` / `sidechains(of:)` (an optional parent rather than an associated-value enum — bridge
   safe), `keyFamily` public, `ManagedWallet` is the container (`accounts`, `selectedAccountId`,
   `mergedFrom`, `orphanKeychainIds`) with `network` / descriptors / `scriptType` / `accountIndex`
   reading through to the selected account so every caller still compiles; the legacy
   `network:` initializer builds a one-account wallet. `FileWalletStore` reads/writes
   `wallets.v2.json` (`{"version":2,"wallets":[…]}`) once `commitV2` has run and never touches
   `wallets.json` again; before that it stays on the legacy file and refuses a multi-account
   write. The planner emits real `ManagedWallet`s. Verified: WalletService 328 host + JUnit, app
   592 tests, Android debug APK with the regenerated bridge.
3. ✅ **Applier** (DONE 2026-11-05, §6.3 "as built"). The "done flag" is the v2 file's existence
   (`FileWalletStore.isV2`) — one source of truth, no UserDefaults flag to drift. Mock-factory tests
   cover merge / empty list / run-once / pass-through / back-out before and after the move /
   resume / report scrubbing; `MigrationApplierBDKTests` runs the whole thing over real BDK SQLite
   stores with a funded store (balance intact after the move, snapshot byte-identical, second launch
   a no-op) and a store written for a different seed (refused by BDK's load, left in place).
   Remove-wallet now purges `orphanKeychainIds` (never a live wallet's id). Still to do on a real
   device: the §9 manual upgrade matrix, before 1.5.0.
4. ✅ **Manager** (DONE 2026-11-05). `createWallet` / `importWallet` / `importPrivateKey` take no
   network: while the secret is in memory they derive an account on every offered mainchain the key
   type can live on (`mainchainsForNewWallets`: eCash mainnet, Bitcoin, L2L Signet; a WIF key only
   the coin-type-0' pair), stores named by the new scheme. `selectedNetwork:` (default
   `.currentEcash`; the claim passes its claim chain) only picks which account the wallet opens on.
   `switchAccount` is the one place `selectedAccountId` changes; `enableNetwork` switches or
   derives-then-switches (the app gates the deriving case behind `DeviceAuth` via `hasAccount`);
   `availableMainchains` / `availableSidechains` feed the nested switcher. The engine cache is
   keyed by the account's store, the BDK persister opens `selectedAccount.storeName`, and the sign
   closure already derives from the selected account's script type and network (I7). The three
   copy-to-network methods are kept as **shims over `enableNetwork`** so the old sheet keeps
   working on the branch; step 5 deletes them with the sheet.
5. ✅ **App** (BUILT 2026-11-05). `NetworkSwitcherSheet` (nested: mainchains, the current one's
   sidechains indented under it; current marked; a lock glyph on a chain the wallet has no account
   on yet) opens from the Home chip, the wallet-list ⋯ menu ("Switch network…") and Settings.
   `AppState.switchNetwork` gates a first-time chain behind device auth, then re-roots the money
   surfaces like a wallet switch. `CreateWalletScreen` replaces `CreateConfirmView`: create pushes
   the entropy grid directly (its own copy explains the swipe). Import keeps Advanced and claim
   mode exactly; `NetworkSelector`, `CopyWalletView`/`CopyWalletViewModel` and the manager's copy
   shims are deleted. "Send to one of my wallets" lists every wallet with an account on the sending
   network and pays THAT account (`nextUnusedAddress(walletId:network:)`); a payment link's
   candidates are (wallet × payable account), so an ambiguous link on a seed wallet still asks
   which chain. Settings → Network lists every account's network. `SplitCheckStore.rekey` applies
   the report's `rekeys` at launch. **`ManagedWallet.network` stays** as the documented
   read-through to the selected account (it is exactly what every money surface wants), so the
   ~140 call sites were not churned — the "compat shim" framing in §7 is withdrawn.
6. **Release prep.** Manual upgrade matrix (§9) on both platforms from a 1.4.7 build, release notes
   stating the downgrade behaviour (§6.4), bump to 1.5.0 / next build number, update CLAUDE.md §2
   Golden Rule 4 and §4 to the container model in the same PR.

Before step 1, re-read §0. If a step can't satisfy an invariant, stop and change the plan, not the
invariant.

