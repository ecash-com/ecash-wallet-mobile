# Thunder sidechain support — research + plan

> Status: **RESEARCH / not started** (2026-07-22). Source-backed notes on how L2L's **Thunder**
> sidechain (`github.com/LayerTwo-Labs/thunder-rust`) handles keys/addresses/signing/transactions,
> and what it would take for this wallet to support it. **Bottom line: Thunder shares NOTHING with
> Bitcoin's crypto — BDK cannot touch it. Supporting it is a second, parallel wallet engine. Leaning
> to build the crypto with ONE cross-platform Swift lib (`swift-crypto` ed25519 + BLAKE3, both native
> on iOS + Android via Skip Fuse) rather than Rust FFI — gated on a build spike (§5a).**

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
get_utxos(addresses: [Address])         -> [PointedOutput]        # ⏳ dev adding (reads full chain state)
balance_for(addresses: [Address])       -> Balance                # ⏳ (or sum get_utxos client-side)
get_transactions(addresses: [Address],
                 limit?)                 -> [ {txid, net_sats, fee_sats?, block_height?, confirmations} ]  # ⏳
submit_transaction(Authorized<Transaction>) -> Txid               # ✅ shipped 0.17.0 (fills the proof)
```
Sync/height reuse existing `getblockcount` / `get_best_sidechain_block_hash`. Fee: TBD (a
`suggested_fee` or a client default).

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

## 8c. What shipped in 0.17.0 — and the remaining delta (2026-07-23)

thunder-rust **0.17.0** (`c9831e83 "Update wallet API"`) landed the sign/submit split — real progress,
but the wallet is still **node-holds-the-seed**, so it does not yet support our non-custodial (keys-only-
on-phone) flow. Verified against `rpc-api/lib.rs` + `app/rpc_server.rs` + `lib/wallet.rs`.

**Shipped and directly usable:**
- ✅ **`submit_transaction(Authorized<Transaction>) -> Txid`** — exactly what we need; submits a
  client-signed tx. Our Borsh + ed25519 + `AuthorizedThunderTransaction.authorize` already produces this.
- ✅ **`create_transfer(dest, value_sats, fee_sats) -> Transaction`** and
  **`create_withdrawal(...) -> Transaction`** — both return an **unsigned** `Transaction` (docstring:
  "without signing it"); the node does coin-selection + change + utreexo proof.

**Why it's still custodial as-is:** `create_transfer` → `wallet.create_transaction(value, fee)` →
`select_coins` picks from the **node's own seed-derived wallet**, and change goes to a node
`get_new_address()`. There is **no `spend_from` / `change_address` param** and **no watch-only path** —
every read (`balance`, `get_wallet_utxos`, `get_addresses`) is scoped to the node's local wallet. So for
the node to build a tx over **our** coins, it must hold **our** seed (`set_seed_from_mnemonic`) = custodial.

> **SUPERSEDED (2026-07-23): the `create_transfer_from` node-coin-selection ask below is NOT what we're
> building.** The dev proposed — and we agreed — a cleaner split: the node does NOT do coin-selection;
> it just serves `get_utxos(addresses)` and `submit_transaction` (which fills the proof). The phone
> selects coins + builds + signs. See **§8b** for the decided flow. The remaining ask kept below only
> for its read-method shapes (`get_utxos`/`balance_for`/`get_transactions`, still needed) — ignore
> `create_transfer_from`. Standalone dev handoff: `docs/thunder-rpc-request.md`.

**(SUPERSEDED spec) The delta — ADDITIVE (keep the local wallet, add a remote-wallet path).** Jake,
2026-07-23: the node should still support a **local wallet** (self-hosters) AND a **remote wallet** (our
mobile app holds the keys; node holds no seed). The existing methods keep serving the local wallet; add
address-scoped variants that serve a remote wallet by reading the node's **full chain STATE** (the
Utreexo UTXO set + accumulator for proofs — `lib/state/`), NOT the local wallet DB:

```
# BUILD (node selects + proves over addresses WE pass; no seed, no signing)
create_transfer_from(
    spend_from:     [Address],     # our addresses whose UTXOs may be spent (node filters the
                                   #   full-state UTXO set to these; it already indexes address->utxo)
    dest:           Address,
    value_sats:     u64,
    fee_sats:       u64,
    change_address: Address        # ours
) -> Transaction                   # UNSIGNED; node built inputs+change and filled the utreexo `proof`
# (create_withdrawal_from = same shape + mainchain_address/mainchain_fee_sats; withdrawals are v2)

# READ (address-scoped, from full state — no seed)
get_utxos(addresses: [Address])         -> [PointedOutput]     # already have PointedOutput{outpoint,output}
balance_for(addresses: [Address])       -> Balance            # or client sums get_utxos
get_transactions(addresses: [Address],
                 limit: Option<u32>)    -> [ {txid, net_sats, fee_sats?, block_height?, confirmations} ]

# SUBMIT — already shipped ✓
submit_transaction(Authorized<Transaction>) -> Txid
```

**Proof round-trips fine over JSON-RPC:** `Transaction.proof` is `#[borsh(skip)]`, so it's excluded from
the SIGNED bytes / txid but serde still serializes it in the JSON. So `create_transfer_from` returns the
proof (JSON) → client signs `borsh(transaction)` (no proof) → `submit_transaction` carries the proof back
(JSON). Client-side we just hold the proof blob opaquely between build and submit; we never decode it.

**Client flow (unchanged from §8b):** `create_transfer_from` (unsigned) → for each input resolve our
address→ed25519 key → `sign(borsh(transaction))` → `Authorized<Transaction>` → `submit_transaction`.
Balance/history via the address-scoped reads. Deposit is still an eCash-mainchain tx via our BDK engine
to `format_deposit_address(...)` (no Thunder spend RPC).

## 8. Bottom line

Thunder is a genuinely separate chain: **ed25519 keys (BIP32 `m/1'/0'/0'/i'`), BLAKE3-hashed base58
addresses, whole-tx ed25519 signatures, Borsh serialization, Utreexo UTXO set, own node RPC.** BDK is
irrelevant to all of it. The path is a **Fuse-native `ThunderService`** on **one cross-platform Swift
crypto stack** — `swift-crypto` (ed25519) + SwiftBlake3 + hand-written SLIP-0010 + a Swift Borsh codec —
plugged into the per-network engine abstraction (`WalletOps`/`WalletFacade`) as a non-BDK engine.

**Status 2026-07-23 — mostly built:**
- ✅ **Crypto/keys/Borsh/authorization** — `ThunderKey`, `ThunderWallet`, `Base58`, `Slip10Ed25519`,
  `Bip39Seed`, `ThunderAddress`, `ThunderTransaction` (Borsh), `AuthorizedThunderTransaction` — all
  vector-tested; builds + runs on iOS + Android (portable-BLAKE3 fix for the Android load crash).
- ✅ **UI** — Thunder is a selectable network (crimson chip); create/import/backup/receive work; ECX
  unit; balance/history/send error `.backendUnavailable` until the RPC lands.
- ⏳ **Remaining (gated on the dev's `get_utxos`/balance/history RPCs, §8b):** a small Swift coin-selector,
  the Thunder RPC client, and wiring `ThunderService`'s send/balance/history ops. Then: the one
  `borsh::to_vec` golden-vector cross-check + persist the revealed-address index (§ receive discipline)
  before enabling real funds. Pure Swift throughout — NOT using the dev's `thunder_types`/FFI crate.
