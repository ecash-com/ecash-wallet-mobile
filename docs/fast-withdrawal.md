# Fast withdrawal

**Status:** 🔧 BUILT, switched off (2026-10-21: `isEnabled = false` in `FastWithdrawalConfig.swift`;
`WithdrawOptionsSheet` shows "Coming soon") pending a live betanet run. No mainnet service yet
(2026-11-10).

**Service:** `https://fastwithdraw.betanet.ecash.ninja` — run by the **L2L team** for **betanet**.
Thunder → betanet L1 only. A mainnet instance is the plan (the server is designed for ECX mainnet);
its URL and operator aren't known yet.

> **Revision note.** The 2026-09-16 version of this doc assessed L2L's public Go server
> (`fast-withdraw-server-go`) and found its quote signature covered only the expiry. The deployed
> service is a **different implementation** (a Rust rewrite, design dated 2026-10-03), reviewed from
> source shared by L2L on 2026-10-13. **Its quote signature is sound** (§4). The Go findings don't
> apply and have been removed.

---

## 1. What it is

A **custodial** shortcut around the BIP300/301 peg. A regular sidechain withdrawal waits months for
miners to approve a bundle. Here an operator pays the user on L1 right away, takes their Thunder
coins, and keeps the slow exit for themselves, plus a fee.

**Not atomic, no on-chain recourse.** The user pays on Thunder first and trusts the operator to pay
on L1. A signed quote is evidence of what was promised, not enforcement. The UI must say so plainly
and name the operator (§8).

Nothing here touches consensus: no withdrawal bundle, no BIP301 construction, no BDK work. The L2 leg
is an ordinary Thunder payment (`ThunderService.send`, FROST-signed — already built).

## 2. Transport

Connect protocol over HTTPS. The service answers **HTTP/JSON** (`POST
/fastwithdraw.v1.FastWithdrawalService/<Method>`, `Content-Type: application/json`) as well as gRPC,
so it reuses our existing `ConnectRPCClient` (CoinNews) — no gRPC library.

proto3-JSON rules apply (same gotchas as CoinNews): field names are lowerCamelCase, `uint64` values
arrive as **strings**, `bytes` as **base64**, timestamps as RFC 3339 strings, enums as their names.

## 3. Methods

| Method | Request | Returns / notes |
|---|---|---|
| `GetServiceInfo` | — | Quote signing public key (32 bytes, Ed25519), fee in basis points, min/max payout, per-chain required confirmations, the hot wallet address (empty while unreachable) |
| `CreateWithdrawal` | `request_id` (fresh non-nil UUID), `sidechain` = `"thunder"`, `l1_destination`, `l1_payout_sats` | A signed, expiring quote: the Thunder address to pay, the exact amount, fee, confirmations, expiry |
| `SubmitPayment` | `withdrawal_id`, `payment_txid`, `payment_vout` | Optional but recommended: locks in a payment still in the mempool. Idempotent |
| `GetWithdrawal` | `withdrawal_id` | Current state; `payout_txid` once paid |
| `RequestRefund` | `withdrawal_id`, `l2_refund_address` | Only for `UNDERPAID`. **One-shot**: the address can't be changed |

**Statuses:** `AWAITING_PAYMENT → CONFIRMING_PAYMENT → PAYMENT_CONFIRMED → PAYOUT_PREPARED → PAID`,
plus `EXPIRED`, `FAILED`, `UNDERPAID → REFUNDED`.

**Live betanet policy** (`GetServiceInfo`, 2026-10-13): fee **1%** (100 bps), payout **10,000 –
10,000,000 sats**, Thunder needs **2 confirmations**. Read these at runtime; never hardcode them.

### Quote creation details

- **Fee** = payout × bps, rounded **up**. The user pays `l2_payment_sats = payout + fee`.
- **Retries:** reusing a `request_id` with the same sidechain, destination and payout returns the
  same quote. Reusing it with different parameters is rejected. So persist the full request.
- **Refusals before any money moves:** payout outside limits; destination not a valid L1 address;
  the operator's Thunder node is behind; liquidity — one quote may use at most **25% of the hot
  wallet's spendable balance** (after a miner-fee reserve). Quotes reserve nothing.
- **Quote lifetime:** 15 minutes by default (`expires_at`).
- **Rate limit:** about 5 requests/second per IP, burst 20. Poll gently.

## 4. Quote signature — verify before paying

**Ed25519**, verified against `quote_signing_public_key` from `GetServiceInfo`.

The signed message is the concatenation of these ten fields, **in this order**, each preceded by its
length as an **8-byte big-endian** integer:

1. Domain: the ASCII string `fastwithdraw.quote.v1` followed by one zero byte
2. `withdrawal_id` (UTF-8)
3. Sidechain: `thunder` (UTF-8)
4. `l2_payment_address` (UTF-8, as returned)
5. `l2_payment_sats` (8-byte big-endian)
6. `l1_destination` (UTF-8, as returned)
7. `l1_payout_sats` (8-byte big-endian)
8. `service_fee_sats` (8-byte big-endian)
9. `required_confirmations` (as 8-byte big-endian)
10. `expires_at` as Unix **seconds** (8-byte big-endian)

**Client checks before paying** (all must pass, or abort with nothing spent):
- the signature verifies;
- `l1_destination` and `l1_payout_sats` are exactly what the user entered;
- `l2_payment_sats == l1_payout_sats + service_fee_sats`, and the fee is consistent with the
  advertised bps;
- the quote hasn't expired, with a margin for the payment to propagate.

**Key pinning:** the signing key comes from the same server it vouches for, so it proves integrity of
a quote against that key, not who the operator is. Pinning is a **future step**: today the endpoint,
operator and key slot are compiled into `FastWithdrawalConfig.endpoint(forSidechain:)` with
`pinnedQuoteKeyBase64 = nil` (the key `GetServiceInfo` reports is accepted). Moving them to the remote
config with a pinned key would catch a swapped server or key.

## 5. Payment rules (what the server accepts)

| Case | Result |
|---|---|
| **One output** to the quote address paying **≥ `l2_payment_sats`** | Accepted |
| Overpayment | Accepted, but the payout is fixed — **the excess is lost** |
| Amount split across several outputs | Each output is judged alone → **`UNDERPAID`** |
| Confirmed payment below the quote | `UNDERPAID`; refund on request (§6) |
| Paid **after** the quote expired | Still honored, **within 7 days** of the quote's creation |
| Paid after 7 days, a second payment to a paid address, or a payment after `PAID`/`FAILED`/`UNDERPAID` | **Ignored** — the coins sit until the operator sweeps them by hand |
| Operator's hot wallet can't fund the payout | Stays `PAYMENT_CONFIRMED`, retried until topped up |
| Payment reorged out | Cleared; the withdrawal goes back to waiting |

So the app must: pay **exactly** `l2_payment_sats` in **one output** (output 0 of
`ThunderService.send` — the vout to report), never pay twice, and only pay a quote that is
`AWAITING_PAYMENT` and not about to expire. (The server's grace for late payments is a safety net,
not something to rely on.)

## 6. Underpayment and refunds

A confirmed payment smaller than the quote makes the withdrawal `UNDERPAID` (with `l2_received_sats`).
The user calls `RequestRefund` with one of **their own** Thunder addresses — **once; it can't be
changed**. The operator sends the refund manually, less a network fee, and the status becomes
`REFUNDED`. The withdrawal ID acts as the credential, so treat it as private.

The app should never cause this (§5), but must handle it: show the received amount, offer a refund
to a fresh address of the same wallet, and never let the user type an arbitrary address here.

## 7. Client design

### Persistence — a withdrawal outlives the screen

```
1. CreateWithdrawal                   server state only; nothing has moved
2. verify the quote (§4)              abort here costs nothing
3. PERSIST the whole record           request_id + every request field, withdrawal_id,
                                      l2_payment_address, amounts, expires_at, signature
4. pay on Thunder                     ← the dangerous instant
5. persist payment txid + vout
6. SubmitPayment                      idempotent; retry freely
7. poll GetWithdrawal until PAID      payout_txid → show on L1
```

**Crash between 4 and 5:** recover by finding the payment to `l2_payment_address` in the wallet's own
Thunder history, then resume at 6. That's why step 3 stores the address, not just the ID.
`request_id` replay (§3) is a second recovery path, which is why step 3 stores every request field.

Store per `walletId` (Golden Rule §5), purge on wallet removal, survive restarts. On app open, re-poll
any withdrawal not yet `PAID`/`REFUNDED`/terminal.

### Polling

Foreground: back off from a few seconds to ~30s. Background: re-poll on app open. Two Thunder
confirmations are the slow part; the user needn't watch.

### Errors

| Situation | What the app does |
|---|---|
| Quote refused (limits, liquidity, node behind) | Explain; nothing was paid |
| Verification fails | Abort before paying; report it as a provider problem |
| `FAILED` | No reason is returned. Show the withdrawal ID and payment txid, and point at the operator |
| `EXPIRED` before paying | Offer a new quote. Never pay an expired quote |
| Network loss after paying | Resume from persisted state (above) |

### Configuration

Endpoint, operator name and the (optional) pinned signing key are **compiled** into
`FastWithdrawalConfig.endpoint(forSidechain:)` (pin `nil`), not read from the remote config; remote
config + pinning are a future step. Only betanet `.thunder` has an entry
(`https://fastwithdraw.betanet.ecash.ninja`, operator L2L) — and that network is retired from the
pickers since 2026-10-30; `.thunderMainnet` returns nil (no service, 2026-11-10). The option is hidden
when there's no entry for the wallet's sidechain or `isEnabled` is false.

## 8. UI

Lives behind **Withdraw → Fast withdrawal** on a Thunder wallet — shown as "Coming soon" while
`FastWithdrawalConfig.isEnabled` is false. Only betanet `.thunder` has a service, and that network is
retired/hidden; `.thunderMainnet` has none (2026-11-10).

1. **Amount + destination** — destination defaults to one of the user's own wallets on the mainchain
   (same-network picker as the regular withdrawal; `nextUnusedAddress`). Show min/max and "≈ fee"
   from `GetServiceInfo`.
2. **Review** — only now request the quote (abandoned quotes then just expire). Show the server's
   numbers as the truth: you pay X on Thunder, you receive Y on betanet, fee Z, expires in N minutes.
   **State the trust plainly**: "You're trusting L2L to pay you. If they don't, there's no way to get
   the coins back on-chain." Device auth, as Send.
3. **Progress** — paid → confirming → paying out → paid, with both txids. Survives leaving the screen.
   Ongoing withdrawals in Activity: **not built** (2026-11-10).

## 9. Open questions

1. Mainnet: URL, operator, and signing key at the fork.
2. Payments the server ignores (§5, last ignored row) are recovered only by the operator by hand. Is
   there a support path for users?
3. Whether L2L will publish the signing key somewhere other than the service itself, for pinning.
