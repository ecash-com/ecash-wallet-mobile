# Transaction-graph deniability — automated self-spend "hops" (churning)

> **Status:** PLANNED / post-v1 — **not built**. Scopes a BitWindow-style "automatic denial"
> feature: bounce coins through scheduled self-spends to muddy their on-chain lineage. Built on
> `docs/coin-control.md` (this is scheduled coin-control self-spends) and the broadcast path
> (`apply-broadcast-tx-to-wallet`). **Distinct** from `docs/plausible-deniability.md`, which is
> seed/passphrase (hidden-wallet) deniability — a completely different mechanism.

## 0. Two unrelated "deniability" features — don't conflate

| | `plausible-deniability.md` | `transaction-deniability.md` (this) |
|---|---|---|
| Secret | a BIP39 **passphrase** | none — it's just transactions |
| Hides | the **existence** of a hidden wallet on your device | the **lineage** of coins on-chain |
| Mechanism | derive a separate wallet from seed+passphrase | repeated **self-spends** with random delays |
| Defends against | device seizure / coercion ("$5 wrench") | chain-analysis taint/source-of-funds tracing |

## 1. What & why

Let a user "deny" a coin's history by sending it to themselves repeatedly ("**hops**") with random
timing and varied amounts, so an observer can't deterministically link the resulting UTXO back to
where it came from. Mirrors BitWindow's "Automatic Denial":

- **Random delays** between hops (up to N min / hr / days) → breaks "moved right after receiving"
  timing correlation.
- **Hop count** ("stop after K hops") → how many times each coin bounces.
- **Target output sizes** (optional) → split/recombine onto common denominations instead of a
  unique fingerprint amount.
- **Presets:** Normal vs. Paranoid (paranoid = more hops, longer/more random delays, more splitting).

## 2. Threat model — what it does and does NOT do (read before building)

This is **deniability, not unlinkability.** The UI copy must not oversell it — overselling privacy
in a wallet gets people hurt.

**Genuinely helps:**
- Timing decorrelation (random delays).
- Amount-fingerprint resistance (target sizes).
- Coin-age / "taint" / blacklist-scoring heuristics — after K hops with delays you can plausibly
  claim "you can't prove this is that coin." Useful against source-of-funds correlation and naive or
  deterministic tracing.

**Does NOT do:**
- It does **not** break the common-input-ownership heuristic. These are *self*-spends, so a competent
  analyst clusters the hops as the same entity (especially via change outputs).
- It is **not CoinJoin / PayJoin** — no other participants, so **no anonymity set** to hide in.
  Strong unlinkability requires multi-party constructions this feature is not.

Frame it as "muddy the graph / reset taint," never as "make my coins private."

## 3. Mechanism — it's scheduled coin-control self-spends

Each hop is an ordinary transaction, built with the same primitives as `docs/coin-control.md`:

1. Select the specific coin: `TxBuilder.addUtxo(outpoint)` + `manuallySelectedOnly()`.
2. Send to a **fresh address this wallet owns** (new external/internal address each hop — never
   reuse, or you defeat the point).
3. Optionally split into target-size outputs (`addRecipient` × N) to hit common denominations;
   otherwise `drainTo(ownAddress)` for a single output (minus fee).
4. Sign → broadcast → fold into the wallet graph (`applyBroadcast`, already done for send/publish so
   the next hop doesn't reselect a spent coin).
5. Decrement hops-remaining; schedule the next hop at `now + random(0, maxDelay)`.

BDK needs **nothing new** — this is consolidation's cousin (self-spend), just repeated, delayed, and
to fresh addresses. No forked binding.

## 4. Data model — "denial jobs" (app-owned metadata)

BDK stores none of this; it lives in `WalletStore` (JSON), namespaced per (wallet × network), like
coin-control freeze/labels:

```
DenialJob {
  id: String                 // "Denial ID" column
  outpoint: String           // txid:vout currently being churned (updates each hop)
  hopsRemaining: Int
  hopsDone: Int              // "Hops" column
  maxDelaySeconds: Int64     // upper bound for the random delay
  targetSizesSats: [Int64]   // optional denominations
  nextExecutionEpoch: Int64? // "Next Execution" column; nil = idle/done
  preset: normal | paranoid
}
```

- Signed-int-only on anything that reaches the bridged surface (no `UInt` properties — JNI
  inline-class mangling crash, CLAUDE.md §5). Convert at the engine boundary.
- A job follows the coin: after a hop, `outpoint` becomes the new self-spend output.
- Purged with the wallet; survives restarts so a slow schedule resumes.

## 5. The scheduler — and the mobile blocker (the hard part)

BitWindow is **desktop**, so it runs a churn scheduler continuously for hours/days. A **mobile**
wallet cannot reliably do that:

- **iOS:** `BGProcessingTask` / `BGAppRefreshTask` are opportunistic and OS-throttled — no guarantee
  a hop fires at a precise future time while the app is closed.
- **Android:** `WorkManager` is more dependable but still subject to Doze / battery optimization for
  multi-hour/day schedules.

**Design consequence — be honest in the UI:**
- Churn aggressively **while the app is foreground** (a due job fires on the next sync tick / a timer).
- **Best-effort background** hops via `BGProcessingTask` (iOS) / `WorkManager` (Android) when the OS
  grants a window.
- A scheduled hop **may slip** until the user next opens the app; show "Next Execution" as a target,
  not a promise, and surface "N hops pending — open the app to continue." Don't imply a daemon.
- No always-on companion exists today; a true 24/7 churner would need one (out of scope).

## 6. Cost

Every hop is an on-chain tx → a fee. **Negligible on L2L Signet** (the right place to build/test
this), **real money on Bitcoin mainnet** — K hops × M UTXOs compounds. The "Start" screen must show
an **estimated total fee** across all planned hops before the user commits, and respect the same
low-fee-when-cheap logic as consolidation.

## 7. UX surfaces (mirroring the reference)

- **UTXO list with denial info:** columns Denial ID · Hops · UTXO · Amount · Next Execution · a
  per-row **Deny** action. (Extends the coin-control UTXO list.)
- **Deny All** — start jobs on every UTXO; **Consolidate** sits alongside (the inverse operation —
  see coin-control §5).
- **Start Automatic Denial** sheet: max random delay (min/hr/day), stop-after-K-hops, optional
  target sizes (+ Add target size), Normal / Paranoid presets, estimated total fee, Start / Cancel.
- **Network chip / mainnet treatment** unchanged; each hop broadcast still honors the broadcast
  confirmation model. Consider an explicit mainnet warning given the fee compounding.

## 8. Architecture fit

- **Watch-only build holds** — hop construction uses public data; the mnemonic loads only at each
  hop's `sign` step (same seam as a normal send). No key-storage change.
- **Per (wallet × network)** isolation unchanged.
- **Engine additions:** a `selfSpend(outpoint:, targetSizes:, feeRate:)` wrapper (fresh own address,
  split, broadcast, applyBroadcast) + a job runner in the app layer that the foreground sync loop and
  the background task both drive.

## 9. Open questions / risks

- **Privacy honesty / liability:** exact wording so users don't mistake this for CoinJoin-grade
  privacy. Possibly a one-time explainer before first use.
- **Background reliability:** how hard to lean on `BGProcessingTask`/`WorkManager` vs. just
  "continues when you open the app." Set expectations in copy.
- **Fee spikes:** pause/skip a hop if the fee rate is above a user ceiling? (Don't churn at a loss.)
- **Address-gap pressure:** many hops to fresh addresses advance the derivation index fast — make
  sure sync's revealed-spks model keeps up (see `sync-scan-model-and-receive-discipline`).
- **Dust / uneconomical coins:** churning a coin worth less than its hop fee is pure loss — flag or
  exclude (ties into coin-control's economical-coin check).
- **Interaction with the 0-conf spend policy:** a hop's output is our own unconfirmed change →
  already treated as spendable, so back-to-back hops work; confirm the timing model doesn't starve
  on unconfirmed parents (long chains of unconfirmed self-spends can hit mempool ancestor limits).
</content>
