# Custom derivation on Import (Advanced) — plan

> Status: **PLAN / not started** (2026-07-17). Design agreed at "Option A" (script-type picker +
> account number). Not necessarily this milestone. This doc is the spec; keep it current if the
> design shifts (per CLAUDE.md).

## 1. Why (this is recovery-correctness, not a power-user toy)

eCash airdrops 1:1 to BTC holders, so the dominant import flow is **restoring an existing Bitcoin
seed to claim eCash**. That seed's coins may live at whatever derivation the user's *old* wallet
used:

- BIP44 legacy P2PKH (`m/44'/…`)
- BIP49 nested segwit P2SH-P2WPKH (`m/49'/…`)
- BIP84 native segwit P2WPKH (`m/84'/…`) ← the only path we derive today
- BIP86 taproot P2TR (`m/86'/…`)
- non-zero account indexes (`…/1'`, `…/2'`) from multi-account wallets

Today we **only ever derive BIP84 account 0**. So a large share of importers will restore their
seed, see **0 ECX**, and think the airdrop is broken. Flexible derivation on import directly serves
the core value proposition.

## 2. Scope

**In (Option A, first cut):**
- An **Advanced** disclosure on the Import screen with:
  - **Script type** picker: Legacy (BIP44) · Nested SegWit (BIP49) · Native SegWit (BIP84, default) · Taproot (BIP86).
  - **Account index** number (default 0).
  - **Live preview** of the first derived receive address, so the user can sanity-check before committing.
- Custom derivation **overrides** the network's default coin-type where relevant (see §5.4).
- Works end-to-end: watch-only balance/receive **and** send (signing) at the chosen derivation.
- **Read-only derivation display** (script type · account) in wallet detail / Settings (§9 decision).
- Script type **and** account index ship together in the first cut (§9 decision).

**Out (later / separate):**
- Full **descriptor-string paste** (`wpkh([fp/84'/0'/0']xpub…/0/*)`) — the BDK-native power input;
  already noted as a future import mode (CLAUDE.md §9). Higher footgun, separate PR.
- **Multi-path recovery scan** ("scan all standard paths + accounts and show me everything") — the
  most airdrop-friendly UX but a bigger build; see §9.
- Arbitrary/non-standard paths (custom purpose, non-`0/1` change branch, Electrum-style). Guard and
  reject clearly for now.
- Exposing this for *existing* wallets ("add account"). Import-only for v1.

## 3. UX

Import screen (`ImportWalletView` / `ImportViewModel`) gains a collapsed **Advanced** section under
the mnemonic + network picker:

```
Recovery phrase           [ 12/24-word input ]
Network                   [ NetworkSelector → default L2L Signet ]

▸ Advanced
    Script type           ( Legacy · Nested · [Native] · Taproot )
    Account               [ 0 ]  (stepper / numeric)
    Derivation preview    m/84'/0'/0'      (read-only, computed)
    First address         bc1q…k4f2         (read-only, live-derived)
```

- Collapsed by default; defaults reproduce today's behavior exactly (Native/BIP84, account 0).
- The derivation-path line and first-address preview update live as the user changes script type /
  account / network — this is the guardrail against a wrong choice.
- Copy should explain *why* someone would touch this ("restoring from another wallet? match its
  address type") without scaring off normal users.

## 4. Descriptor derivation (the crux)

### 4.1 Two tiers of effort

BDK 2.3.1 ships `Descriptor.newBip44/49/84/86` and `…Public` variants (verified). Their signatures
are `(secretKey|publicKey, keychainKind, network)` — **account is fixed at 0', coin-type derives
from `network`.** So:

- **Script type + account 0 → use the BDK templates directly.** Trivial, clean, no string-building.
  This already covers the biggest airdrop case: a BTC seed at `m/8x'/0'/0'` imported onto `.ecash`
  (which is `Network.bitcoin`, coin-type `0'`) — the template yields exactly the right path.
- **Account index ≠ 0 → build the descriptor string manually.** The templates can't take an account,
  so we assemble `SCRIPT([fingerprint/PURPOSE'/COIN'/ACCOUNT']XPUB/branch/*)` ourselves (BDK still
  does all crypto — we only assemble the string, as `Descriptors.swift` already does for wpkh).

Recommend shipping **script-type first (templates, account 0)**, then adding the account field
(manual strings) — possibly same PR, but the account tier is where the extra validation lives.

### 4.2 The TWO seams that must both change (or send silently breaks)

Derivation is currently hardcoded to `newBip84` in two security-critical places. A custom choice must
be honored in **both**:

1. **Public descriptor build at import** — `BDKWalletEngineFactory.deriveDescriptors` (uses
   `newBip84Public`). Feeds the watch-only engine (balance/addresses/receive).
2. **Sign-on-demand private rebuild** — the `signPsbt` closure (uses `newBip84` again). BDK
   re-derives signing keys from the **PSBT's BIP32 paths**; a BIP84 signer will NOT hold a
   custom-path wallet's keys → build+broadcast succeed but **signing fails**. Classic "receive works,
   send is broken." **This is the #1 correctness risk of the feature.**

Pick the template/string by the wallet's chosen script type + account in *both* spots.

### 4.3 Data model

Once built, the **public descriptor string is stored** in `ManagedWallet` and reload is unaffected
(the watch-only engine loads from the string). But **signing rebuilds the private descriptor from
scratch** and needs to know the script type + account. So persist the choice:

- Add `scriptType` (enum: `bip44|bip49|bip84|bip86`) and `accountIndex: Int32` to `ManagedWallet`
  (default `.bip84` / `0` for all existing wallets → zero behavior change on migration).
- `signPsbt` picks the matching template/string from these fields.
- Bonus: lets the UI show "Native SegWit · account 0" on the wallet later.

Bridged-surface note: keep new props signed (`Int32`) and String/enum-backed per the JNI rules
(CLAUDE.md §5, memory `bridged-surface-signed-types-only`).

## 5. Details & footguns

1. **Change branch** assumed external=`0`, change=`1` (BIP44+). Fine for the four standard types;
   non-standard wallets (some old Electrum) differ — out of scope, and safe because we only offer the
   four standard purposes.
2. **Hardened notation** — accept both `'` and `h`; normalize for display.
3. **Account bounds** — clamp account to `0…2^31-1`; reject negatives/non-numeric.
4. **Coin-type vs network** — for the four templates, coin-type = the network's (0' on `.bitcoin`/
   `.ecash`, 1' on testnets). That's correct for the airdrop (BTC path 0' on `.ecash`). If we later
   allow a custom coin-type, it must **override** the network default with a clear guard against
   nonsensical combos. Document precedence: explicit custom > network default.
5. **Same seed, different path = a second wallet.** Re-importing a seed at another script type creates
   a distinct `walletId` (mnemonic stored twice in Keychain). Acceptable; note it so it's intentional.
6. **`check_network`** still applies — a custom path doesn't bypass network validation on load.
7. Golden Rule §1 intact — BDK owns all derivation/signing; we only choose a template or assemble a
   descriptor string.

## 6. Testing (gate before ship)

Per CLAUDE.md §11, WalletService + signing changes need tests in the same PR:

- **Derivation vectors (fast/unit):** known test mnemonic → known first external + change addresses
  for **each script type (44/49/84/86) × mainnet vs L2L Signet**, asserting they differ and match
  fixed vectors. Extend `DescriptorsTests` / `WalletKeysDescriptorTests`.
- **Account index:** `account 0` vs `account 1` derive different, correct addresses.
- **Path-string correctness:** `m/44'/0'/0'`, `m/49'/1'/0'`, `m/86'/0'/2'` … assembled exactly.
- **Integration (real BDK, iOS sim + Android emulator) — the critical one:** import at each script
  type → **build → sign → broadcast** on L2L Signet. Proves §4.2 seam #2 (signing) works, not just
  receive. **No ship without this per type.**
- **Persistence round-trip:** import at a non-default type/account → cold-load → addresses + signing
  still correct (proves the `scriptType`/`account` persistence).
- **View-model:** `ImportViewModel` advanced state (script type, account, live preview) drives the
  right `WalletManager.importWallet(...)` params through the mock engine.

## 7. Files to touch

- UI: `Screens/ImportWalletView.swift`, `ViewModels/ImportViewModel.swift` (advanced disclosure +
  live preview).
- Engine seam: `Packages/WalletService/…/BDKWalletEngineFactory.swift` (both `deriveDescriptors` and
  `signPsbt`), `Descriptors.swift` (script-type templates + account paths).
- Model/API: `Models.swift` (`ManagedWallet` + a `ScriptType` enum), `WalletManager.importWallet`
  (new script-type/account params), possibly `WalletStore` DTO (persist the new fields).
- Tests: `DescriptorsTests`, `WalletKeysDescriptorTests`, `BDKWalletEngineTests`, `WalletManagerTests`,
  `ImportViewModelTests`.

## 8. Phasing

1. **A1 + A2 together (the near-term deliverable, §9 decision).** Script-type picker (templates) +
   account index (manual strings) + both seams generalized (§4.2) + `scriptType`/`accountIndex`
   persisted (§4.3) + read-only derivation display + the full test set incl. the per-type
   sign→broadcast gate (§6). Internally, script-type can land first and the account field can hide
   behind a flag if it's not ready — but plan them as one PR since they share the seam + data model.
2. **Fast-follow — multi-path recovery scan.** Target before the airdrop (block 964,000, ~Aug 2026);
   not a blocker for earlier releases (§9).
3. **Later — descriptor-string paste** (power users).

## 9. Decisions (resolved 2026-07-17)

- **Ship A1 + A2 together** (script type **and** account index in the first cut). Rationale: both
  require the *same* two-seam plumbing (§4.2) and the *same* `ManagedWallet` data-model change
  (§4.3) — splitting them would touch the signing seam and persistence twice for little benefit.
  Multi-account recovery is real, and the account field is cheap incremental UI. De-risk by keeping
  account 0 the default and, if the account tier isn't ready, hiding just that field behind a flag
  while script-type ships.
- **Multi-path recovery scan is NOT launch-blocking, but it's a high-priority fast-follow.** A1/A2
  (know-your-type manual import) is enough to *unblock* recovery for the general release. But since
  many airdrop users won't know their original derivation, the scan is the UX that actually prevents
  "0 ECX → I lost my coins" confusion — so aim to have it by the **airdrop activation (block 964,000,
  ~Aug 2026)**, even though it doesn't block earlier releases.
- **Yes — display the wallet's derivation** (script type · account) read-only in wallet detail /
  Settings, once `scriptType`/`accountIndex` are persisted (§4.3). It's nearly free (data already
  stored) and helps users confirm/debug a recovery. Include it in the A1/A2 PR.

### Priority

This is a **near-term wanted feature** (recovery-correctness for the airdrop, §1), not a someday
idea. Do A1/A2 (+ derivation display) soon; schedule the multi-path scan ahead of the airdrop.
