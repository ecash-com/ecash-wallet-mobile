# Sidechains in the wallet — UI design

**Status:** 🟡 PARTLY BUILT — 2026-09-29. Built: §6 steps 1–4 (view model, list + detail screens,
icon, Activity deposit labels), verified live on iOS + Android against betanet. Deposits (§3c) are
now BUILT as a dedicated flow pushed from the detail screen ("Deposit to Thunder"), not yet proven
on-chain; `s9_` paste routing in Send and deposit-to-self (§5) are not built. Real-fork transition: `docs/real-ecash-fork-transition.md`.
Originally a design-only doc. The data layer it sits on **is** built:
`EnforcerClient` / `EnforcerFetching` / `EnforcerEndpointRegistry` (`Sources/ECashWalletMobile/Drivechain/`),
live-verified on betanet. Deposit mechanics and the safety rules the UI enforces are in
`docs/sidechain-deposits.md`; this doc is where they surface.

Principles carried over from CLAUDE.md: native-first chrome, network chip on every money surface
(§2.6), explicit confirmation of recipient, amount, fee **and network** (§2.7), no SF Symbols (§8).

---

## 1. The model users need

Three facts, in the order a user meets them:

1. **Sidechains belong to a mainchain network.** Betanet has eight; Bitcoin has none. So sidechains
   appear *inside* an eCash wallet's context, never as a global list.
2. **Depositing is sending.** Coins leave the wallet in an ordinary mainchain transaction. It goes
   through the same review, auth gate and broadcast as a send, because that's what it is.
3. **Coming back is slow.** A withdrawal waits for months of miner votes (§4). Users must learn that
   *before* they deposit, not after.

The words BIP300 uses (M5, CTIP, slot, treasury, bundle) stay out of the UI, with one exception:
**slot number** is shown small, because it's the only unambiguous identity two sidechains with
similar names have.

| Protocol term | UI term |
|---|---|
| Sidechain | Sidechain |
| M5 deposit | Deposit |
| Treasury / CTIP value | "Locked in escrow" (BitWindow's word too) |
| Slot | "Slot 9" (secondary text only) |
| Proposal | "Being voted in" |
| Withdrawal bundle (M6) | "Withdrawal batch" |

## 2. Where it lives

**Recommendation: a "Sidechains" entry on Home, not a new tab.**

- Tabs are Wallet / Activity / News / Settings. A fifth tab for something most users touch rarely
  crowds the bar on both platforms, and it would have to hide on Bitcoin and Signet, which makes the
  tab bar change shape between wallets. News already does that; doing it twice makes the app feel
  unstable.
- Home already hosts contextual, per-network affordances (the faucet button, the split-coins nudge).
  A sidechains row there follows the same pattern.
- The deposit action itself joins **Send**, because it is a send (§3).

Gate every sidechain surface on `EnforcerEndpointRegistry.isAvailable(on: wallet.network)`. That
means betanet only today; alphanet stays off while its host serves betanet's chain.

```
┌─────────────────────────────────┐
│  Savings  ▾         [Betanet]   │
│                                 │
│       12.50000000 ECX           │
│                                 │
│   [ Send ]        [ Receive ]   │
│                                 │
│  ┌───────────────────────────┐  │
│  │ ⎇  Sidechains          8 ›│  │  ← only where an enforcer exists
│  └───────────────────────────┘  │
│                                 │
│  Recent activity                │
│  ↗ Deposit to Thunder  -0.1 ECX │
│  ↙ Received            +2.0 ECX │
└─────────────────────────────────┘
```

## 3. Screens

### 3a. Sidechains (list)

Reached from the Home row. One screen, two sections.

```
┌─────────────────────────────────┐
│ ‹  Sidechains        [Betanet]  │
│                                 │
│ ACTIVE                          │
│  Thunder                   Slot 9│
│  Large & growing blocksize…     │
│  5.19790000 ECX in escrow     › │
│ ─────────────────────────────── │
│  BitNames                  Slot 2│
│  Replace ICANN…                 │
│  2.44018653 ECX in escrow     › │
│ ─────────────────────────────── │
│  zSide                    Slot 98│
│  Private transactions           │
│  No deposits yet              › │
│ ─────────────────────────────── │
│  Slot 130                Slot 130│  ← no v0 declaration: named by slot
│ …                               │
│                                 │
│ BEING VOTED IN                  │
│  Solana                    Slot 8│
│  ▓▓▓▓▓▓▓▓░░  808 / 1,008 votes  │
│  Elements                 Slot 24│
│  ▓▓▓▓▓▓▓▓▓░  953 / 1,008 votes  │
└─────────────────────────────────┘
```

- Data: `sidechains()` + `treasury(slot:)` per row + `sidechainProposals()`. The vote threshold comes
  from `bip300Constants()` (1,008 for an unused slot, 13,150 for a used one), never hardcoded.
- Descriptions come from the enforcer (the on-chain declaration). `drivechain.dev/config`'s
  `sidechains[]` can *add* presentation (a longer blurb, an icon) keyed by slot, but it never decides
  what's listed: it lags the enforcer (it lists 1 sidechain for betanet; the enforcer reports 8).
- Proposals are informational and **not tappable into a deposit**. A deposit to a slot that isn't
  active loses the coins (`sidechain-deposits.md` §3a).
- Pull-to-refresh. Otherwise refetch when `chainTip()`'s hash changes, which is at most once a block.
- **Enforcer unreachable:** keep the last list visible with a "Couldn't update" footer, and disable
  deposits until a fresh read succeeds. Deposits never run on a cached list.

### 3b. Sidechain detail

```
┌─────────────────────────────────┐
│ ‹  Thunder                      │
│                                 │
│  A sidechain with a large &     │
│  growing blocksize, plus fraud  │
│  proofs.                        │
│                                 │
│  Slot            9              │
│  Active since    block 968,998  │
│  In escrow       5.19790000 ECX │
│                                 │
│  [      Deposit to Thunder    ] │
│  [      Open Thunder wallet   ] │  ← only if the user has one (§5)
│                                 │
│  WITHDRAWALS IN PROGRESS        │
│  Batch aa76…ced4                │
│  ▓░░░░░░░░░  121 / 13,150 votes │
│  About 3 months left to pass    │
└─────────────────────────────────┘
```

- The withdrawal section is the honest answer to "how long to get back out". It shows real batches
  and real vote counts from `withdrawalBundleProposals(slot:)`, which does more than any warning copy.
- "About N left" = `(threshold − votes)` blocks × 10 min, rounded coarsely ("about 3 months",
  "about 2 weeks"). It's an estimate, and the copy says so.

### 3c. Deposit = Send with a sidechain destination

The deposit is the Send flow with one new destination type. It inherits the auth gate, fee tiers,
nav lock, broadcast and `applyBroadcast` for free, and there's no second money path to keep safe.

**Entry points** (all land in the same flow):
1. "Deposit to Thunder" on the detail screen: Send opens with the sidechain preselected.
2. Send's destination picker gains a **"Sidechain…"** row next to "One of my wallets".
3. **Pasting or scanning an `s9_…` address in plain Send** switches to a Thunder deposit. Today that
   string is rejected as an invalid Bitcoin address. It's unambiguous, and it's what users will
   copy out of sidechain wallets.

**Destination step:**

```
┌─────────────────────────────────┐
│ ×  Deposit to Thunder  [Betanet]│
│                                 │
│  TO                             │
│  ┌───────────────────────────┐  │
│  │ My Thunder wallet       › │  │  ← §5
│  └───────────────────────────┘  │
│  ┌───────────────────────────┐  │
│  │ s9_8twUkpctzwgbjqi…_a1b2c3│  │  paste / scan
│  └───────────────────────────┘  │
│  ✓ Thunder address · checksum OK│
└─────────────────────────────────┘
```

Validation (from `sidechain-deposits.md` §2b), with inline messages:
- checksum wrong → "This address has a typo — check it and try again";
- slot mismatch (an `s2_…` BitNames address in a Thunder deposit) → "This is a BitNames address,
  not Thunder". **Never silently switch sidechains**;
- bare address with no `s9_` prefix → accepted only when the sidechain is already chosen.

**Review step** (Golden Rule §7, with the sidechain added):

```
┌─────────────────────────────────┐
│ ‹  Review deposit               │
│                                 │
│  From      Savings  [Betanet]   │
│  To        Thunder · Slot 9     │
│            8twUkpct…qWjrD9uk    │
│  Amount    0.10000000 ECX       │
│  Fee       0.00000450 ECX       │
│  Total     0.10000450 ECX       │
│                                 │
│  ⚠ Coins on Thunder come back   │
│    by withdrawal, which takes   │
│    about 3 months of miner      │
│    votes. Only deposit what you │
│    mean to use there.           │
│                                 │
│  [   Confirm deposit   ]        │  ← DeviceAuth, like Send
└─────────────────────────────────┘
```

- The warning's duration comes from `bip300Constants()`, not a string.
- The engine re-reads the treasury and runs the shape validator at confirm time. If the treasury
  moved (someone else deposited), rebuild once silently. If it moved again, say "Thunder was busy,
  try again", and never change the amount.

**Done:** "Deposit sent. It appears in your Thunder wallet once this transaction confirms." Plus a
link to the activity row.

### 3d. Activity

- Classifier: an output whose script is `<opcode> 01 <slot> 51` marks the tx as a deposit. That's
  local and exact, like `coinNewsKind`. Row: **"Deposit to Thunder"**, sidechain icon, amount = the
  deposit (treasury delta), not the whole tx.
- Detail sheet adds: sidechain + slot, destination address, and **credit status**. That status is
  Thunder only for now (`/deposit/{txid}` on its index): "Waiting for confirmation" → "Credited on
  Thunder". Other sidechains show only mainchain confirmations until they have an index we read.

## 4. Numbers the UI must not hardcode

| Shown | Source |
|---|---|
| Which sidechains exist / are depositable | `sidechains()` |
| Escrow amount | `treasury(slot:)?.valueSats` |
| Vote thresholds (slot activation, withdrawal) | `bip300Constants()` |
| Withdrawal time estimate | threshold − votes, × 10 min |
| Enforcer freshness | `chainTip()` vs the wallet backend's tip |

## 5. Deposit-to-self and the Thunder wallet

Thunder keys come from **the same BIP39 mnemonic** as the eCash wallet (ed25519, `m/1'/0'/0'/i'`,
`docs/thunder-sidechain-support.md`). Two consequences:

- **"My Thunder wallet" can mean this very seed.** The destination can be derived from the eCash
  wallet's own mnemonic, with no separate Thunder wallet needed.
- **But it needs the mnemonic.** ed25519 derivation is hardened-only, so there's no xpub to derive
  from, unlike our BIP84 watch-only model (CLAUDE.md §7). Producing that address reads the key
  material, so it goes behind the same `DeviceAuth` gate as signing. The derived *address* (public)
  can then be cached per wallet so later deposits don't re-prompt, the same approach as
  `ThunderAddressIndexStore`.

That means the "My Thunder wallet" row should offer:
1. **This wallet's Thunder account** (same seed; auth once to derive, then cached), and
2. any separate `.thunder` wallets in the manager, when Thunder is un-hidden from the pickers.

Open decision: once deposit-to-self exists, does a Thunder balance show *on the eCash wallet's
Home* (one seed, two chains), or only in a separate Thunder wallet? Showing it on Home is closer to
how people think ("my money"). It's also a bigger change to the one-wallet-one-network model, so
it's deferred until deposits work end to end.

## 6. Build order (UI)

1. `SidechainsViewModel` over `EnforcerFetching`, with mock-driven tests: list, proposals, stale /
   unreachable states, tip-hash refetch.
2. Sidechains list + detail (read-only). This is shippable on its own, because it shows real,
   live state and nothing can go wrong with money.
3. Material Symbols icon for sidechains (`account_tree` or `lan`), via the `.symbolset` workflow.
4. Activity classifier + row (read-only).
5. Deposit destination type in Send, `s9_` paste routing, review copy. Gated on the engine work in
   `sidechain-deposits.md` §7.3–4.
6. Thunder deposit-to-self (§5).

Steps 1–4 carry no money risk and can ship while the engine's output-ordering problem is solved.

## 7. Open questions

1. Home row vs a tab (§2): the recommendation is the Home row. Revisit if sidechains become central.
2. Should the Sidechains screen list sidechains the app **can't** do anything with yet (everything
   but Thunder has no wallet engine)? The recommendation is yes, since depositing works for all of
   them and a user may hold a BitNames wallet elsewhere, but lead with Thunder.
3. Thunder balance on the eCash Home (§5)?
4. Icon per sidechain: does `drivechain.dev/config` grow an `icon` field, or do we bundle a few?
