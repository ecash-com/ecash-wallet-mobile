# Advanced import — choose derivation path / script type

> **Status:** PROPOSED / post-v1 — not built. An "Advanced" section on the Import screen that lets a
> user pick the **script type / derivation path** so wallets created in *other* apps restore with the
> right addresses (and balance). General interop feature.
>
> **Does NOT solve BitWindow** — that's a *different seed*, not a different path (see
> `docs/bitwindow-import.md`). Keep the two distinct or this feature will get blamed for not fixing it.

## 1. Problem
We hardcode **BIP84 native segwit** (`m/84'/<coin>'/0'`, `wpkh`). A seed created in a wallet that uses
a different **script type** derives a *different address set*, so importing it here shows **no balance**
even though the mnemonic is valid and on the right chain. Common cases:

| Standard | Path | Script | Addresses |
|---|---|---|---|
| BIP44 | `m/44'/c'/0'` | legacy P2PKH | `1…` / `m`/`n` |
| BIP49 | `m/49'/c'/0'` | nested segwit `sh(wpkh)` | `3…` / `2…` |
| **BIP84** (ours) | `m/84'/c'/0'` | native segwit `wpkh` | `bc1q…` / `tb1q…` |
| BIP86 | `m/86'/c'/0'` | taproot `tr` | `bc1p…` / `tb1p…` |

Plus non-standard **account index** (`…/1'`, `…/2'`) and occasional custom **coin-type** overrides.

## 2. Approach
- **Prefer BDK's standard template constructors** — `Descriptor.newBip44 / newBip49 / newBip84 /
  newBip86` (with a `DescriptorSecretKey` + keychain) — over hand-built descriptor strings. Safer, and
  they encode the right path + script. **Verify the pinned `bdk-swift`/`bdk-android` 2.3.x exposes
  44/49/86** (we use/verified 84) and that **taproot** works, before building.
- **Generalize the descriptor builder.** `Descriptors.swift` + `BDKWalletEngineFactory` currently
  assume BIP84; thread a `DerivationSpec { scriptType, account, coinTypeOverride? }` through create/
  import → engine.
- **Persist the spec on `ManagedWallet`.** CRITICAL: the chosen script type/path must be remembered
  forever, because **signing must use the same derivation.** Our watch-only + sign-on-demand seam
  means the `signPsbt` closure rebuilds the private descriptor — it must use the *same* spec or sends
  break. Spec threads through both build (watch-only) and sign.
- Bridged-surface rule still applies (signed ints only on anything bridged; convert at the engine
  boundary).

## 3. UX — two layers
- **Default unchanged:** BIP84. Most users never open Advanced.
- **Advanced disclosure** on Import: script-type picker (Legacy / Nested SegWit / Native SegWit /
  Taproot) + optional account index + optional custom path / coin-type. Footgun mitigation: presets
  first, free-text last.
- **Recommended headline feature — "auto-scan standard paths":** on import, derive BIP44/49/84/86
  (+ a couple of account indices), sync each, and report **which has funds/history** — *"Found funds on
  Native SegWit (m/84'/1'/0')."* Sparrow/BlueWallet-style. Most users shouldn't need to know BIP
  numbers; the manual picker is the fallback. Doubles as a great recovery tool.

## 4. Out of scope (bigger, later)
- **Watch-only descriptor / xpub paste** (Sparrow-style: paste an output descriptor or xpub, no
  signing keys). Useful but a separate, larger feature — multiple script types per wallet, no signing,
  different storage. Not part of this.
- **Multiple simultaneous script types** in one wallet (scan + combine). v1 of this feature picks
  **one** script type per imported wallet.

## 5. Effort
Moderate: generalize the descriptor builder, persist the spec, thread it to signing, build the
Advanced UI + the auto-scan helper, and verify the BDK template surface. Not consensus/Rust work.
The auto-scan UX is the part that turns this from "power-user toggle" into a genuinely friendly
recovery feature — worth prioritizing over the raw custom-path field.
