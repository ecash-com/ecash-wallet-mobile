# Key Derivation — OPEN DECISION

**Status:** 🟢 RESOLVED for derivation/addresses (2026-06-12), confirmed at the chain level by
**two** L2L primary sources: their node (`bitcoin-patched`, the live eCash Bitcoin Core fork) uses
chain params **byte-identical to Bitcoin** — mainnet magic `f9beb4d9`, port 8333, bech32 HRP `bc`,
xpub `0488B21E`; testnet4 (`1c163f28`, HRP `tb`) and signet are the standard Bitcoin ones too. Their
wallet (`BlueWallet` "redwallet" fork) correspondingly uses stock bitcoinjs networks + standard
BIP84. **eCash is Bitcoin at the wallet/address/derivation layer**, so our existing BIP84 +
coin-type `0'`/`1'` + HRP `bc`/`tb` is already correct — no change needed.

⚠️ The real open work is no longer *derivation* but **network SAFETY**: because eCash shares
Bitcoin's network magic AND address format AND xpubs, there is **no replay protection** and an eCash
address is indistinguishable from a Bitcoin address. See §2b — that's what still needs design.

This file is the decision record for how the wallet derives keys. Keep it in sync with
`Descriptors.swift` / `NetworkRegistry.swift` and CLAUDE.md §6/§14.

---

## 1. What's already settled

We use **BIP84 — native SegWit (`wpkh`, bech32)** for every network. For a Testnet4 wallet the
external receive chain is:

```
m / 84' / 1' / 0' / 0 / *
    │     │    │    │   └─ address index (advances on use)
    │     │    │    └───── chain: 0 = receive (external), 1 = change (internal)
    │     │    └────────── account: 0'
    │     └─────────────── coin-type  (see §2)
    └───────────────────── purpose 84' → native SegWit (wpkh), bech32 (tb1…/bc1…)
```

(Built by `Descriptors.accountPath`/`keychainPath`; BDK turns it into the real `wpkh(...)`
descriptor via `Descriptor.newBip84`.)

**Settled choices and why:**
- **Purpose 84' (BIP84 native SegWit).** Lowest fees, universal bech32 support, first-class in BDK.
  Alternatives: 44' (legacy `1…`), 49' (nested SegWit `3…`), 86' (Taproot `bc1p…`). Taproot is the
  only one worth a future, deliberate upgrade (privacy / richer scripts); not v1.
- **Testnet coin-type `1'`** for Testnet4 / signet / regtest. SLIP-44 reserves `1'` for *all*
  testnets. Uncontroversial.
- **Receive vs change on separate branches** (`/0/*` vs `/1/*`) so change never reuses a handed-out
  address.
- **Bitcoin mainnet = `0'`** exists in the enum only as the spec reference vector; **we are not
  shipping a Bitcoin-mainnet wallet** (see the `no-bitcoin-mainnet` decision). Our real mainnet is
  eCash.

---

## 2. The open question: eCash coin-type + address format

eCash is the **Layer Two Labs Bitcoin hardfork** at block **964,000** (~Aug 2026) that activates
Drivechain (BIP300/301) via CUSF and **airdrops eCash 1:1 to BTC holders**. The wallet needs three
eCash facts before it can derive eCash keys:

1. **Coin-type** for the BIP84 path (`m/84'/<?>'/0'`).
2. **Address HRP / format** (is it `bc1…` like Bitcoin, or a new prefix?).
3. **Network magic / chain params** (for BDK to model the network at all).

### What the L2L BIP300/301 specs say about this: nothing — on purpose

Both `bip300.md` and `bip301.md` (github.com/LayerTwo-Labs/bip300_bip301_specifications) are
**consensus** specs (sidechain hashrate-escrow + blind-merge-mining). They explicitly **leave wallet
derivation and address format undefined**:

> BIP300: "Interpretation of `A` for a particular sidechain slot is up to the authors of the
> sidechain" — the enforcer treats a deposit address as "an arbitrary meaningless array of bytes."

So coin-type / HRP are **not** in the BIP specs. They live in the **eCash chain implementation**
(L2L's Bitcoin Core fork — the `LayerTwo-Labs/mainchain` repo and successors define `chainparams`:
bech32 HRP, address version bytes, network magic). **That's where to look to close items 2 & 3.**

### The decisive wrinkle: 1:1 fork, identical addresses, opt-in replay protection

eCash is a straight Bitcoin hardfork with a 1:1 airdrop. Implications:

- A forked chain + 1:1 airdrop ⇒ a holder's **existing Bitcoin keys already control their eCash at
  the same addresses**. To let users access airdropped coins, the eCash wallet derives at **Bitcoin's
  path (coin-type `0'`)** and supports importing a BTC seed. (Done.)
- eCash addresses are **Bitcoin-format** (same bech32) — an eCash address *is* a Bitcoin address, and
  a signed tx is structurally valid on both chains. So the network is unmistakable only via the
  backend/chip (Golden Rule §6), and **cross-chain replay is a real concern**.

**Replay protection — CORRECTED 2026-07-24 (supersedes earlier "no/weak replay protection" notes).**
eCash's patched Bitcoin Core (LayerTwo-Labs/bitcoin-patched#24) adds an **opt-in** replay-protection
marker: a tx with **`nLockTime == LOCKTIME_THRESHOLD - 1` (= 499,999,999)** is treated as *final* on
eCash, but stock Bitcoin Core reads it as a **block height ~500M blocks (~9,500 years) out** and
rejects it as **non-final** → the tx confirms on eCash but **can never replay onto Bitcoin**. It only
bites when at least one input is non-final (`nSequence < 0xFFFFFFFF`); BDK's default RBF (`0xFFFFFFFD`)
guarantees that. **Our wallet stamps this on every eCash tx it builds** (`send` + `publishData`), gated
per network via `NetworkRegistry.replayProtectionLockHeight` and applied in
`WalletEngine.applyingReplayProtection` — stock bdk-swift/bdk-android, no BDK fork. So a user's eCash
spend can't move their BTC (the direction that matters). *Caveat:* it's **directional** — a plain
Bitcoin tx (`nLockTime == 0`) is still replayable onto eCash; and it's **opt-in**, so a tx built by
another wallet that omits the marker isn't protected.

### 2a. What L2L's reference wallet actually does (primary source)

L2L maintains a BlueWallet fork — `LayerTwo-Labs/BlueWallet`, branded "redwallet" — as their eCash
wallet. Reading its diffs vs upstream (commit `1e86473d`, "Implement support for testnet4 and
signet"; default net set to **signet** in `3b961d75`) settles the derivation question:

- **It uses stock Bitcoin network params.** The new `models/network.ts` defines `mainnet` /
  `testnet` / `signet` but adds **no custom params** — it returns bitcoinjs-lib's built-ins
  (`bitcoin.networks.bitcoin`, `bitcoin.networks.testnet`) and explicitly maps **signet → the same
  object as testnet** ("same address format, derivation paths"). `isTestnet()` = "not mainnet."
- **Standard BIP84 derivation, standard coin-types.** Derivation paths are the vanilla
  `m/84'/0'/0'` (mainnet) and `m/84'/1'/0'` (testnet) — coin-type **`0'` mainnet / `1'` testnet**,
  the same as ours. zpub/vpub version bytes are the standard `04b24746` / `045f1cf6`.
- **Same address format as Bitcoin.** It threads the network through bitcoinjs's `p2wpkh`/`p2sh`/
  `p2pkh`/`Psbt`/`ECPair` but never overrides the HRP or version bytes → addresses are Bitcoin
  bech32 (`bc1…` / `tb1…`).

**Conclusion:** L2L's own wallet treats eCash as **vanilla Bitcoin** at the key/address layer.
That confirms **Option A** below, and it means our existing `Descriptors` (BIP84) +
`NetworkRegistry` (coin-type `0'`/`1'`, HRP `bc`/`tb`) are **already aligned with the reference
implementation** — no derivation change needed. Note their fork is still on **signet/testnet4**
pre-fork (no distinct "eCash mainnet" network yet), which is why eCash *mainnet's* final HRP/params
are the one thing still to confirm from the chain itself (see §5 / the `mainchain` dig).

### 2b. What the eCash node actually uses (chain-level primary source) — and the safety fallout

`LayerTwo-Labs/bitcoin-patched` ("Private L2L version of Bitcoin Core", active) is the eCash fork
node. Its `src/kernel/chainparams.cpp` is **Bitcoin's params, unchanged at the wallet layer**:

| Param (mainnet `CMainParams`) | eCash node | Bitcoin | 
|---|---|---|
| `bech32_hrp` | `bc` | `bc` |
| `EXT_PUBLIC_KEY` / `EXT_SECRET_KEY` | `0488B21E` / `0488ADE4` | same → BIP44 coin-type **`0'`** |
| `PUBKEY_ADDRESS`/`SCRIPT_ADDRESS`/`SECRET_KEY` | 0 / 5 / 128 | same |
| `pchMessageStart` (network magic) | **`f9 be b4 d9`** | **`f9 be b4 d9`** |
| default P2P port | 8333 | 8333 |

Testnet4 (`1c163f28`, HRP `tb`), signet, regtest (`bcrt`) are likewise the standard Bitcoin ones.
(The older deprecated `mainchain` node used a near-identical set with a custom magic/port; the
current `bitcoin-patched` is *exactly* Bitcoin.) This is why their BlueWallet fork (§2a) just uses
`bitcoin.networks.bitcoin` — there is nothing eCash-specific to define.

**Consequences for our wallet (this is the part that needs design, not derivation):**

1. **Derivation/addresses: done.** eCash mainnet ⇒ Bitcoin params (HRP `bc`, coin `0'`, xpub);
   eCash testnet ⇒ Bitcoin testnet4/signet params (HRP `tb`, coin `1'`). Our code already matches.
2. **BDK modeling is trivial — CLAUDE.md §14 #6 mostly dissolves.** eCash needs **no** custom
   rust-bitcoin `Params` or forked binding: eCash mainnet = `Network.bitcoin`, eCash testnet =
   `Network.testnet4`/`.signet`. The *only* thing that distinguishes an eCash wallet from a Bitcoin
   wallet is **which backend (Electrum/node) you point at** — addresses, magic, and xpubs are
   identical.
3. **Identical addresses + opt-in replay protection = the core safety problem.** An eCash address *is*
   a Bitcoin address, and a signed tx is structurally valid on both chains. eCash's opt-in `nLockTime`
   marker (see "replay protection" above) protects the eCash→BTC direction *when we stamp it* (we do,
   per-network via `NetworkRegistry.replayProtectionLockHeight`) — but addresses are still
   indistinguishable and the reverse direction is unprotected. So:
   - Network separation is **purely backend-based** — there is no on-chain/address signal. The
     wallet must bind each wallet hard to its network's backend and never cross.
   - This is exactly why **not shipping a BTC-mainnet wallet** (the `no-bitcoin-mainnet` decision)
     matters even more: if we ever did, "Bitcoin mainnet" and "eCash mainnet" would be the *same
     addresses/keys* talking to different servers — a footgun. Keeping the app eCash-only avoids
     presenting two indistinguishable mainnets.
   - Golden Rule §6 (network unmistakable) must be enforced on the **backend/endpoint** identity,
     and we should never auto-select or silently fall back a mainnet endpoint.
4. **Airdrop access (the original motivation) confirmed.** Because coin-type/addresses are
   Bitcoin's, importing a pre-fork BTC seed reproduces the same addresses on eCash → airdropped
   coins are directly spendable. No special BTC-path import flow needed (Option A, confirmed).

---

## 3. Options

**A. eCash reuses Bitcoin's coin-type `0'`** (lean)
- ✅ Airdrop "just works": import your BTC seed → your eCash is there at the same paths.
- ✅ Matches how the fork actually distributes coins.
- ⚠️ Addresses collide with BTC mainnet format → replay-protection footguns; UI must make the
  network unmistakable and never silently cross to BTC.

**B. eCash gets a distinct coin-type**
- ✅ Clean key separation from BTC.
- ❌ A fresh eCash wallet's addresses won't match the holder's pre-fork BTC addresses, so claiming
  the airdrop needs an explicit BTC-path import/sweep flow.
- ❌ No coin-type to use yet — SLIP-44 `1899` belongs to the **unrelated** XEC "eCash" (Bitcoin
  ABC), **not** this L2L chain, so we can't borrow it; we'd need whatever L2L registers/uses.

(Purpose stays 84'/`wpkh` in both options unless L2L's address format dictates otherwise.)

---

## 4. Decision

- **BIP84 / `wpkh`**, **coin-type `0'` mainnet / `1'` testnet**, HRP `bc`/`tb` — **confirmed** by
  both L2L primary sources. This is **Option A**, and our code already implements it. No derivation
  change required.
- Taproot (purpose `86'`) remains a deliberate future upgrade, not v1.
- The 1:1 airdrop is directly spendable from a pre-fork BTC seed (same addresses) → **no special
  BTC-path import/sweep flow needed**.

What this re-points the remaining work at: **network identity is backend-only** (eCash and Bitcoin
share magic + addresses + xpubs), so the open items are safety + plumbing, not derivation.

---

## 5. Remaining to close (narrowed)

- [x] eCash coin-type / HRP / address format — **Bitcoin's** (confirmed via `bitcoin-patched`
      `chainparams.cpp` + the BlueWallet fork). Our `Descriptors`/`NetworkRegistry` already match.
- [x] eCash → BDK mapping (CLAUDE.md §14 #6) — **no custom Params/fork needed**: eCash mainnet =
      `Network.bitcoin`, eCash testnet = `Network.testnet4`/`.signet`. Distinguish by backend only.
- [ ] **eCash Electrum/Esplora endpoints** (mainnet + L2L signet/testnet) for `NetworkRegistry`.
      Until the fork is live (block 964,000, ~Aug 2026) we develop on Testnet4/signet — already wired.
- [ ] **Network-safety design** (the real work, given no replay protection + identical addresses):
      bind each wallet hard to its network's backend; never cross or auto-fallback to a BTC endpoint;
      enforce Golden Rule §6 on backend identity; keep the app eCash-only so there aren't two
      indistinguishable mainnets. Capture this in the network layer + send/receive review screens.
- [ ] Add the eCash `WalletNetwork` cases (`.ecashMainnet` / `.ecashTestnet`) when endpoints land —
      a `NetworkRegistry` entry reusing Bitcoin/testnet4 params + eCash backends, NOT a refactor.

---

## Sources

- **eCash node (authoritative chain params):** `LayerTwo-Labs/bitcoin-patched`
  `src/kernel/chainparams.cpp` — mainnet magic `f9beb4d9`, HRP `bc`, xpub `0488B21E` (= Bitcoin).
  Deprecated predecessor: `LayerTwo-Labs/mainchain` (`src/chainparams.cpp`).
- **eCash wallet (reference derivation):** `LayerTwo-Labs/BlueWallet` (the "redwallet" fork),
  commit `1e86473d` ("Implement support for testnet4 and signet") + `models/network.ts` — stock
  bitcoinjs networks, standard BIP84 `m/84'/0'/0'`/`m/84'/1'/0'`, zpub/vpub `04b24746`/`045f1cf6`.
- L2L BIP300/301 specs: <https://github.com/LayerTwo-Labs/bip300_bip301_specifications> — consensus
  only; address/derivation explicitly left to the sidechain/chain author.
- eCash fork / 1:1 airdrop / block 964,000 / Drivechain via CUSF:
  <https://www.livebitcoinnews.com/layertwo-labs-announces-bitcoin-fork-ecash-airdrop-planned-for-btc-holders/>
- Replay-protection concern between BTC and eCash:
  <https://www.coindesk.com/tech/2026/05/02/bitcoin-s-hazardous-airdrop-why-developers-are-warning-against-paul-sztorc-s-ecash-fork>
