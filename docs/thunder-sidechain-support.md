# Thunder sidechain support — research + plan

> Status: **BUILT, not yet run against a real node** (updated 2026-07-27). Source-backed notes on how
> L2L's **Thunder** sidechain (`github.com/LayerTwo-Labs/thunder-rust`) handles keys/addresses/signing/
> transactions, and what this wallet does about it. **Bottom line: Thunder shares NOTHING with Bitcoin's
> crypto — BDK cannot touch it, so it is a second, parallel wallet engine, built as ONE cross-platform
> Swift stack** (`swift-crypto` ed25519 + vendored BLAKE3 + hand-written SLIP-0010 + Borsh, all native
> on iOS + Android via Skip Fuse) **rather than Rust FFI.**
>
> **Where it stands:** the non-custodial send path is complete on both sides — the node's half shipped
> in thunder-rust branch `2026-07-24-refactor` (§8c), ours in commit `302dc78` (§8d). Balance, receive,
> send and sweep are wired; **history is the one gap**, waiting on a `get_stxos` RPC (§8c). Thunder is
> deliberately **commented out of `WalletNetwork.selectable`** until it has run against a live node, so
> none of it is reachable in the UI. Two things are still owed before real funds move: a `borsh::to_vec`
> golden-vector cross-check against a real node, and an actual endpoint to test against.

## 1. What Thunder is

A BIP300/301 **Drivechain sidechain** by Layer Two Labs — a simple, high-throughput UTXO chain that
receives deposits from the Bitcoin mainchain and can withdraw back to it. It is its OWN chain with
its own node + RPC; it is NOT a Bitcoin network variant like our `.bitcoin`/`.signet`/`.ecash`.

## 2. Crypto model (verified against `thunder-rust` source)

Every layer is different from Bitcoin:

| Concern | Bitcoin (BDK) | **Thunder** | Source |
|---|---|---|---|
| Signature curve | secp256k1 (ECDSA/Schnorr) | **ed25519** (`ed25519-dalek`) | `lib/authorization.rs` |
| HD derivation | BIP32/BIP44/84 (secp256k1) | **ed25519 BIP32 / SLIP-0010** (`ed25519-dalek-bip32`), path **`m/1'/0'/0'/index'`** (ALL hardened — ed25519 BIP32 only allows hardened) | `lib/wallet.rs` |
| Seed | BIP39 mnemonic → seed | **same BIP39** mnemonic → 64-byte seed (`bip39`, empty passphrase) | `lib/wallet.rs` |
| Hashing | SHA-256 / RIPEMD-160 | **BLAKE3** | `lib/authorization.rs` |
| Address | P2PKH/P2SH/segwit/taproot, base58check / bech32 | **first 20 bytes of `BLAKE3(pubkey)`**, encoded as **plain base58** (NO checksum, NO version byte) | `lib/types/address.rs`, `authorization.rs::get_address` |
| Tx serialization | Bitcoin consensus encoding | **Borsh** (canonical) | throughout `lib/types/` |
| UTXO set | queryable (Electrum/Esplora) | **Utreexo accumulator** — inputs carry utreexo proofs; there is no address→UTXO query | `lib/types/transaction.rs` (`proof: Proof`) |

### Keys
- `SigningKey` (private, 32 B) / `VerifyingKey` (public, 32 B) / `Signature` (64 B) from `ed25519-dalek`.
- Derivation (`wallet.rs::get_signing_key`): `ExtendedSigningKey::from_seed(seed)` →
  `derive(m/1'/0'/0'/index')` → `signing_key`. New address = bump `index`, derive, store
  `index → address`.

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

### 5a. Crypto/signing layer (ed25519 / BLAKE3 / Borsh)
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
ed25519 keys from it (same BIP39 mnemonic → ed25519 `m/1'/0'/0'/i'`), **signs the `AuthorizedTransaction`
locally, and pushes the SIGNED tx to the Thunder RPC.** The Thunder node RPC is **"just another API,"
treated like our existing backends** — i.e. a per-network endpoint (`kind: "thunder"`, a URL) carried in
the same remote config (`drivechain.dev/config`) alongside electrum/esplora, and resolved the same way.
The node is a dumb relay + chain-data source; it never sees the seed. **The ONLY gap is on the node
side:** thunder-rust must expose (1) `submit_transaction(AuthorizedTransaction)` (its internal
`Node::submit_transaction` already does exactly this) and (2) a fetch-my-UTXOs-with-utreexo-proofs
method. Those two RPC additions are the gating dependency — not the crypto — and they're L2L's to add.

### 5c. Thunder is a sidechain OF the eCash fork (Jake, 2026-07-22)
Not a separate chain to bolt on — it's a **BIP300/301 sidechain of the eCash mainchain we already
support** (`.ecash`). So:
- **Deposits** (eCash-mainchain → Thunder) are an **eCash *mainchain* transaction** to a special
  deposit address (`format_deposit_address`: `s{sidechain}_{base58}_{sha256[:3]}`). Our **existing
  eCash BDK engine can build that mainchain tx** — the sidechain side just credits it. (`create_deposit`
  RPC does it node-side today; client-side we'd build the mainchain tx ourselves via BDK.)
- **Withdrawals** (Thunder → eCash-mainchain) are the `Content::Withdrawal { value, main_fee,
  main_address }` output → a withdrawal bundle settled on the eCash mainchain (BIP300/301).
- **Presentation (TBD — Jake unsure):** likely NOT a separate top-level "network" in the switcher, but
  a **layer/tab within the eCash wallet** — an eCash wallet has a mainchain balance and a Thunder
  (L2/sidechain) balance, with deposit/withdraw moving funds between them. Same seed could derive both
  the eCash (secp256k1) and Thunder (ed25519) keys. Decide the UX model before building.

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
- **Presentation UX** (§5c) — Thunder is a sidechain of eCash → likely a **layer/tab inside the eCash
  wallet** (mainchain vs Thunder balance + deposit/withdraw), not a separate network. Jake TBD.
- **Deposit/withdrawal flows** — deposit = an eCash *mainchain* tx our BDK engine can build (to the
  special deposit address); withdrawal = a Thunder `Content::Withdrawal` → BIP300/301 bundle. Scope
  separately (CLAUDE.md §12 "BIP300/301 deposits & withdrawals" — Thunder is the concrete instance).

## 8b. The decided flow — thin node, pure-Swift client (2026-07-23)

**Agreed with the Thunder dev.** The node is a **UTXO source + relay**; the phone does everything else
locally with our pure-Swift stack. NO node-side coin-selection (that was an earlier proposal — see §8c
"superseded"). The seed never leaves the phone.

```
1. derive addresses            phone   ed25519 m/1'/0'/0'/i' (SLIP-0010 → BLAKE3 → base58)   ✅ built
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
get_stxos(addresses: [Address])         -> [(OutPoint, SpentOutput)]   # ⏳ asked for — history (§8c)
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

**⏳ The one remaining ask — history.** There is no address-scoped way to see *spent* outputs, and
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
2. **`Authorization.verifying_key` / `.signature`** are annotated `String`, but ed25519-dalek 2.2
   serializes via `serializer.serialize_bytes` (no `serdect`/`serde_bytes` anywhere in the dependency
   graph) → **arrays of 32 / 64 numbers**. This isn't a preference: its `Deserialize` implements
   `visit_bytes` and `visit_seq` but *not* `visit_str`, so a hex string is rejected outright.
3. **`OutPoint::Deposit`** wraps a *mainchain* `bitcoin::OutPoint`, and `bitcoin::Txid` serializes as
   **display** hex — byte-REVERSED relative to the internal bytes we Borsh-encode. Thunder's own `Txid`
   (in `Regular`) is the opposite: raw byte order, no reversal. Convert on the `Deposit` boundary only.
   Get this backwards and you build a plausible-looking input whose utxo hash the node can't match.

Shapes that are what you'd hope: `Address` is base58, `Txid`/`MerkleRoot`/`BlockHash` are lowercase hex
(`hexstr_human_readable`), `Content` is externally tagged — `{"Value": <sats>}` /
`{"Withdrawal":{"value_sats","main_fee_sats","main_address"}}`. `proof` is a **required** field with no
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
  `transactions()` throws `.historyUnavailable` — deliberately distinct from `.backendUnavailable`, so
  the UI can say "not available yet" rather than "can't reach the node". `splitToSelf` throws
  `.unsupportedOperation` (splitting guards an eCash-fork replay concern this chain doesn't have).
- **Performance:** `ThunderKey.derive(seed:index:)` + `ThunderWallet.keys(for:)` compute the BIP39 seed
  (PBKDF2, 2048 iterations) **once per scan** instead of once per index — a 20-address scan was 20 PBKDF2
  runs, and signing re-scanned from zero for every input.

**When `get_stxos` lands:** add the method to `ThunderRPCClient` and implement `transactions()` by
netting `get_utxos` + `get_stxos` per txid (received = outputs to us keyed by `outpoint.txid`; sent =
ours spent, keyed by `inpoint.txid`). Nothing else needs to change.

## 8. Bottom line

Thunder is a genuinely separate chain: **ed25519 keys (BIP32 `m/1'/0'/0'/i'`), BLAKE3-hashed base58
addresses, whole-tx ed25519 signatures, Borsh serialization, Utreexo UTXO set, own node RPC.** BDK is
irrelevant to all of it. The path is a **Fuse-native `ThunderService`** on **one cross-platform Swift
crypto stack** — `swift-crypto` (ed25519) + SwiftBlake3 + hand-written SLIP-0010 + a Swift Borsh codec —
plugged into the per-network engine abstraction (`WalletOps`/`WalletFacade`) as a non-BDK engine.

**Status 2026-07-27 — built, unproven against a real node:**
- ✅ **Crypto/keys/Borsh/authorization** — `ThunderKey`, `ThunderWallet`, `Base58`, `Slip10Ed25519`,
  `Bip39Seed`, `ThunderAddress`, `ThunderTransaction` (Borsh), `AuthorizedThunderTransaction` — all
  vector-tested; builds + runs on iOS + Android (portable-BLAKE3 fix for the Android load crash).
- ✅ **Node RPCs we need for sending** — `get_utxos` + proof-regenerating `submit_transaction` shipped
  on thunder-rust `2026-07-24-refactor` (§8c).
- ✅ **Client engine** — utxo-hash, RPC client, coin selection, persisted address index, and
  `ThunderService` balance/sync/send/sweep (§8d, commit `302dc78`). 218 host tests green; release APK
  builds. Pure Swift throughout — NOT using the dev's `thunder_types`/FFI crate.
- ✅ **UI** — create/import/backup/receive work; crimson chip; ECX unit. Thunder is **commented out of
  `WalletNetwork.selectable`**, so it is not reachable until the flow is proven end to end.
- ⏳ **History** — blocked on `get_stxos` (§8c); `transactions()` throws `.historyUnavailable`.
- ⏳ **Before real funds:** a live endpoint to test against, and the `borsh::to_vec` golden-vector
  cross-check against a real thunder-rust encoding. Everything above is verified only against
  hand-built vectors and stubbed JSON — no byte of it has met a real node yet.
