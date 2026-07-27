# Thunder RPC — remote (non-custodial) wallet support

**To:** thunder-rust maintainer · **From:** eCash.com Wallet (mobile) · **Updated:** 2026-07-27
**Against:** thunder-rust branch `2026-07-24-refactor` (PR #116, head `fb922ee`)

## Status: the send path is done — thank you

Both blockers are gone, and we've built our half against them (see
`docs/thunder-sidechain-support.md` §8d):

```
1. derive addresses            phone   ed25519 m/1'/0'/0'/i'                          ✅ ours
2. get_utxos(addresses)        node    UTXOs for our addresses, from full chain state ✅ ed23b82
3. select coins + build tx     phone   coin-select + construct Transaction (Borsh)    ✅ ours
4. sign locally                phone   ed25519 over borsh(transaction), per input     ✅ ours
5. submit_transaction(atx)     node    regenerates the utreexo proof, applies         ✅ fb922ee
```

`get_utxos` reading `State::get_utxos_by_addresses` (full chain state, not the node's wallet DB) is
exactly what we needed — the node never sees our seed. And with `submit_transaction` regenerating the
proof, the phone never touches the accumulator.

The existing **local-wallet** API (`create_transfer`, `balance`, `get_wallet_utxos`,
`set_seed_from_mnemonic`, `sign_transaction`, …) is untouched by any of this, so self-hosters keep
working. Both modes coexist: local (node holds seed) and remote (phone holds seed, node serves
`get_utxos` + relays).

## The one thing still missing: history

With `get_utxos` we can show a balance and receive, but we can't build an Activity list — spent outputs
are gone from the UTXO set, so everything the user has ever *sent* is invisible. `get_transaction(txid)`
doesn't help, since we have no way to discover the txid in the first place.

Smallest fix, and close to a copy of the `get_utxos` you just wrote — same filter-by-`output.address`
scan, over the `stxos` DB instead of `utxos`:

```rust
async fn get_stxos(addresses: HashSet<Address>) -> RpcResult<Vec<(OutPoint, SpentOutput)>>;
```

`SpentOutput { output, inpoint }` and `InPoint` already derive `Serialize`, so no new types are needed.
That's enough for us to reconstruct history client-side: `outpoint.txid` is the tx that paid us,
`inpoint` is the tx that spent it, and we net the two per txid.

**Optional, only if it's cheap:** `block_height: Option<u32>` on `GetTransactionResponse` — you already
resolve `block_hash` there and `archive.get_height` is adjacent. Without it we can show *what* happened
but not reliably in what order. Skippable if it's a hassle.

## Two notes on our side (pure-Swift client)

We hand-write the Borsh, matched to `types::Transaction` / `Output` / `OutPoint`, so **we're not using
the `thunder_types`/FFI crate**. Two small things that help us stay byte-correct:

1. **Wire format stability** — we diffed `transaction.rs` across the `lib/types` → `types/` extraction
   and confirmed the Borsh encoding is unchanged; thank you. A heads-up on any future field/encoding
   change would be appreciated, since it would silently break our signatures.
2. **One golden vector** — still the outstanding ask: a single `borsh::to_vec(&transaction)` example (a
   known `Transaction` → expected hex, ideally plus the resulting `txid`) so we can assert our Swift
   Borsh matches yours before we enable real sends.

## Two schema/serde mismatches (FYI — no action needed)

We're handling these client-side; noting them only in case they bite someone generating a client from
the OpenAPI document, or in case the annotations are simply meant to be accurate:

- `Transaction.inputs` is annotated `Vec<(OutPoint, String)>`, but `Hash = [u8; 32]` has no serde hex
  wrapper, so it serializes as an array of 32 numbers.
- `Authorization.verifying_key` / `.signature` are annotated `String`, but ed25519-dalek 2.2 uses
  `serialize_bytes` (no `serdect`/`serde_bytes` in the graph), so those are arrays of 32 / 64 numbers
  too. Its `Deserialize` implements `visit_bytes`/`visit_seq` but not `visit_str`.

## Types we reference
- `PointedOutput { outpoint: OutPoint, output: Output }` — exists.
- `SpentOutput { output: Output, inpoint: InPoint }` — exists (the `get_stxos` payload above).
- `Authorized<Transaction>` (`= { transaction, authorizations: [Authorization{verifying_key, signature}] }`)
  — exists; this is our `submit_transaction` payload.
