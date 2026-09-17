# Fast withdrawal — assessment

**Server:** `github.com/LayerTwo-Labs/fast-withdraw-server-go` (Go, Connect RPC, SQLite, MIT org)
**Assessed:** 2026-09-16 against `HEAD` · **Status:** not started, not scheduled

## What it is

A **custodial** shortcut around the BIP300/301 consensus peg. A normal sidechain exit is a withdrawal
bundle that accumulates ACKs over roughly three months. Here an operator fronts you the L1 coins
immediately, takes your L2 coins, and keeps the slow bundle exit for themselves plus a fee.

The README is refreshingly blunt about what that means: *"The operator is still trusted to stay solvent
and honor quotes."*

## The protocol — four RPCs and one ordinary payment

```
GetServiceInfo    → quote signing pubkey, fee basis points, min/max payout, per-chain confirmations
CreateWithdrawal  → (request_id UUID, sidechain, l1_destination, l1_payout_sats)
                    ← l2_payment_address, l2_payment_sats, expires_at, quote_signature
   … pay l2_payment_sats to l2_payment_address on the sidechain, normally …
SubmitPayment     → (withdrawal_id, payment_txid, payment_vout)   — idempotent
GetWithdrawal     → poll until WITHDRAWAL_STATUS_PAID, which carries payout_txid
```

Statuses: `AWAITING_PAYMENT → CONFIRMING_PAYMENT → PAYMENT_CONFIRMED → PAYOUT_PREPARED → PAID`, plus
`EXPIRED` and `FAILED`.

**Nothing here touches consensus.** No withdrawal bundle, no BIP301 transaction construction. That
matters enormously for us: it sidesteps the plan in CLAUDE.md §12 — no `bdk-ffi` extension, no Rust
work, no regenerating bindings across the seam. The L2 leg is an ordinary payment we already know how
to make.

## ⚠️ The quote signature is broken (upstream bug)

**Do not rely on `quote_signature` as evidence of anything.** As written it commits only to the expiry
timestamp — not the amounts, not the addresses, not the withdrawal ID.

`withdraw/service.go`:

```go
// canonical length-prefixes each part with its eight-byte big-endian size.
func canonical(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(u64(uint64(len(p))), p...)   // ← overwrites `out`; never appends to it
	}
	return out
}
```

`out` is assigned but never read inside the loop, so each iteration discards everything accumulated so
far. The function returns only the **last** part. Verified by running it:

```
as-written : 16 bytes  0000000000000008000000006aa1f940      ← just len(8) + expiry
intended   : 176 bytes
changing l1_payout_sats from 99000 → 1 leaves the preimage BYTE-IDENTICAL
```

So an operator can sign a quote for 99,000 sats, pay out 1 sat, and the signature still verifies. Any
two quotes sharing an expiry second have the same signature.

The fix is one line — accumulate into `out`:

```go
out = append(out, u64(uint64(len(p)))...)
out = append(out, p...)
```

**Worth reporting upstream before we build against it.** The documented intent is sound (domain
separator `fastwithdraw.quote.v1\0`, length-prefixed fields, Ed25519); only the accumulator is wrong.
Once fixed, the preimage is — in order — domain, withdrawal ID, sidechain, L2 address, L2 sats, L1
destination, L1 payout sats, fee sats, required confirmations, Unix expiry; each length-prefixed with
its 8-byte big-endian length.

## Trust model — say it plainly in the UI

This is **not atomic and has no on-chain recourse.** You pay L2 first and then trust the operator to
pay L1. A signed quote (once the signature works) is *evidence of a promise*, not enforcement — it
would help you complain, not recover coins.

For an app whose entire pitch is self-custody, that screen has to be honest about handing coins to a
counterparty. This is the opposite of every other money path in the wallet, and it should look and feel
different from a normal send. Compare the framing already used for Bitcoin mainnet sends (§6 Golden
Rules): weightier confirmation, explicit statement of what is being trusted.

Server-side mitigations, for accuracy: each L2 outpoint can be claimed once, payouts are signed and
persisted before broadcast, and aggregate liability is capped against the confirmed wallet balance.
Those reduce operator error and double-claims. None of them protect the customer from an operator who
simply stops paying.

## What we would build

Modest, and mostly from parts we already have:

1. **Connect RPC client** for the four methods. We have this pattern — CoinNews already ships two
   ConnectRPC/HTTP-JSON adapters, including the proto3-JSON gotchas (see `docs/coinnews-integration.md`
   and the CoinNews fetch-layer memory). Same shape, fewer methods.
2. **The L2 payment** — `ThunderBackend.submit`, already built and live-verified.
3. **Quote verification** — Ed25519 over the preimage above, against `quote_signing_public_key`.
   Cheap, and it is the only check available to us. **Blocked on the upstream fix**; verifying today
   would give false assurance, which is worse than not verifying.
4. **Polling + persistence.** A withdrawal outlives the screen: the app must survive being killed
   between paying L2 and seeing `PAID`, or the user has paid and lost the handle. `request_id` is
   caller-generated and reusable for the same quote, and `SubmitPayment` is idempotent — both are there
   precisely to make retries safe. Store `withdrawal_id` alongside the L2 txid the moment we broadcast.

## What blocks it

**Thunder.** Fast withdrawal moves coins *off* a sidechain, so it presupposes a funded Thunder wallet.
Thunder is still commented out of `WalletNetwork.selectable` because the drivechain-esplora index
reports no blocks (`docs/thunder-sidechain-support.md` §8e). Until that resolves there is nothing to
withdraw from, and this cannot be tested end to end.

Also unknown: whether a **public server instance** exists, and on which chains. `GetServiceInfo`
returns per-chain policy, so the client should read the chain list rather than assume Thunder.

## UI sketch (deferred)

A **"Fast withdraw"** action visible only on a Thunder wallet — the natural home is beside Send/Receive
on Home, or in the wallet's own menu. Flow mirrors Send: destination (an L1 address, defaulting to one
of the user's own eCash wallets via the existing same-network picker logic), amount, then a review step
that states the fee, the expiry, and — prominently — that this hands coins to a named third party.
Details deferred; nothing here is designed yet.

## Can we ship against it as-is? Yes — here is how

Every gap above has a client-side answer except the signature, and the signature was only ever
evidence, never enforcement. Nothing here needs the server to change first.

**The one real engineering problem is persistence, and it is ours to solve.** A withdrawal outlives the
screen, the app process, and possibly the install. Order of operations, with the money-losing window
called out:

```
1. CreateWithdrawal                    server state only; no coins have moved
2. PERSIST the whole record locally    withdrawal_id, request_id, every request parameter,
                                       l2_payment_address, amounts, expires_at
3. broadcast the L2 payment            ← the dangerous instant
4. persist the L2 txid + vout
5. SubmitPayment                       idempotent; safe to retry forever
6. poll GetWithdrawal until PAID
```

Crash between 3 and 4 and we have paid with no handle — except that **we own our own transaction
history**, and we know the exact address we were told to pay. Recovery is: find the payment to
`l2_payment_address` in the wallet's own history, take its txid and vout, resume at step 5. That closes
the window completely, and it is the reason step 2 must persist `l2_payment_address` and not merely the
withdrawal id.

`request_id` is a second, independent recovery path: it is `UNIQUE` with a `request_hash` server-side,
so replaying `CreateWithdrawal` with byte-identical parameters returns the same quote rather than a new
one. That only works if we kept every parameter — another reason step 2 stores the whole request, not
just the id.

**Working around each gap:**

| Gap | What we do instead |
|---|---|
| `FAILED` has no reason | Show the withdrawal id and the L2 txid, and point the user at the operator. We can still detect expiry ourselves from `expires_at`, so the commonest failure is explainable without the server's help. |
| No operator identity | Carry it app-side in the **remote config** we already ship (`RemoteEndpointConfig` / `RemoteServiceOverlay`) — endpoint, operator name, terms URL — the same mechanism that already rotates eCash endpoints without an app update. The app must be able to name who is being trusted. |
| No live capacity | Just call `CreateWithdrawal` and handle rejection. It happens **before** any payment, so a rejected quote costs the user nothing but a round trip. |
| Lookup only by `withdrawal_id` | Local persistence above, plus the `l2_payment_address` history scan, plus `request_id` replay. Three independent paths; no server change needed. |
| No cancel | Do not create a withdrawal until the user actually commits — build it at the **review** step, not on screen open. Abandoned quotes then become rare, and the ones that happen simply expire. |
| Polling only | Poll with backoff while the screen is foregrounded; persist and re-poll on app open. Confirmations are the slow part, and the user does not need to watch them. |
| Fee rounding (`floorBPS`/`ceilBPS`) | Never present a client-computed fee as authoritative. Show "≈" from `fee_basis_points` before committing, and the server's quoted `service_fee_sats` / `l2_payment_sats` as the truth at review. |
| **Quote signature is broken** | **Do not verify, and do not imply we did.** Verifying the current 16-byte preimage would confirm only an expiry timestamp while looking like real assurance — worse than no check. Leave the verification seam in place, unused, with a comment pointing at this document; enable it when upstream lands the fix. |

Net: the protocol as it stands is sufficient for a correct, recoverable client. What we lose by
shipping before the upstream fix is the ability to *prove* what was quoted — which never protected the
user's coins anyway, because the scheme has no on-chain recourse either way.

## Open questions

1. Is there a public deployment, and on which chains?
2. Who runs it, and is the operator identity surfaced to the user? "Trust the operator" is meaningless
   if the app cannot say who that is.
3. Fee in basis points — what is it in practice, versus the ~3-month wait it replaces?
4. What is the failure path if the operator takes payment and never pays out? Anything beyond the
   (currently broken) signed quote?
