# Sidechain deposits (BIP300 M5) — design

**Status:** 🟡 BUILT, NOT YET PROVEN ON-CHAIN — 2026-09-29. This doc records what a deposit is,
byte for byte, where every input to building one comes from, and the order it was built in.

**Built (2026-09-29, build 1.2.0 (23)):**
- `Drivechain.swift` (WalletService): per-network opcode, treasury script, address-bytes check,
  `isValidDeposit` shape validator, deposit detection for Activity.
- `WalletEngine.depositToSidechain` → `prepareDeposit`: fetches the treasury's previous tx from the
  wallet's OWN backend and verifies script + value (Esplora also refuses an already-spent
  treasury), builds with the treasury as a foreign input (`SKIP REPLACE` for bdk-android's
  `Input`), rebuilds until the output order is valid (≤32, rejected builds cancelled), shape-checks
  before signing and again before broadcast. Five new `WalletError` cases.
- Plumbing: `WalletManager` → `WalletOps` / `WalletManagerOps` / `WalletFacade`; Thunder refuses.
- App: `SidechainDepositAddress` (unwrap + checksum + slot check), `SidechainDepositViewModel`,
  `SidechainDepositScreen` pushed from the sidechain detail screen.
- Tests: 17 `DrivechainTests` (host + Robolectric), 12 real-BDK `DepositEngineTests` (host),
  app-side parser + view-model suites. Robolectric compile of the engine and an Android release
  build pass.

**Not done:** the §7.6 on-chain proof on betanet (the ship gate), `s9_` paste routing in plain
Send, the Thunder deposit-to-self destination, CTIP chaining through the mempool (§4c).
Deliberate deviation from `docs/sidechains-ui.md` §3c: the deposit is its own flow (like Split
coins), not a Send destination type. It reuses Send's fee tiers and the same auth gate.

Sources, all read or probed on 2026-09-29:

- `bip300301_enforcer` — `lib/validator/task/mod.rs` (`handle_m5_m6`, what makes a deposit valid),
  `lib/messages.rs` (`OpDrivechain`, `try_parse_op_return_address`), `lib/types.rs` (per-network
  opcode), `lib/wallet/mod.rs` (`create_deposit_psbt`, the enforcer's own BDK builder).
- BitWindow — `drivechain-frontends/sidechain-orchestrator/api/deposit.go` +
  `api/deposit_chain.go` (builds M5s without an enforcer wallet, which is our situation) and
  `bitwindow/server/drivechain/utils.go` (`DecodeDepositAddress`).
- A real betanet deposit, `f83c5c7a…88c5`, and the live endpoints listed in §3.

**Moving to the real fork** (opcode, enforcer URL, config id): `docs/real-ecash-fork-transition.md`.

Supersedes the deposit half of `docs/thunder-deposit-withdraw.md` (§2, §5.4, open question 1).

---

## 1. The conclusion first

**Everything a deposit needs is reachable from the phone today, with BDK, over HTTPS.** No enforcer,
no mainchain node, no new server endpoints. The earlier research concluded deposits were "the hard
direction"; that was before the drivechain-esplora index existed and before BitWindow shipped an
enforcer-free builder we could read.

One real obstacle remains, and it is in our BDK binding, not the protocol: **bdk-ffi 2.3.1 does not
expose output ordering** (§4).

## 2. What a valid deposit is

An M5 is an ordinary mainchain transaction. The enforcer recognises it by shape — there is no tag:

| Part | Content | Rule |
|---|---|---|
| Input | the sidechain's current treasury UTXO (the **CTIP**) | Required if the slot has a treasury. Anyone-can-spend: **empty scriptSig**, no witness. Omitted only for the first-ever deposit to a slot. |
| Inputs | our wallet's UTXOs | Fund the deposit + fee, as in a normal send. |
| Output *k* | `OP_DRIVECHAIN OP_PUSHBYTES_1 <slot> OP_TRUE` | Value = **old CTIP value + deposit amount**. Exactly one per slot per tx. |
| Output *k+1* | `OP_RETURN <one push: sidechain address>` | **Must immediately follow the treasury output** (`MissingDepositAddress` otherwise). Exactly one push, nothing after it. |
| Other outputs | change | Anywhere else. |

The deposit amount the sidechain credits is **new treasury − old treasury**. A tx that spends the
treasury without recreating it is rejected (`TreasurySpentWithoutNewCtip`); one whose new value is
*smaller* is read as a withdrawal (M6), not a deposit.

### 2a. `OP_DRIVECHAIN` is a per-network consensus constant

| Network | Opcode | Byte | Source |
|---|---|---|---|
| L2L Signet | `OP_NOP5` | `0xb4` | `NetworkParams::for_network` |
| Alphanet (`.ecash`) | `OP_NOP5` | `0xb4` | `NetworkParams::alphanet` |
| Betanet (`.ecashBeta`) | `OP_NOP8` | `0xb7` | `NetworkParams::betanet` — verified on-chain, §2c |
| Bitcoin mainnet | — | — | No BIP300; no deposits. |

This goes in the compiled `NetworkRegistry`, **never** remote config (Golden Rules §1/§4): a wrong
byte produces an output the enforcer doesn't recognise as a treasury — an anyone-can-spend output
that anyone can sweep. The deposit would be lost.

> ⚠️ **Report upstream.** BitWindow's orchestrator hardcodes `opDrivechain = 0xb7 // OP_NOP8`
> (`sidechain-orchestrator/m8.go`). That is right only on betanet; on signet/alphanet it would build
> exactly the lost-funds output described above. (Checked `m8.go` only — confirm there's no
> per-network override elsewhere before filing.)

### 2b. The address in the OP_RETURN is the BARE sidechain address

Users see `s<slot>_<address>_<checksum>`, e.g. `s9_8twUkpctzwgbjqi5o14qWjrD9uk_xxxxxx`. That string is
a **UI encoding**. The OP_RETURN carries only `<address>`, as its UTF-8/ASCII bytes. BitWindow:

> "The OP_RETURN must carry the bare address: the sidechain cannot parse the wrapped form and
> credits the coins to an unspendable address."

Decoding (identical in BitWindow's server and orchestrator):

1. Split on `_`. One part → a bare address (slot must come from context). Two → `s<slot>_<addr>`.
   Three → `s<slot>_<addr>_<checksum>`. Anything else → reject.
2. `slot` must parse as 0–255 **and equal the slot we're depositing to** — a Thunder address pasted
   into a BitNames deposit must be rejected, not silently redirected.
3. With a checksum: `hex(sha256("s<slot>_<addr>_")[0..3])` must match (case-insensitive).
4. Emit `<addr>`.

The format is the same for every sidechain; only the slot differs. What the address *itself* must
look like is sidechain-specific (Thunder: base58 of 20 bytes, `docs/thunder-sidechain-support.md`);
v1 validates Thunder's and treats others as opaque strings.

### 2c. Verified against a real betanet deposit

`f83c5c7a975798aefa35a98299b31bebcf4dda5edf885bd6f893244a1b2688c5` (block 970,642), currently the
Thunder CTIP:

```
vin  0  a7e46fe7…bc66:0   prevout b7010951   scriptSig <empty>   ← old CTIP
vin  1  ee0e6e67…1574:1   prevout P2WPKH                           ← depositor funds
vout 0  b7 01 09 51       OP_NOP8 PUSHBYTES_1 09 OP_TRUE   519,790,000
vout 1  6a 1b <27 bytes>  OP_RETURN "8twUkpctzwgbjqi5o14qWjrD9uk"         0
vout 2  P2WPKH                                              91,146,342    ← change
```

The Thunder index credits it: `/deposit/f83c5c7a…` returns the sidechain output (10,000,000 sats,
`outpoint_kind: "deposit"`). This tx is the fixture for our shape-validator tests.

## 3. Where every input comes from

| Need | Source | Verified |
|---|---|---|
| Which sidechains exist on a network | `GET {box}/drivechain/sidechains` (or `{thunder-index}/drivechain/sidechains`) — every active slot, title, activation height, treasury | ✅ betanet: 8 slots (2, 4, 9, 13, 98, 99, 130, 255) |
| The CTIP (outpoint + value) | same, or `GET {thunder-index}/drivechain/sidechain/{slot}`; `"treasury": null` = no deposits yet | ✅ |
| The CTIP's full tx (for the PSBT `nonWitnessUtxo`) | mainchain Esplora `GET /tx/{txid}/hex` | ✅ `esplora.beta.ecash.ninja` |
| Has someone already spent the CTIP? | mainchain Esplora `GET /tx/{txid}/outspend/{vout}` | ✅ answers `{"spent":false}`; mempool visibility still to confirm |
| Did the sidechain credit it? (Thunder) | `GET {thunder-index}/deposit/{mainchain_txid}` | ✅ |
| Display metadata (description, version) | `drivechain.dev/config` → `networks[].sidechains[]` | ✅ |

`{thunder-index}` today is `https://seed.beta.ecash.eu.com/thunder` (betanet). The `/drivechain/*`
routes read the **mainchain** through the enforcer behind the index, not Thunder's own chain, so
they answer for **every** slot even though the host is Thunder's.

**Use the dedicated host instead:** the same box serves the escrow index at the bare path
**`https://seed.beta.ecash.eu.com/drivechain`** (`/sidechains`, `/sidechain/{slot}` — identical
payloads, verified). That is the URL BitWindow's config names for it (§3b) and the one we should use,
so deposits don't depend on Thunder's index being deployed. The box also hosts address indexes for
`bitnames`, `bitassets`, `coinshift` (live) and `photon` (up, "holds no blocks yet") under
`/<chain>` — relevant later for crediting status on non-Thunder deposits.

> ⚠️ **`seed.alpha.ecash.eu.com` serves BETANET's escrow.** Its `/drivechain/sidechain/9` returns
> treasury `f83c5c7a…88c5`, which exists on `esplora.beta.ecash.ninja` and 404s on
> `esplora.alpha.ecash.ninja`; its sidechain tip heights match beta's exactly. A deposit on alphanet
> built from it would spend a nonexistent input (rejected — a safe failure, but a broken feature).
> Until L2L fixes or retires it: **no alphanet deposits**, and the engine should verify the CTIP
> exists on the wallet's own backend (`/tx/{txid}`) before building — which the `nonWitnessUtxo`
> fetch does for free.

### 3a′. The hosted enforcer — the live, authoritative source (PREFERRED)

BitWindow's light mode talks to a **hosted BIP300 enforcer** at
**`https://seed.beta.ecash.eu.com/enforcer`**. It is a Connect server, so from the phone it's plain
**HTTPS POST + JSON**. There's no gRPC library, no auth and no HTTP/2 requirement (verified
2026-09-29 with curl):

```
POST https://seed.beta.ecash.eu.com/enforcer/cusf.mainchain.v1.ValidatorService/<Method>
Content-Type: application/json
Connect-Protocol-Version: 1

{"sidechainNumber": 9}
```

The host puts a read-only allowlist in front of it (the same one as BitWindow's
`enforcerproxy.validatorPath`). Wallet methods answer **403**, which is what we want. What's useful
to us:

| Method | Body | Gives us | Verified |
|---|---|---|---|
| `GetSidechains` | `{}` | every **active** slot: `sidechainNumber`, `declaration.v0.{title,description}`, `voteCount`, `activationHeight` | ✅ |
| `GetCtip` | `{"sidechainNumber":9}` | `ctip.{txid.hex, vout, value, sequenceNumber}`; `{}` when the slot has no treasury | ✅ (`vout` is omitted when 0, per proto3 JSON) |
| `GetChainTip` | `{}` | height and hash the enforcer has validated. Use it to refuse deposits while the enforcer lags the wallet's backend (BitWindow's `depositTreasuryReady`) | ✅ height 970,659 |
| `GetChainInfo` | `{}` | `network`, `bip300Constants` (withdrawal max age / threshold, activation height). This is **real data for the withdrawal timescale copy**, not hardcoded months | ✅ |
| `GetSidechainProposals` | `{}` | slots being voted in right now (e.g. **slot 8 "Solana", 808 votes**), for a "coming soon" view | ✅ |
| `GetWithdrawalBundleProposals` | `{"sidechainId":9}` | pending M6 bundles with `voteCount`. This is the withdrawal-status source (`thunder-deposit-withdraw.md` §5.3) | ✅ 1 bundle, 121 votes |
| `SubscribeEvents` | `{"sidechainId":9}` (streaming) | connect/disconnect block events carrying **deposits and withdrawal-bundle events** per slot | ⚠️ stream opens (200) but sent nothing in 25 s. Expected between blocks, but not proven |

Field names use proto3 JSON camelCase (`sidechainNumber` for GetCtip, but `sidechainId` for the
bundle/subscribe requests; that follows the proto). Wrapper types (`UInt32Value`) are bare numbers
in JSON. Our CoinNews client already speaks this (`docs/coinnews-integration.md`, `coinnews-fetch-layer`
memory), so this is a small, known adapter.

**Why prefer it over the `/drivechain` index:** the index is derived from this enforcer. Going
direct removes a layer that can lag, and gives us everything above that the index doesn't serve
(proposals, bundles, BIP300 constants, chain tip). The index remains a reasonable fallback. For
"live", **poll `GetChainTip` and refetch on a new hash** (BitWindow caches `ListSidechains` per
block hash the same way). A long-lived stream is the wrong tool for a mobile app that's backgrounded
most of the time.

**Coverage today:**

| Network | Enforcer | State |
|---|---|---|
| Betanet | `seed.beta.ecash.eu.com/enforcer` | ✅ live |
| Alphanet | `seed.alpha.ecash.eu.com/enforcer` | ❌ **serves betanet**: identical tip hash, `activationHeight` 967,680 (betanet's fork, not alphanet's 963,648). Same misrouting as its `/drivechain` index |
| Real ECX | `seed.ecash.eu.com/enforcer` (BitWindow's default) | not up (connection fails) |
| L2L Signet | none found (`node.signet.drivechain.info/enforcer` is the website) | ❌ |

**It isn't in `drivechain.dev/config`.** BitWindow has `services.enforcer.url` in its *embedded*
catalog (`netcatalog/networks.json`), but the live config omits it. Ask L2L to publish it. Until
then, a per-network default in our registry, marked as a service URL (not consensus), with the
config able to override it.

**Trust:** this is a server's word about consensus state, the same trust we already place in the
Esplora backend. The §5 validator bounds the damage. A lying enforcer can make a deposit fail (a
wrong or spent CTIP gets rejected by the network), but it can't redirect funds: the treasury script,
slot, destination and amount all come from us, not from the server. The one exception is **offering
an inactive slot**. That turns the treasury output into ordinary anyone-can-spend coins, so a slot
must appear in `GetSidechains` **and** have a slot number the user explicitly chose.

### 3b. Where BitWindow gets its list

Read in `drivechain-frontends` (2026-09-29):

- **Always from an enforcer's `GetSidechains` + per-slot `GetCtip`**
  (`bitwindow/server/api/drivechain/drivechain.go` `ListSidechains`, cached per block hash). That's
  a local enforcer in full-node mode, or — in "light" mode — a **hosted enforcer** proxied over
  Connect/gRPC, URL from `services.enforcer.url` in its catalog
  (`https://seed.beta.ecash.eu.com/enforcer`, `…alpha…/enforcer`; `config/remote_enforcer.go`). Not
  plain HTTP (a bare GET answers 403), so not something we'd call from the phone.
- **It does not use `drivechain.dev/config`'s `sidechains[]` at all.** Its catalog decoder
  (`sidechain-orchestrator/config/netcatalog`) never reads that field. The array is apparently for
  the node launcher/presentation, which is why it can lag the enforcer's real active set (§3a).
- **An HTTP escrow client exists but isn't wired yet:** `escrow_index.go` reads `<base>/sidechains`
  (the exact JSON above, same comment about `treasury: null`), and
  `config.DrivechainIndexURLForNetwork` resolves `<eCash box>/drivechain` (alpha → `seed.alpha…`,
  beta → `seed.beta…`, real ECX → `seed.ecash.eu.com`). Both only have test callers in this
  snapshot. That's the direction L2L is heading, and it's what we'd use — so we're aligned, not
  inventing a dependency.
- Note BitWindow's box URLs are **hardcoded** per eCash generation in `config/network.go`, not read
  from `drivechain.dev/config`. We'd rather they be published there (§8 Q2).

### 3a. drivechain.dev/config vs the index — they disagree

The config lists **only Thunder** under betanet; the index reports **eight** active slots on the same
network (including `130 FreeBank`, which the config doesn't list anywhere). So:

- **Deposit eligibility comes from the index** (`/drivechain/sidechains`): it is the enforcer's view,
  i.e. what consensus will actually honour. A slot the index doesn't report as active must not be
  offered — a deposit to an inactive slot is an ordinary anyone-can-spend output (the enforcer's
  `if !dbs.sidechain().contains_key(...) { continue; }`), i.e. lost coins.
- **The config is presentation**: descriptions, which sidechains we *choose to feature*, and ideally
  the per-network index URL. Worth asking L2L either to make the config list every active slot, or
  to add an explicit `services.drivechain.url` so we're not borrowing "the Thunder index" for a
  mainchain question.

`RemoteEndpointConfig` currently ignores `sidechains[]`; decoding it is additive (lenient decoder).

## 4. Building it with BDK

bdk-swift / bdk-android 2.3.1 can express the whole transaction. It mirrors the enforcer's own
`create_deposit_psbt`, which is itself BDK:

```swift
// Pseudocode — bdk-ffi 2.3.1 names.
let ctipInput = Input(nonWitnessUtxo: ctipTx,           // Esplora /tx/{txid}/hex
                      finalScriptSig: Script(rawOutputScript: Data()),  // anyone-can-spend
                      /* everything else empty */)
let builder = TxBuilder()
    .addRecipient(script: treasuryScript(opcode, slot), amount: oldCtip + deposit)
    .addData(data: Data(bareAddress.utf8))
    .feeRate(feeRate)
builder = try builder.addForeignUtxo(outpoint: ctipOutpoint, psbtInput: ctipInput,
                                     satisfactionWeight: 0)   // enforcer uses ZERO too
let psbt = try builder.finish(wallet: watchOnlyWallet)
```

The foreign input contributes the old CTIP value, so coin selection only has to find
`deposit + fee` from our wallet — exactly as a normal send.

### 4a. The blocker: output ordering

BDK's default `TxOrdering` is **Shuffle**. The enforcer calls `builder.ordering(custom)` to pin the
OP_RETURN right after the treasury; **bdk-ffi 2.3.1 has no `ordering` method at all**. A shuffled
deposit is invalid about ⅔ of the time with three outputs — and "invalid" here means the treasury
output is *recognised* but the address isn't, so the enforcer rejects the block-level parse
(`MissingDepositAddress`); we must never broadcast one.

Options, in order of preference:

1. **Expose `TxOrdering` in bdk-ffi upstream** (even just `Untouched`, which keeps recipients then
   data in insertion order). Correct and small, but gated on a bdk-ffi release — or us carrying a
   fork, which CLAUDE.md §3 ("never float") makes expensive.
2. **Rebuild until valid, validate before signing.** Build the unsigned PSBT, run the §5 shape
   validator; if the shuffle put the OP_RETURN elsewhere, discard and build again (bounded retries).
   Nothing is signed or broadcast until the validator passes, so a bad order costs only CPU. Ugly but
   safe, and it's the interim that unblocks everything else.
3. Reorder the PSBT's outputs ourselves pre-signing. Requires editing raw PSBT bytes (unsigned tx +
   per-output maps in lockstep). Not worth it.

Recommendation: **ship on (2), file (1) in parallel, delete (2) when the binding catches up.**

> **Update 2026-09-29: the binding already caught up.** bdk-ffi **3.0.0** (2026-06-09) exposes
> `TxBuilder.ordering(TxOrdering)`, including `Untouched` (insertion order), and 3.1.0 is current. So
> option (1) is "upgrade", not "file a request". We're pinned to 2.3.1, and 3.0 has breaking changes
> that touch key derivation (`DescriptorSecretKey::new` no longer adds a wildcard; `Descriptor` and
> `DescriptorSecretKey` constructors take a `NetworkKind`), plus bdk_wallet 3.0's persistence. That
> makes it its own deliberate upgrade (CLAUDE.md §3: "upgrade deliberately"), gated on the BIP84
> spec-vector tests and a persistence round-trip. **Built on (2)** (`WalletEngine.prepareDeposit`,
> ≤32 attempts, rejected builds cancelled). After the upgrade, set `.ordering(.untouched)` and delete
> the loop; keep the shape check, which guards more than ordering.

### 4b. Signing the foreign input

Our sign-on-demand path (`BDKWalletEngineFactory.signPsbt`, CLAUDE.md §7) signs with a transient
private-descriptor wallet. It must sign our inputs and **leave the pre-finalized CTIP input alone**.
The enforcer relies on this ("This might be wrong. Seems to work!"); we need a real-BDK integration
test on both platforms proving it, and that `extractTx` yields an empty scriptSig on input 0.

### 4c. The CTIP race

The CTIP is a single shared UTXO. Two deposits built on the same CTIP conflict; one loses.

- **Chain onto unconfirmed deposits.** BitWindow walks forward: `outspend(ctip)` → if spent, find the
  spender's treasury output → repeat (limit 21, mempool's ancestor limit). A spender that creates
  *no* treasury output is a withdrawal (M6) — stop and wait for a block. We can do the same walk with
  `/tx/{txid}/outspend/{vout}` + `/tx/{txid}`, if Esplora reports mempool spends (to verify).
- **On broadcast rejection** (`txn-mempool-conflict`, missing inputs), re-read the CTIP and rebuild
  once, then surface a clear "the sidechain treasury moved, try again" error. Never silently resubmit
  with a different amount.
- **After our broadcast,** `applyBroadcast` folds the tx into the wallet as for any send (CLAUDE.md
  §6), so our change is spendable and a second deposit doesn't reselect spent coins.

## 5. The shape validator (the safety net)

A pure function over the unsigned tx, run after `finish` and **again** on the signed tx before
broadcast. It is the thing that turns every mistake above into an error instead of lost coins:

- exactly one output whose script is `<registry opcode> 01 <slot> 51`, and it's for **our** slot;
- the output immediately after it is `6a <single push>` whose bytes equal our bare address;
- if the index reported a CTIP: exactly one input spends it, and the treasury output's value is
  `ctip.value + amount` exactly;
- if the index reported `treasury: null`: no input spends a treasury, and the value is `amount`;
- no other `OP_DRIVECHAIN`-shaped output for any slot.

Test vectors: the real betanet tx in §2c, plus the enforcer's own `handle_m5_m6_*` cases.

## 6. UX and safety

> Full UI design with mockups: **`docs/sidechains-ui.md`**. Summary below.

- **Entry points:** a "Deposit to sidechain" action on eCash networks only (hidden where the index
  reports no active slots — i.e. Bitcoin). A sidechain picker from `/drivechain/sidechains`, titled
  and described from the config.
- **Destination:** paste/scan `s<slot>_…`, or — for Thunder — "my Thunder wallet", which fills a
  fresh address from the user's own Thunder engine (same seed; `docs/thunder-sidechain-support.md`).
  Deposit-to-self is the common case and removes a paste step.
- **Review (Golden Rule §7):** network chip, **sidechain name + slot**, destination, amount, fee,
  and a plain statement that the coins leave the mainchain and **coming back is a withdrawal measured
  in weeks to months** (`docs/thunder-deposit-withdraw.md` §3). Mainnet-weight confirmation — this is
  real ECX.
- **Activity:** the classifier (`WalletTx`, like `coinNewsKind`) can recognise a deposit from the
  treasury-script output alone — unlike BitWindow, which has to keep a local record because it
  doesn't classify. Row: "Deposit to Thunder", with sidechain-credit status from `/deposit/{txid}`
  where the sidechain has an index.

## 7. Build order

1. **Registry + pure logic, tested.** `NetworkParams.drivechainOpcode` (nil on Bitcoin); deposit
   address decoder; treasury-script builder; the §5 validator. All pure, all fast tests, vectors
   from §2c and the enforcer.
2. ✅ **BUILT 2026-09-29 — read layer.** `Sources/ECashWalletMobile/Drivechain/` (`EnforcerClient`,
   `EnforcerFetching`, `EnforcerEndpointRegistry`, `DrivechainModels`); `services.enforcer.url` parsed
   from remote config; 24 tests on captured betanet payloads plus an opt-in live test
   (`ENFORCER_LIVE=1`). A Connect-JSON `EnforcerClient` (`GetSidechains`, `GetCtip`, `GetChainTip`,
   `GetChainInfo`, `GetSidechainProposals`, `GetWithdrawalBundleProposals`) against the hosted
   enforcer (§3a′), refetching on a new tip hash. `{box}/drivechain` is the fallback. Enforcer URL
   per network: ask L2L to publish `services.enforcer.url`; until then use a registry default,
   overridable by config.
3. **Engine.** `WalletEngine.depositToSidechain(slot:address:amount:feeRate:)` — foreign CTIP input,
   ordering via §4a option 2, validator gate, sign, broadcast, `applyBroadcast`. Bridged surface via
   `WalletManager`, signed types only (CLAUDE.md §5).
4. **Real-BDK integration tests** on iOS sim + Android emulator: foreign-input signing (§4b), shape,
   first-deposit (`treasury: null`) path.
5. **UI** per §6.
6. **On-chain proof on betanet** with a small amount, confirmed credited via `/deposit/{txid}`,
   before any release — the same bar split-coins had to clear.

## 8. Open questions

1. Does mainchain Esplora's `/outspend` report **mempool** spends? Decides whether we can chain onto
   pending deposits or must wait for confirmation.
2. Will L2L add a first-class drivechain/enforcer URL to `drivechain.dev/config`, and reconcile the
   config's sidechain lists with the enforcer's active set (§3a)?
3. Minimum deposit: is there a sidechain-side dust floor below which a deposit is credited but
   unspendable?
4. Ordering retries: with change, 1 in 3 shuffles is valid; without change (exact-amount spend),
   1 in 2. Bound the retries (e.g. 32 → failure odds ≈ 10⁻⁶) and test both.
5. Upstream: file the bdk-ffi `TxOrdering` request, the BitWindow `OP_NOP8` hardcode (§2a), and
   `seed.alpha.ecash.eu.com` serving betanet's escrow **and** enforcer (§3, §3a′).
6. Will L2L commit to the hosted enforcer as a public, rate-limited service for mobile clients, and
   stand one up for signet and real ECX? Does `SubscribeEvents` deliver over Connect/HTTP-1.1 (§3a′)?
