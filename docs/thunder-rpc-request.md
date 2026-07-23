# Thunder RPC — remote (non-custodial) wallet support

**To:** thunder-rust maintainer · **From:** eCash.com Wallet (mobile) · **Updated:** 2026-07-23
**Against:** thunder-rust `0.17.0` (`c9831e83` "Update wallet API")

## Agreed flow (thin node, client holds keys)

We settled on your proposal — the node does **not** do coin-selection; the phone does everything except
fetch UTXOs and relay. The seed/private keys never leave the phone.

```
1. derive addresses            phone   ed25519 m/1'/0'/0'/i'  (we do this locally)
2. get_utxos(addresses)        node    returns the UTXOs for our addresses          ← RPC you're adding
3. select coins + build tx     phone   coin-select + construct ThunderTransaction (Borsh)
4. sign locally                phone   ed25519 over borsh(transaction), per input
5. submit_transaction(atx)     node    fills the utreexo proof, applies             ← you'll fill the proof ✅
```

**Utreexo proof:** resolved — you said `submit_transaction` will fill the proofs node-side. So the phone
builds the tx with an **empty** proof and signs `borsh(transaction)`; since `Transaction.proof` is
`#[borsh(skip)]` it's not in the signed bytes, and `submit_transaction`/`regenerate_proof` attaches it
before applying. The phone never touches the accumulator. 👍

## What we need from the node

```rust
// Reads — address-scoped, from full chain state (no seed on the node)
async fn get_utxos(addresses: Vec<Address>) -> RpcResult<Vec<PointedOutput>>;
async fn balance_for(addresses: Vec<Address>) -> RpcResult<Balance>;   // optional — we can sum get_utxos
async fn get_transactions(
    addresses: Vec<Address>,
    limit:     Option<u32>,
) -> RpcResult<Vec<TxHistoryItem>>;   // { txid, net_sats, fee_sats?, block_height?, confirmations }

// Submit — already shipped ✅ (0.17.0); will fill the utreexo proof
async fn submit_transaction(transaction: Authorized<Transaction>) -> RpcResult<Txid>;
```

The existing **local-wallet** API (`create_transfer`, `balance`, `get_wallet_utxos`,
`set_seed_from_mnemonic`, `sign_transaction`, …) is **untouched** — this is purely additive, so
self-hosters keep working. Both wallet modes coexist: local (node holds seed) and remote (phone holds
seed, node serves `get_utxos` + relays).

## Two notes on our side (pure-Swift client)

We're keeping the client **pure Swift** — we hand-write the Borsh, matched to `types::Transaction` /
`Output` / `OutPoint` — so **we won't be using the `thunder_types`/FFI crate**. Two small things that help
us stay byte-correct:

1. **Wire format stability** — when you move types into `thunder_types`, please keep the Borsh
   serialization identical (relocating types is fine; a field/encoding change would break our Swift
   Borsh). A heads-up on any change is appreciated.
2. **One golden vector** — a single `borsh::to_vec(&transaction)` example (a known `Transaction` →
   expected hex bytes, and ideally the resulting `txid`) would let us assert our Swift Borsh matches
   yours exactly before we enable real sends.

## Types we reference
- `PointedOutput { outpoint: OutPoint, output: Output }` — exists.
- `Balance { total, available }` — exists.
- `Authorized<Transaction>` (`= { transaction, authorizations: [Authorization{verifying_key, signature}] }`)
  — exists; this is our `submit_transaction` payload.
