# In-wallet network switching — design record (TO BUILD)

> **Status:** 🟡 PLANNED — not built. Captures what we need, how it stays secure, and the risks, so
> we can tackle it deliberately later. Today a wallet is **pinned** to the network chosen at
> create/import (`ManagedWallet.network` is `let`; there is no switch path). This doc is the plan to
> make the selected network switchable **within a safe group**.
>
> Complements `docs/wallet-and-network-model.md` (the "network is a switchable view" intent),
> `docs/key-storage.md`, `docs/backends-and-endpoints.md`, and `docs/key-derivation.md`
> (eCash = Bitcoin params). See memory `bitcoin-mainnet-bundled`.

---

## 1. Goal

Let the user switch which **network** a wallet is viewed on, **without re-importing the seed**, for
networks that share the wallet's key material — e.g. flip one seed between **Testnet4 ⇄ L2L Signet**
(and later eCash-testnet/signet). Each network keeps its **own isolated** balance/history/UTXO set;
switching shows the cached state immediately, then syncs.

**Out of scope / explicitly disallowed:** switching a wallet between networks that do **not** share
its address class — above all **mainnet ⇄ testnet** (different coin-type → different addresses) and
**Bitcoin mainnet ⇄ eCash mainnet** (same addresses, real money, no replay protection — §5). Mainnet
stays chosen at creation.

## 2. Why this is safe *in principle*

All testnet-class networks derive from **coin-type `1'`**, so the same seed produces the **same
public keys → the same scriptPubKeys** on every one of them. (The `NetworkRegistry` HRP — `tb` for
Testnet4/Signet, `bcrt` for Regtest — only changes the *address string*, not the on-chain script.)
So one descriptor set already serves all of them; switching is "point the same watch-only descriptors
at a different chain + backend." No key re-derivation, no new secrets, no Keychain access.

The networks are nonetheless **separate blockchains with separate UTXO sets**, and they're all
**valueless test coins**, so cross-chain replay among them is harmless. The only thing that can break
is our **local bookkeeping** if we let two chains share one cache — which §4 fixes.

## 3. What's already in place (reuse)

- **Coin-type-aware descriptors** (`Descriptors.swift`) — the `1'` set already serves all testnet-class.
- **Per-network backend resolution + overrides** (`WalletManager.resolvedBackend(for:)`, Settings →
  Network) — switching just resolves the new network's backend.
- **Engine cache eviction** — `engines.removeAll()` already runs on backend changes; reuse on switch.
- **Network badge + unit/explorer/HRP** all resolve from `NetworkRegistry` by the wallet's network,
  so the UI updates for free once the selected network changes.

## 4. What we must change

### 4.1 Make the selected network mutable (within a group)
- Add `WalletManager.setNetwork(walletId:to:)` that **rejects** any target outside the wallet's
  **switch group** (§5). `ManagedWallet.network` becomes settable through the manager (persisted to
  the `FileWalletStore`), or model the wallet as `{ addressClass fixed at creation, selectedNetwork
  switchable }`. Mainnet wallets have a singleton group → effectively still pinned.
- Evict the cached engine for that wallet on switch.

### 4.2 Namespace chain data per `(walletId × network)` — ✅ DONE (2026-06-14, ahead of the feature)
Done early because it's a no-op while wallets are pinned (1:1 rename) and de-risks the switcher.
- `BDKWalletEngineFactory.makePersister(for:network:)` now writes `<walletId>-<network>.sqlite`, so
  the same seed on two coin-`1'` chains never shares a store (their scriptPubKeys are identical, §2 —
  mixing would corrupt UTXO accounting / cause `bad-txns-inputs-missingorspent`).
- `purgeChainData` enumerates and removes **every** `<walletId>-*` / legacy `<walletId>.sqlite*` file,
  so remove-wallet still purges completely.
- **Migration:** a legacy un-namespaced `<walletId>.sqlite` (+`-wal`/`-shm`) is moved to the
  network-scoped path on first open of its pinned network, so existing chain data survives (no forced
  rescan).
- Covered by real-BDK tests (`testPurgeChainDataDeletesSqliteFile`, `testLegacyStoreMigratesToNetworkScopedPath`),
  host build + tests green, and a clean `skip app launch` on both platforms.

What remains for the actual switcher is everything else in this section (mutable selected network,
per-`(wallet×network)` observable state, the §5 allowlist, UI).

### 4.3 Per-`(wallet × network)` observable state
- `AppState` currently mirrors a single `balance`/`transactions` for the selected wallet. On switch,
  show that `(wallet × network)`'s cached state immediately, then `sync()`. Refresh fiat too
  (`refreshPrice()`), which already no-ops on networks without a price provider.

### 4.4 Harden the load fallback (defense in depth)
- `engine(for:)` does `Wallet.load` and, on **any** error, falls through to constructing a fresh
  wallet over the same path. With per-network stores this is fine, but we should make a
  **`check_network` mismatch fail loud** rather than be silently masked + re-initialized — it's the
  backstop that catches a wrong-network load.

## 5. Switch groups (the security rule)

Define explicit **switch groups**; a wallet may only switch *within* its group. Membership requires
**both**:
1. **Identical address derivation** (same coin-type → same scriptPubKeys), and
2. **Acceptable replay posture** — all members are valueless testnets, **or** the group is a single
   mainnet on its own.

| Group | Members | Switchable? | Why |
|---|---|---|---|
| Testnet-class | Testnet4, L2L Signet, Regtest (+ future eCash-testnet/signet) | ✅ yes | coin `1'`, shared scripts, valueless → replay harmless |
| Bitcoin mainnet | `bitcoin` | ❌ singleton | real money |
| eCash mainnet | `ecashMainnet` (future) | ❌ singleton | real money |

**Critical:** Bitcoin mainnet and eCash mainnet are **both coin-type `0'` with identical addresses**,
and eCash's replay protection is **opt-in + directional** (an eCash tx we stamp with the `nLockTime`
marker can't replay onto BTC, but a plain BTC tx *can* replay onto eCash, and the addresses are
indistinguishable). So they must **never** share a switch group — the same coin exists on both chains
and an unstamped signed tx can be valid on both (§6). "Same coin-type" is necessary but **not
sufficient** for grouping; the table is the allowlist, not a coin-type check.

## 6. Risks & mitigations

- **Local UTXO/cache collision (high, likely):** shared chain store across networks → merged/
  corrupted UTXO accounting. → **Per-`(walletId × network)` store** (§4.2). Primary mitigation.
- **Cross-chain replay (high, mainnet only):** identical-address chains with only opt-in/directional
  replay protection (BTC ⇄ eCash mainnet; we stamp the eCash `nLockTime` marker on eCash sends, but BTC
  txs still replay onto eCash). → **Never group them** (§5); they stay create-time-pinned singletons. Revisit
  with a full threat model before eCash mainnet ships.
- **Wrong-network broadcast (high):** sending while the UI/engine disagree on the active network. →
  Network badge everywhere (already), **send review states the network** (already), `check_network`
  on load (§4.4), confirm-before-broadcast (already, Golden Rule §7). Switch must atomically update
  the engine + the observable network the review reads.
- **Stale cache after switch (medium):** showing chain A's balance while on chain B. → swap to the
  target store's cached state on switch, then sync; never show another network's numbers.
- **Migration data loss (medium):** legacy `<walletId>.sqlite` orphaned by the rename. → migrate/
  fallback in §4.2; a missed file just forces a re-sync (no fund risk — watch-only, re-derivable).
- **No key/seed risk (reassure):** switching never touches the mnemonic; engine stays watch-only,
  signing remains the only Keychain read (`docs/key-storage.md §3`). Worst case is a corrupted local
  cache fixed by purge + rescan — never lost funds or exposed keys.

## 7. Definition of done (when we build it)

- `WalletManager.setNetwork` enforces the §5 allowlist (reject out-of-group with a typed error).
- Persister + purge namespaced by `(walletId × network)`; legacy migration covered.
- Switch is atomic: persist network → evict engine → swap observable balance/history/fiat → sync.
- UI: a network switcher (testnet-class only) on a wallet; badge/unit/explorer update everywhere;
  send review reflects the active network.
- Tests (per CLAUDE §11): two coin-`1'` networks on one seed keep **isolated** UTXOs/balances; a
  switch never mixes stores; out-of-group switch is rejected; remove-wallet purges **all** network
  stores; `check_network` mismatch fails loud. Real-BDK integration on sim + emulator.

## 8. Open questions

1. Model shape: mutate `ManagedWallet.network`, or split into `addressClass` (fixed) +
   `selectedNetwork` (switchable)? The latter encodes the §5 rule structurally.
2. Should a switch be remembered per wallet (persist last selected) — yes, almost certainly.
3. UX: where does the switcher live — wallet manager row, or a control on Home next to the badge?
4. Do we expose Regtest in the switcher in release builds, or dev-only? (See the regtest visibility
   note in memory `bitcoin-mainnet-bundled`.)
