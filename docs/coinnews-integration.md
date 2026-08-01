# CoinNews integration — design record (TO BUILD)

> **Status:** 🟢 SUBSTANTIALLY BUILT (read + publish, per-network) — **with one gap: we do not yet
> verify signatures on what we display** (see §4.1). Design below is the original record. Captures how the wallet will **fetch** and **publish** CoinNews
> once we're ready. The protocol itself is summarized in memory `coinnews-protocol`; the canonical
> spec is the CoinNews draft (BSD-2). Reference code lives in `LayerTwo-Labs/drivechain-frontends`:
> the wire codec at **`coinnews/codec/`** (Go) and a standalone hostable indexer+API at
> **`coinnews/server/`** (Go, ConnectRPC) with a Next.js consumer at `coinnews/app/` — NOT the
> BitWindow desktop GUI (that's a separate consumer of the same on-chain data).
>
> CoinNews is a trustless, server-less bulletin board (Topics → Stories → signed Comments/Votes)
> encoded entirely in Bitcoin `OP_RETURN` outputs. Every indexer rebuilds the identical view by
> scanning blocks in canonical `(block_height, tx_index, vout_index)` order. eCash is byte-identical
> Bitcoin, so it runs on our chain. Complements `docs/backends-and-endpoints.md`, `docs/key-storage.md`,
> and `docs/wallet-and-network-model.md`.

---

## 1. Scope

Two independent halves, very different in difficulty:

- **Fetch (read):** show a CoinNews feed — front page (ranked Stories), threads (Comments), scores.
- **Publish (write):** post a Story, reply with a Comment, cast an Up/Downvote, create a Topic.

Both are **network-scoped** (CoinNews on Testnet4 ≠ on eCash mainnet) and resolve through the same
`NetworkRegistry` seam as backends/explorers — a CoinNews wallet on network X reads/writes X's board.

Likely build order: **read-only feed first** (lower risk, no new signing), then publishing.

## 2. Architecture overview

Three pieces; keep them separate:

1. **`CoinNewsCodec` (pure Swift, cross-platform).** Encode/decode the wire format from the spec:
   envelope (`"CN" ‖ TypeTag`), compact-size varints, the six message types, the TLV layer, ItemID
   truncation (`sha256(txid_LE ‖ vout_LE)[0:12]`), and the per-type BIP-340 tagged-hash domains. No
   platform deps → compiles natively on both platforms in Fuse (same posture as `QRCodeGenerator`).
   Mirror **`coinnews/codec/`** (Go: `encode.go`/`decode.go`/`sign.go`/`itemid.go`/`tlv.go`/
   `varint.go`); port `codec_test.go`'s vectors verbatim (the spec also ships hex vectors — §"Test
   Vectors"). This is shared by both the reader (verify) and the publisher (build).
2. **`CoinNewsReader` (indexer client).** Fetches the ranked feed / threads (see §4).
3. **`CoinNewsPublisher` (compose + sign + broadcast).** Builds the `OP_RETURN` tx via the
   WalletService/BDK seam and signs the author Schnorr signature (see §3).

## 3. Publishing (write) — closest to what we already do

A CoinNews message is a transaction with **one `OP_RETURN` output** carrying the payload. We already
do build → sign → broadcast; this adds an `OP_RETURN` output and an author signature.

### 3.1 Building the OP_RETURN tx
- BDK `TxBuilder` can add an `OP_RETURN`/data output. **VERIFY:** does `bdk-swift` 2.3.1 expose
  `add_data` / an OP_RETURN output on `TxBuilder`? (rust-bdk has `TxBuilder::add_data`.) If the FFI
  doesn't surface it, that's a `bdk-ffi` extension — same "regenerate Swift+Kotlin together" path as
  the future BIP300/301 work (CLAUDE §12).
- The tx still needs a funding input + change; the `OP_RETURN` output is value-0. Normal coin
  selection + fee. Reuses the watch-only-build / sign-on-demand path (`docs/key-storage.md §3`).
- **ItemID** of the new Item = `sha256(txid_LE ‖ vout_LE)[0:12]` of the message's own output — known
  only *after* the tx is built (txid). For references (a Comment's `parent_id`, a Vote's `target_id`),
  the publisher already holds the target outpoint (it's rendering the target) and hashes it.

### 3.2 Author identity + Schnorr signing — DECISIONS (2026-06-15)

> **Update 2026-08-01:** BIP-340 signing now uses **real auxiliary randomness** per signature
> (`CoinNewsCrypto.secureAuxRand()` — `SecRandomCopyBytes` on Apple, `java.security.SecureRandom` on
> Android), replacing a hardcoded all-zero `auxRand`. Zero aux is spec-valid and there was never a
> nonce-reuse risk (the nonce derives from the message), but it forfeited BIP-340's defence in depth
> against fault/side-channel attacks. Note the identity key lives at the hardened `m/1899'/0'/0'`,
> separate from `m/84'` spend keys, so the exposure was reputational, never financial.
>
> **Do not "simplify" that into Swift's `random(in:)`** — this module is transpiled, so it becomes
> `kotlin.random.Random` on Android, which is not a CSPRNG. It would compile, pass tests, and be
> weaker than the zeros it replaced.
- **Identity model (DECIDED): one CoinNews identity per wallet, derived from the wallet seed** at a
  dedicated BIP-340 path (its own branch, distinct from the `m/84'/…` spend keys). Recoverable on
  restore; "wallet = identity." Derive/sign on demand, never persist the key (Golden Rule §2 /
  `docs/key-storage.md`). NOTE: revisit supporting **multiple identities per wallet** later (path
  identity-index `…/0'`, `…/1'`, + an identity picker) — start with one. Privacy caveat: the publish
  tx is funded by wallet coins, so a post is already linkable to the wallet on-chain via the funding
  input regardless of the Schnorr key — the key is for **authorship + per-`(author,target)` vote
  dedup (§8)**, not anonymity.
- **Schnorr availability (RESOLVED): BDK does NOT expose it.** `DescriptorSecretKey.secretBytes()`
  gives the raw 32-byte private key (cross-platform), but bdk-ffi has no raw Schnorr / priv→pub. So
  we pull a secp256k1 lib into `WalletService` via the same `#if` seam as bdk-swift/bdk-android
  (DECIDED — not the Rust/bdk-ffi route for now, though sidechain work may force that later):
  - **iOS:** `swift-secp256k1` (21-DOT-DEV, industry standard), product **`P256K`**, `~0.23.2`.
    `schnorrsig` is in its DEFAULT traits, so no trait wiring needed.
  - **Android:** `fr.acinq.secp256k1:secp256k1-kmp-jni-android:0.17.3` (Maven), via `skip.yml`.
  - Both wrap audited libsecp256k1; Golden Rule §1 (never hand-roll signing) upheld.
- Comments/Votes sign **BIP-340 Schnorr over a per-type tagged hash**
  (`tagged_hash("CoinNews/Vote", typetag ‖ target_id)`, `tagged_hash("CoinNews/Comment", parent_id ‖
  tlv_blob)`). SHA-256 (for tagged hashes + ItemID) via platform crypto in the transpiled module
  (CryptoKit iOS / `java.security.MessageDigest` Android under `#if SKIP`).
- Stories/Topics are **unsigned** — Phase 1 codec (`CoinNewsCodec`, app module) + the OP_RETURN
  publish path (`WalletEngine.publishData` / bridged `WalletManager.publishOpReturn`) are **BUILT &
  spec-vector-tested** (2026-06-15). Comment/Vote (signed) is Phase 2, in progress.

### 3.3 Relay policy — the 111-byte problem
- A **Vote/Comment is 111 bytes** of `OP_RETURN`, above the **80-byte** standard relay default. The
  publishing node/relay needs **`-datacarriersize ≥ 111`**. Our default public backends
  (mempool.space, blockstream) likely **reject** it. **VERIFY** eCash/drivechain relay policy; if it
  doesn't allow 111-byte data, publishing Votes/Comments requires a permissive relay or own node
  (ties into the custom-endpoint feature, `docs/backends-and-endpoints.md`). Stories (often ≤80 B)
  may broadcast on default relays; longer payloads chunk via Continuation (§9 of the spec).

## 4. Fetching (read) — the harder half

A feed needs an **indexer**: scan every block's `OP_RETURN`s, decode, resolve ItemIDs, verify
signatures, dedup votes, rank (HN formula). **The Electrum/Esplora protocols our BDK backend speaks
can't enumerate `OP_RETURN`s** — they're keyed by scriptPubKey/txid (no content scan) — so we cannot
derive a feed from our existing sync path. The indexing itself happens server-side against a node.

**This already exists as a standalone, hostable service.** In `LayerTwo-Labs/drivechain-frontends`
there's **`coinnews/server`** (Go), decoupled from the BitWindow desktop GUI:
- connects to a **Bitcoin Core node via RPC** (`COINNEWS_BITCOIND_URL`), scans blocks through
  `coinnews/codec`, persists to **SQLite**, and serves a **ConnectRPC** API on `:8080`;
- `-scan`/`COINNEWS_SCAN` toggles the scanner — **`scan=false` = read-only API mode**, so the heavy
  scanning and the API can be split (one scanner fills the DB; light API servers serve it);
- the reference consumer is the **Next.js `coinnews/app`** (web), which talks to it via Connect —
  i.e. the architecture is already "hostable server ← thin clients", which is exactly our model.

**`CoinNewsService` (read-only RPCs):** `ListFrontPage`, `ListNewFeed`, `GetItem`, `ListThread`,
`ListByAuthor`, `ListByTopic`, `ListTopics` — paginated (`limit`/`offset`), filterable by
`subtype`/`topic_hex`; returns `Item`/`Comment`/`Topic` (hex IDs, score, points, block height/time).
No publish RPCs — publishing stays wallet-side (§3).

| Option | What | Mobile fit | Trust |
|---|---|---|---|
| **A. Consume `coinnews/server`** | Call its ConnectRPC over **HTTP/JSON** (URLSession; or `connect-swift`) | ✅ Best for a phone | Trusted for *availability/ordering*; verifiable for *authorship* (§4.1) |
| **B. + client verification** | Same API, client re-verifies sigs + ItemIDs against on-chain data | ✅ Good | Low — indexer can omit but not forge |
| **C. Embedded indexer** | Scan blocks on-device | ❌ Not viable on mobile (a node + full scan) | None |

**Recommendation:** ship **A → B**. `CoinNewsReader` calls the `coinnews/server` ConnectRPC — Connect
unary calls are plain `POST /coinnews.v1.CoinNewsService/<Method>` with a JSON body, so **URLSession
is enough; no gRPC dependency** (or use the pure-Swift `connect-swift` client). The endpoint is a
`NetworkRegistry`-resolved default + user override (same pattern as backends). Then layer client-side
verification: `CoinNewsCodec` verifies each Item's Schnorr sig and recomputes its ItemID from the
cited outpoint (fetched via the wallet's own Electrum/Esplora backend). The spec's "no trusted server"
ethos holds — *anyone* can run `coinnews/server` and clients can verify; the phone never scans.

### 4.1 What the client can verify regardless of the indexer
Given an Item's `(txid, vout)`, the wallet independently: recomputes the ItemID, fetches the tx
(backend), reads the `OP_RETURN`, decodes it, and verifies the Schnorr signature. So a hostile
indexer can **hide** Items or **misrank** them, but **cannot forge** authorship or content. Surface
verification state in the UI when we get to B.

> ⚠️ **NOT IMPLEMENTED — the standing gap (confirmed 2026-08-01).** `CoinNewsCrypto.schnorrVerify`
> exists and is vector-tested, but **nothing in the app calls it.** The read models
> (`CoinNewsModels`) carry `authorXpkHex` — the *claimed* author — and **no signature field at all**,
> because the `coinnews.v1` indexer doesn't return one. So today a compromised or malicious indexer
> can fabricate stories, comments, and votes attributed to any identity and the wallet renders them
> as genuine. Impact is reputational/trust, not funds (nothing here touches spending keys), but it
> undermines the property that makes an on-chain bulletin board worth having.
>
> Closing it needs one of: (a) the indexer returning the signature + signed payload per item, or
> (b) the client fetching the raw `OP_RETURN` by `(txid, vout)` and verifying against the chain —
> the design already assumed (b) is possible. Not fixable client-side alone with today's API; needs
> a conversation with whoever runs the indexer.
>
> Notably, the Aug 2026 external security assessment scrutinised our *signing* path and never asked
> whether we verify what we *read*.

## 5. Where it lives in the app

- **`CoinNewsCodec`** — pure-Swift, app-module or its own SwiftPM package (no platform deps). Shared
  by reader + publisher; this is where the spec's test vectors live as unit tests.
- **Schnorr signing + `OP_RETURN` tx build** — through the **WalletService/BDK seam** (the only place
  with key material and consensus logic, Golden Rule §1/§3). Likely a `bdk-ffi` extension.
- **`CoinNewsReader`** — an HTTP client (URLSession; remember `import FoundationNetworking` on
  Fuse-Android, memory `fuse-networking-and-pricing`). Endpoint per network via `NetworkRegistry` +
  override, mirroring backends.
- **Identity key** — derived in `WalletService` from the seed at a fixed path; sign-on-demand.
- **UI** — a CoinNews tab/section (feed, thread, compose). Out of scope until the data layer lands.

## 6. Key unknowns to resolve before building

1. **Schnorr signing primitive** — does the BDK binding expose BIP-340 signing of an arbitrary
   tagged hash, or do we extend `bdk-ffi`? (Blocks Comment/Vote publishing.)
2. **`OP_RETURN` output via `TxBuilder`** — confirm `add_data` is in `bdk-swift` 2.3.1 or needs FFI work.
3. **Relay `datacarriersize`** on eCash/drivechain — can 111-byte `OP_RETURN`s be broadcast on the
   default backends, or only via a permissive/own node?
4. **Identity derivation path** — one CoinNews author key per wallet; pick a path; relation to the
   wallet's BIP-84 keys (separate, by design).
5. **Indexer hosting — NO public endpoint exists yet (probed 2026-06-15).** The API
   (`coinnews/server` ConnectRPC `CoinNewsService`) and its shape are known, but a scan of L2L hosts
   found only the signet **faucet** (`node.signet.drivechain.info`) and **explorer**
   (`explorer.signet.drivechain.info`) — no live `CoinNewsService` anywhere, and `coinnews.*`/`news.*`
   subdomains don't resolve. Matches the repo (web client defaults to `localhost:8080`; README runs
   locally). So **we must self-host `coinnews/server`** (signet/eCash Core node + scanner) and point
   the wallet at it, or wait for L2L to deploy a public one. This blocks only the **read** phase;
   the codec phase (Phase 1) needs no server.

## 7. Phased plan

1. **Codec + vectors.** `CoinNewsCodec` encode/decode all six types + TLV + ItemID, ported Go test
   vectors. No chain, no UI. Pure unit tests, both platforms.
2. **Read-only feed (Option A).** `CoinNewsReader` against a configurable indexer endpoint; a feed +
   thread UI. Render-only; no keys.
3. **Publish Stories.** Compose an `OP_RETURN` Story tx (unsigned — no Schnorr yet) via WalletService;
   broadcast; optimistic insert. Resolves unknowns #2 and #3 on the easiest message.
4. **Identity + signed Comment/Vote.** Add the Schnorr identity key + signing (unknown #1), then
   Comments and Votes. Voting needs the 111-byte relay (#3).
5. **Trust-minimized read (Option B).** Client-side sig/ItemID verification against on-chain data.

## 8. Out of scope (for now)
Embedded on-device indexing; running our own CoinNews indexer; the metadata-registry tooling
(§11 of the spec — informational); moderation/curation beyond the spec's ranking.
