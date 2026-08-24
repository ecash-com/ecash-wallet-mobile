# Coin splitting — how we detect and separate shared coins

**Status:** 🟢 BUILT. Splitting proven on-chain (drynet3, 2026-07-28); the Bitcoin-backed detection
check shipped 2026-08-24. This is the app's most consequential money feature — read §4 before
changing any of it.

Related: `docs/key-derivation.md` (eCash = Bitcoin params — the root cause), CLAUDE.md §6
(replay protection) and §9 (Split coins).

---

## 1. The problem

eCash forked from Bitcoin and shares its history up to the fork block. It is byte-identical —
same address format, same `bc` HRP, same coin-type `0'` — so a coin that existed before the fork is
literally the **same `txid:vout` on both chains**. One coin, two ledgers.

Spend it with an ordinary transaction and that transaction is valid on *both* chains. Anyone can
rebroadcast it on the other one, and your BTC moves along with your ECX.

## 2. What splitting does

Drain the wallet's spendable balance to a **fresh address of the same wallet**, in a transaction
Bitcoin will not accept:

```swift
nLockTime = 499_999_999          // LOCKTIME_THRESHOLD - 1
nSequence = 0xFFFF_FFFD          // non-final on every input
```

eCash's patched consensus treats that locktime as *final*; stock Bitcoin Core reads it as a height
~500,000,000 (~9,500 years out) and rejects the transaction as non-final. Both halves are required —
Bitcoin only *enforces* locktime when at least one input is non-final, so with all-final inputs the
marker is ignored and the transaction replays anyway.

Afterwards the chains hold genuinely separate coins. Only eCash moves; the Bitcoin UTXOs stay
untouched, and the user pays only an eCash fee. `NetworkRegistry.replayProtectionLockHeight` returns
nil for Bitcoin and Signet, where stamping it would make transactions unminable.

**Note the asymmetry:** this protects eCash → Bitcoin only. An ordinary Bitcoin transaction
(`nLockTime = 0`) is perfectly valid on eCash, so *spending BTC can still replay onto eCash* until
the coins are split. That's the whole reason the feature exists.

## 3. Detection — two steps

### Step 1: block height (free, every sync)

A coin confirmed **below** the network's fork height predates the split, so it's shared. Runs on
every sync, costs nothing, and drives the Home nudge and the Settings row.

Fork height comes from the remote config (`WalletManager.effectiveForkHeight`), because it moves per
dry-run chain — alphanet **963,648**, drynet4 961,632 — and pinning it in the binary would
misclassify every coin confirmed between two heights after a rollover.

### Step 2: ask Bitcoin (on demand)

**Settings → Check for splittable coins.** For each spendable coin we ask a Bitcoin backend about
that exact outpoint:

| Bitcoin's answer | Verdict |
|---|---|
| Doesn't know the transaction | eCash-only → **chain-specific** |
| Knows it, output **unspent** | live on both chains → **needs splitting** |
| Knows it, output **already spent** | a replay would be a double-spend → **separated** |

On demand rather than automatic: it's a request per coin against a chain the wallet otherwise never
contacts, and it hands that operator the wallet's addresses.

### Three states, not two

`needsSplit` / `unverified` / safe. **`unverified` deliberately does not drive the Home nudge**, or
every wallet nags forever — it's what the check resolves. Coins we couldn't reach a backend for stay
unverified; "we couldn't check" and "you're fine" must never be the same answer on a money screen.

## 4. Why height alone is unsound — read this before "simplifying"

**eCash's replay marker is permissive, not mandatory.** Fork commit `8b8a68d2` is a one-line change
in `tx_verify.cpp` that makes the magic nLockTime *count as final*. Its own message says it "**lets**
a transaction confirm on this chain while being unable to replay onto Bitcoin." Nothing requires it.

So eCash still accepts ordinary Bitcoin-valid transactions. Spend an eCash coin from Sparrow,
Electrum, a hardware wallet or an exchange, and that transaction is valid on Bitcoin too — its
outputs then exist on **both chains at post-fork heights**.

Height therefore fails in both directions:

- **Under-reports (dangerous).** A post-fork coin from a non-protected spend is shared, but height
  calls it safe. The nudge disappears, the user believes they're separated, and their next spend
  moves their BTC. This is why the Bitcoin check exists.
- **Over-reports.** A pre-fork coin already spent on Bitcoin can't be replayed onto, so it needs no
  split — but height insists it does.

The correct invariant is inductive, not a height comparison:

> A UTXO is chain-specific **iff the transaction that created it could not appear on the other
> chain** — it carried the marker, or every one of its inputs was already chain-specific.

Height is only a proxy, exact only for coins whose entire post-fork history ran through *our* wallet.

## 5. The Esplora trap (cost us a real bug)

`/tx/{txid}/outspend/{vout}` **does not 404 for a transaction that doesn't exist.** It answers from
the spend index and returns `200 {"spent":false}` for any txid, real or not. Verified against
`esplora.mainnet.drivechain.info`:

```
/tx/{fake}/outspend/0   ->  200 {"spent":false}
/tx/{fake}              ->  404 Transaction not found
```

The first implementation read a 404 on `outspend` as "Bitcoin never saw it" — which never happens —
so *every eCash-only coin* came back `spent:false` and was classified **shared**, including the fresh
output a split had just created. The nudge never cleared.

**Ask `/tx/{txid}` first** (existence), and only then `/outspend` (spentness). It's also cheaper: an
eCash-only coin resolves in one request. The decision lives in a pure
`SplitCheckService.verdict(txExistsOnBitcoin:spent:)` with tests for all four cases, precisely
because the I/O is what kept the wrong logic untested.

## 6. Endpoint requirements

The check speaks **HTTP only**, so it needs an **Esplora** endpoint for Bitcoin — which is *not* the
same as Bitcoin's primary backend. `resolvedPrimaryBackends()` keeps one backend per network by
priority and discards the rest, so the Esplora URL vanished whenever Electrum outranked it.

Esplora URLs are therefore harvested separately (`resolvedEsploraEndpoints()`) and stored per network
via `RemoteServiceOverrides.setEsploraURL`. "Which backend syncs this network" and "where can we ask
an HTTP question about an outpoint" are different jobs and must not share an answer.

The eCash side is irrelevant here — an alphanet wallet on Electrum is fine, since the eCash backend
only supplies the local UTXO list.

## 7. Caching

`SplitCheckStore`, keyed by `walletId` (Golden Rule §5 — purged on wallet removal).

- **Only decided answers are cached.** `.unknown` describes our failure to reach a backend, not a
  property of the coin; persisting it would make an outage look like a settled fact.
- **Merges rather than replaces**, so a partial check (some outpoints timed out) can't erase what
  earlier runs established.
- **Stale in the harmless direction only.** The one transition a cached verdict can miss is
  `shared → chainSpecific`, when someone later spends the Bitcoin side — which only makes the coin
  safer, so we'd suggest an unnecessary split rather than hide a needed one.
- The key carries a version (`…v2`); bump it whenever a checker bug invalidates stored verdicts.

## 8. Safety properties

- The check is **read-only** — HTTP GETs. No key is touched, nothing is signed or broadcast, so it
  cannot move BTC.
- Splitting is **eCash-only** and pays a fresh address of the **same wallet**, so the user keeps
  control on both chains.
- Results are **point-in-time**: someone can spend the Bitcoin side afterwards.
- The check **reveals the wallet's addresses to a Bitcoin backend**. Same addresses either chain, but
  a different operator learning them — which is why it's a button, not automatic.

## 9. Known gaps

1. **The bundled fallback is stale.** `NetworkRegistry` still hardcodes drynet3 —
   `defaultBackend: esplora.drynet3.drivechain.dev`, `displayName: "Drynet3"`, `forkHeight 957_600`
   — while the config has rolled to alphanet (963,648). Harmless while the remote fetch succeeds
   (remote wins), but an offline first launch classifies against a height ~6,000 blocks wrong.
2. **No batching.** One or two requests per coin; a wallet with hundreds of UTXOs makes a lot of
   them. `/address/{addr}/utxo` intersected against our set would be O(addresses) instead.
3. **No automatic re-check** after a split, though the summary is recomputed from cache.

## 10. Where the code lives

| Concern | File |
|---|---|
| Classification (pure, tested) | `Packages/WalletService/…/Models.swift` — `SplitSummary.classify` |
| Candidates + summary | `…/WalletEngine.swift` — `splitSummary`, `splitCandidates` |
| The split transaction | `…/WalletEngine.swift` — `splitToSelf`, `applyingReplayProtection` |
| Replay constants | `…/NetworkRegistry.swift` — `replayProtectionLockHeight`, `replayProtectionSequence` |
| Bitcoin check | `Sources/ECashWalletMobile/Split/SplitCheckService.swift` |
| Verdict cache | `Sources/ECashWalletMobile/Split/SplitCheckStore.swift` |
| Orchestration | `AppState.checkSplittableCoins()` |
| UI | `SettingsScreen` (check row + Split coins), Home nudge, `SplitCoinsView` |

Tests: `SplitSummaryTests` (classification, both override directions), `SplitCheckTests` (the four
verdicts), `RemoteEndpointConfigTests` (Esplora survives Electrum winning priority).
