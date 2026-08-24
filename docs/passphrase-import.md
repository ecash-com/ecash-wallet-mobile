# BIP-39 passphrase on import — options & open questions

**Status:** 🔵 DISCUSSED, NOT DECIDED, NOT BUILT — 2026-08-24. Deliberately records the trade-offs
without picking one; the storage question needs thinking time and is expensive to reverse once users
have passphrase wallets in the app.

**Trigger:** a user couldn't import a wallet they hold elsewhere, because that wallet uses a BIP-39
passphrase and we have no way to enter one.

Related: `docs/plausible-deniability.md` (same mechanism, opposite storage rule — §3 below),
`docs/key-storage.md`, CLAUDE.md §7 (key storage) and §2 (Golden Rules).

---

## 1. Mechanism

A BIP-39 passphrase (the "25th word") is an input to the KDF, nothing more:

```
PBKDF2-HMAC-SHA512(mnemonic, salt = "mnemonic" + passphrase, 2048)
    → 512-bit seed → BIP-32 master xprv → descriptors
```

Consequences that shape everything below:

- **A different passphrase is a different wallet.** Not an error — a *valid, empty* one.
- **There is no checksum over it.** Nothing can tell a typo from a deliberate choice.
- **Empty passphrase == no passphrase.** They are the same input, so there's no ambiguous state.
- **Signing does not need it.** It's consumed once, producing the seed. See §4.

## 2. Where the code stands today

`password: nil` is hardcoded in exactly three places:

- `Packages/WalletService/Sources/WalletService/BDKWalletEngineFactory.swift:138` (signing path)
- `…/BDKWalletEngineFactory.swift:239`
- `…/CoinNewsIdentity.swift:35` (BIP-340 identity — **easy to miss**; a passphrase wallet must not
  post under an identity derived from the passphrase-less seed)

`KeyStore` stores the mnemonic and nothing else (`saveMnemonic` / `loadMnemonic` /
`deleteMnemonic`) — there is no slot for a second secret.

The import screen already has an **Advanced** disclosure section
(`Sources/ECashWalletMobile/Screens/ImportWalletView.swift:110`) and, on the WIF path, a **live
address preview** (`:238`). Both are directly reusable here — see §5.

## 3. Conflict with the plausible-deniability design

`docs/plausible-deniability.md` §4 already commits to a model built on the *same mechanism* with the
**opposite** storage rule:

> **Empty passphrase → the standard wallet** — persisted…
> **Any non-empty passphrase → a hidden wallet** — derived on demand, **never written to the store**.

That rule makes "has a passphrase" synonymous with "is hidden". A passphrase wallet imported as a
**daily driver** contradicts it directly.

This has to be resolved before either feature ships, or we end up with two features that look
identical to a user and behave completely differently — and someone believes they have deniability
when they don't. Options:

- **(a)** Persistence becomes an explicit per-wallet choice at import ("remember this passphrase"),
  and the hidden-wallet feature is simply that choice set to *no*, reached via its own entry point.
- **(b)** Keep the doc's rule; imported passphrase wallets are ephemeral too — which means
  re-entering the passphrase on every launch just to read a balance.
- **(c)** Import-only-and-stored now, and the deniability model gets its own explicit entry point
  later rather than being implied by the passphrase.

Jake's stated leaning (not final): **import-only** scope.

## 4. The storage question — the actual decision

**The passphrase is not needed at signing.** It produces the seed and is then finished with. We
would need it again only because our key-storage model re-derives from the mnemonic every time
(CLAUDE.md §7: "Derive xprv/descriptors at runtime; never persist private descriptors").

So the question is really *what we persist*:

| What we persist | Passphrase re-entry | Notes |
|---|---|---|
| **Mnemonic only** (today) | Every send, split, CoinNews publish/vote | The only genuinely stronger option |
| **Mnemonic + passphrase** | Never | Reuses the existing derivation path (`password:` instead of `nil`) |
| **Derived seed / xprv** | Never | Puts spendable key material on disk — §7 currently forbids it; also needs new storage plus rework of CoinNews identity derivation |

**Rows 2 and 3 are equivalent security.** Both mean device compromise yields full spending
authority. Only row 1 changes that.

What a *stored* passphrase still buys: protection for the **paper backup**. Someone who photographs
the 12 words in a drawer gets nothing without the passphrase. That matches most users' mental model
("my written backup isn't enough on its own") — but it is strictly weaker than the case a passphrase
is classically chosen for, where the device never holds full spending authority.

Cost asymmetry worth weighing: prompting means touching four signing flows (send, split coins,
CoinNews publish, CoinNews vote) plus their error and cancel paths. Storing stops at import + backup.

Also note **Confirm-send is already behind device auth** (`SendViewModel.authorize`). A passphrase
prompt would land immediately after Face ID / passcode — a second secret to type right after
authenticating, which many users will read as the app being broken.

## 5. The silent failure — highest support risk

**A wrong passphrase yields a valid, empty wallet, not an error.** The user's reading of that is
"the app lost my money."

Mitigations, in order of value:

1. **Address preview before committing the import.** Show the first derived address so the user can
   compare it against their other wallet. The pattern already exists on the WIF path
   (`ImportWalletView.swift:238`).
2. **Honest empty state after import.** If the first sync finds no history, say *"No transactions
   found — check your passphrase"* rather than showing a confident zero.
3. **Never trim the passphrase.** Whitespace is significant; a trailing space is a different wallet.
   (Opposite of the address field, which trims deliberately.)
4. **NFKD normalization**, per BIP-39. Non-ASCII passphrases have historically diverged between
   wallets, so a passphrase that works elsewhere may not here if this is skipped.

## 6. Backup — the funds-loss risk

Today Backup reveals the phrase and marks `isBackedUp`. **For a passphrase wallet the phrase alone
does not restore anything.**

Settled in discussion: **the passphrase is NOT part of the backup and is NOT revealed.** It stays the
user's to remember — backing it up beside the seed defeats the point of having one.

But if it's stored silently and never shown, a user can forget one exists at all — especially years
later, restoring from a drawer. So Backup must state that it exists without displaying it:

> These 12 words are not enough on their own. This wallet also requires the passphrase you entered
> when importing it. We can't show it to you — you must remember it.

Without that, someone backs up 12 words, believes they're covered, restores elsewhere, sees an empty
balance, and concludes we lost their money — the §5 failure, delayed by years.

**Open:** should `isBackedUp` be reachable at all for a passphrase wallet? Marking it "Backed up"
after a phrase-only verification arguably asserts something false — we've verified they wrote down
half of what they need.

## 7. Open decisions

1. **Store the passphrase, prompt for it, or make it an explicit per-wallet choice?** (§4 — the one
   that needs thinking time.)
2. **How does this square with `docs/plausible-deniability.md`?** (§3 — (a), (b) or (c).)
3. **Import-only, or also create-with-passphrase?**
4. **Can a passphrase wallet be marked backed-up?** (§6.)
5. If stored: purge with the rest of the wallet's artifacts on remove (Golden Rule §5) — the
   `KeyStore` delete path needs to cover the new key.

## 8. If it gets built — surface

- Passphrase field in the existing **Advanced** section on Import (`ImportWalletView.swift:110`),
  alongside the script-type/derivation options, since it's the same class of "I know what my other
  wallet did" setting.
- Address preview wired to it (§5.1).
- `password:` threaded through the three sites in §2 — including `CoinNewsIdentity`.
- Backup copy change (§6).
- `KeyStore` gains a passphrase entry keyed by `walletId`, purged on remove.
