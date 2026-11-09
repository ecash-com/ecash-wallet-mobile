# Moving to the real eCash fork

**Status:** 🟢 LIVE IN CONFIG 2026-10-26 — the remote config publishes the real fork as id **`ecash`** (served from **`https://dev.ecash.com/config`** since 2026-11-09, `drivechain.dev/config` before; same schema, but the eCash.com config lists only `ecash` + `betanet`, so Bitcoin / Signet keep their last-applied or bundled endpoints)
(not the staged `ecash-mainnet`; 1.4.4 only knew the staged spelling, 1.4.5 maps both). `WalletNetwork.ecashMainnet`
was added 2026-10-22, gated on the remote config (below). Alphanet retired from the pickers 2026-10-26. Written 2026-09-29 ahead of the real fork. Alphanet and betanet are test generations;
**betanet keeps running beside the real fork** (Jake, 2026-10-22) and its case is never repurposed.
The real fork is the chain that holds real ECX.

## What is wired (2026-10-22)

Read from the node (github.com/ecash-com/bitcoin master) and from L2L's catalog staging
(LayerTwo-Labs/drivechain-frontends `sidechain-orchestrator/config/netcatalog`, fixture
`testdata/ecash-mainnet.json`):

| Value | Where | Source |
|---|---|---|
| config id **`ecash`** (LIVE 2026-10-26, display "eCash"; the staged `ecash-mainnet` spelling also maps) | `RemoteEndpointConfig.walletNetwork` allow-list | drivechain.dev/config |
| fork height **973,728** | `NetworkRegistry.forkHeight` fallback; config `fork_height` wins | node `consensus.EcashHeight` |
| replay marker **`499_999_998`** (`LOCKTIME_THRESHOLD - 2`) | `NetworkRegistry.replayProtectionLockHeight`, compiled | node `IsFinalTx`; the config's new `replay_lock_time` field is NOT read (unsigned) |
| `OP_DRIVECHAIN` = **NOP8 (0xb7)** | `Drivechain.opcode` | node `script.h` |
| magic `eca5dcb7`, HRP `bc`, prefixes = Bitcoin | BDK `Network.bitcoin`, coin-type `0'`, ECX/szat | node `chainparams.cpp` |
| chip = the eCash brand **amber**; alphanet moved to **slate** | `NetworkChipStyle`, `netEcashLegacy` colorset | design (amber now means real ECX) |
| real money: `isMainnet == true` | extra send confirm + warnings ("Real eCash") | §2 |
| bundled endpoints `esplora.ecash.ninja` / `explorer.ecash.ninja` / `seed.ecash.eu.com/enforcer` | offline fallback ONLY — unverified pattern guesses | config overrides them |

**The two gates (`EcashMainnetLaunch`, WalletService):**
1. **Offered** — since 1.4.6 build 44 (2026-10-29) **compiled on** (`EcashMainnetLaunch.offeredInThisBuild`):
   the entry was published 2026-10-26, and gating the picker on a successful fetch left a launch whose
   first fetch failed or was throttled with no eCash mainnet until a later resume (the Android 1.4.6
   report). builds 41–43 still open the gate remotely — a backend for `.ecashMainnet`
   (`WalletManager.hasRemoteBackendDefault`) — which is kept as the second half of `isOffered`.
2. **Default** — **since 1.4.6 build 44 (2026-10-29) `WalletNetwork.currentEcash` IS the real fork,
   unconditionally, and it is first in the picker** (Jake: "no need to wait for fork on that"). Until
   then it stayed betanet until the chain was observed at or past the mainnet entry's `fork_height`.
   That observation still runs — `ForkWatch` (app) asks `/blocks/tip/height` on the mainnet entry's
   Esplora (remote, else the bundled `esplora.ecash.ninja`), then Bitcoin's, on every launch/resume,
   and latches `EcashMainnetLaunch.isDefault` — but the latch now steers nothing; it is the app's
   record that the fork has happened. Betanet's tip is never consulted (it is already past 973,728 on
   its own chain).

**Investor claims (2026-10-29):** "Claim your ECX" follows the **selected wallet's** eCash chain —
betanet wallet → betanet, mainnet wallet → mainnet — and anything else (Bitcoin/Signet/Thunder/none)
→ mainnet (`ClaimNetwork.target`). It does NOT use `currentEcash`, so a claim from a mainnet wallet in
the hours before the fork still lands on mainnet. The Dashboard moved to mainnet the same day
(`docs/dashboard-plan.md` §11).

**Still open:** Thunder on mainnet (`.thunder` is wired to betanet's index; needs its own case +
index URL, and the config carries nothing about Thunder — §1 table); a fiat price provider for real
ECX (`PriceProviderRegistry`, product choice); sidechain deposits on real money stay behind the
on-chain proof (§2); migration nudge "open this betanet wallet on eCash" (§4); alphanet is DONE —
retired from `selectable` 2026-10-26, and **betanet + Thunder betanet followed 2026-10-30** (cases
kept for existing wallets, which still load/sync/send; no new creation, import, or copy-to-network;
Settings → Network keeps a retired chain's endpoint row while a wallet is still on it).

---

The original analysis follows.

Built from a sweep of the code for every per-network decision (every `switch` on `WalletNetwork`,
every betanet URL / height / id), plus the upstream enforcer and BitWindow sources.

---

## 0. Fix first, and ship early: the config would silently remap alphanet ✅ FIXED 2026-09-29 (ship it)

> **Fixed, not yet released.** `walletNetwork` is now an explicit id allow-list (`bitcoin`,
> `signet`, `alphanet`, `betanet`, legacy `drynet*`), and unknown ids are ignored. Tests in
> `RemoteEndpointConfigTests` put the real fork FIRST in the config under `ecash` / `ecx` / `mainnet` /
> `ecash-mainnet` / `ecashMain` and check that nothing reaches alphanet or betanet; they fail
> against the old mapping (verified). **It only protects users once it's installed, so it needs to
> go out in a release well before the fork.** When the real fork's case is added, add its id to the
> allow-list in the same change. What follows is the original analysis.

`RemoteEndpointConfig.RemoteNetwork.walletNetwork` (`Config/RemoteEndpointConfig.swift`) maps a
config entry to a network. Two of its paths land on `.ecash`, **which is alphanet**:

1. `WalletNetwork(rawValue: id)`: `.ecash`'s raw value is `"ecash"`, so a config entry with
   `id: "ecash"` maps to alphanet.
2. The fallback: `family == "ecash"` with an unrecognised id maps to `.ecash`.

If L2L publishes the real fork as `"ecash"`, `"ecx"`, `"mainnet"` or any other new eCash-family id,
**every installed copy of the app points its alphanet wallets at the real fork's backends and fork
height**. Existing wallets would sync against the wrong chain, and split-coins would classify
against the wrong boundary. It doesn't need a new app release to trigger; publishing the config
entry is enough.

**Do now, in the next release, so the fix is installed before the fork:**
- Map `.ecash` only from `id == "alphanet"` (and the historical `drynet*` ids). Drop the bare
  `family: "ecash"` fallback, and don't let the raw value `"ecash"` match. An unknown eCash-family
  id should map to **nil** (ignored), which is what the "unknown entries are skipped" comment
  promises.
- Tests: `id: "ecash"`, `id: "mainnet", family: "ecash"` and `id: "ecx", family: "ecash"` all
  resolve to nil in a build that doesn't know the real fork.
- Tell L2L the ids we match on, and ask what id the real fork will use (§6 Q1).

## 1. Add a new network case. Never repurpose an old one

A wallet's network is fixed at creation and persisted as `WalletNetwork.rawValue` (and enforced by
BDK's `check_network`). Pointing `.ecashBeta` at the real fork would silently move every betanet
wallet onto real money. So: **a new case**, e.g. `case ecashMain` with raw value `"ecash-main"`
(anything not already used; `"ecash"` is taken by alphanet).

Adding it makes the compiler list most of the work, because every per-network decision is an
exhaustive `switch` on purpose:

| Where | Decision for the real fork | Source of truth |
|---|---|---|
| `NetworkRegistry.bundledParams` (WalletService) | Esplora/Electrum default, explorer template, unit `ECX`, sub-unit `szat`, display name | config + L2L |
| `NetworkRegistry` fork height | **964,000**? (CLAUDE.md §1 says activation at 964,000; the config's `fork_height` wins) | config `fork_height` |
| `NetworkRegistry` nLockTime replay marker | **`499_999_998`**: one lower than the test forks' `499_999_999` (`LOCKTIME_THRESHOLD - 1`). Set it in `replayProtectionLockHeight(for:)`, and update `docs/coin-splitting.md` §2 | L2L (decided) |
| `BDKSeam.network` | `Network.bitcoin` (eCash = Bitcoin params, `docs/key-derivation.md`) | settled |
| `WalletNetwork.keyFamily` / `sharesKeys` | same family as Bitcoin + the test forks (coin-type `0'`) | settled |
| `WalletNetwork.supportsCoinSplit` | **true**: this is the chain where splitting real coins matters most | settled |
| `WalletNetwork.selectable` | add; decide whether alphanet/betanet stay creatable | product |
| `WalletNetwork.currentEcash` | point at the new case, so new wallets, imports and claims go to real ECX | the switch-over itself |
| `Drivechain.opcode(for:)` (WalletService) | `0xb4` (NOP5) or `0xb7` (NOP8)? **Not decided upstream**: the enforcer has no real-fork preset yet, only a `--op-drivechain` flag. Betanet trialled NOP8 "at mainnet scale". **Confirm; never guess.** A wrong byte makes deposits anyone-can-spend | L2L / enforcer preset |
| `EnforcerEndpointRegistry` | `https://seed.ecash.eu.com/enforcer` is BitWindow's default for real ECX (not live as of 2026-09-29) | config `services.enforcer.url` |
| `CoinNewsAvailability` / `CoinNewsEndpointRegistry` | real-fork CoinNews indexer? | config |
| `FaucetRegistry` | **nil**: no faucet on real money | settled |
| `PriceProviderRegistry` | ✅ eCash.com price API `dev.ecash.com/price` (keyless, USD, volume-weighted), 2026-11-09 — was the wECX Orca pool via GeckoTerminal 2026-11-05 | done |
| `NetworkChipStyle` + a colorset | the real fork's chip colour. It must read as *real money* and never be confused with the test forks' teal | design |
| `PaymentLink` wrong-network copy | covered by the `.ecash, .ecashBeta` group; add the new case | trivial |
| `RemoteEndpointConfig.walletNetwork` | map the real fork's config `id` to the new case (after §0) | config id |
| Thunder (`.thunder`, `NetworkRegistry`) | Thunder is hard-wired to the **betanet** index (`seed.beta.ecash.eu.com/thunder`). Real-fork Thunder needs its own index, and probably its own network case for the same persisted-rawValue reason | L2L |

## 2. Real money: treat it like Bitcoin mainnet

Golden Rules §4/§6 already require this for Bitcoin; the real fork gets the same treatment:
- The extra send confirmation and real-money warnings that `.bitcoin` has.
- **Never** auto-select it for anything irreversible.
- Its own unmistakable chip colour (above).
- Sidechain deposits on it: the full shape validator and on-chain proof
  (`docs/sidechain-deposits.md` §5, §7.6) before the feature is enabled there.

## 3. Sidechains specifically

What already carries over, and what doesn't:
- ✅ **Enforcer client, list and detail screens, Activity deposit labels** are all per-network
  through `EnforcerEndpointRegistry` and `Drivechain.opcode(for:)`. They turn on for the real fork
  when those two return values for it. No screen code changes.
- ✅ **Sidechain names** are cached per network (`SidechainNameCache`), so betanet's list never
  labels a real-fork deposit.
- ⚠️ **The opcode** (above) is the one value that must be confirmed, not inferred.
- ⚠️ **Hosted enforcer:** confirm L2L will run a public one for the real fork (the betanet one is
  what BitWindow's light mode uses) and whether it's rate-limited for mobile clients.
- ⚠️ **Alphanet's host already serves betanet's data** (`docs/sidechain-deposits.md` §3). Check that
  the real fork's host serves the real fork on day one (`GetChainInfo.activationHeight` must equal
  the real fork height). That's a quick curl, and it's worth making an automated check.

## 4. Existing test-fork wallets

- Alphanet and betanet wallets keep working as long as their backends are up; the cases stay (the
  raw values are persisted). When L2L turns a test fork off, its wallets show a sync error, not
  lost funds. They were test coins.
- **Same seed, real coins:** every eCash generation derives identical addresses from one seed
  (coin-type `0'`, `bc`). A user's betanet wallet's seed **is** their real-ECX wallet's seed.
  "Copy wallet to network" (`docs/copy-wallet-to-network.md`) already exists; offer it as
  "Open this wallet on real eCash" rather than asking users to re-import.
- The alphanet burn credit is paid on real ECX (`docs/alphanet-burn.md`), and copy-to-network is how
  users reach it.
- Once a test fork is gone, hide it from `selectable` (keep the case, so the rawValue still resolves).

## 5. Order of operations

1. **Now:** §0, the config remap fix, released well before the fork so it's installed.
2. **When L2L publishes parameters** (id, backends, fork height, opcode, enforcer URL): add the case
   (§1), wire everything the compiler flags, and keep it **not selectable** and **not
   `currentEcash`** yet. Ship.
3. **At the fork:** publish the config entry, verify the backends and enforcer serve the real chain
   (§3 curl), then flip `currentEcash` + `selectable` (a small release), or gate both on a config
   flag so the flip needs no release. In the same config publish, point the **Dashboard** at mainnet:
   top-level `"dashboard": {"network_id": "<mainnet id>", "display_name": "Mainnet", "explorer_url":
   "<mainnet explorer, mempool-style /api>", "releases_channel": "<releases.ecash.com channel>"}`
   (`docs/dashboard-plan.md` §4.6). No release needed; until it's set the Dashboard stays on betanet.
4. **After:** migration nudges (§4), ~~retire test forks from `selectable`~~ (DONE 2026-10-30), enable
   sidechain deposits on the real fork only after the on-chain proof.

## 6. Questions for L2L

1. The real fork's config `id` and `display_name`.
2. Its `OP_DRIVECHAIN` opcode (NOP5 or NOP8).
3. ~~Fork height: 964,000 (CLAUDE.md §1), or has it moved?~~ Answered: 973,728 (node `consensus.EcashHeight`).
4. ~~The nLockTime replay-protection marker.~~ Decided: `499_999_998` (one below the test forks).
5. Hosted enforcer, Esplora, Electrum, explorer and CoinNews URLs; is the enforcer public for
   mobile use?
6. Real-fork Thunder: index URL, and whether its addresses and keys differ from betanet Thunder's.
7. When are alphanet and betanet shut down?
