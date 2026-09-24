# Alphanet burn for real ECX — plan

> Status: **PLANNED, NOT BUILT (2026-09-24).** Researched against BitWindow
> (`LayerTwo-Labs/drivechain-frontends` @ `882de28`), which ships the feature today. The transaction
> format below is taken from BitWindow's code, so it is what L2L's claim scanner expects. **Open
> questions for L2L (§7) block the UI copy, not the engine work.** Companion feature:
> `docs/copy-wallet-to-network.md` — how the user reaches the credited ECX afterwards.

## 1. What it is

A user burns **alphanet** coins, and when the real eCash network launches, L2L credits them
**1/100 of the burned amount as real ECX**. The burn is an ordinary alphanet transaction with a fixed
shape; nothing on-chain pays the credit. L2L scans alphanet for burns and pays each one out of band
to the address the burn names.

**It pays real ECX, not betanet.** BitWindow's copy says "Burn … for real ECX" and "a claim of real
ECX", and its network config treats alphanet and betanet as separate test generations, with real ECX
on its own host (`seed.ecash.eu.com`). Confirm with L2L (§7 Q1) before we write any user-facing text.

## 2. The transaction (the protocol)

From `sidechain-orchestrator/wallet/ecx_burn.go` and `commands/wallet_burn_ecx.go`:

| output | value | script |
|---|---|---|
| burn | the burned amount `B` | P2PKH to `1BitcoinEaterAddressDontSendf59kuE` = `76a914759d6677091e973b9e9d99f19c68fbf43e3f05f988ac` |
| claim | `0` | `OP_RETURN <push: ASCII bytes of the claim address>` |
| change | any | back to the burning wallet (optional) |

Rules BitWindow enforces before it signs (`checkBurnPreview`), which we should match exactly:

- **Exactly one** burn output with value `B`, **exactly one** claim output with value 0, and nothing
  else except the wallet's own change.
- **Replay protection** is required: `nLockTime == 499_999_999` and no input at `SEQUENCE_FINAL`.
  Ours already does this for `.ecash` (`WalletEngine.applyingReplayProtection`: that lock time plus
  sequence `0xFFFFFFFD`), so it passes BitWindow's `replay.Protected` check unchanged.
- **Minimum** `B` = **100,000,000,000 sats = 1,000 alphanet coins** (a burn of exactly the minimum is
  accepted — BitWindow commit `9796be8f`).
- **Credit** = `ceil(B / 100)` ECX sats. 1,000 coins burned → 10 ECX.
- **Claim address**: the burning wallet's **first receive address (external index 0)**, written as
  its ASCII string (a `bc1q…` address is 42 bytes, well inside `OP_RETURN` limits). BitWindow's
  detector accepts any mainnet-format address in a single push **except P2PK**.

**Why the payout can't be redirected:** the claim address is inside the transaction the burner
signed. Changing it would invalidate the signature. L2L pays whatever address the burner committed
to.

**Why the credit shows up in the same wallet:** eCash uses Bitcoin's parameters on every generation
(coin-type `0'`, `bc` addresses; `docs/key-derivation.md`). The same seed gives the same index-0
address on alphanet and real ECX, so the credit lands in the wallet the user already holds. Getting
there is the companion feature.

## 3. How it maps onto our code

Everything needed already exists in `WalletService`; this is one new transaction shape, not new
engine work.

- **Engine:** add `WalletEngine.burn(amount:claimAddress:feeRate:)`. It is `send` (`addRecipient` to
  the burn script) plus `publishData`'s `addData` (the claim bytes) in **one** `TxBuilder`, with
  `applyingReplayProtection`, signed with the existing sign-on-demand closure, then `applyBroadcast`.
  Build the burn output from the fixed **script**, not by parsing the eater address, so a
  network/HRP mismatch can't change it.
- **Validate before signing**, a port of `checkBurnPreview`: walk the built PSBT's outputs and require
  exactly the shape in §2 (burn value == `B`, claim value 0, every other output is our change),
  replay protection present, and fee == inputs − outputs. On failure throw, never broadcast. Pure
  logic, so it's unit-testable against hand-built transactions.
- **Claim address:** external index 0 from the watch-only engine (BDK `peekAddress(external, 0)`).
  **Not** `nextUnusedAddress`: index 0 is fixed, so the claim never depends on how many addresses
  the wallet has handed out.
- **Manager (bridged):** `WalletManager.burnForECX(walletId:amountSats:feeRate:) async throws ->
  WalletTx`, plus a preview call returning the claim address, the credit and the exact fee (the
  confirm screen needs the real fee, as BitWindow waits for it). Bridge-safe types only: `Int64`
  sats, `String` address (CLAUDE.md §5).
- **Activity marking:** classify burns like CoinNews (`WalletTx.coinNewsKind`). Add a burn detector
  (positive output to the eater script + one valid non-P2PK claim push) and show the row as
  "Burned for ECX · credit X ECX" instead of "Sent". Same logic as BitWindow's `burnTransactionWarning`.

## 4. Who can use it

- **Network:** `.ecash` (alphanet) wallets **only**. Hide the entry point everywhere else, like
  BitWindow (which shows its card only when the network is alphanet). Gate it on a
  `WalletNetwork.supportsECXBurn` switch, exhaustive like `supportsCoinSplit`, not `== .ecash`
  checks (that pattern broke split-coins on betanet).
- **Wallet kind:** mnemonic wallets and WIF wallets. For a WIF wallet "index 0" is its single `1…`
  address, which also passes the detector (P2PKH, not P2PK). Thunder never.
- **Backed up (required, not a warning).** The credit is paid to an address only this seed can
  spend. A burn from a wallet whose phrase is lost burns the coins *and* forfeits the credit. Require
  `isBackedUp` and send the user to Backup first.
- **Balance:** spendable ≥ 1,000 coins + fee. Below that, show the minimum rather than an error on
  submit.

## 5. UI

Entry point: a row on the alphanet wallet (Settings → wallet, or a Home card like the split-coins
nudge, shown only when the balance clears the minimum). Flow:

1. **Amount**: sats/coins entry with a **Max** that leaves the fee, the minimum stated up front,
   live "You'll receive ≈ X ECX".
2. **Review**, covering everything BitWindow's preview shows: amount burned, "to the burn address
   (unspendable)", the claim address with "the first address of this wallet", credit in ECX, exact
   network fee, total, and **"You cannot reverse this burn."** Network chip (Golden Rule §6).
3. **Confirm**: goes through the same `DeviceAuth` gate as Send (`SendViewModel.authorize`) with the
   nav lock (`isSendingLocked`). A burn is irreversible, so the confirm should be at least as
   deliberate as a mainnet send; consider type-to-confirm.
4. **Done**: txid + explorer link, "Credit pending: X ECX, paid to this wallet when eCash
   launches", and a pointer to the companion feature.

## 6. Tests (CLAUDE.md §11)

- **Pure:** credit rounding (`ceil`, incl. exact multiples and `B % 100 == 1`), the minimum
  boundary, the shape validator accepting the good shape and rejecting every deviation (extra
  output, wrong value, value on the claim, two claims, missing replay lock, a final sequence, fee
  mismatch), claim-bytes encoding, the Activity detector (burn vs. ordinary send vs. CoinNews).
- **Cross-check against BitWindow:** hand a tx our engine built to BitWindow's decoder (or port its
  Go test vectors from `wallet/burn_psbt_test.go` / `commands/wallet_burn_ecx_test.go`) so both
  sides agree on what a valid burn is. This protects users' money: a burn L2L's scanner doesn't
  recognise destroys coins and pays nothing.
- **Integration (real BDK, sim + emulator):** build + validate a burn from a funded alphanet
  wallet without broadcasting; then **one real minimum burn on alphanet**, confirmed by Jake (§7
  Golden Rule), and checked in BitWindow's explorer, which labels it as a burn.

## 7. Open questions for L2L (block the copy, not the engine)

1. Is the credit paid on **real ECX** (as BitWindow says) or betanet? When?
2. Who scans and pays, and what gets a burn **rejected** (malformed claim, P2PK, after a cut-off)?
3. Is there a **deadline** or a **cap** on burns?
4. Is the **1,000-coin minimum** final?
5. Is the claim address required to be the wallet's **first** address, or does the scanner accept
   any address in the `OP_RETURN`? (BitWindow chooses index 0; its detector accepts any.) Our plan
   uses index 0 either way, but the answer decides whether an advanced "credit to a different
   address" option is ever safe to offer. Don't offer it until then.
