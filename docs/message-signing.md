# Signed messages (BIP-137 / BIP-322) — research

> Status: **NOT BUILT, not scheduled.** Written 2026-10-30 after a user asked whether the mobile
> wallet could sign messages "like BitWindow". This is the write-up of what BitWindow shipped,
> what the feature is for, and what it would take here. Nothing in the app changes until someone
> decides to build it.

## 1. What a signed message is

A signed message proves that whoever produced it controls the private key behind a given
address, without spending anything. The verifier needs only three strings — **address**,
**message**, **signature** — and no chain access. Two formats exist:

- **BIP-137 ("Bitcoin Signed Message")** — the format Electrum, Sparrow and Bitcoin Core have
  used for years. A 65-byte recoverable ECDSA signature over
  `sha256d("\x18Bitcoin Signed Message:\n" ‖ varint(len) ‖ message)`, base64-encoded. The first
  byte is a header that encodes the recovery id plus the address type: 27–30 uncompressed P2PKH,
  31–34 compressed P2PKH, 35–38 P2SH-P2WPKH, 39–42 P2WPKH. It covers pay-to-pubkey-hash shapes
  only, because verification recovers a public key and re-derives the address from it.
- **BIP-322 ("Generic Signed Message Format")** — generalises signing to *any* script by building
  two virtual transactions: `to_spend` (spends a null outpoint, scriptSig carries the BIP-340
  tagged hash of the message, pays 0 to the address's scriptPubKey) and `to_sign` (spends
  `to_spend:0`, single `OP_RETURN` output). The signature is the witness that makes `to_sign`
  valid — it can never be broadcast because `to_spend` is unspendable. Three encodings: **legacy**
  (= BIP-137, P2PKH only), **simple** (the consensus-encoded witness stack; P2WPKH/P2WSH/P2TR),
  **full** (the whole signed `to_sign` tx; anything, incl. timelocks). An optional
  proof-of-funds variant adds real UTXOs as extra inputs.

BIP-322 is marked *Complete* but adoption is uneven: Bitcoin Core merged only basic support
(PR #24058), btcd has full support, Sparrow signs/verifies it, many wallets still don't. The BDK
ecosystem has two young crates — `bdk_bip322` 0.1.0 (published 2026-09-23) and the experimental
`bdk-message-signer` — and **neither is in `bdk-ffi`**, so bdk-swift / bdk-android 2.3.1 expose
no message signing at all.

## 2. What BitWindow actually shipped

PR **LayerTwo-Labs/drivechain-frontends#2381** "bitwindow: sign messages in the bitcoin format"
(octobocto, merged 2026-09-24; fixes #2206, "Sign message does not work in Light mode"). The
wallet signs with its own key, so it works without a node.

- `bitwindow/server/signmessage/signmessage.go` — the package comment is the whole design:
  **BIP-137 for P2PKH, P2SH-P2WPKH and P2WPKH; BIP-322 *simple* for every other address type**
  (in practice Taproot — it builds `to_sign` and Schnorr-signs the key-path sighash). `Sign`
  verifies its own output before returning. `Verify` sniffs the format: a 65-byte blob with a
  header in 27…42 is BIP-137, anything else is parsed as a BIP-322 witness and run through
  btcd's script engine against `to_sign`. It accepts Electrum's quirk of writing the compressed-
  P2PKH header (31–34) for segwit addresses too.
- RPC: `wallet.v1.WalletService/SignMessage(wallet_id, message, address)` → `signature`, and
  `VerifyMessage(…)`. The address must belong to the wallet.
- UI 1: **Use Bitcoin → Sign/Verify Message** (`bitwindow/lib/pages/message_signer.dart`). Pick
  one of your addresses, type a statement, get a signature; or paste address + message +
  signature to check. Its help text: *"You can sign messages/agreements with your addresses to
  prove you can receive Drivechain coins sent to them. Be careful not to sign anything vague or
  random, as phishing attacks may try to trick you into signing your identity over to them. Only
  sign fully-detailed statements you agree to."*
- UI 2: **Proof of Funds** (`bitwindow/lib/widgets/proof_of_funds_modal.dart`) — signs a chosen
  or random message with every UTXO's address and writes a CSV report; a Verify tab checks such
  a report and counts valid signatures.

So "BitWindow supports BIP-322" is true only for Taproot addresses. For native segwit — what
every wallet in our app uses by default — it emits the ordinary BIP-137 signature that Electrum,
Sparrow and Core verify.

## 3. What people use it for

- **Prove control of an address without moving coins.** An exchange, OTC counterparty, auditor
  or tax authority supplies a phrase; if the signature verifies, you hold the key.
- **Proof of reserves / proof of funds.** Sign the same message from every funded address and
  hand over the list (BitWindow's CSV report).
- **Bind an identity or agreement to an address.** "I, <name>, agree to <terms>" signed from an
  address makes the address the signer. (Sidechain naming systems like BitNames lean on this.)
- **Claims and snapshots.** A service that wants proof the claimant *held the key* at an
  address — not merely knows the address — asks for a signed challenge.

## 4. The eCash angle

eCash addresses are byte-identical to Bitcoin addresses (`docs/key-derivation.md`), so **one
signature proves control of the key on both chains**. That is exactly what an airdrop/snapshot
claim wants ("prove you held this pre-fork Bitcoin address") — and exactly the replay risk a user
must understand: a signed message carries **no chain identifier**. A statement signed for an eCash
purpose verifies unchanged if presented to a Bitcoin counterparty, and vice-versa. Any flow we
build must make the user sign **fully-specified text that names the chain and purpose**, and the
UI must repeat BitWindow's phishing warning. Never offer "sign this random nonce" without showing
the full text.

The investor-claim path in the app (`ClaimNetwork`, "ECX Claim" wallets) does not currently need
this: claims are keyed by the wallet importing the letter's key, not by a signed challenge. If
L2L/eCash.com ever runs a web claim or verification portal, a signed message is the natural
proof, and this doc is the starting point.

## 5. How it would be built here

**Sign** — mirror BitWindow's split, chosen by the address's `ScriptType`:

| Wallet / address | Format | Primitive |
|---|---|---|
| `.bip84` P2WPKH (default), `.bip49`, `.bip44`, legacy WIF | BIP-137 compact ECDSA (header 39 / 35 / 31, or 27 for an uncompressed WIF) | recoverable ECDSA |
| `.bip86` P2TR | BIP-322 *simple* — key-path Schnorr over `to_sign` sighash | BIP-340 Schnorr |

Both primitives already exist in the app's crypto seam: `CoinNewsCrypto` does BIP-340 Schnorr via
**P256K** on Apple and **fr.acinq.secp256k1** under `#if SKIP` on Android; both libraries also do
recoverable ECDSA (`ecdsa.SignCompact` equivalents). No new dependency, and the code lives in the
transpiled `WalletService` package like the rest of the signing path.

**Key access** — reuse sign-on-demand exactly as `signPsbt` does (`BDKWalletEngineFactory`,
`docs/key-storage.md §3`): behind the same `DeviceAuth` gate as Confirm-send, load the mnemonic
once, derive the one child key for the chosen address (BDK's `DescriptorSecretKey.derive` at the
address's `AddressInfo.index`, or the WIF itself), sign, drop. This does not widen the key's
in-memory window beyond what a send already does (Golden Rule §2 / §7). The signing key never
leaves `WalletService`; the bridged surface gets `signMessage(walletId:address:message:) -> String`
and `verifyMessage(address:message:signature:) -> Bool` (bridge-safe: strings and `Bool`, §5 of
CLAUDE.md).

**Verify** — pure public-key work: BIP-137 → recover pubkey, derive the candidate addresses per
the header (incl. the Electrum quirk), compare; BIP-322 simple → rebuild `to_spend`/`to_sign`,
check the Schnorr signature against the Taproot output key (key-path only — no script-path, no
P2WSH, until a need appears). No Keychain access, safe to run while rendering.

**UI** — a "Sign message" row in the wallet's ⋯ menu / Settings → wallet section: address picker
(the wallet's *revealed* addresses — never advance the index for this), message editor with the
full text always visible, the phishing warning, result as mono text with copy/share. A "Verify"
tab with three fields. Keep the network chip on screen (Golden Rule §6) and prefix nothing to the
message silently.

**Tests** — BitWindow's `signmessage_test.go` vectors (same BIP-322 test key
`L3VFeEujGtevx9w18HD1fhRbCH67Az2dpCymeRE1SoPK6XQtaN2k`), the BIP-322 spec vectors for `to_spend`
/ `to_sign` txids and the P2WPKH "Hello World" signature, and round-trips that Sparrow/Electrum
output verifies here and ours verifies there. Explicit no-secret-in-errors assertion as for every
other `WalletError`.

**Effort** — roughly a few days: ~1 day crypto + vectors, ~1 day key plumbing + bridge, ~1 day UI
+ copy, plus both-platform verification.

## 6. Open questions before building

1. Is there an actual eCash-side consumer (claim portal, exchange onboarding, proof-of-reserves
   ask)? Without one this is a nice-to-have that exposes a signing surface.
2. Should the default be BIP-137 (maximum interop today) or BIP-322 simple for *all* segwit
   addresses (spec-pure, but Electrum/Core users can't verify it)? BitWindow chose interop.
3. Proof-of-funds (multi-address CSV) — in scope, or sign-one-address only?
4. Should the UI force a template ("eCash: <purpose> — <date> — <counterparty>") rather than
   free text, to blunt replay across the two chains (§4)?

## References

- BIP-322 spec — https://github.com/bitcoin/bips/blob/master/bip-0322.mediawiki
- BIP-137 (message signing header bytes) — https://github.com/bitcoin/bips/blob/master/bip-0137.mediawiki
- BitWindow: `bitwindow/server/signmessage/signmessage.go`, `bitwindow/lib/pages/message_signer.dart`,
  `bitwindow/lib/widgets/proof_of_funds_modal.dart` in LayerTwo-Labs/drivechain-frontends; PR #2381, issue #2206
- `bdk_bip322` — https://docs.rs/crate/bdk_bip322/latest ; `bdk-message-signer` — https://github.com/bitcoindevkit/bdk-message-signer
- BDK demo PR — https://github.com/bitcoindevkit/bdk/pull/1893
- Sparrow BIP-322 implementation (drongo) — https://code.sparrowwallet.com/sparrowwallet/drongo/commit/f47d5de3922a88ae385e586dcc3947f05c2ae803
- Related in this repo: `docs/key-storage.md` (sign-on-demand), `docs/key-derivation.md` (eCash = Bitcoin params)
