# Moving to the real eCash fork

**Status:** 📋 CHECKLIST — written 2026-09-29, ahead of the real fork (expected within ~a month).
Alphanet and betanet are test generations that will be phased out; the real fork is the chain that
holds real ECX. This is what has to change in the app, and in what order.

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
| `NetworkRegistry` nLockTime replay marker | same `499_999_999` as the test forks? | L2L |
| `BDKSeam.network` | `Network.bitcoin` (eCash = Bitcoin params, `docs/key-derivation.md`) | settled |
| `WalletNetwork.keyFamily` / `sharesKeys` | same family as Bitcoin + the test forks (coin-type `0'`) | settled |
| `WalletNetwork.supportsCoinSplit` | **true**: this is the chain where splitting real coins matters most | settled |
| `WalletNetwork.selectable` | add; decide whether alphanet/betanet stay creatable | product |
| `WalletNetwork.currentEcash` | point at the new case, so new wallets, imports and claims go to real ECX | the switch-over itself |
| `Drivechain.opcode(for:)` (WalletService) | `0xb4` (NOP5) or `0xb7` (NOP8)? **Not decided upstream**: the enforcer has no real-fork preset yet, only a `--op-drivechain` flag. Betanet trialled NOP8 "at mainnet scale". **Confirm; never guess.** A wrong byte makes deposits anyone-can-spend | L2L / enforcer preset |
| `EnforcerEndpointRegistry` | `https://seed.ecash.eu.com/enforcer` is BitWindow's default for real ECX (not live as of 2026-09-29) | config `services.enforcer.url` |
| `CoinNewsAvailability` / `CoinNewsEndpointRegistry` | real-fork CoinNews indexer? | config |
| `FaucetRegistry` | **nil**: no faucet on real money | settled |
| `PriceProviderRegistry` | a real ECX price feed, once one exists | product |
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
   flag so the flip needs no release.
4. **After:** migration nudges (§4), retire test forks from `selectable`, enable sidechain deposits
   on the real fork only after the on-chain proof.

## 6. Questions for L2L

1. The real fork's config `id` and `display_name`.
2. Its `OP_DRIVECHAIN` opcode (NOP5 or NOP8).
3. Fork height: 964,000 (CLAUDE.md §1), or has it moved?
4. The nLockTime replay-protection marker.
5. Hosted enforcer, Esplora, Electrum, explorer and CoinNews URLs; is the enforcer public for
   mobile use?
6. Real-fork Thunder: index URL, and whether its addresses and keys differ from betanet Thunder's.
7. When are alphanet and betanet shut down?
