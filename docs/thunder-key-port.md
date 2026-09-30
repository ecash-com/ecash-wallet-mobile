# Thunder key port (thunder-rust 0.18) — and a sidechain layer for the next ones

Status (2026-09-30): **steps 1–4 BUILT, uncommitted; step 6 (live betanet check) pending.** 466 app tests
green; `SidechainCryptoSelfCheck OK` on the iOS simulator and an Android emulator.

Progress:
- **Step 1 ✅** `Sidechain/` core: `RistrettoBip32` (+`biasFix`, public derivation), `FrostSchnorr`,
  `SidechainAddress` (`ThunderAddress` is now a typealias), `SidechainKeyScheme` /
  `WatchOnlySidechainKeyScheme` / `RistrettoSidechainKeyScheme.thunder`, `SidechainHash`, `Bip39Seed`,
  `Base58` moved here. `SidechainCryptoTests` pin Thunder AND coinshift (no bias fix) vectors.
- **Step 2 ✅** `ThunderTransaction018Tests` pin v0.18.1's own bytes: pointed-output hashes, tx borsh,
  txid, authorized borsh, and the full submit JSON; thunder-rust's `verify_authorized_transaction`
  accepted a Swift-signed tx. **It caught three submit-JSON breaks** that would have failed every send
  on 0.18: `verifying_key`/`signature` are now hex strings (were ed25519 arrays of numbers), a `Deposit`
  outpoint is the string `"txid:vout"` (we sent an object), and withdrawal fields are `value`/`main_fee`
  (were `value_sats`/`main_fee_sats`; old names still decode). Withdrawal content now carries
  `mainAddress` (JSON) alongside `mainScriptPubKey` (Borsh).
- **Step 3 ✅** `ThunderKey`/`ThunderWallet`/`ThunderAuthorization` on FROST; `Slip10Ed25519` deleted.
- **Step 4 ✅** watch-only: `ThunderAccountKeyStore` (UserDefaults, key `thunder.accountKey.v018.<id>`);
  the mnemonic is read once per wallet for the account xpub, then only to sign.
- Also: wallet removal now purges Thunder's revealed index, first-seen times and account xpub
  (`WalletOps.forget`) — the first two were previously left behind (Golden Rule §5 gap).
- Step 5: no storage migration needed; old-address coins are unrecoverable (decision pending, §6).
- Step 7 partial: libsodium added to the licences screen + README. Still to do: remove
  `SidechainCryptoSelfCheck` + its launch log, update `docs/thunder-sidechain-support.md` / CLAUDE.md §12.

## 1. Why

thunder-rust **0.18.0** (2026-09-17), the release that added **betanet**, replaced Thunder's keys:

| | What our app does today | thunder-rust ≥ 0.18 (v0.18.1, `b62658f`) |
|---|---|---|
| Signature | ed25519 (`Curve25519.Signing`) | FROST(ristretto255, SHA-512) single-signer Schnorr — `frost-ristretto255` (commit `58a6c6e` is *titled* "ed25519 -> schnorrkel" but uses FROST, not schnorrkel) |
| Derivation | SLIP-0010 ed25519, `m/1'/0'/0'/i'`, all hardened | "bip32ish" over ristretto255 (`lib/wallet/bip32.rs`), `m/43'/1899'/0'/9'/0'/i` — account hardened, **address index non-hardened** |
| Address | `BLAKE3(ed25519 pk)[..20]` | `BLAKE3-XOF(compressed ristretto pk)[..20]` (same bytes as `BLAKE3(pk)[..20]`) |

Our `.thunder` network reads the **betanet** Thunder index, which only exists on 0.18+. So today:

- Our Thunder addresses differ from BitWindow's for the same recovery phrase.
- Coins sent to them can't be spent: no ristretto key hashes to an ed25519-derived address, and the
  node rejects ed25519 signatures. **Nothing errors** — the index happily reports those coins.
- Thunder send is broken, the 1.2.0 deposit flow credits unspendable addresses, and the planned
  withdrawal feature (`docs/thunder-deposit-withdraw.md`) can't be built on top.

## 2. Proof of concept (done, uncommitted at time of writing)

- `Packages/Ristretto255` — 5 files of libsodium 1.0.22 compiled from source + a Swift wrapper
  (RFC 9496 vectors pass). See its README for the exact vendored set and local changes.
- `Thunder/ThunderFrostSpike.swift` — 0.18 derivation, address, FROST sign/verify.
- `ThunderFrostSpikeTests` match **byte-for-byte** reference values from a scratch Rust program that
  runs thunder-rust's own `bip32.rs` (master key, account path, 3 addresses, deposit strings, and a
  fixed-nonce signature that frost-ristretto255's own verifier accepted).
- Launch self-check logged `ThunderFrostSpike OK` on the iOS simulator **and** an Android emulator
  (API 34, arm64) — the load-on-device check BLAKE3 originally failed.

Golden: `abandon ×11 about`, passphrase `""`, sidechain 9, index 0 → `NKqSr4bQejFbKpd5yLQgWEiMJFx`.

## 3. Design: a shared sidechain crypto core + per-sidechain plug-ins

We will add more of L2L's Rust sidechains later. Research on truthcoin-dc (v0.19.0, slot 13) and
coinshift-rs (v0.14.8, slot 255) shows what is shared and what isn't:

| Layer | Thunder | Truthcoin | Coinshift | → |
|---|---|---|---|---|
| Group / signature | FROST ristretto255 (frost rev `0966bd1`) | same | same | **shared** |
| Key & sig bytes | pk 32, sig `R‖z` 64 | same | same | **shared** |
| Address | BLAKE3-XOF(pk)[..20], base58 | same | same | **shared** |
| Deposit string | `s{slot}_{b58}_{hex(sha256(prefix)[..3])}` | same | same | **shared, slot is a parameter** |
| Key derivation | ristretto bip32ish, bias fix, `m/43'/1899'/0'/9'/0'/i` | **secp256k1 BIP32** `m/0'/i`, secret bytes read LE mod ℓ | ristretto bip32ish **without** the bias fix, slot 255 | **per sidechain** |
| Signed message | `borsh(tx)` | `0x00 ‖ borsh(tx)` | `borsh(tx)` | **per sidechain** |
| Tx / output layout | Thunder | different (memos, `data`, `actor_proof`, no input hashes) | Thunder + trailing `TxData` | **per sidechain** |
| Withdrawal output | `u64 value, u64 main_fee, u32-len scriptPubKey` | identical | identical | **shared encoder** |
| Thin-client RPC | yes | yes | **no** (needs upstream work) | per sidechain |

So the code splits into:

```
Packages/Ristretto255/            libsodium subset + Swift wrapper (group/scalar ops) — exists
Sources/ECashWalletMobile/
  Sidechain/                      NEW — shared, sidechain-agnostic
    RistrettoBip32.swift            bip32ish over ristretto255; `biasFix: Bool` (Coinshift = false)
    FrostSchnorr.swift              sign / verify (H2 = SHA-512 "FROST-RISTRETTO255-SHA512-v1"‖"chal")
    SidechainAddress.swift          20-byte address, base58, deposit string(slot)
    SidechainKeyScheme.swift        protocol: seed → signing scalar for (index); Thunder impl now
    WithdrawalContent.swift         the shared withdrawal-output encoder (later, with withdrawals)
  Thunder/                        Thunder-specific: tx codec, service, backends, UI glue
```

Rules for this milestone, so we don't over-build:

- Build the **shared core** properly (it is small and every future sidechain needs it).
- Build **only the Thunder** key scheme and codec. The protocol seam exists so Truthcoin/Coinshift
  plug in later without touching the core, but we don't write their implementations yet.
- `ThunderAddress` becomes a thin wrapper over `SidechainAddress` with `slot = 9`, so call sites
  don't churn.

## 4. Steps

### Step 1 — Promote the spike into `Sidechain/`
- Split `ThunderFrostSpike` into `RistrettoBip32` (+ `biasFix`), `FrostSchnorr`, `SidechainAddress`.
- Tests move with it (existing Rust vectors) plus: hardened-index child (`i ≥ 2^31`), zero-scalar
  rejection, non-canonical point/`z` rejection, and one **`biasFix = false`** vector from coinshift-rs
  so the parameter is exercised from day one.

### Step 2 — Prove the Thunder 0.18 *transaction* bytes (gate)
The keys are proven; the transaction format isn't. Thunder's `types/` was heavily restructured between
the branch our Borsh vectors came from (`2026-07-24-refactor`) and v0.18.1 (18 files, ~2.3k lines).
Before switching, generate from **v0.18.1 itself** (scratch Rust program depending on the `types`
crate at `b62658f`):
- `borsh(Transaction)` + txid for a tx with Regular/Deposit inputs and Value + Withdrawal outputs;
- the per-input hash (utreexo leaf hash of the spent `PointedOutput`) our `utxoHash()` computes;
- then **sign in Swift** and have Rust run `verify_authorized_transaction` on the bytes.

Fix any mismatch before step 3. (Withdrawal content already matches — research 2026-09-30.)

### Step 3 — Switch Thunder to the new keys
- `ThunderKey` → derive through `ThunderKeyScheme` (ristretto, `m/43'/1899'/0'/9'/0'/i`).
- `ThunderAuthorization` → FROST signature; wire format unchanged (vk 32 + sig 64).
- `ThunderWallet` → derive the **account key once**, then cheap non-hardened children (today every
  index repeats the full path).
- Delete `Slip10Ed25519.swift` and the ed25519 path; drop the `Curve25519` import. swift-crypto stays
  (HMAC/SHA-512/SHA-256).
- Update `ThunderKeyTests`, `ThunderWalletTests`, `ThunderAuthorizationTests`, `ThunderServiceTests`
  golden values to 0.18.

### Step 4 — Watch-only address derivation (recommended, same milestone)
The old scheme was all-hardened, so every sync, receive and change address loaded the **mnemonic** from
the Keychain just to list addresses. ristretto bip32ish derives address children **non-hardened**, so
the account *public* key + chain code (an "xpub") is enough:
- Derive `(account pubkey, chaincode)` once at create/import/first unlock after upgrade; store it with
  the wallet's other public metadata (like BDK's public descriptors — public, but privacy-sensitive).
- Sync / receive / change derive from it; **only signing loads the mnemonic** — the same watch-only +
  sign-on-demand model as the BDK side (CLAUDE.md §7).
- Needs public child derivation: `child_pk = parent_pk + tweak·G` with the tweak from
  `HMAC(chaincode, compressed(parent_pk) ‖ be32(i))`. Test that it equals `derive(secret)·G`.

### Step 5 — Existing Thunder wallets
- **Nothing to migrate in storage:** the recovery phrase is the same; addresses simply re-derive.
  The revealed-index counter can stay (it's only a counter).
- **Coins already sent to old addresses are unrecoverable** on 0.18 nodes (betanet test coins, e.g.
  1.2.0 deposits). Decision needed — see §6.
- Bump a Thunder schema marker so cached history from old addresses is dropped on first launch.

### Step 6 — Verify on betanet, both platforms
1. Create a Thunder wallet; check its first address against **BitWindow / thunder-rust** for the same
   phrase (the real-world cross-check).
2. Deposit from a betanet eCash wallet with the app's own deposit flow; see the balance land.
3. Thunder → Thunder send; confirm the node accepts the FROST-signed tx and it confirms.
4. Restore the same phrase on the other platform; balance and history match.
Real device for Android (not just `skip export` — the BLAKE3 lesson).

### Step 7 — Clean up
Remove `ThunderFrostSpike` and the temporary launch self-check; update
`docs/thunder-sidechain-support.md`, CLAUDE.md §12, `OpenSourceLicense.all` (libsodium, ISC) + README
licence table.

Then: the withdrawal feature (researched; plan in `docs/thunder-deposit-withdraw.md` §5 + session
notes), built on this.

## 5. Adding the next sidechain later (what it will take)

- **Truthcoin** (slot 13, v0.19.0) — feasible as a thin client (`get_utxos`, `submit_transaction`,
  `push_tx`). Needs: a secp256k1 BIP32 key scheme (the app already links swift-secp256k1), the `0x00`
  signing prefix, its own tx codec (memos, `data`, `actor_proof`, extra OutPoints, no utreexo), and a
  known-answer vector from its node. Its markets/votes are a product decision, separate from "hold and
  send".
- **Coinshift** (slot 255, v0.14.8) — **not** supportable as a thin client until upstream adds a
  per-address UTXO query and external-tx submission. Its swap trust model is weak by its own docs
  (the L1 leg isn't consensus-checked). Wait.
- Each new sidechain: a `WalletNetwork` case, a registry entry (slot, key scheme, sign prefix, codec,
  backend, unit), and a mainchain mapping in `SidechainWalletNetwork`.

## 6. Open questions

1. **Old-address coins:** drop silently with a release note (they're betanet test coins), or scan the
   legacy addresses once and tell affected users "X ECX sent before this update can't be recovered"?
2. **Watch-only (step 4):** include in this milestone? Recommended — it's small now, and it shrinks the
   mnemonic's exposure from every sync to signing only.
3. **Confirm with L2L** that the betanet Thunder index and node run ≥ 0.18.0 (they must, since betanet
   support only exists there) and whether more key-scheme changes are planned before the real fork.
4. **Truthcoin's secp256k1 derivation** reading secret bytes little-endian mod ℓ looks unintentional —
   worth asking before we copy it.
