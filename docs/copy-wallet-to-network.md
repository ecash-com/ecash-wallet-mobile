# Copy a wallet to another network — plan

> Status: **BUILT (2026-09-24).** Companion to `docs/alphanet-burn.md`. Works now
> against alphanet → betanet; the real-ECX target waits on the real eCash network entry (§6).

## 1. What it is

An action on a wallet, **"Copy to network…"**, that creates a new wallet on the chosen
network **from the same recovery phrase** (or WIF), without the user retyping it. The new wallet has
exactly the same keys and addresses, so it immediately sees whatever that seed holds on that network.

Why it's needed: a wallet's network is fixed at creation (`ManagedWallet.network` is `let`;
`docs/wallet-and-network-model.md`). Today, reaching the same coins on another eCash generation means
importing the phrase again by hand.

Uses:
- **Alphanet → betanet, now.** Bring an old alphanet wallet onto the current network in one tap.
- **Alphanet → real ECX, at the fork.** Burn credits (`docs/alphanet-burn.md`) are paid to the
  alphanet wallet's first address. On real ECX the same seed controls that address, so copying the
  wallet there is how the user reaches the credit.
- **eCash ↔ Bitcoin.** Same coin-type `0'` and `bc` addresses, so the same seed on Bitcoin sees the
  user's BTC. Useful for airdrop holders.

## 2. Why no key conversion is needed

eCash uses Bitcoin's parameters on every generation: coin-type `0'`, `bc` HRP, same key/xprv
formats (`docs/key-derivation.md`; `NetworkRegistry`: `.bitcoin`, `.ecash`, `.ecashBeta` are all
`coinType 0`, HRP `bc`). One secret → the same private keys and addresses on each. "Copying" is just
running the existing import with the stored secret.

## 3. Design

`WalletManager.copyWallet(id:to network:label:) throws -> ManagedWallet` (bridged):

1. Load the source wallet's secret from the Keychain (`KeyStore.loadMnemonic`, which also holds a WIF
   wallet's key).
2. Re-run the **existing** import with the source's derivation settings: `importWallet(label:,
   network:, mnemonic:, scriptType: source.scriptType)` for a mnemonic wallet, `importPrivateKey`
   for a WIF wallet. Carry `accountIndex` too once import accepts it; today every wallet is account 0,
   so assert that and fail loud if not.
3. **Verify before saving:** the new wallet's public descriptors must equal the source's (which
   implies the same index-0 address, and every address after it). On mismatch, throw and persist
   nothing. This catches any future derivation drift (a new script type,
   a passphrase) that would otherwise produce a wallet that looks right and holds nothing.
4. The new wallet inherits `isBackedUp` (same secret). Its label is `"<source label> (<network>)"`,
   e.g. "Wallet 1 (Betanet)" (decided 2026-09-24), so the two are distinguishable in the list.
5. Select it and **sync immediately**, like create/import already do (CLAUDE.md §6 sync triggers).

### Copy the secret; don't share it

The new wallet gets its **own `walletId` and its own Keychain entry** containing the same secret.
Removing either wallet then purges only its own copy (Golden Rule §5, remove = purge, stays simple).
Sharing one entry between wallets would need reference counting in the removal path, and a bug there
deletes a key the other wallet still needs. That's the one failure mode here that loses money.

### Security

- Reading the secret goes through **`DeviceAuth`** first, same as revealing the seed in Backup and
  same as signing. Never read it silently.
- The secret is in memory only for the import call; it never touches logs, errors or the JSON
  `FileWalletStore` (Golden Rule §2). Errors say "couldn't copy this wallet", nothing more.

## 4. Which copies to offer

| from → to | offer? | why |
|---|---|---|
| `.ecash` / `.ecashBeta` / real ECX / `.bitcoin` → another of these | **yes** | coin-type `0'`, identical addresses |
| `.signet` → the above (or back) | **no** | coin-type `1'` vs `0'`: different addresses, so it isn't "the same wallet"; a user expecting their coins would see an empty wallet |
| anything ↔ `.thunder` | **no** | ed25519, a different key system entirely |
| to a network where this seed already has a wallet | **no** (listed greyed out as "Added ✓", not tappable) | two wallets with the same keys on one network double-count and confuse |

Gate on a property, not scattered equality checks: e.g. `WalletNetwork.addressFamily` (same family =
copyable), exhaustive like `supportsCoinSplit`.

### Real money

Copying *to* `.bitcoin` or real ECX creates a real-money wallet. It gets that network's own chip
colour and the heavier send confirmation, **never** the violet test-network styling. Show a one-line
"This is real money" note on the confirm step (Golden Rule §6).

## 5. UI

- **Entry points:** the wallet row's "⋯" menu in the wallets sheet → **"Copy to network…"** (next to Rename and Remove), and Settings → Security → **"Copy to another network"** for the selected wallet. Also offered
  from the alphanet burn's Done screen once real ECX exists.
- **Sheet ("Copy to another network"):** the eligible networks (§4) as chip rows (networks the
  wallet is already on are greyed out with "Added ✓"), then **Copy wallet**. Auth prompt on Copy
  (when app-lock is on, like Split).
- **Result:** switch to the new wallet; it syncs and shows its balance.
- **"Added" detection:** match by public descriptors + network across existing wallets, not by
  comparing secrets (no need to load other wallets' keys for this).

## 6. Real-ECX target: what's missing

There is **no real-eCash network entry yet**: `WalletNetwork` has `.ecash` (alphanet) and
`.ecashBeta` (betanet). At launch:
- add the case + `NetworkRegistry` entry (backend on the production host BitWindow already names,
  `seed.ecash.eu.com`; unit ECX; real-money chip), and move `WalletNetwork.currentEcash` to it;
- no change to this feature beyond the new case joining the `0'` family.

## 7. Tests

- **Pure / mock:** eligibility table (§4) incl. "Added"; label; `isBackedUp`
  inheritance; remove-one-copy-leaves-the-other (Keychain + JSON + BDK store for the removed id only).
- **Integration (real BDK, sim + emulator):** copy a known test mnemonic alphanet → betanet and
  assert identical index-0/1/2 receive and change addresses; same for a WIF wallet; a `scriptType
  .bip44`/`.bip49` source keeps its script type; the index-0 verification rejects a deliberately
  mismatched derivation; cold restart keeps both wallets independent.
