# Plausible deniability — passphrase (hidden) wallets

> **Status: PROPOSED (design only — not built).** Decision record for adding BIP39-passphrase
> hidden wallets so a user can reveal a believable wallet under coercion while keeping real funds
> in a wallet that leaves no trace on the device. Builds on [[key-storage-model]] and
> `docs/seed-container-model.md` (wallet = seed, network switched inside it). CLAUDE.md §2 (Golden Rules — secret scrub, wallet isolation) binds
> this feature especially hard.

## 1. What & why

Plausible deniability lets you hand over **a** wallet — believable, with some funds and history —
when *forced* to (the "$5 wrench attack," a border search, a coercive demand), while your actual
funds sit in a **separate hidden wallet that is cryptographically invisible**: nothing on the device
proves it exists, so you can credibly claim "that's all I have."

**Threat model.** Assume the coercer can: unlock the device, unlock the app (app-lock), read the
wallet list, read the seed (Backup), and read everything on disk. They **cannot** know your
passphrase. The feature is safe iff the passphrase — and anything derived from it — never persists.
The seed being known/recoverable is *fine*; that's the whole point of BIP39 deniability — the secret
is the **passphrase**, not the seed.

This is the **passphrase** flavor (Trezor/Ledger "hidden wallet"), not BlueWallet's decoy-password
flavor (a second app-encryption password that opens a fake wallet set). We choose passphrase because
it's the real cryptographic version and BDK already supports it (below).

## 2. Mechanism — BIP39 passphrase ("the 25th word")

A BIP39 mnemonic + an optional **passphrase** derives an *entirely different* seed → a different
wallet (different xpub, addresses, keys, balance). Same words, different passphrase → a different
valid wallet. Empty passphrase → the "standard" wallet. Because **every** passphrase yields a valid
wallet and nothing records whether one was used, a coercer with your 12/24 words can't prove there's
anything behind a passphrase.

**BDK supports this directly** — no custom crypto:

```swift
// bdk-swift BitcoinDevKit.swift
public convenience init(network: Network, mnemonic: Mnemonic, password: String?)
```

`password:` is the BIP39 passphrase. We call this in **two** places in `BDKWalletEngineFactory`, both
currently passing `password: nil`:
- `walletKeys(network:mnemonic:scriptType:)` (`~373`) — derives the **public** descriptors stored per
  account at create/import (one per offered mainchain since the seed-container model).
- the `signPsbt` closure (`~199`) — re-derives the **private** key to sign a send.

**Two more sites derive from the same phrase and also need the passphrase (2026-11-10):**
- `CoinNewsIdentity.swift:~35` — the BIP-340 posting identity. Without it a hidden wallet would post
  under the **standard** wallet's CoinNews identity — a deniability leak that links the two.
- `ThunderWallet.swift:~21` — the Thunder (ristretto255) seed via `Bip39Seed.seed(mnemonic:passphrase:)`,
  today always `""`.

Threading a passphrase into all four is the entire crypto change. The passphrase changes the derived
xpub, so the public descriptors (and thus the wallet's addresses) differ — a passphrase wallet is a
genuinely separate wallet, not a view of the standard one.

## 3. The deniability invariant (non-negotiable)

Nothing derived from the passphrase may persist:

1. **Passphrase is never stored** — not in Keychain, not anywhere. Typed each time it's used.
   (Storing it would both leave a trace and hand it to anyone who unlocks the device.)
2. **Hidden wallet is never in the `FileWalletStore`** — if it shows in the wallet list, it isn't
   hidden. It cannot be a normal persisted `ManagedWallet`.
3. **No hidden chain data on disk** (v1) — a second BDK SQLite store full of a stash's
   addresses/balances is a tell. The hidden wallet is synced fresh in memory and dropped. The same
   goes for the **Thunder account key**, which the standard wallet persists per `walletId` in
   `UserDefaults` (`ThunderAccountKeyStore.swift:~27`, key `thunder.accountKey.v018.<id>`) — a hidden
   wallet must never write it (2026-11-10).
4. **No "hidden wallet enabled" flag anywhere** — the flag itself is the leak. The affordance to
   enter a passphrase must be **always present**, even for users with no hidden wallet, because any
   passphrase derives *a* valid (possibly empty) wallet. Its presence reveals nothing.

## 4. Chosen model — *summoned, ephemeral passphrase wallets*

Every wallet (seed) can be opened two ways:

- **Empty passphrase → the standard wallet** — persisted, in the list, the daily driver (what exists
  today).
- **Any non-empty passphrase → a hidden wallet** — derived on demand, **never written to the store**.
  Enter the passphrase → derive its public descriptors in memory → sync → show balance/history for
  the session. Lock / background / "close" → it vanishes with no trace. Re-enter the passphrase to
  see it again.

End-to-end for a hidden wallet:
1. **Open** — user invokes "Open passphrase wallet" and types a passphrase. We build a transient,
   in-memory wallet (not a stored `ManagedWallet`): public descriptors from
   `DescriptorSecretKey(mnemonic, password: passphrase)` → `Descriptor.newBip84Public`.
2. **Sync** — no persisted checkpoint, so a full scan (gap-limit 20) each open; reveal index lives in
   memory for the session only.
3. **Receive / build** — addresses + PSBT building run watch-only from the in-memory descriptors.
4. **Send** — sign-on-demand re-derives the private key with the *same* passphrase, signs, drops it
   (the existing one-shot signing window, now passphrase-parameterized).
5. **Close** — clearing the session drops all in-memory artifacts; nothing remains on disk.

## 5. How it maps to our architecture

Almost entirely reuses existing pieces — the watch-only + sign-on-demand design (key-storage.md §3)
was, conveniently, the right foundation:

| Piece | Today | With passphrase |
|---|---|---|
| Public descriptors | derived once at create/import, **stored** per account across all mainchains | derived live with the passphrase, **in-memory only** |
| Everyday engine | watch-only from stored descriptors | watch-only from the in-memory descriptors |
| Signing | `signPsbt` re-derives (`password: nil`) | `signPsbt` re-derives (`password: passphrase`) |
| Sync | persisted checkpoint + revealed-spks | no checkpoint → full scan each open |
| Wallet list / metadata | `FileWalletStore` | **not persisted** |

New surface: a passphrase-entry flow, an *ephemeral wallet* representation in `AppState`/
`WalletManager` (parallel to `ManagedWallet` but never persisted), and routing the passphrase into
the four derivation points (§2).

## 6. Tradeoffs / footguns

- **Ephemeral = no persistence.** Full scan on each open (fine on signet / for a small stash; slower
  on mainnet). In-memory reveal index only. This is the price of zero disk trace.
- **Unrecoverable.** The seed backup does **not** cover passphrase wallets. A forgotten or mistyped
  passphrase silently opens a *different empty wallet* — no error. The Backup flow needs a clear,
  non-alarmist note.
- **Convincing decoy.** True deniability needs the *standard* (revealed) wallet to look like a real,
  used wallet — an empty decoy isn't believable. This is user behavior, not code, but worth saying
  in copy.
- **Discipline.** Leans hard on the secret-scrub rule + no-leak guarantee — the hidden wallet must
  produce zero entries in logs, the store, or the switcher when not active. Add a no-leak test.

## 7. v1 scope (when greenlit)

- [ ] Thread `passphrase: String?` into `walletKeys` + the `signPsbt` closure + `CoinNewsIdentity` +
      the Thunder seed (the four sites in §2); `passphrase == nil`/empty stays byte-identical to
      today's standard wallet.
- [ ] Ephemeral wallet representation (in-memory, never in `FileWalletStore`).
- [ ] "Open passphrase wallet" affordance — always present (no persisted enable flag); passphrase
      entry; mounts the ephemeral wallet for the session; "close" tears it down.
- [ ] Re-sync-on-open (full scan), in-memory reveal index, sign-on-demand with the passphrase.
- [ ] Backup-flow note: passphrase wallets are separate and unrecoverable.
- [ ] No-leak test: opening + closing a passphrase wallet leaves the `FileWalletStore`, logs, and
      chain-data dir unchanged; the passphrase never reaches Keychain.

## 8. Open decisions (need a call before building)

1. **Per-seed or standalone?** Open a passphrase wallet *from an existing wallet's seed* (cleanest,
   matches BIP39 — recommended), vs. a top-level "enter seed + passphrase" entry.
2. **Confirm-on-first-use?** BIP39 passphrases have no checksum, so a typo = a silent different
   (empty) wallet. Re-enter the passphrase the first time to catch typos, or accept the footgun for
   maximum deniability / simplicity?
3. **Ephemeral-only for v1 (recommended)** or invest now in **encrypted persistence** (store the
   hidden wallet's data encrypted under the passphrase for fast reload + persisted indices)?

## 9. Future

- Encrypted-at-rest hidden wallets (persisted under a passphrase-derived key) for speed + reliable
  address-index tracking, without breaking the invariant.
- Multiple hidden wallets per seed (each passphrase = its own).
- Guidance/automation for a believable decoy (e.g. a nudge to keep some funds on the standard
  wallet).
