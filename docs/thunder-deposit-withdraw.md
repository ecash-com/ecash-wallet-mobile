# Thunder deposits & withdrawals — how they work, and what we'd have to build

**Status:** 🔵 RESEARCH, NOT BUILT — 2026-08-27. Written after reading the Drivechain message spec
([bips.bip300.xyz/drivechain-messages.html](https://bips.bip300.xyz/drivechain-messages.html)),
thunder-rust, and the BIP300 enforcer, and after probing a live Thunder node
(`157.180.96.24:16009`).

Related: `docs/thunder-sidechain-support.md` (the engine), `docs/coin-splitting.md` (the other
place eCash-vs-Bitcoin mechanics bite).

> **Correction worth recording.** An earlier reading of the RPC surface suggested a deposit would
> simply be "an eCash send to a tagged address". It isn't (§2). The tagged `s9_…` string is an
> instruction to a deposit-*building* wallet, not a payable address. Withdrawals turn out to be the
> tractable direction for us; deposits are the hard one.

---

## 1. The governing asymmetry

The spec states it plainly:

> "Money in is permissionless; money out is not."

A **deposit** needs no miner approval — the mainchain already validated the coins moving in. A
**withdrawal** asks the mainchain to release coins based on sidechain state it *cannot verify*,
because blind merged mining means miners never see sidechain contents. Verification is replaced by a
long miner vote, and the length of that vote **is** the security.

Everything below follows from that one asymmetry.

## 2. Deposits (M5) — permissionless, but not a payment

An M5 deposit is an ordinary mainchain transaction that:

1. **spends the sidechain's current treasury UTXO** (the "ctip"),
2. **recreates it with more value**, and
3. carries the destination sidechain address in a separate `OP_RETURN`.

There is no tag byte — M5 is recognised by its *shape*. Anyone can broadcast one; once mined the
treasury grows and the sidechain credits the address in the OP_RETURN.

**Why this is hard for us.** We'd have to build a transaction that spends a UTXO the user doesn't
own. The treasury is anyone-can-spend by consensus rule, so no signature is required, but we would
need to:

- ~~**learn the current ctip**~~ — **SOLVED 2026-09-01.** It changes with every deposit and
  withdrawal and isn't in a Bitcoin Esplora/Electrum view of the chain; thunder-rust gets it from the
  enforcer over gRPC (`--mainchain-grpc-url`), which we don't speak. But the **drivechain-esplora**
  index we now use for Thunder reads through to an enforcer and serves it over plain HTTPS:
  `GET /drivechain/sidechain/9` returns the slot, its M1 declaration, and the treasury as
  `{"txid", "vout", "value_sats"}` — which is the ctip. **Verified live** against
  `seed.alpha.ecash.eu.com/thunder` (it answers today, even with the index holding no blocks, because
  these two routes read the mainchain rather than the sidechain index). A slot with no treasury
  answers `"treasury": null` rather than zero sats, so "nothing deposited yet" is distinguishable from
  "a treasury holding nothing". Caveat: these routes are only as available as the enforcer behind
  them, and a deployment without one answers 503. See `docs/thunder-sidechain-support.md` §8e.
- **add it as a foreign input** — BDK supports this (`add_foreign_utxo`), so it's possible, but it's
  well outside the "build a normal send" path everything else uses.
- **get the recreate-value exactly right**, or the transaction isn't a valid M5 at all.
- **race other depositors** — the ctip is a single shared UTXO, so two deposits built against the
  same ctip conflict and one loses.

**The deposit address format** is at least trivial and reproducible on device — pure, no node state
(`types/address.rs`):

```rust
let prefix = format!("s{}_{}_", THIS_SIDECHAIN, self.as_base58());  // "s9_<base58>_"
let digest = sha256(prefix.as_bytes());
format!("{prefix}{}", hex(&digest[..3]))                            // + 3-byte checksum
```

So `s9_<address>_<6 hex>`. **Open question:** whether that string is what goes in the OP_RETURN, or
just the human-facing form a deposit-building wallet parses. Worth confirming before designing UI
around it.

## 3. Withdrawals (M3 → M4 → M6) — slow, but ours to build

Four stages, only the first of which is ours:

1. **The user's withdrawal request** — a *Thunder* transaction whose output is a withdrawal rather
   than a value transfer. This is a normal sidechain transaction: we build it, sign it on device,
   and `submit_transaction`. **This part we can do.**
2. **Bundle proposal (M3)** — the sidechain operator aggregates pending withdrawals into one bundle
   and nominates it by txid in a coinbase message. Opens a vote; settles nothing.
3. **Voting (M4)** — miners upvote the bundle slate in their coinbases, block after block. They may
   abstain (`0xFF`) or alarm (`0xFE`).
4. **Payout (M6)** — once approved, a mainchain transaction spends the treasury and pays each
   recipient. Output 0 is the new treasury; outputs 1+ are the withdrawals.

Stages 2–4 are operator and miner territory. Our involvement ends at stage 1 and resumes only as
*reporting*.

### The timelines are months

From `bip300301_enforcer/lib/types.rs`:

```rust
pub const MAINNET: Self = Self {
    withdrawal_bundle_max_age: 26_300,
    withdrawal_bundle_inclusion_threshold: 13_150,
    …
};
```

At ~10 min/block: **≈3 months** to accumulate enough votes, and a bundle that never reaches
threshold **expires as failed at ≈6 months**. Activation requires `votes > threshold` strictly and
`age ≤ max_age` inclusive.

Test networks are not this slow — the enforcer's integration tests note that "non-mainnet networks
all use the SHORT thresholds", so alphanet is where a full round trip is actually exercisable.

### Consequences for the UI

- **A withdrawal is not a send.** It's a months-long pending operation. Presenting it with the
  normal send flow's "sent ✓" would be a lie; it needs its own state, visible bundle progress, and
  an explicit warning about the timescale before the user commits.
- **Batching means your wait isn't your own.** Your withdrawal rides a bundle with other people's;
  it moves when the *bundle* is approved.
- **Failure is a real outcome.** A bundle can expire, returning coins to the sidechain to be
  re-bundled. `latest_failed_withdrawal_bundle_height` reports it, and the UI must not present a
  failed bundle as lost funds.

## 3a. Confirmed against thunder-rust, not just the spec

**Deposits: thunder-rust doesn't build them either.** `App::deposit` delegates the whole thing to
the enforcer's mainchain wallet (`app/app.rs`):

```rust
let Some(miner) = self.miner.as_ref() else {
    return Err(Error::NoCusfMainchainWalletClient);
};
miner_write.cusf_mainchain_wallet.create_deposit_tx(address, amount, fee)
```

That settles §2: building an M5 client-side means doing something the reference implementation
itself delegates, because the enforcer is what knows the ctip and holds the mainchain funds. Any
deposit design that starts "we construct the transaction" is starting in the wrong place.

**Withdrawals: an ordinary sidechain transaction** (`lib/wallet.rs`, `create_withdrawal`):

```rust
let outputs = vec![
    Output { address: self.get_new_address()?,
             content: OutputContent::Withdrawal { value, main_fee, main_address } },
    Output { address: self.get_new_address()?, content: OutputContent::Value(change) },
];
Transaction { inputs, proof, outputs }
```

Four details that matter for our implementation:

- The withdrawal output carries a **fresh sidechain address of our own** *and* the `main_address` in
  its content. It isn't addressed to the mainchain address directly.
- Coin selection must cover **value + fee + main_fee** — the mainchain payout fee is funded from
  sidechain coins at withdrawal time, not later.
- Change is an ordinary `Value` output to another fresh address. Same shape as a normal send.
- It carries a **Utreexo proof** (`accumulator.prove(...)`). Our client submits regular transactions
  with an empty proof because the node regenerates it (thunder-rust `fb922ee`) — worth confirming
  that holds for withdrawals too, since it's the one place our send path diverges from the
  reference.

So the delta between "send" and "withdraw" in our engine is the output content variant and its
encoding — not a new transaction pipeline.

## 4. What the RPC surface gives us

The public endpoint exposes exactly the read/submit group. The wallet methods are on a **separate
private server** (`--private-rpc-addr` vs `--rpc-addr` in `app/cli.rs`) and are not reachable —
verified against the live node:

| Method | Public endpoint | Use to us |
|---|---|---|
| `submit_transaction` | ✅ | Submit our locally-signed withdrawal |
| `get_utxos` / `get_stxos` | ✅ | Balance and history |
| `pending_withdrawal_bundle` | ✅ | Is our withdrawal in the current bundle? |
| `latest_failed_withdrawal_bundle_height` | ✅ | Did a bundle expire? |
| `create_withdrawal` / `create_deposit` | ❌ Method not found | Wouldn't use — node-side keys |
| `format_deposit_address` | ❌ Method not found | Reproducible on device anyway (§2) |
| `balance`, `get_wallet_addresses`, `mine` | ❌ Method not found | Node's own wallet |

**That split is correct and convenient.** The key-holding methods being unreachable matches our
keys-on-device model (Golden Rule §2) — we would not have used them regardless.

**No new endpoints are needed from the Thunder developer for withdrawals.** The gap is on our side.

## 5. What we'd build, in order

1. **Withdrawal output encoding.** `ThunderOutputContent` already models
   `Withdrawal { value_sats, main_fee_sats, main_address }` but doesn't Borsh-encode it, because
   that needs the mainchain address's **scriptPubKey bytes**. So: address → scriptPubKey, then
   encode. Bounded, local, testable against thunder-rust's own vectors like the existing codec work.
2. **Two fees in the UI.** `create_withdrawal`'s signature shows the shape: a sidechain `fee_sats`
   *and* a `mainchain_fee_sats` for the eventual payout. Users must understand they're paying twice.
3. **Withdrawal status.** Poll `pending_withdrawal_bundle` for our outpoint, and
   `latest_failed_withdrawal_bundle_height` for expiry. Render as a long-running operation.
4. **Deposits — decide the approach.** Building M5 ourselves means learning the ctip and adding a
   foreign input (§2). **The ctip half is no longer a blocker** — the drivechain-esplora index serves
   it over HTTPS (§2), so the remaining work is the foreign input, the exact recreate-value, and the
   depositor race. The alternatives are still routing users to a tool that already does it
   (BitWindow), or asking L2L for a thin deposit-construction endpoint. **This is the decision to
   make before any deposit work starts.**

## 6. Open questions

1. Does the `s9_…` string go in the OP_RETURN verbatim, or is it a UI-level encoding?
2. ~~How do we learn the current ctip without speaking enforcer gRPC?~~ **ANSWERED** —
   `GET /drivechain/sidechain/9` on the drivechain-esplora index (§2). Not yet wired into the app:
   nothing consumes it, because deposits remain out of v1 scope (CLAUDE.md §12).
3. Are alphanet's SHORT thresholds short enough to test a full withdrawal round trip in a session?
4. Does a withdrawal need a minimum value to be worth bundling (dust at mainchain payout time)?
5. What does the user see if the sidechain operator simply never proposes a bundle?
