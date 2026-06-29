# Importing a BitWindow wallet — design record

> **Status:** PROPOSED (feature not built) — but the **core derivation is VERIFIED** (see §2).
> Lets a user move funds from BitWindow (Drivechain / Layer Two Labs desktop app) into this wallet.
> Distinct from `docs/advanced-import.md` (general script-type/path import) — that does **not** solve
> BitWindow; this does.

## 1. The problem (root cause)
A user imported their BitWindow recovery phrase, the import "succeeded," but **no balance**. Cause:
**the phrase BitWindow shows you is not the seed that holds your L1 funds.**

A BitWindow backup (v1) for each wallet contains *three tiers* of mnemonics:
- **`master`** — the 12-word phrase BitWindow presents as "your recovery phrase."
- **`l1`** — labelled *"Bitcoin Core (Patched)"*; **this seed controls the mainchain (signet) BTC.**
- **`sidechains[]`** — one derived mnemonic per sidechain slot (Thunder, Truthcoin, …). Not L1.

The `l1` (and each sidechain) mnemonic is **derived from `master`** by a non-standard scheme. Our
wallet derives standard BIP84 *directly* from whatever phrase is imported, so importing `master`
produces a different, empty address set → "imported, no balance." BitWindow's L1 wallet itself uses
**BIP84 native segwit** (`getnewaddress "bech32"` / patched Core) on **Drivechain signet** — the same
chain + path our L2L Signet uses — so once you import the **right seed** (`l1`), everything lines up.

## 2. The master → l1 derivation (VERIFIED)
Reproduces BitWindow's `wallet/keygen.go` `DeriveStarter` (slot `256` = the L1 starter):

```
1. seed   = BIP39 mnemonicToSeed(master, passphrase="")        // PBKDF2-HMAC-SHA512, 2048 rounds
2. root   = HMAC-SHA512(key="Bitcoin seed", seed)              // BIP32 master: [0:32]=key, [32:64]=chaincode
3. child  = derive root at m/44'/0'/256'                       // ALL HARDENED (index + 0x80000000)
4. digest = SHA256( 0x00 ‖ child.privKey(32 bytes) )
5. entropy= digest[0:16]                                       // 128 bits → 12 words
6. l1     = BIP39 entropyToMnemonic(entropy)
7. then build a normal BIP84 wallet from l1: m/84'/1'/0'/{0,1}/i on L2L Signet (tb1q…)
```

Hardened-only derivation means step 3 needs the child **private** key (HMAC-SHA512 + mod-n scalar
add) — **no secp256k1 EC point math**. Sidechains use the same scheme at `m/44'/0'/<slot>'`
(out of scope for L1 import, but the mechanism is identical if we ever import sidechain funds).

**Verification:** confirmed against **2 of 2 real BitWindow v1 backups** — the BIP32 root key +
chain code reproduce each backup's `master_key`/`chain_code`, and the derived mnemonic exactly equals
each backup's `l1.mnemonic`. (Script lived in `/tmp`; not committed. **Do not commit the test seeds**
— for the suite, generate a throwaway BitWindow wallet and capture a fresh known-answer vector.)

## 3. Two implementation options

### Option A — import the `l1` phrase directly (zero code)
Tell users to import the **`l1`** mnemonic (not `master`) on **L2L Signet**. Works **today** with the
existing BIP84 import — the only gap is *knowing* to use the l1 phrase. Ship this as
documentation/support guidance immediately; it's the unblock for the current user.

### Option B — import the `master` phrase, auto-derive l1 (the real feature)
A "**Import from BitWindow**" mode: user pastes the phrase BitWindow shows (`master`); we run the §2
transform, then import the derived `l1` as a normal BIP84 wallet. Nicer UX (matches what users have).

- **What we persist:** the derived **`l1` mnemonic** (that's what controls the funds and what signing
  must use) keyed by `walletId` in the Keychain, exactly like any imported wallet. The `master` is
  used **transiently** to derive l1, then dropped — never stored.
- **Where to implement the transform:** it needs HMAC-SHA512 + SHA256 + mod-n scalar add + BIP39
  entropy→mnemonic. Options, in order of preference:
  1. **In the transpiled `WalletService`** using primitives we can reach (BDK `Mnemonic`/entropy +
     a small BIP32-hardened routine; SHA/HMAC via swift-crypto or platform). Keeps it in the Swift
     seam.
  2. **Extend `bdk-ffi`** (Rust) with the routine and regenerate bindings — heaviest, but one audited
     impl (the CLAUDE.md §12 pattern). Likely overkill for a derivation this small.
  - **Verify the binding surface** first: does `bdk-swift`/`bdk-android` expose `Mnemonic` from
    entropy and arbitrary BIP32 child-key extraction? If not, the small manual routine (option 1) is
    the path.
- **Optional later:** parse a full BitWindow backup JSON (`master` + `l1` + `sidechains[]`) and offer
  a picker — but L1-only via the `master`→`l1` transform covers the immediate need.

## 4. Network / settings
Import as **L2L Signet** (coin-type `1'`, BIP84, `tb1q…`) — BitWindow's default is Drivechain signet
on the same backend (`node.signet.drivechain.info`). If a user is on a different BitWindow network,
the same transform applies with that network's coin-type.

## 5. Confirm before building
Have the user import the **`l1`** phrase (Option A) on L2L Signet and confirm the balance appears.
That validates the last assumption (the enforcer/patched-Core wallet uses standard BIP84 `m/84'/1'/0'`
on l1) before we invest in Option B.

## 6. Security
- Never log `master` or `l1`; the derivation is transient and the result is stored only via the
  normal Keychain path.
- A pasted BitWindow backup is **all** the user's seeds (master + l1 + every sidechain) — if we ever
  add JSON-backup import, treat the file as maximally sensitive, parse in memory, never persist it.

## 7. Effort
- **Option A:** zero (docs/support).
- **Option B:** small–moderate — a small, verified derivation routine + an "Import from BitWindow"
  toggle on the import screen + a known-answer test (throwaway vector). Not BDK-consensus work.
