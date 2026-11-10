# Accounts & Labels (metadata) — design record

**Status:** 🔵 DESIGN (post-v1 feature; shape the data model now to avoid a migration). Covers
multi-account-per-seed (savings/checking) and per-key-pair / per-output / per-tx metadata. Complements
`docs/key-derivation.md` and `docs/key-storage.md`. Address labeling / coin control is CLAUDE.md §12
"Future".

---

## 1. The core fact: BDK does not store semantic metadata

Verified against `bdk_wallet` 2.3 (bdk-swift bindings): **no label / memo / note / metadata / tag /
BIP-329 API.** BDK owns the consensus + wallet data; everything human/semantic is **app-owned**, in
our `WalletStore`.

| BDK owns (its SQLite via `Persister`) | We own (`WalletStore`) |
|---|---|
| descriptors, derived scripts, **derivation index + keychain** per address, UTXOs (`LocalOutput`), transactions, chain state | account names, address/tx **labels**, free-text **notes**, **coin-control** flags (frozen/do-not-spend), optional fiat-at-receive, contact tags |

BDK gives us the **stable anchors** to key metadata to: each address knows its `(keychain, index)`,
each UTXO its `outpoint (txid:vout)`, each tx its `txid`.

## 2. Accounts (savings / checking from one seed)

"Savings" and "checking" from the same mnemonic = the BIP-84 **account level**:
`m/84'/coin'/account'/…` — savings = account `0'`, checking = account `1'`. Each account is a fully
separate branch: own xpub, own gap-scan, own balance/history. Our `Descriptors.accountPath(for:account:)`
already takes the account index (we just always pass `0` today).

**Data-model change** — **DONE in shape (2026-11-10, seed-container 2026-11-05):** the seed/account
split below is now the real model. A `ManagedWallet` *is* the seed and holds one `WalletAccount` per
`(network, scriptType, accountIndex)` (`Packages/WalletService/Sources/WalletService/Models.swift`,
`WalletAccount`), each with its own BDK store. What is *not* done: `accountIndex` is always `0`
today (no "add account to this seed" UI), and no labels / BIP-329 / freeze flags exist yet.

- **Seed** — the mnemonic (KeyStore, keyed by the wallet id). The unit you back up. `isBackedUp`
  lives here (`ManagedWallet`).
- **Account** — as built: `WalletAccount { id, network, scriptType, accountIndex: Int32,
  externalDescriptor, internalDescriptor, storeName }` (the id is
  `"<network>-<scriptType>-<accountIndex>"`, unique within its wallet, so the `seedId` is the
  enclosing wallet's id); each gets its own BDK `Wallet` + per-account `Persister` (own
  balance/history/addresses). A per-account `label` is still not stored.
- **Remove** has two levels: remove an account (its data) vs remove the seed (all its accounts + the
  mnemonic).
- **Restore discovery:** importing a mnemonic scans account `0'`, and if it has history, `1'`, … by an
  account gap limit. Rediscovers the accounts — **but not their labels** (see §4).

**Security tradeoff:** one-seed-many-accounts = a single backup phrase (convenient) but a seed
compromise exposes every account; separate mnemonics = stronger isolation, more backups. Offer
both: "add account to this seed" vs "add new wallet".

> **DECIDED 2026-06-12 (now `docs/seed-container-model.md` §1a):** the **default** is separate seeds —
> a "Wallet" = its own mnemonic (savings/checking/inheritance = three phrases; inheritance
> especially wants isolation). **Accounts-under-one-seed is the opt-in, later feature** described
> here, not the default and not v1.

## 3. Per-key-pair / per-output / per-tx metadata

A small app-owned store, namespaced by account, keyed BIP-329-style:

```
WalletMetadata {
  accountId: String
  type: addr | output | tx | xpub      // (BIP-329 ref types)
  ref:  String                          // address (or "keychain/index"), "txid:vout", txid, or xpub
  label: String?
  note:  String?
  frozen: Bool                          // coin-control: exclude from coin selection (future)
  // createdAtEpoch, fiatAtReceive?, … as needed
}
```

- **Keying:** prefer `(keychain, index)` for address refs — stable across rescans. The address string
  is the equivalent human-facing ref and what BIP-329 uses on export.
- **Stored in `WalletStore`** (our local metadata), **never** in BDK's persister. Survives app restart;
  removed when its account/seed is removed (Golden Rule §5).
- **Coin control** (`frozen`) is the hook for later: the Send slice's `TxBuilder` would exclude frozen
  UTXOs (BDK supports unspendable/manual UTXO selection).

## 4. Labels are local — backup is a separate decision

Labels/notes are **not on-chain and not in the seed**, so a restore-from-seed on a fresh device gets
your coins back but **not your names/notes**. Options:

- **Best-effort local** (simplest): labels live only on the device; lost on uninstall/new device.
- **Backed up / portable:** adopt **BIP-329** label export/import (a `.jsonl` file of
  `{type, ref, label}`). Interoperable with other wallets. BDK doesn't implement it — we'd add the
  serializer (or a crate). This is the right answer if labels must persist.

Decision deferred; lean toward shipping local labels first, BIP-329 export as a follow-on.

## 5. Scope & sequencing

- **Not v1 build.** v1 ships multiple independent wallets (each its own seed). Multi-account-per-seed
  and labels/coin-control are post-v1 (CLAUDE.md §12).
- **But shape the schema now.** ✅ **DONE (2026-11-10):** the record is shaped — `WalletAccount`
  carries `accountIndex` (and is keyed under its wallet = seed), even though every account is
  `0` today — exactly like we built multi-wallet/multi-network from day one; retrofitting stored
  data later would have been the painful path. `Descriptors.accountPath(for:account:)` still
  defaults to `0`.

## 6. Open decisions

- [ ] Address-ref key: `(keychain, index)` vs address string (lean `(keychain, index)`).
- [ ] Labels best-effort-local vs BIP-329-backed (lean local first, BIP-329 later).
- [ ] UX naming when one seed has many accounts: is the top-level thing a "wallet" (= seed) with
      "accounts", or do we keep calling each account a "wallet" and group by seed?
- [ ] Coin-control (`frozen`) in v1 metadata schema even if the Send UI ships later? (cheap to include).
