# drivechain-esplora — notes and one ask from a mobile wallet

**To:** drivechain-esplora maintainer (`github.com/octobocto/drivechain-esplora`)
**From:** eCash.com Wallet (mobile) · **Updated:** 2026-09-01
**Against:** `master`, deployed at `https://seed.alpha.ecash.eu.com/thunder`

## Nothing here is blocking

We've switched our Thunder backend from the node's JSON-RPC to your index, and it's built and tested
against the API exactly as it exists today. **No change on your side is required for us to ship.**
Everything below is either a nice-to-have or a question — please read it that way.

Why we switched, briefly: the node keys its state by outpoint only, so `get_utxos(addresses)` scans
the whole UTXO table in memory per call, and it exposes **no per-transaction height** at all. That last
one is the real problem — no height means no confirmation depth, no fee, and no chronological ordering,
so our Activity list had to invent an order from "when this device first saw the txid". Your index
answers all of it. The `/drivechain/*` routes were an unexpected bonus: they give us the treasury CTIP
over plain HTTPS, which we'd otherwise have needed an enforcer gRPC client to learn.

A few things we appreciated while reading the source, since they're the kind of thing that usually gets
skipped: reorg handling with a transactional rollback (and the comment naming *why* — showing a user
coins that don't exist); `get_block_index` existing because deposits never appear in a block body and
bundle spends have no transaction at all; `"treasury": null` versus zero sats; and `prevout` always
populated because a stock Esplora client dereferences it without a nil check.

## The ask: a batch address route

**The one place your API costs us more than the node RPC is request count.** There's no
multi-address route — faithful to Blockstream's Esplora, which has none either — so where the node took
one call for our whole address window, we now make one request per address.

We've made that affordable rather than painful:

- `/address/{a}` is our gap-limit probe. It returns a handful of integers, and most of a window has
  never been used, so we ask it first and only fetch UTXOs + history for addresses with `tx_count > 0`.
- Requests run 6 at a time.

A fresh wallet's window is 21 addresses, so a normal sync is ~21 probes plus a couple of real fetches —
roughly 6 round trips, a few hundred milliseconds. **Genuinely fine.** It stops being fine for a
heavily-used wallet: 100 used addresses is 100 probes plus ~200 fetches.

The highest-value single addition, by a distance, is a batch form of the **stats** route — that's the
one we call for every address in the window on every sync:

```
POST /addresses
body:     ["<base58>", "<base58>", …]
response: { "<base58>": { "chain_stats": {…}, "mempool_stats": {…} }, … }
```

That alone turns ~21 requests per sync into 1. Against Postgres it should be close to the query you
already run with `WHERE address = ANY($1)` instead of `= $1`.

Secondary, only if the first one proves worth it — the same shape for the two fetch routes, which we
call only for addresses that are actually used:

```
POST /addresses/utxo   →  { "<base58>": [UTXO], … }
POST /addresses/txs    →  [Tx]   (deduplicated, newest first, paged as /txs/chain is)
```

A `POST` for a read is unusual, but an address list doesn't fit comfortably in a query string and your
API already breaks Esplora's shape where the chain requires it (`POST /tx` taking JSON). A
`GET /addresses?list=a,b,c` would suit us equally well if you'd rather keep verbs conventional. A cap
on list length is fine — anything ≥ 25 covers our window.

## Questions

1. **When does the `/thunder` index expect to hold blocks, and against which chain** — Thunder signet,
   or the alpha eCash chain? `/blocks/tip/height` currently answers 404 *"the index holds no blocks
   yet"*, while `/fee-estimates` and `/drivechain/*` work and the address routes answer zeros. We
   handle that state deliberately (an empty sync, not a connection error), but nothing on our side has
   met real indexed data yet, so it's our last gate before real funds.
2. **Rate limits.** Is ~25–30 requests in a burst of 6 concurrent, per wallet sync, comfortable? Happy
   to lower our concurrency if it's a problem.
3. **Is the enforcer behind `/drivechain/*` permanent** for this deployment? The routes answer today,
   and we'd like to rely on them for deposit construction rather than shipping our own mainchain
   client. We understand a deployment without one answers 503.
4. **Is a human-facing explorer planned?** We link out to a block explorer per network, and with none
   available our Thunder link currently points at your `/tx/{txid}` JSON. Not a request — just
   checking whether to keep the slot warm.

## One observation

The chain table in the README lists seven sidechains, but `register.go` registers a single decoder
(thunder), so the rest return *"chain has no output decoder yet"*. Took us a moment to work out. Worth
a line in the README marking which are implemented versus specced — the architecture clearly supports
them, which is a large part of why this approach appeals to us for other chains later.

## What we verified against the live deployment

Read-only, on 2026-09-01, with the index still empty. All passing:

- Routes compose correctly against the service mounted under `/thunder` (including with a trailing
  slash — bare `/thunder/` is a 404, so we strip it).
- `/blocks/tip/height` 404 is distinguishable from a network failure and surfaces as "index is empty".
- `/address/{a}` stats decode as documented; `/address/{a}/utxo` and `/txs/chain` return empty arrays.
- A malformed address returns 400 with a usable plain-text message.
- `/drivechain/sidechain/9` returns slot 9, the M1 declaration, and the treasury outpoint + value.

Two behaviours we depend on, noted so a future change to either is a known break rather than a silent
one — both are documented, we just want to be explicit that we rely on them:

- **`POST /tx` relays its body into `submit_transaction` unchanged.** Our transaction is signed on the
  phone, and the body we post is byte-for-byte what we'd send the node as `params[0]`. If the index
  ever rewrote or re-encoded it, our signature would no longer cover what the node validates.
- **Hash byte order**: chain-native everywhere, Bitcoin display order for a mainchain txid inside a
  deposit. We flip only the latter, and it feeds a BLAKE3 utreexo leaf hash, so getting it wrong
  produces a valid-looking input the node rejects.

Thanks — this is a well-judged piece of infrastructure, and it removed a category of compromise we'd
been carrying.
