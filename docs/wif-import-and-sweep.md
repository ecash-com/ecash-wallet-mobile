# Import private key (WIF) — plan

> Status: **BUILT — engine + UI (2026-07-21).** WalletService WIF path (single-key `pkh` wallet,
> watch-only + sign-on-demand) and the Advanced-on-Import UI (type toggle + live address preview)
> are implemented and verified: real-BDK derives the distribution WIF `Kzjzb4…` → `14kwDb3…`, WIF
> never in the public descriptor, iOS + Android builds green, unit tests pass. **Remaining:** funded
> send end-to-end (ship-gate, needs test coins), reveal-the-WIF in Backup, WIF QR-scan.
> Original plan (2026-07-17). Feasibility **confirmed against our pinned
> bdk-swift/bdk-android 2.3.1** — no Rust, no binding changes (§2). Companion to
> `docs/custom-derivation-path-import.md`; both are "bring legacy Bitcoin into eCash" features but
> different mechanisms. **Design (decided 2026-07-17): import the WIF as a persistent single-key
> wallet** — the user sees the coins and sends wherever they want via the **normal Send flow**. No
> dedicated sweep / "move all" feature — ordinary Send (incl. send-max) already covers moving funds,
> and where the coins go is entirely the user's choice. Keep current if the design shifts (per CLAUDE.md).

## 1. Why / the concrete use case

eCash distributes coins by **moving them onto freshly-generated legacy P2PKH (`1…`) addresses and
handing each recipient the address's WIF** (private key). Example row from the distribution sheet:

| quantity | Address | P2PKH Script | WIF |
|---|---|---|---|
| 333 | `14kwDb3YYj6cdhz9fxGftn1Uga5vdtfrxP` | `76a914` `2937…21f5` `88ac` | `Kzjzb4…UekWj` (compressed) |

The recipient's job: **paste the WIF → it becomes a wallet → they see the coins → they send whenever
they like.** Standard P2PKH, so the hard P2PK case (custom rust signer,
`[[legacy-utxo-sweep-p2pk-p2pkh]]`) never touches the user — that was the *move*, done upstream.

## 1b. No derivation — a WIF is a single key, not a seed

A WIF encodes **one EC private key** (+ network byte + compression flag). It is a **leaf, not an HD
root** — it has **no BIP32 chain code**, so children literally can't be derived from it. There is **no
derivation path, no account, no gap scan** — the key *is* the address. So this feature has **zero
derivation UI**; that belongs only to the seed-import feature
(`docs/custom-derivation-path-import.md`). The only WIF "variant" is **script type** — the same key
can be wrapped as `pkh` (`1…`), `wpkh` (`bc1q…`), or `sh(wpkh)` (`3…`) — which is a different encoding
of the *same* key, not derivation. The distribution is P2PKH, so we use `pkh(<WIF>)` → the `1…` address.

## 2. Feasibility — YES, on current BDK (verified 2026-07-17)

A WIF wallet is a **single-key wallet** and fits our existing watch-only + sign-on-demand model:

```
import:  WIF ("Kzjzb4…")
  → derive pubkey → PUBLIC descriptor  pkh(<pubkey>)        // watch-only; stored in ManagedWallet
  → store the WIF as the wallet's SECRET in the Keychain (keyed by walletId, like a mnemonic)
  → build watch-only Wallet → sync → show balance / the 1… address / history

send:    normal flow — TxBuilder → PSBT (built watch-only)
  → sign-on-demand: load WIF → pkh(<WIF>) private wallet (in-memory) → sign → broadcast → to any addr
```

APIs all present in 2.3.1: `Descriptor(descriptor:network:)` (@2833), `Wallet(...)`/`createSingle`,
`DescriptorSecretKey`/`fromString`, plus our existing send path. bdk_wallet has legacy-sighash tests.
**No FFI fork, no Rust.** Moving funds out is just the **normal Send** (send-max to any address) — no
special sweep code needed.

## 3. Scope

**In (first cut):**
- A distinct **"Import private key"** flow (separate from mnemonic import): paste/scan a **WIF**.
- It becomes a **persistent single-key wallet**: the `1…` address, balance, history, receive, and
  **send** — behaves like any other wallet in the switcher.
- Marked **already backed up** (the user holds the WIF) → no backup nudge, consistent with imported
  seeds (`WalletManager.importWallet` sets `isBackedUp: true`).
- Moving funds = the **normal Send flow** (send-max to any address). The user decides where — another
  of their wallets, an exchange, a hardware wallet, wherever. **No dedicated sweep/"move all" feature.**

**Out (later / not needed):**
- **P2PK** (bare-pubkey) — needs a custom signer; not what users receive. Excluded.
- **Multi-script-type** import of one key (also `wpkh`/`sh(wpkh)`/`tr` for the same key) — the
  distribution is P2PKH, so v1 is `pkh` only; multi-type is a documented enhancement.
- Descriptor-string paste (covered by the derivation doc's later phase).

## 4. UX

New entry point alongside "Import wallet": **Import private key**.

```
Import private key
  Network              [ NetworkSelector — must match the WIF's network (§5.3) ]
  Private key (WIF)    [ paste field + QR scan ]
                       → detected address:  14kwDb3…dtfrxP   (read-only, derived live)
  Label                [ e.g. "Claimed coins" ]
  [ Import ]  → creates the single-key wallet, selects it, syncs

Home (the new wallet, in the switcher like any other)
  DRYNET2  ·  333.00000000 ECX
  Receive → shows the 1… address        Send → normal send to any address
  ⋯ menu → "Move all funds" (optional)  → pick destination → drain → sign → broadcast
```

- **Live address preview** from the WIF is the guardrail (user sees the `1…` address before importing).
- Receive shows the **single `1…` address** (no HD "new address" advancing — a single-key wallet has
  one address; change on sends returns to it).
- Everything else (Send, history, network chip, tx detail) is the standard wallet UI.

## 5. Technical design & footguns

### 5.1 Single-key wallet in the existing seam
Same shape as a mnemonic wallet, different key material:
- `ManagedWallet` gains a **key type** (`mnemonic` | `wif`) so the factory knows how to build/sign.
  `externalDescriptor` = `internalDescriptor` = `pkh(<pubkey>)` (one key, no separate change branch —
  change returns to the same address).
- New import API, e.g. `WalletManager.importPrivateKey(label:network:wif:)`, mirroring
  `importWallet`. `previewAddress(forWIF:network:)` for the live preview.
- Watch-only engine + sign-on-demand: the everyday engine is built from `pkh(<pubkey>)` (no secret
  read); signing loads the WIF and builds the transient `pkh(<WIF>)` private wallet
  (`Persister.newInMemory()`), exactly like the mnemonic path.

### 5.2 Secret handling (Golden Rule §2)
- The WIF is the wallet's **stored secret** — persisted in the Keychain keyed by `walletId`, same
  posture as a mnemonic. **Never logged**, never in errors/analytics; scrub from `WalletError`.
- **Remove wallet** purges the WIF from the Keychain (same as mnemonic wallets).
- Backup/reveal: the "reveal recovery phrase" screen reveals **the WIF** for a WIF wallet (there's no
  mnemonic). `isBackedUp` defaults **true** on import (user already has it) → no nudge.

### 5.3 Network matching
A WIF carries a **network version byte** (mainnet `0x80`). eCash uses Bitcoin's mainnet bytes
(`.ecash` → `Network.bitcoin`), so a mainnet WIF is valid on **`.ecash`** (and real `.bitcoin`), and
**invalid on L2L Signet**. Validate up front; reject a mismatch with a clear, non-leaky message.

### 5.4 Compression is intrinsic
The WIF encodes compressed (`K…`/`L…`) vs uncompressed (`5…`), which fixes the exact `1…` address.
`pkh(<WIF>)` reproduces the right one automatically — nothing to ask. (The distribution's `Kzjzb4…`
is compressed.)

### 5.5 Address reuse (accepted for v1)
A single-key wallet reuses its one `1…` address (receiving more, change on sends). That's a privacy
tradeoff inherent to a single key — acceptable for a claim-and-spend wallet; the "move all" option
lets a user consolidate into an HD/segwit wallet if they care.

### 5.6 "Move all funds" (optional)
`drainWallet().drainTo(dest)` → sign → broadcast; fold into the destination via `applyBroadcast`
([[apply-broadcast-tx-to-wallet]]). Handle empty/dust-only (nothing to move → friendly message).
If the destination is another in-app wallet, its history updates optimistically.

### 5.7 Sighash / replay caveat
P2PKH signing assumes **standard Bitcoin legacy sighash, no BCH-style `SIGHASH_FORKID`**. Our notes
say eCash has no replay protection — **confirm against the fork spec**; a forkid would change the
sighash preimage and stock BDK signing wouldn't validate.

### 5.8 Shared-key note (product)
Whoever sees a WIF controls its coins. If WIFs are ever distributed in a shared doc rather than
privately, surface a gentle "anyone with this key can take these — move them soon" hint and make
"Move all funds" prominent. If delivered privately 1:1, keep-as-wallet is fine as-is.

## 6. Decisions (made 2026-07-17)

- **Keep-as-wallet is the primary flow** (import → persistent single-key wallet → send anytime). No
  forced sweep.
- **Persist the WIF** as the wallet's secret (Keychain), same posture as a mnemonic.
- **`pkh` (P2PKH) only for v1** — exactly what the distribution uses; multi-type is a fast-follow.
- **`isBackedUp: true` on import** (no backup nudge) — the user already holds the key.
- **"Move all funds" is an optional convenience**, not the default path.

### Open (needs a product call)
- **Which networks** to enable it on — just `.ecash`? also real `.bitcoin`? (`.signet` can't apply to
  mainnet WIFs.) Leaning `.ecash` first.
- Whether to show the shared-key "move soon" hint by default (depends on how WIFs are distributed).

## 7. Testing (gate before ship)

- **WIF parse/validate (unit):** valid compressed/uncompressed mainnet WIFs → correct `1…` address
  (fixed vectors incl. the distribution example); bad checksum / wrong-network → rejected cleanly;
  **assert the WIF never appears in any error string** (Golden Rule §2).
- **Descriptor build (unit):** WIF → `pkh(<pubkey>)` public + `pkh(<WIF>)` signing → same `1…` address.
- **View-model:** import-key state machine (idle → detected → importing → done/error), network
  mismatch, live preview — via the mock engine.
- **Integration (real BDK, iOS sim + Android emulator) — the gate:** fund a P2PKH address from a known
  WIF on L2L Signet → import → **balance shows** → **send** a normal payment → recipient sees it; and
  the optional **"Move all"** drains correctly. Failure cases: empty key, dust-only, network mismatch.
- **Persistence round-trip:** import WIF → cold-load → wallet + balance + signing intact (proves the
  WIF is stored/loaded correctly).

## 8. Files to touch

- UI: `Screens/ImportPrivateKeyView.swift` + `ViewModels/ImportPrivateKeyViewModel.swift` (+ entry
  point on Import/onboarding). Reuse the QR scanner. Optional "Move all" action on the wallet menu.
- Engine/model: `Models.swift` (`ManagedWallet` key-type flag), `WalletManager`
  (`importPrivateKey(...)`, `previewAddress(forWIF:)`, optional `moveAllFunds(...)`),
  `BDKWalletEngineFactory`/`Descriptors` (single-key `pkh` public + signing), `KeyStore` (store/load a
  WIF — same interface as a mnemonic string), `WalletStore` DTO (persist key-type),
  `WalletError` (WIF-scrubbed cases).
- Tests: WalletService WIF/descriptor/vector + persistence tests + `ImportPrivateKeyViewModelTests`.
- No `NetworkRegistry`/consensus changes.

## 9. Relationship to the derivation feature

| | WIF import (this) | Custom derivation on import |
|---|---|---|
| Input | one private key (WIF) | 12/24-word seed |
| For | the eCash P2PKH distribution / paper wallets | restoring an HD wallet at a non-BIP84 path |
| Result | persistent single-key wallet | ongoing HD wallet |
| BDK | supported today, no Rust | supported today (templates), no Rust |

Both near-term airdrop-recovery on-ramps. This one is **tightly coupled to the coin distribution**, so
its priority tracks whenever that distribution goes live.

## 10. Bottom line

**Ship it on the BDK we already have.** Import the WIF → it's a normal single-key wallet → the user
sees their coins and sends when they want. No forced sweep; "move all" is there if they want it. The
only hard legacy piece (P2PK) is upstream and never reaches the app.
