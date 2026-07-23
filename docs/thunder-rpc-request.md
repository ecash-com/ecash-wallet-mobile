# Thunder RPC request — remote (non-custodial) wallet support

**To:** thunder-rust maintainer · **From:** eCash.com Wallet (mobile) · **Date:** 2026-07-23
**Against:** thunder-rust `0.17.0` (`c9831e83` "Update wallet API")

## TL;DR

0.17.0 added everything we need to *submit* a client-signed transaction
(`submit_transaction`) and to get an *unsigned* tx back (`create_transfer` /
`create_withdrawal` return `Transaction` "without signing it"). Thank you — that's the hard half.

**The gap:** every build/read method is hard-wired to the node's **own seed-derived wallet**, so the
node can only transact for a wallet **whose seed it holds**. That's fine for a local wallet; it can't
serve a wallet whose keys live off-node (our mobile app) without us handing over our seed — which defeats
the point. We need the node to support **two wallet modes at once**, and today it only supports one.

---

## The two wallet modes the node needs to support

| | **Local wallet** (today, keep it) | **Remote wallet** (missing — our mobile app) |
|---|---|---|
| Who holds the seed/keys | The **node** | The **client** (phone). Node holds **no seed**. |
| Coin-selection over whose UTXOs | Node's own wallet UTXOs | UTXOs for **addresses the client passes in** |
| Signing | Node signs (`sign_transaction`) | **Client signs**, node just relays (`submit_transaction`) |
| Reads (balance/utxos/history) | Node's own wallet | **Scoped to addresses the client passes in** |
| Status in 0.17.0 | ✅ Works | ❌ No API path |

**Why it can't do "remote" today:** there is no `spend_from` parameter and no watch-only / address-import
path. The *only* way to make the node act for our addresses is `set_seed_from_mnemonic(<our seed>)` — i.e.
turn our remote wallet into a local (custodial) one. So as-is, "the node can transact for the mobile
wallet" and "the node never holds the mobile wallet's seed" are mutually exclusive. We need both.

The node already has everything required for the remote mode in its **full chain state** — it's a Utreexo
full node that sees every UTXO and its address and can build inclusion proofs. It just doesn't expose any
of that scoped to a caller-supplied address list; it only exposes its *own* local-wallet view.

---

## Why 0.17.0 doesn't work for a mobile (non-custodial) wallet

The mobile wallet is non-custodial by design: the **seed/private keys never leave the phone**, and the
node must never see them. But the current spend/read paths assume the node *is* the wallet:

- `create_transfer(dest, value_sats, fee_sats)` → `wallet.create_transaction(value, fee)` →
  **`select_coins`** over the **node's own seed-derived wallet UTXOs**, with change to the node's own
  `get_new_address()`.
- `balance()`, `get_wallet_utxos()`, `get_addresses()` are all scoped to the **node's local wallet**.

So for `create_transfer` to spend **our** coins, the node has to know which UTXOs are ours — and the
only way to tell it today is `set_seed_from_mnemonic(<our seed>)`. **That puts our seed on the node =
custodial.** There's no `spend_from` parameter and no watch-only / address-import path.

Everything needed already exists in the node's **full chain state** — it's a Utreexo full node that sees
every UTXO and its address and can produce inclusion proofs. It just isn't exposed scoped to an arbitrary
address list; only the node's *own* wallet view is.

---

## What we're asking for (additive — the local wallet is untouched)

This is purely additive: **nothing about the existing local-wallet API changes**, so local-wallet users
keep working exactly as today. We add a **parallel remote-wallet surface** — the caller supplies the
addresses, the node holds no seed. Supporting both modes = the existing methods (local) **plus** these
new ones (remote). The new methods read the node's **full chain state** (the Utreexo UTXO set +
accumulator for proofs, `lib/state/`), **not** the local wallet DB.

### Build — node selects coins + fills the utreexo proof over addresses *we* pass (no seed, no signing)

```rust
/// Like `create_transfer`, but coin-selects over the full-state UTXOs owned by `spend_from`
/// (addresses the CALLER controls) and sends change to `change_address`. Returns UNSIGNED.
async fn create_transfer_from(
    spend_from:     Vec<Address>,   // caller-owned addresses whose UTXOs may be spent
    dest:           Address,
    value_sats:     u64,
    fee_sats:       u64,
    change_address: Address,        // caller-owned
) -> RpcResult<Transaction>;        // same unsigned Transaction shape create_transfer returns
```

`create_withdrawal_from` = same treatment (add `spend_from` + `change_address`) — but withdrawals are v2
for us, so it's lower priority than `create_transfer_from`.

### Read — address-scoped, from full state (no seed)

```rust
async fn get_utxos(addresses: Vec<Address>) -> RpcResult<Vec<PointedOutput>>;   // PointedOutput already exists
async fn balance_for(addresses: Vec<Address>) -> RpcResult<Balance>;            // or we sum get_utxos client-side
async fn get_transactions(
    addresses: Vec<Address>,
    limit:     Option<u32>,
) -> RpcResult<Vec<TxHistoryItem>>;   // { txid, net_sats, fee_sats?, block_height?, confirmations }
```

### Submit — already shipped ✅ (no change)

```rust
async fn submit_transaction(transaction: Authorized<Transaction>) -> RpcResult<Txid>;   // 0.17.0
```

---

## Resulting mobile flow (all keys stay on the phone)

1. Phone derives its ed25519 addresses locally (`m/1'/0'/0'/i'`, SLIP-0010, BLAKE3 → base58).
2. `create_transfer_from(our_addresses, dest, value, fee, our_change_addr)` → **unsigned** `Transaction`
   (node did coin-selection + change + utreexo proof).
3. Phone signs `borsh(transaction)` with its ed25519 keys → `Authorized<Transaction>`.
4. `submit_transaction(authorized)` → `Txid`.
5. Balance/history via `get_utxos` / `balance_for` / `get_transactions`.

## Why the client-signing split is safe with the proof

`Transaction.proof` is `#[borsh(skip)]`, so it's excluded from the signed bytes and the txid — but serde
still serializes it over JSON-RPC. So the proof round-trips build → submit inside the JSON: the client
signs `borsh(transaction)` (no proof), holds the returned proof blob opaquely, and passes it back in
`submit_transaction`. The client never decodes or invalidates it, and the node can even refresh a stale
proof at submit without breaking signatures.

---

## The whole ask, minimally

- **`create_transfer_from(spend_from, dest, value_sats, fee_sats, change_address) -> Transaction`**
  (the one blocker for spending)
- **`get_utxos(addresses)` / `balance_for(addresses)` / `get_transactions(addresses, limit)`** (reads)
- `submit_transaction` — **already done**; the existing local-wallet API is **unchanged**.
