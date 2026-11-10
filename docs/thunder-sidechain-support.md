# Thunder sidechain support — research + plan

> Status: **BUILT** (updated 2026-11-10). Source-backed notes on how L2L's **Thunder** sidechain
> (`github.com/LayerTwo-Labs/thunder-rust`) handles keys/addresses/signing/transactions, and what this
> wallet does about it. **Bottom line: Thunder shares NOTHING with Bitcoin's crypto — BDK cannot touch
> it, so it is a second, parallel wallet engine, built as ONE cross-platform Swift stack** (FROST
> ristretto255 Schnorr over vendored libsodium `Packages/Ristretto255` + vendored BLAKE3 + a ristretto
> "bip32ish" deriver + Borsh, all native on iOS + Android via Skip Fuse) **rather than Rust FFI.**
> `swift-crypto` is used only for SHA-256/SHA-512/HMAC now (the ed25519 era is history — §9).
>
> **Where it stands (2026-11-10):**
> - **Keys:** FROST ristretto255 at `m/43'/1899'/0'/9'/0'/index` (thunder-rust ≥ 0.18; port done in
>   commit `1c1dba7`, 1.2.1 — §9). The ed25519 / SLIP-0010 `m/1'/0'/0'/i'` model described in §2, §5a
>   and §8 below is **historical (pre-0.18)** and kept for the record.
> - **Networks:** `.thunderMainnet` (slot 9, index `https://seed.ecash.eu.com/thunder`, added
>   2026-11-10) is in `WalletNetwork.selectable` as an **offered sidechain nested under eCash mainnet**
>   (`Models.swift` `selectable` / `parentChain`): offered to every seed wallet in the network switcher,
>   derived on first tap, never a create/import target. `.thunder` (Thunder **betanet**, parent
>   `.ecashBeta`, index `https://seed.beta.ecash.eu.com/thunder`) is **retired** with betanet — the case
>   stays so old wallets load. One index per chain (`NetworkRegistry.swift`).
> - **Send path:** balance, receive, send, sweep, **history** (`get_stxos` shipped — §8c/§8d) and
>   **withdraw to mainchain** (`ThunderService.withdrawToMainchain`, §10) are built. Deposits from the
>   mainchain are built too (`docs/sidechain-deposits.md`) but not yet proven on-chain. Fast withdrawal
>   is built but switched off (`FastWithdrawalConfig.isEnabled = false`).
> - The `borsh::to_vec` golden-vector cross-check is **DONE** (2026-08-01 against `2026-07-24-refactor`,
>   re-pinned against v0.18.1 in `ThunderTransaction018Tests` — §9).

## 1. What Thunder is

A BIP300/301 **Drivechain sidechain** by Layer Two Labs — a simple, high-throughput UTXO chain that
receives deposits from the Bitcoin mainchain and can withdraw back to it. It is its OWN chain with
its own node + RPC; it is NOT a Bitcoin network variant like our `.bitcoin`/`.signet`/`.ecash`.

## 2. Crypto model (verified against `thunder-rust` source)

> **Historical — pre-0.18 (2026-07).** The signature and derivation rows below describe thunder-rust
> < 0.18. Since **0.18.0** (2026-09-17) Thunder signs with **FROST(ristretto255, SHA-512)** single-signer
> Schnorr and derives at **`m/43'/1899'/0'/9'/0'/index`** (account hardened, index non-hardened); the
> app follows (`ThunderKey.swift`, `ThunderAuthorization.swift`; §9). Hashing, address, Borsh and
> Utreexo rows are unchanged.

Every layer is different from Bitcoin:

| Concern | Bitcoin (BDK) | **Thunder** | Source |
|---|---|---|---|
| Signature curve | secp256k1 (ECDSA/Schnorr) | ~~**ed25519** (`ed25519-dalek`)~~ → **FROST ristretto255** since 0.18 (§9) | `lib/authorization.rs` |
| HD derivation | BIP32/BIP44/84 (secp256k1) | ~~**ed25519 BIP32 / SLIP-0010** (`ed25519-dalek-bip32`), path **`m/1'/0'/0'/index'`** (ALL hardened)~~ → ristretto "bip32ish" **`m/43'/1899'/0'/9'/0'/index`** since 0.18 (§9) | `lib/wallet.rs` |
| Seed | BIP39 mnemonic → seed | **same BIP39** mnemonic → 64-byte seed (`bip39`, empty passphrase) | `lib/wallet.rs` |
| Hashing | SHA-256 / RIPEMD-160 | **BLAKE3** | `lib/authorization.rs` |
| Address | P2PKH/P2SH/segwit/taproot, base58check / bech32 | **first 20 bytes of `BLAKE3(pubkey)`**, encoded as **plain base58** (NO checksum, NO version byte) | `lib/types/address.rs`, `authorization.rs::get_address` |
| Tx serialization | Bitcoin consensus encoding | **Borsh** (canonical) | throughout `lib/types/` |
| UTXO set | queryable (Electrum/Esplora) | **Utreexo accumulator** — inputs carry utreexo proofs; there is no address→UTXO query | `lib/types/transaction.rs` (`proof: Proof`) |

### Keys (historical, pre-0.18 — see §9 for the current scheme)
- `SigningKey` (private, 32 B) / `VerifyingKey` (public, 32 B) / `Signature` (64 B) from `ed25519-dalek`.
- Derivation (`wallet.rs::get_signing_key`): `ExtendedSigningKey::from_seed(seed)` →
  `derive(m/1'/0'/0'/index')` → `signing_key`. New address = bump `index`, derive, store
  `index → address`.
- **Now:** a ristretto255 scalar at `m/43'/1899'/0'/9'/0'/index` (`ThunderKey.swift`), 32-byte
  compressed public key, 64-byte `R ‖ z` FROST signature (`ThunderAuthorization.swift`). Same wire
  sizes (vk 32 + sig 64), so the Borsh layout did not change.

### Address
```rust
// authorization.rs
let mut reader = blake3::Hasher::new().update(vk.to_bytes()).finalize_xof();
let mut out = [0u8; 20]; reader.fill(&mut out);
Address(out)                          // base58(out) for display
```
Deposit-from-mainchain form is special: `s{sidechain}_{base58}_{sha256(prefix)[..3] hex}`.

## 3. Transaction & signing model (the big departure)

```rust
struct Transaction { inputs: Vec<(OutPoint, Hash)>, proof: UtreexoProof, outputs: Vec<Output> }
struct Output { address: Address, content: Content }
enum   Content { Value(Amount), Withdrawal { value, main_fee, main_address }, /* deposit-related */ }
enum   OutPoint { Regular{txid,vout}, Coinbase{..}, Deposit(bitcoin::OutPoint) }
struct Authorized<T> { transaction: T, authorizations: Vec<Authorization> }  // authorizations == witnesses
struct Authorization { verifying_key: VerifyingKey, signature: Signature }
```

**Signing is radically simpler than Bitcoin — and totally incompatible with it:**
- **The signed message is `borsh::to_vec(&transaction)` — the ENTIRE canonical serialization of the
  whole transaction.** There is **no sighash, no per-input message, no script, no sighash flags.**
- **One `Authorization` per input.** To spend an output at `Address A`, attach an `Authorization`
  whose `verifying_key` satisfies `BLAKE3(vk)[..20] == A` and whose `signature` is the ed25519
  signature of that same whole-tx message. Verification = `ed25519_dalek::verify_batch(...)`.
- Amounts are `bitcoin::Amount` (sats, 8-decimal) — the one thing that maps cleanly to our `Amount`.

Deposits reference a mainchain `bitcoin::OutPoint`; withdrawals (`Content::Withdrawal`) bundle a
mainchain payout address + main fee (BIP300/301 withdrawal semantics).

## 4. Why BDK is out (confirming the hunch)

BDK is secp256k1 + Bitcoin script + Bitcoin sighash + Bitcoin consensus serialization + a queryable
UTXO set. Thunder is ed25519 + BLAKE3 addresses + whole-tx ed25519 signatures + Borsh + Utreexo.
**There is zero overlap in the signing/derivation/address/serialization path.** BDK cannot generate a
Thunder key, derive a Thunder address, build a Thunder tx, or sign one. This is not a "new network in
`NetworkRegistry`" — it's a **second wallet engine**.

## 5. What supporting Thunder requires

Everything the user listed — generate keys, import keys, sign transactions — plus address derivation,
balance/UTXO tracking (with utreexo), and deposit/withdrawal. Two big pieces:

### 5a. Crypto/signing layer (ed25519 / BLAKE3 / Borsh) — historical plan (pre-0.18)

> The ed25519 / SLIP-0010 parts below were built and then **replaced** by the FROST ristretto255 port
> (§9, commit `1c1dba7`). `swift-crypto` stayed, but only for SHA-256/SHA-512/HMAC; signing now runs
> over vendored libsodium (`Packages/Ristretto255`). The BLAKE3 / Borsh / Fuse-native reasoning still
> holds as built.

Needed: BIP39 mnemonic → seed → ed25519 BIP32 (`m/1'/0'/0'/i'`) key; `BLAKE3(pubkey)[..20]` base58
address; Borsh-serialize a `Transaction` and ed25519-sign it into `Authorization`s; import (a BIP39
mnemonic, or a raw ed25519 signing key). **The Borsh encoding must byte-match `thunder-rust` exactly**
(custom `borsh_serialize` for amounts/keys/sigs, exact field order) or signatures won't verify — this
is consensus-critical.

**Recommended (per Jake, 2026-07-22): ONE cross-platform Swift crypto lib, no Rust FFI.** Because the
app is Skip **Fuse** — native Swift compiled for BOTH iOS and Android (Swift Android SDK) — a pure
Swift crypto package that builds on both platforms gives us the "one lib for Apple and Android" we
want, and keeps the whole thing in the native-Swift world (no bdk-style transpiled/bridged island, no
Rust toolchain/CI). Building blocks:
- **ed25519 sign/verify → `swift-crypto`** (`github.com/apple/swift-crypto`, Apple's OPEN-SOURCE
  implementation of the CryptoKit API — `Curve25519.Signing.PrivateKey/PublicKey`). It's the same API
  as built-in CryptoKit on Apple, and compiles off-Apple (BoringSSL-backed), so it's the natural
  cross-platform ed25519. **MUST verify it builds under the Swift Android SDK via `skip export`** —
  that's the gating spike before committing to this path.
- **BLAKE3** — NOT in CryptoKit/swift-crypto. Need a Swift BLAKE3 package (e.g. a C-backed or
  pure-Swift `blake3`) that also compiles for Android/Fuse. Verify in the same spike.
- **SLIP-0010 ed25519 BIP32 derivation** (`m/1'/0'/0'/i'`, all-hardened) — small; implement in Swift
  on top of swift-crypto's HMAC-SHA512. (Or a Swift SLIP-0010 package.)
- **Borsh** — hand-write a Swift Borsh codec that byte-matches thunder-rust's `Transaction`/`Output`/
  `OutPoint`/`Content` layout (including the custom `borsh_serialize` for `bitcoin::Amount`,
  `VerifyingKey`, `Signature`). Lock it down with cross-impl test vectors generated from thunder-rust.

Host this as a **Fuse-native `ThunderService` module** (plain native Swift on both platforms — simpler
than the WalletService BDK seam, which is transpiled only because bdk-android is Kotlin). **Fallback:**
if any of swift-crypto / BLAKE3 / etc. won't build under the Android Swift SDK, wrap `thunder-rust`
itself in a Rust FFI crate (UniFFI, like bdk-ffi) — reuses Thunder's audited code but re-adds a Rust
toolchain + a transpiled/bridged island. Prefer the Swift path; keep FFI as the escape hatch.

**The gating spike:** in a throwaway branch, add `swift-crypto` + a BLAKE3 package to a Fuse module,
do a `Curve25519.Signing` sign + a BLAKE3 hash, and run `skip export --debug` to confirm BOTH compile
for Android. Everything else (SLIP-0010, Borsh, RPC) follows only if that spike is green.

### 5b. Node / backend layer — ✅ RESOLVED (see §8b for the decided flow)

> **STATUS 2026-07-23 — this blocker is resolved; the section below is the historical analysis.**
> thunder-rust **0.17.0** shipped `submit_transaction(Authorized<Transaction>)` and unsigned
> `create_transfer`/`create_withdrawal`. The dev then agreed to a **thin-node, pure-Swift-client** flow
> (better than node-side coin-selection): phone derives addresses → `get_utxos(addresses)` → phone
> selects coins + builds + signs → `submit_transaction`, **which fills the utreexo proof node-side** (so
> the phone never touches the accumulator). We stay **pure Swift** (no `thunder_types`/FFI). See **§8b**
> (decided flow) and **§8c** (0.17.0 status). Remaining: the node's `get_utxos`/balance/history RPCs (dev
> implementing) + our RPC client + coin-selector.

Thunder has its own node + JSON-RPC (`rpc-api/lib.rs`). The full method set (as of the 2026-07-22 audit):
`balance, connect_peer, create_deposit, format_deposit_address, forget_peer, generate_mnemonic,
get_block, get_bmm_inclusions, get_best_mainchain_block_hash, get_best_sidechain_block_hash,
get_new_address, get_transaction, get_wallet_addresses, get_wallet_utxos, getblockcount,
latest_failed_withdrawal_bundle_height, list_peers, list_utxos, mine, openapi_schema,
pending_withdrawal_bundle, remove_from_mempool, set_seed_from_mnemonic, sidechain_wealth, stop,
transfer, withdraw`.

**This is a NODE-HOLDS-THE-WALLET RPC (like bitcoind's wallet RPC), NOT a client-side-signing API:**
- `set_seed_from_mnemonic(mnemonic)` / `generate_mnemonic()` — the **NODE holds the seed**.
- `get_new_address()`, `get_wallet_addresses()`, `get_wallet_utxos()` — the node's own wallet.
- `transfer(dest, value_sats, fee_sats) -> Txid`, `withdraw(mainchain_addr, amount, fee)`,
  `create_deposit(addr, value, fee)` — the node **builds + ed25519-signs + submits** internally.
- **There is NO RPC to submit a client-signed tx, and NO way to fetch an arbitrary address's UTXOs +
  utreexo proofs.** So as-is, using Thunder = pushing your seed to a node and letting it sign.

**Consequence — two paths, and only one fits our non-custodial model:**
- **Path A — client-side signing (our model, Golden Rule §2).** Phone holds the ed25519 seed, builds +
  signs the `AuthorizedTransaction` locally (§5a swift-crypto stack), node used ONLY for chain data +
  broadcast. **BLOCKED on the RPC:** needs (1) a `submit_transaction(AuthorizedTransaction)` method and
  (2) a fetch-my-UTXOs-with-utreexo-proofs method. **Good news: the node ALREADY has the capability —
  `lib/node/mod.rs::Node::submit_transaction(AuthorizedTransaction)` exists internally; it's just not
  exposed over RPC.** So this is a **modest addition to `thunder-rust`** (L2L owns it), not new
  consensus code. Coordinate with L2L to add those two RPC methods.
- **Path B — thin client to the node's wallet.** Call `set_seed_from_mnemonic` + `transfer`/`withdraw`.
  Simplest, ships today — but the **seed lives on the node**, which is **custodial / trust-the-node**
  and violates our "keys never leave the secure store" rule UNLESS the user runs their OWN Thunder node
  they control (then it's self-custody, and the phone is just a remote control for that node). Pushing
  the seed to a shared/L2L-hosted node is a non-starter for us.

**DECIDED (Jake, 2026-07-22): Path A.** The **eCash wallet holds the one seed**, derives the Thunder
keys from it (same BIP39 mnemonic → at the time ed25519 `m/1'/0'/0'/i'`; since 0.18 FROST ristretto255
`m/43'/1899'/0'/9'/0'/i`, §9), **signs the `AuthorizedTransaction` locally, and pushes the SIGNED tx to
the Thunder RPC.** The Thunder node RPC is **"just another API," treated like our existing backends** —
i.e. a per-network endpoint (`kind: "thunder"` / `"thunder-esplora"`, a URL) carried in the same remote
config (`https://dev.ecash.com/config` since 2026-11-09; `drivechain.dev/config` before) alongside
electrum/esplora, and resolved the same way.
The node is a dumb relay + chain-data source; it never sees the seed. **The ONLY gap is on the node
side:** thunder-rust must expose (1) `submit_transaction(AuthorizedTransaction)` (its internal
`Node::submit_transaction` already does exactly this) and (2) a fetch-my-UTXOs-with-utreexo-proofs
method. Those two RPC additions are the gating dependency — not the crypto — and they're L2L's to add.

### 5c. Thunder is a sidechain OF the eCash fork (Jake, 2026-07-22)
Not a separate chain to bolt on — it's a **BIP300/301 sidechain of the eCash mainchain we already
support**. In code (`Models.swift` `parentChain`): `.thunder` (betanet) → `.ecashBeta`,
`.thunderMainnet` → `.ecashMainnet`; the retired alphanet `.ecash` has no sidechain. So:
- **Deposits** (eCash-mainchain → Thunder) are an **eCash *mainchain* transaction** to a special
  deposit address (`format_deposit_address`: `s{sidechain}_{base58}_{sha256[:3]}`). Our **existing
  eCash BDK engine can build that mainchain tx** — the sidechain side just credits it. (`create_deposit`
  RPC does it node-side today; client-side we'd build the mainchain tx ourselves via BDK.)
- **Withdrawals** (Thunder → eCash-mainchain) are the `Content::Withdrawal { value, main_fee,
  main_address }` output → a withdrawal bundle settled on the eCash mainchain (BIP300/301).
- **Presentation — DECIDED and built (2026-11-05/10, `docs/seed-container-model.md`):** a wallet is
  the seed; Thunder is a `WalletAccount` of that wallet **nested under its parent mainchain in the
  network switcher** (`NetworkSwitcherSheet`; `WalletManager.availableSidechains`), offered to every
  seed wallet and derived on first tap (`enableNetwork`). The same seed derives both the eCash
  (secp256k1) and Thunder (ristretto255) keys; deposit/withdraw move funds between the two accounts.

## 6. Fit with our architecture

Our design already abstracts networks behind `WalletManager` (vends an engine per network) and
`WalletEngineProtocol` (balance/address/build/sign/broadcast). Thunder slots in as a **new engine that
implements `WalletEngineProtocol` but is backed by `ThunderService` (ed25519 + Thunder RPC), NOT BDK.**
Notes:
- `WalletNetwork` today assumes Bitcoin-family semantics (coin-type, HRP, `Network.bitcoin`). Thunder
  is a different *chain family* — likely a new `WalletNetwork` case whose engine factory returns the
  Thunder engine instead of the BDK one, and whose address/unit/derivation come from Thunder, not
  `NetworkRegistry`'s Bitcoin params. May want a `chainFamily` discriminator.
- `Amount` (Int64 sats) is reusable as-is (Thunder uses `bitcoin::Amount`).
- The mnemonic UX (generate/import 12/24 words) is reusable — same BIP39 — but the derivation +
  addresses are Thunder's. A user's Bitcoin seed and Thunder seed can be the same phrase yet control
  entirely different coins.
- Send/receive/history/backup screens are largely engine-agnostic already; the WIF-style "import a raw
  key" flow has a Thunder analog (import a raw ed25519 signing key).

## 7. Open questions (before building)

- **[#1 BLOCKER — ✅ RESOLVED 2026-07-23]** thunder-rust RPC. 0.17.0 shipped `submit_transaction`;
  decided flow is thin-node (§8b): node adds `get_utxos(addresses)` + address-scoped balance/history,
  `submit_transaction` fills the utreexo proof. Remaining is the dev's `get_utxos` + our client.
- **Utreexo on a phone — ✅ RESOLVED:** the phone does NOT track proofs. It builds the tx with an EMPTY
  proof and signs (proof is `#[borsh(skip)]`); `submit_transaction` regenerates the proof from the
  node's accumulator before applying. The phone stays light.
- **Cross-platform Swift crypto vs Rust FFI — ✅ DECIDED pure-Swift.** The spike PASSED (swift-crypto +
  SwiftBlake3 build on iOS + Android); the full key/Borsh/authorization stack is built + tested. We are
  NOT adopting the dev's `thunder_types`/FFI crate — we keep the hand-written Swift Borsh (matched to
  `transaction.rs`). Owed: one `borsh::to_vec` golden-vector cross-check vs the dev's crate before sends.
- **Presentation UX — ✅ RESOLVED (2026-11-10):** Thunder is an account of the seed wallet, nested
  under its parent mainchain in the network switcher (§5c).
- **Deposit/withdrawal flows — ✅ BUILT:** withdrawal = `ThunderService.withdrawToMainchain` (a
  `Content::Withdrawal` output → BIP300 bundle; status via the enforcer — §10). Deposit = an eCash
  *mainchain* M5 built by the BDK engine (`docs/sidechain-deposits.md`; built, not yet proven on-chain).

## 8b. The decided flow — thin node, pure-Swift client (2026-07-23)

**Agreed with the Thunder dev.** The node is a **UTXO source + relay**; the phone does everything else
locally with our pure-Swift stack. NO node-side coin-selection (that was an earlier proposal — see §8c
"superseded"). The seed never leaves the phone.

```
1. derive addresses            phone   ristretto m/43'/1899'/0'/9'/0'/i (→ BLAKE3 → base58)  ✅ built (was ed25519 pre-0.18)
2. get_utxos(addresses)        node    RPC returns the UTXOs for our addresses               ⏳ dev
3. select coins + build tx     phone   pure-Swift coin-selector → ThunderTransaction (Borsh) ⏳ selector
4. sign locally                phone   ed25519 over borsh(transaction) per input             ✅ built
5. submit_transaction(atx)     node    node FILLS the utreexo proof, applies                 ✅ 0.17.0
```

**Why the phone can build+sign without the accumulator:** `Transaction.proof` is `#[borsh(skip)]` — it's
absent from the signed bytes and the txid. The phone builds the tx with an **empty proof** and signs
`borsh(transaction)`; **`submit_transaction` regenerates the proof node-side** (`Node::regenerate_proof`)
before applying. So the phone never tracks utreexo. (Our `ThunderTransaction` already omits proof from
Borsh entirely — it maps to this exactly.)

### Node RPCs we consume
```
get_utxos(addresses: [Address])         -> [PointedOutput]        # ✅ shipped (reads full chain state)
submit_transaction(Authorized<Transaction>) -> Txid               # ✅ shipped (fills the proof)
getblockcount()                         -> u32                    # ✅ pre-existing (height/liveness)
get_stxos(addresses: [Address])         -> [Pointed<SpentOutput>]      # ✅ shipped (thunder-rust f98c31ec) — history (§8c)
```
Balance is summed from `get_utxos` client-side — no `balance_for` needed. Fee: no node-side estimator
and no min-relay rule, so the client prices it (see §8d).

### Client responsibilities (all pure Swift — most already built)
- Coin selection over the `get_utxos` result (value + outpoint + address). **⏳ to write** (small,
  RPC-shape-independent, testable).
- Build `ThunderTransaction` (inputs `(OutPoint, utxo_hash)`, outputs, empty proof). **✅ Borsh built.**
- Resolve each input's address → ed25519 key, sign `borsh(transaction)` → `AuthorizedThunderTransaction`.
  **✅ `ThunderWallet.authorize` built.**
- POST `submit_transaction(authorized)`. **⏳ RPC client to write.**

### Deposit (eCash mainchain → Thunder) — NOT a Thunder spend RPC
`format_deposit_address(address) -> "s{n}_{base58}_{checksum}"` already exists. The wallet formats a
Thunder receive address, then **builds the deposit as an eCash *mainchain* tx via our existing BDK
engine** and broadcasts it on eCash; the sidechain credits it. No Thunder `submit_transaction` involved.

### How it maps to `WalletOps` / the Thunder engine (`ThunderService`)
`balance()`→`balance_for`(or sum `get_utxos`); `receiveAddress()`→derive ed25519 addr locally;
`send()`→`get_utxos`→coin-select→build→`ThunderWallet.authorize`→`submit_transaction`;
`transactions()`→`get_transactions`. Same `WalletOps` surface the BDK path implements, routed by
`WalletFacade` — the Thunder engine just swaps BDK for (swift-crypto + Thunder RPC).

## 8c. The node side — what shipped, and the one remaining ask (2026-07-27)

Reviewed against thunder-rust branch **`2026-07-24-refactor`** (PR #116 "WIP: refactor for mobile
wallets", head `fb922ee`). **Both blockers are gone — the non-custodial send path is open.**

**Shipped:**
- ✅ **`get_utxos(addresses) -> [PointedOutput]`** (`rpc-api/lib.rs`, commit `ed23b82`) → `Node::
  get_utxos_by_addresses` → `State::get_utxos_by_addresses` (`lib/state/mod.rs`). Crucially it reads the
  **full chain UTXO set**, not the node's local wallet DB, so no seed is required for the node to serve
  our addresses. (Implementation note: it iterates the whole `utxos` DB and filters per call — fine at
  current chain size; revisit if it ever gets slow.)
- ✅ **`submit_transaction` regenerates the utreexo proof** before validating (commit `fb922ee`,
  `lib/node/mod.rs` → `State::regenerate_proof`). So the phone submits with an **empty proof** and never
  touches the accumulator — exactly the §8b flow.
- ✅ **Borsh wire format unchanged** by the `lib/types` → `types/` crate extraction (commit `c7a4ba2`):
  diffing `transaction.rs` across it shows only import paths, `#[cfg(feature = "heed")]` gates and test
  renames. Our Swift codec stays valid. `THIS_SIDECHAIN` is still `9`.

**✅ The one remaining ask — history — SHIPPED** (`get_stxos`, thunder-rust `f98c31ec`; consumed by
`ThunderRPCClient.getStxos` → `ThunderHistory`). The original ask, for the record:

There is no address-scoped way to see *spent* outputs, and
`get_utxos` by definition returns only unspent ones, so a remote wallet can show a balance and receive
funds but cannot reconstruct any history: every send it has ever made is invisible. `get_transaction
(txid)` doesn't help — it needs a txid we have no way to discover.

The ask (raised 2026-07-27; dev expects to do it same-day or next) is deliberately minimal — it mirrors
the `get_utxos` he just wrote, over the `stxos` DB that already exists:
```
get_stxos(addresses: [Address]) -> [(OutPoint, SpentOutput)]
```
`SpentOutput { output, inpoint }` and `InPoint` already derive `Serialize`, so it needs no new types.
That is enough to rebuild history client-side: `outpoint.txid` is the tx that paid us, `inpoint` is the
tx that spent it, and we net the two per txid. Plus one optional extra: **`block_height: Option<u32>` on
`GetTransactionResponse`** (the node already resolves `block_hash` there and `archive.get_height` is
adjacent) so history can be ordered — without it we can show *what* happened but not reliably in what
order.

### ⚠️ The node's OpenAPI schema disagrees with its serde — trust serde

Three shape traps, all verified by reading the `types` crate. **Do not generate a client from the
OpenAPI document**; these are why `ThunderRPCTypes.swift` is hand-written.

1. **`Transaction.inputs`** is annotated `Vec<(OutPoint, String)>`, but `Hash = [u8; 32]` carries no
   serde hex wrapper → JSON is an **array of 32 numbers**. Each input is a 2-element JSON array (a Rust
   tuple).
2. **`Authorization.verifying_key` / `.signature`** — **changed in 0.18.** Pre-0.18 they were
   annotated `String` but ed25519-dalek 2.2 serialized via `serialize_bytes` → arrays of 32 / 64
   numbers (and rejected hex). **Since 0.18 they are hex strings** (pinned against v0.18.1 by
   `ThunderTransaction018Tests`; `ThunderRPCTypes.swift`). Also since 0.18 a `Deposit` outpoint
   serializes as the string `"txid:vout"`, not an object.
3. **`OutPoint::Deposit`** wraps a *mainchain* `bitcoin::OutPoint`, and `bitcoin::Txid` serializes as
   **display** hex — byte-REVERSED relative to the internal bytes we Borsh-encode. Thunder's own `Txid`
   (in `Regular`) is the opposite: raw byte order, no reversal. Convert on the `Deposit` boundary only.
   Get this backwards and you build a plausible-looking input whose utxo hash the node can't match.

Shapes that are what you'd hope: `Address` is base58, `Txid`/`MerkleRoot`/`BlockHash` are lowercase hex
(`hexstr_human_readable`), `Content` is externally tagged — `{"Value": <sats>}` /
`{"Withdrawal":{"value","main_fee","main_address"}}` (since 0.18; the pre-0.18 names `value_sats` /
`main_fee_sats` still decode — `ThunderRPCContent` in `ThunderRPCTypes.swift`). `proof` is a **required** field with no
`#[serde(default)]`, so submit must send `{"targets":[],"hashes":[]}`.

**Superseded:** the `create_transfer_from` node-side-coin-selection ask (previously in this section) is
dead — the node does not select coins at all, the phone does. See §8b.

## 8d. The client side — what we built (commit `302dc78`, 2026-07-27)

All of `Sources/ECashWalletMobile/Thunder/`. Pure Swift; no `thunder_types`/FFI crate.

- **`ThunderPointedOutput`** — `BLAKE3(borsh(PointedOutput))`, i.e. the `Hash` in every transaction
  input and the utreexo leaf the node proves against (thunder-rust builds inputs as
  `hash(&PointedOutput { outpoint, output })`). **This is ours to compute and it is consensus-critical:**
  get it wrong and `regenerate_proof` proves the wrong leaf and the tx is rejected. The Borsh encoders
  live on `ThunderOutPoint`/`ThunderOutputContent`/`ThunderOutput` so this reuses byte-for-byte the same
  encoding the signed transaction uses rather than a parallel copy.
- **`ThunderRPCTypes`** — Codable matched to serde (see the traps above). Withdrawal outputs decode but
  are marked unspendable — consensus refuses to let anyone spend them (thunder-rust `f585f25`) — so they
  are excluded from both balance and coin selection.
- **`ThunderRPCClient`** — JSON-RPC 2.0 with positional params and an injected `fetch`, so every path is
  unit-tested against canned JSON with no server. Endpoint resolves per call via
  `manager.backendURL(for: .thunder)`, so a Settings override applies without rebuilding the service.
- **`ThunderCoinSelector`** — largest-first. Thunder's only consensus rule here is
  `value_in >= value_out` (`NotEnoughValueIn`) — no min-relay floor, no vbyte/weight concept — so the fee
  is the exact canonical Borsh size × sat/byte with a 1-sat floor, and change worth less than the output
  it would occupy is folded into the fee instead of creating uneconomic dust.
- **`ThunderAddressIndexStore`** — the revealed index is now **persisted** per wallet. Thunder has no
  watch-only xpub (all-hardened SLIP-0010), so the app is the only thing that knows how far down the
  chain a wallet has gone; if that counter reset on relaunch we would re-issue published addresses
  (privacy) and sync only a shallow prefix, making funds at a high index *look* missing. Sync scans
  `0 ..< revealed + 20`; change goes to a fresh index, never back to an input's address.
- **`ThunderService`** — `balance` (cached from the last sync, since `WalletOps.balance` is synchronous),
  `sync`, `send`, `sweep`. Spent coins are evicted from the cache after submit so an immediate second
  send cannot reselect them. `pendingBalance` is **0 by design**: `get_utxos` reads the node's state,
  which has no mempool view, so a just-submitted tx appears at the next sync after it is mined.
  `transactions()` originally threw `.historyUnavailable` (distinct from `.backendUnavailable`, so the
  UI could say "not available yet" rather than "can't reach the node"); **no longer thrown** since
  `get_stxos` shipped — history comes from the sync cache (`ThunderError.swift` keeps the case). `splitToSelf` throws
  `.unsupportedOperation` (splitting guards an eCash-fork replay concern this chain doesn't have).
- **Performance:** `ThunderKey.derive(seed:index:)` + `ThunderWallet.keys(for:)` compute the BIP39 seed
  (PBKDF2, 2048 iterations) **once per scan** instead of once per index — a 20-address scan was 20 PBKDF2
  runs, and signing re-scanned from zero for every input.

**`get_stxos` landed — DONE:** `ThunderRPCClient.getStxos` + `ThunderHistory` implement
`transactions()` by netting `get_utxos` + `get_stxos` per txid (received = outputs to us keyed by
`outpoint.txid`; sent = ours spent, keyed by `inpoint.txid`). On the default Esplora index (§8e) history
comes with heights/times/fees instead.

## 8e. The backend layer — drivechain-esplora (2026-09-01)

**Decision: the default Thunder backend is an Esplora-compatible index, not the node's own JSON-RPC.**
The node RPC path is kept and still works; the endpoint's `kind` picks between them
(`ThunderBackendFactory`).

### Why

[`octobocto/drivechain-esplora`](https://github.com/octobocto/drivechain-esplora) walks a rust
sidechain block by block, writes an address index into Postgres, and answers every request from
Postgres. It exists because the node cannot do this job:

- The node's state DB keys by **outpoint only**. `get_utxos(addresses)` / `get_stxos(addresses)` take
  an arbitrary address set but iterate the whole table and filter in memory. That does not improve as
  the chain grows.
- The node exposes **no height for a transaction**. `Header` carries none, `get_block` returns none,
  and `getblockcount` gives only the tip. This is the root cause of every compromise documented in
  `ThunderHistory`: no fee, no confirmation depth, no chronological ordering.

The index answers all of it. What we gain, concretely:

| Was, on the node RPC | Is, on the index |
|---|---|
| `blockHeight` nil, `confirmations` pinned at 1 | `status.block_height` + `/blocks/tip/height` → real depth |
| ordering faked from a local first-seen record | `status.block_time` → real chronological order |
| `feeSats` nil (not derivable from our half of the tx) | `Tx.fee`, computed over the whole transaction |
| history inferred from unspent-vs-spent evidence | `/address/{a}/txs/chain` — full txs with `vin[].prevout` |
| deposits invisible | `/deposit/{mainchain_txid}`, `/address/{a}/deposits` |
| CTIP needs a mainchain/enforcer client of our own | `/drivechain/sidechain/9` returns slot + treasury |

That last row matters for §8's deposit flow: the CTIP an M5 spends is readable without us shipping a
mainchain client.

### What it costs

**Request count.** There is no batch-address route — Blockstream's Esplora has none and this is
faithful to it — so a sync is one request per address instead of one for the whole window. Managed in
`ThunderEsploraBackend`:
- `/address/{a}` (a few integers) probes each address first; only addresses with `tx_count > 0` cost a
  UTXO + history fetch. A gap-limit window is mostly unused addresses, so this is the difference
  between ~42 requests and ~21 small ones plus a handful of real ones.
- Requests run 6 at a time.
- **Worth asking the operator for a multi-address route.** It is a small addition on their side and
  would take a sync back to a couple of round trips.

**No mempool**, ever: `/address/{a}/txs/mempool` is always `[]` and `/mempool` is all zeros. Same as the
node RPC (`get_utxos` reads connected-block state only), so `pendingBalance` stays honestly 0 — not a
regression, but not fixed either.

**Trust.** One indexer sees the whole address window and is taken at its word for balances. That is the
same trust the node RPC already required, and the endpoint stays overridable in Settings.

### Wire-shape notes (all verified against the Go source)

- **`POST /tx` relays its body into `submit_transaction` unchanged** — the index signs nothing and
  rewrites nothing (`internal/index/broadcast.go` → `node.SubmitTransaction` → `Call("submit_transaction",
  []any{tx})`). So the body is byte-for-byte the object `ThunderRPCAuthorizedTransaction` already
  encodes as `params[0]`, and the whole authorization/Borsh path is shared. It answers the txid as
  **plain text**, not JSON.
- **Hashes are not reversed**, except a *mainchain* txid inside a deposit, which keeps Bitcoin display
  order — the same split `ThunderRPCOutPoint` already handles. `ThunderEsploraUTXO.outPoint()` flips it
  back for Borsh.
- **A UTXO row carries no address** — the route is the key. `pointedOutput(address:)` takes the queried
  address, which is also exactly what signing needs.
- **A withdrawal's reported `value` folds in the mainchain fee**, so it could not be reconstructed into
  an exact `Content`. It is dropped from the spending path — which was already required (consensus
  rejects spending one) but is now *also* what stops us computing a wrong utreexo leaf hash.
- `version`, `locktime` and `sequence` are always 0; these chains have no such fields.

### The consensus-critical bit

Every input carries `BLAKE3(borsh(PointedOutput))` as its utreexo leaf. Rebuilding that from an Esplora
row means rebuilding both the outpoint *and* the full output (20-byte address + content). The invariant
is pinned by `ThunderEsploraTypesTests.esploraAndRPCAgreeOnTheUtxoHash` (and the deposit variant): the
same coin, described in both wire shapes, must hash identically. As long as that holds, which backend
is in use cannot change what the node validates.

### Adding other sidechains

`internal/chain/block.go` states it outright: *"Everything else in a rust sidechain block is identical
across chains."* The per-chain `Decoder` interface is two methods, and only the **output content**
varies. That is the same shared shape our Thunder stack is built on — `ThunderKey`, `ThunderAddress`,
`BorshWriter`, `ThunderAuthorization`, `ThunderPointedOutput`, `ThunderCoinSelector` are not
Thunder-specific. Adding BitNames or Truthcoin as a value-transfer network would be a registry entry,
an endpoint, a chip colour and a content decoder.

Two caveats. The seven-chain table in the README is aspirational — `register.go` registers exactly one
decoder (thunder); the rest return *"chain has no output decoder yet"*. And "moves plain value"
is not "correct wallet for that chain": the index reduces every output to `{ValueSats, Type}`, which is
the whole truth for Thunder but not for BitNames (names), BitAssets (assets), Truthcoin (market
positions) or ZSide (shielded outputs).

### Gap-limit discovery (what the per-address probe unlocked)

`revealedIndex` is local device state — a UserDefaults integer. A wallet **restored onto a new phone
starts at 0**, so the old fixed `revealed + gap limit` window covered only indices 0…20 and a wallet
used further down its chain would show a partial balance. Thunder has no watch-only xpub and no
BDK-style revealed-SPK store to recover the count from, so the app has to go and look — and the cheap
`/address/{a}` probe is what finally makes looking affordable.

`ThunderService.discoverWindow` applies BIP44's rule: keep walking in gap-limit batches while any
address in the trailing stretch has been used; stop once a whole stretch is untouched (capped at
`maxDiscoveryRounds` = 20 batches, so a server calling everything "used" can't make us derive forever).
Whatever it finds is **persisted back to `revealedIndex`**, so the wider window is free from then on —
including for the send path, which never runs discovery.

**This does not abolish the gap limit.** Coins past 20 consecutive unused addresses stay
undiscoverable, exactly as they are for BDK on the Bitcoin side. What it fixes is the common shape: a
wallet used progressively down its chain, where each extension keeps finding more. Only a backend that
can answer "used?" cheaply takes part — `ThunderRPCBackend.usedAddresses` returns nil, because probing
the node batch by batch would cost a full UTXO-table scan each time, so that path keeps its fixed
window.

### Status

- ✅ `ThunderEsploraClient` / `ThunderEsploraTypes` / `ThunderEsploraHistory` / `ThunderEsploraBackend`,
  behind a `ThunderBackend` protocol with the node RPC as the other implementation.
- ✅ `NetworkRegistry.thunder` defaults to `https://seed.beta.ecash.eu.com/thunder` (betanet; was
  the alphanet `seed.alpha…` until 2026-09-24), kind `thunder-esplora`. `WalletBackend.Kind` and
  `BackendURLValidator` know both kinds.
- ✅ Gap-limit **discovery** with the result persisted (see above).
- ✅ 48 new host tests (wire decode, the utxo-hash cross-check, history arithmetic, route composition,
  request shaping, paging, failure, discovery walk/stop/cap).
- ✅ **Live-verified against the real deployment** — `ThunderEsploraLiveTests`, opt-in via
  `THUNDER_ESPLORA_ENDPOINT`. Proves what a stub cannot: routes compose against a service mounted
  under a path (including with a trailing slash), the empty-index 404 really is a 404 that maps to
  `.indexEmpty` and not `.network`, a bad address really is a 400 surfaced as `.server`, and the
  address-stats JSON really carries the fields we decode. All true today, with nothing indexed.
- ✅ **Verified with Thunder un-hidden, then re-hidden** (2026-09-01) — historical. `.thunder` was
  commented out of `WalletNetwork.selectable` while the index held no blocks (a Thunder wallet would
  hand out real addresses while showing a zero balance), un-hidden 2026-09-29, then **retired with
  betanet on 2026-10-30** (case kept so old wallets load). Today `.thunderMainnet` is the offered
  Thunder, listed in `selectable` as a sidechain nested under eCash (next item).
- ✅ **Thunder MAINNET wired 2026-11-10**: `WalletNetwork.thunderMainnet` (parent `.ecashMainnet`) →
  `https://seed.ecash.eu.com/thunder`, kind `thunder-esplora`, display "Thunder", real-money. Offered
  from the network switcher under eCash (`WalletManager.availableSidechains` lists offered sidechains,
  `enableNetwork` derives the account), never from create/import. `ThunderService` takes the network
  per call (`makeBackend(network)`, `networkOf(walletId)`) and scopes revealed index / first-seen /
  caches by `chainKey` (betanet keeps the bare wallet id). On 2026-11-10 the mainnet enforcer
  (`seed.ecash.eu.com/enforcer`) reported slot 9 active since height 978,324 with a funded treasury,
  while the mainnet index still held no blocks — the `.indexEmpty` path below applies there too.
- ⏳ **The live index holds no blocks yet.** `/blocks/tip/height` answers 404 *"the index holds no
  blocks yet"*; `/fee-estimates` and the `/drivechain/*` routes work (an enforcer is attached), and the
  address routes answer zeros. That case is handled as `ThunderBackendError.indexEmpty` → an empty sync
  rather than a connection error, but nothing on this path has met real indexed data.
- ⏳ **Open with the operator — written up in `docs/drivechain-esplora-request.md`**: when the index
  syncs and against which chain; a batch address route
  (nice-to-have, not blocking); rate limits; whether the enforcer behind `/drivechain/*` is permanent;
  and whether a human-facing explorer will exist (`explorerTxTemplate` currently points at the index's
  own JSON `/tx` route).

## 8. Bottom line

Thunder is a genuinely separate chain: **FROST ristretto255 keys (`m/43'/1899'/0'/9'/0'/i`; ed25519
`m/1'/0'/0'/i'` before 0.18), BLAKE3-hashed base58 addresses, whole-tx Schnorr signatures, Borsh
serialization, Utreexo UTXO set, own node RPC.** BDK is irrelevant to all of it. The path is a
**Fuse-native `ThunderService`** on **one cross-platform Swift crypto stack** — vendored libsodium
(`Packages/Ristretto255`) + SwiftBlake3 + `Sidechain/` (ristretto bip32ish, FROST) + a Swift Borsh codec,
with `swift-crypto` for SHA/HMAC only — plugged into the per-network engine abstraction
(`WalletOps`/`WalletFacade`) as a non-BDK engine.

**Status 2026-07-27 (snapshot; see the banner for 2026-11-10) — built, unproven against a real node:**
- ✅ **Crypto/keys/Borsh/authorization** — `ThunderKey`, `ThunderWallet`, `Base58`, `Slip10Ed25519`,
  `Bip39Seed`, `ThunderAddress`, `ThunderTransaction` (Borsh), `AuthorizedThunderTransaction` — all
  vector-tested; builds + runs on iOS + Android (portable-BLAKE3 fix for the Android load crash).
- ✅ **Node RPCs we need for sending** — `get_utxos` + proof-regenerating `submit_transaction` shipped
  on thunder-rust `2026-07-24-refactor` (§8c).
- ✅ **Client engine** — utxo-hash, RPC client, coin selection, persisted address index, and
  `ThunderService` balance/sync/send/sweep (§8d, commit `302dc78`). 218 host tests green; release APK
  builds. Pure Swift throughout — NOT using the dev's `thunder_types`/FFI crate.
- ✅ **UI** — create/import/backup/receive work; crimson chip; ECX unit. (Was commented out of
  `WalletNetwork.selectable` at the time; today `.thunderMainnet` is offered in the switcher under eCash
  and `.thunder` betanet is retired — see the banner.)
- ✅ **History** — two paths now. On the node RPC it is reconstructed from `get_utxos` + `get_stxos`
  (`ThunderHistory`), undated and pinned at 1 confirmation. On the **drivechain-esplora index** (the
  default since 2026-09-01, §8e) it arrives with real heights, times and fees.
- ✅ **Borsh cross-checked against real thunder-rust** (2026-08-01): two golden vectors generated by
  running `borsh::to_vec()` on thunder-rust's own `types::Transaction` (branch `2026-07-24-refactor`)
  and pinned in `ThunderBorshTests` — a simple Regular/Value tx, and one covering a **Deposit**
  outpoint + **Withdrawal** output. Bytes and txids match exactly.
- ⏳ **Before real funds:** a live endpoint with data to run against. Both wire layers are still
  exercised only against stubbed JSON. The indexes are `seed.beta.ecash.eu.com/thunder` (betanet,
  retired) and `seed.ecash.eu.com/thunder` (mainnet; held no blocks on 2026-11-10 — §8e).

## 9. Key port to thunder-rust 0.18 — FROST ristretto255 (DONE, commit `1c1dba7`, 1.2.1)

Folded in from the former `docs/thunder-key-port.md` (2026-09-30). thunder-rust **0.18.0** (2026-09-17,
the release that added betanet) replaced Thunder's keys; the app ported in `1c1dba7` (version 1.2.1).

| | Before (what we had built) | thunder-rust ≥ 0.18 (v0.18.1, `b62658f`) — **what we run now** |
|---|---|---|
| Signature | ed25519 (`Curve25519.Signing`) | FROST(ristretto255, SHA-512) single-signer Schnorr — `frost-ristretto255` (commit `58a6c6e` is *titled* "ed25519 -> schnorrkel" but uses FROST) |
| Derivation | SLIP-0010 ed25519, `m/1'/0'/0'/i'`, all hardened | "bip32ish" over ristretto255 (`lib/wallet/bip32.rs`), `m/43'/1899'/0'/9'/0'/i` — account hardened, **address index non-hardened** |
| Address | `BLAKE3(ed25519 pk)[..20]` | `BLAKE3-XOF(compressed ristretto pk)[..20]` (same bytes as `BLAKE3(pk)[..20]`) |

**Golden vector** (pinned in `ThunderWalletTests`, reused by `ThunderRPCTests` / `ThunderHistoryTests` /
`ThunderEsploraClientTests`): `abandon ×11 about`, passphrase `""`, sidechain 9, index 0 →
`NKqSr4bQejFbKpd5yLQgWEiMJFx`. `ThunderTransaction018Tests` pin v0.18.1's own bytes (pointed-output
hashes, tx borsh, txid, authorized borsh, full submit JSON), and thunder-rust's
`verify_authorized_transaction` accepted a Swift-signed tx. That gate caught three submit-JSON breaks
(§8c trap #2 and the `value`/`main_fee` rename).

**What was built:** `Sources/ECashWalletMobile/Sidechain/` (shared, sidechain-agnostic core —
`RistrettoBip32` with a `biasFix` flag + public derivation, `FrostSchnorr`, `SidechainAddress`,
`SidechainKeyScheme` / `RistrettoSidechainKeyScheme.thunder`, `SidechainHash`, `Bip39Seed`, `Base58`),
over `Packages/Ristretto255` (five files of libsodium 1.0.22 compiled from source + a Swift wrapper,
RFC 9496 vectors pass). `ThunderKey` / `ThunderWallet` / `ThunderAuthorization` sit on top;
`Slip10Ed25519` and the `Curve25519` import are gone. **Watch-only:** the account public key + chain
code is derived once per wallet and stored (`ThunderAccountKeyStore`, key
`thunder.accountKey.v018.<id>`); sync / receive / change derive non-hardened children from it and only
signing loads the mnemonic — the same model as the BDK side (CLAUDE.md §7). Wallet removal purges the
revealed index, first-seen times and account xpub (`WalletOps.forget`). No storage migration: the
phrase is the same, addresses re-derive; coins sent to pre-0.18 (ed25519) addresses are unrecoverable
on 0.18 nodes.

**Shared core vs per-sidechain** (research on truthcoin-dc v0.19.0 slot 13 and coinshift-rs v0.14.8
slot 255):

| Layer | Thunder | Truthcoin | Coinshift | → |
|---|---|---|---|---|
| Group / signature | FROST ristretto255 | same | same | **shared** |
| Key & sig bytes | pk 32, sig `R‖z` 64 | same | same | **shared** |
| Address | BLAKE3-XOF(pk)[..20], base58 | same | same | **shared** |
| Deposit string | `s{slot}_{b58}_{hex(sha256(prefix)[..3])}` | same | same | **shared, slot is a parameter** |
| Key derivation | ristretto bip32ish, bias fix, `m/43'/1899'/0'/9'/0'/i` | **secp256k1 BIP32** `m/0'/i`, secret bytes read LE mod ℓ | ristretto bip32ish **without** the bias fix, slot 255 | **per sidechain** |
| Signed message | `borsh(tx)` | `0x00 ‖ borsh(tx)` | `borsh(tx)` | **per sidechain** |
| Tx / output layout | Thunder | different (memos, `data`, `actor_proof`, no input hashes) | Thunder + trailing `TxData` | **per sidechain** |
| Withdrawal output | `u64 value, u64 main_fee, u32-len scriptPubKey` | identical | identical | **shared encoder** |
| Thin-client RPC | yes | yes | **no** (needs upstream work) | per sidechain |

**Adding the next sidechain:** a `WalletNetwork` case + `parentChain`, a registry entry (slot, key
scheme, sign prefix, codec, backend, unit), a chip colour, and a mapping in `SidechainWalletNetwork`.
**Truthcoin** (slot 13) is feasible as a thin client (`get_utxos`, `submit_transaction`, `push_tx`): a
secp256k1 key scheme (the app already links swift-secp256k1), the `0x00` signing prefix, its own tx
codec, and a known-answer vector from its node. **Coinshift** (slot 255) is **not** supportable as a
thin client until upstream adds a per-address UTXO query and external-tx submission — wait.

**Still open:** (1) old-address betanet coins — drop silently with a release note, or scan the legacy
ed25519 addresses once and tell affected users? (Moot for mainnet: `.thunderMainnet` only ever used
0.18 keys.) (2) Truthcoin's secp256k1 derivation reading secret bytes little-endian mod ℓ looks
unintentional — ask before copying it. Resolved: watch-only is in (above); the real-fork Thunder uses
the same slot-9 keys (confirmed by the 2026-11-10 mainnet wiring, same `RistrettoSidechainKeyScheme.thunder`).

## 10. Withdrawals (Thunder → mainchain) — BUILT

Folded in from the former `docs/thunder-deposit-withdraw.md` (research 2026-08-27; deposits half
superseded by `docs/sidechain-deposits.md`). The Drivechain spec's governing asymmetry: **"Money in is
permissionless; money out is not."** A deposit (M5) needs no miner approval; a withdrawal asks the
mainchain to release coins on sidechain state it cannot verify, so verification is replaced by a long
miner vote — and the vote's length *is* the security.

**Stages (M3 → M4 → M6)** — only the first is ours: (1) the user's withdrawal request, a normal Thunder
tx whose output is `Content::Withdrawal { value, main_fee, main_address }` — built, signed on device and
submitted by `ThunderService.withdrawToMainchain` (`SidechainWithdrawScreen`); (2) bundle proposal (M3)
by the operator; (3) miner voting (M4), block after block, abstain `0xFF` / alarm `0xFE`; (4) payout (M6)
spends the treasury, output 0 the new treasury, outputs 1+ the withdrawals.

**Timelines are months.** `bip300301_enforcer/lib/types.rs` MAINNET:
`withdrawal_bundle_inclusion_threshold = 13_150`, `withdrawal_bundle_max_age = 26_300` blocks — at
~10 min/block **≈3 months** to pass (`votes > threshold`, strictly) and **≈6 months** before an
unapproved bundle **expires as failed** (`age ≤ max_age`). Test networks use the enforcer's SHORT
thresholds. A failed bundle returns the coins to the sidechain to be re-bundled; it is not lost funds.

**UI consequences (as built):** a withdrawal is not a send — `TxDetailSheet` shows a `WithdrawalStatus`
(`confirming` / `waitingForBatch` / `voting(votes, votesNeeded, blocksUntilExpiry)` / `paid`, built
from the enforcer's `GetWithdrawalBundleProposals` plus the threshold/max-age constants —
`Drivechain/WithdrawalStatus.swift`, `AppState.withdrawalStatus(for:)`), a vote-progress bar, and a
"can no longer pass" state; your withdrawal rides a bundle with other people's, so it moves when the
*bundle* passes.

**`create_withdrawal` output shape (thunder-rust `lib/wallet.rs`), mirrored by ours:** the withdrawal
output is addressed to a **fresh sidechain address of our own** (consensus forbids anyone spending it;
the address just names an owner) with `main_address` in its content; change is an ordinary `Value`
output to another fresh address; coin selection covers **value + sidechain fee + main_fee** (the
mainchain payout fee is funded from sidechain coins now). Floor: `minimumWithdrawalSats = 546` and
`mainFee > 0` (`withdrawalTooSmall`). **Utreexo caveat:** the reference builds the withdrawal with a real
`accumulator.prove(...)`; we submit with an **empty proof** and rely on the node regenerating it
(thunder-rust `fb922ee`), as for every send — unconfirmed on-chain for a withdrawal specifically.

**Public vs private RPC** (verified against a live node, 2026-08-27; the wallet methods live on
`--private-rpc-addr`):

| Method | Public endpoint | Use to us |
|---|---|---|
| `submit_transaction` | ✅ | submit our locally-signed withdrawal |
| `get_utxos` / `get_stxos` | ✅ | balance and history |
| `pending_withdrawal_bundle` | ✅ | is our withdrawal in the current bundle? |
| `latest_failed_withdrawal_bundle_height` | ✅ | did a bundle expire? |
| `create_withdrawal` / `create_deposit` / `format_deposit_address` | ❌ not found | node-side keys — wouldn't use; the deposit string is reproducible on device |
| `balance`, `get_wallet_addresses`, `mine` | ❌ not found | node's own wallet |

That split matches our keys-on-device model (Golden Rule §2); no node-side additions were needed for
withdrawals. (The app reads bundle status from the enforcer rather than these two node RPCs.)

**Still open:** (3) are a test network's SHORT thresholds short enough to exercise a full round trip in
a session? (4) is there a minimum withdrawal value worth bundling (dust at mainchain payout) beyond our
546-sat floor? (5) what does the user see if the operator never proposes a bundle? (Q1 — the `s9_…`
string is UI-only, the OP_RETURN carries the bare address — and Q2 — the ctip comes from
`GET /drivechain/sidechain/9` — are answered in `docs/sidechain-deposits.md`.)
