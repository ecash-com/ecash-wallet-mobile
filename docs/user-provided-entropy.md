# User-provided entropy ("paranoid mode") — design

> Status: **PLAN, not built** (2026-09-07). Reference: BitWindow's desktop "Paranoid mode".
> Related: `docs/key-storage.md`, `docs/plausible-deniability.md`, CLAUDE.md §7.

## 1. What this is

A second way to create a wallet: instead of taking 128/256 bits from the OS CSPRNG, the user supplies
the entropy themselves by swiping across a custom on-screen grid. The characters they trace accumulate
in a field, and that field — deterministically — becomes the wallet's BIP39 mnemonic.

Two requirements drive the whole design:

1. **Reproducible.** The same input string must always yield the same 12/24 words, on both platforms,
   forever. The user can re-enter their string and check.
2. **Auditable.** The derivation must be simple enough that a user can verify it with standard tools,
   without trusting our binary.

The existing CSPRNG path stays the default. This is opt-in, behind the create flow's **Advanced**
section, with a warning — the same posture BitWindow takes ("You must know what you are doing").

## 2. The central tension — read this before implementing

**Requirement 1 means the mnemonic is a pure function of the visible string. So the entire security of
the wallet rests on that string being unpredictable.** Hashing does not create entropy; it only
spreads what is already there. A 20-character string a human thought was "random enough" might carry
40–60 bits, and the resulting wallet is brute-forceable no matter how good our hash is.

That makes **the entropy requirement the security mechanism**, not the hash. Everything in §5 exists
because of this sentence.

### The specific trap: swipe paths are not random

The obvious implementation — emit a character every time the finger crosses into a new cell — is
badly broken, and it is broken in a way that *looks* fine:

- A swipe is a smooth, continuous path. From any cell, the next cell crossed is almost always one of
  the ~3 neighbours in the current direction of travel. That is **~1.5 bits per character, not
  `log2(alphabet)`**.
- With a 32-key grid, naive accounting credits 5 bits per character. The real figure is roughly a
  third of that. A meter that says "128 bits ✓" after 26 characters would be delivering something
  closer to **40 bits** — a wallet an attacker can grind out.
- Worse, the failure is invisible: the string looks like gibberish, the meter turns green, and the
  wallet is created.

So: **never credit characters at their nominal alphabet rate.** §6 defines conservative accounting,
and §6.3 adds structural checks that catch the realistic lazy-user pattern (back-and-forth swiping).

## 3. Modes — and why mixing is auditable

Three ways to fill the entropy, and **one derivation for all of them**. The trick that makes this work
is that there are not two separate entropy sources to reconcile: there is **one visible string**, and
the modes differ only in *who writes into it*.

| Mode | The field contains | Gate |
|---|---|---|
| **System** (default today) | characters drawn from the OS CSPRNG | none — CSPRNG supplies the full 128/256 bits |
| **Mixed** (recommended default when opting in) | a CSPRNG-generated prefix, then the user's swiped characters appended | full user target (§6.4) |
| **User only** | only the user's swiped characters | full user target (§6.4) |

Because the field *is* the input, and the field is fully visible, **mixed mode is exactly as auditable
as user-only**. The user sees the CSPRNG prefix, sees their own characters after it, and can run the
same one-line `shasum` over the whole string (§4). Nothing is hidden and nothing is combined off-screen.

### What the user can and cannot verify in mixed mode

This distinction is worth being precise about, because it is the answer to "can you even audit a mix?":

- **Can verify:** that their own entropy actually went in, unmodified, and was not discarded — the
  string they swiped is right there in the field, and the derivation over the whole field reproduces
  the mnemonic.
- **Cannot verify:** that the CSPRNG prefix genuinely came from a healthy CSPRNG rather than being
  attacker-chosen.

**The second one does not matter**, and that is the entire point of mixing: if the user's own portion
carries the full target on its own, the wallet is safe *regardless of how the system prefix was
chosen*. The system portion can only help. So the property the user needs to check is the one they
can check.

### Mixed strictly dominates user-only

Worth stating plainly, because it affects what we should default to:

- If the CSPRNG is healthy, mixed is ≥ the target no matter what the user swipes.
- If the CSPRNG is broken or backdoored, mixed degrades to exactly the user's own entropy — which we
  gate at the full target anyway.

So mixed is never worse than user-only and is better whenever the user's randomness is worse than they
think. **It protects against a broken CSPRNG and against the user's own bad randomness at the same
time, for identical effort.** Recommend defaulting to mixed whenever custom entropy is switched on.

The one honest reason to keep user-only: a user who wants their wallet reproducible from material they
generated entirely off-device (dice, coin flips) with nothing from the phone in it at all. That is a
real, coherent want, so keep the mode — just do not make it the default.

### The field format

The field is not a bare string — it is a structured, fully visible record of every component that fed
the hash:

```
v1&<wordCount>&<64 hex chars: SHA-256 of 32 CSPRNG bytes>&<unix millis>&<user's grid characters>
```

Every mode uses this shape. In user-only mode the CSPRNG field is empty (`v1&24&&<millis>&<chars>`);
in system mode the user field is empty. The whole thing is what gets hashed, and the whole thing is
what the user sees and copies.

Being explicit about provenance is the point: a user can look at the string and see which run of
characters is theirs, rather than trusting that their swipe went in somewhere.

**Three notes on the components:**

- **Capture the timestamp and the CSPRNG bytes once, when the view opens, and freeze them.** Not at
  hash time, not at Continue. This is what keeps the string auditable: the user hashes the string on
  screen, so every component must already be *in* that string and must not change under them. A
  timestamp read at hash time and never displayed would be unreproducible — the one way this component
  could genuinely break the audit. Frozen and visible, it costs the user nothing: they are not
  computing it, just hashing characters that include it. Freezing at open also satisfies the
  system-first invariant below. ("Clear" starts a fresh session and re-captures both; returning from
  background does not.)
- **The timestamp contributes ~0 bits and must never be credited.** An attacker who knows the wallet
  was created on a given day is guessing among ~86 million milliseconds — about 27 bits, and far fewer
  if they can narrow it to an hour. Hashing it does not help: SHA-256 of a guessable value is still
  guessable, you just hash each guess. It is included because extra material can never *reduce* the
  hash's entropy, and it cheaply distinguishes two wallets made from the same swipe — not because it
  is a source. **Store it raw, not as `sha256(timestamp)`**: hashing it makes a low-entropy value look
  like a 256-bit one, which is exactly the confusion to avoid. Shown raw, nobody mistakes it for
  secret material.
- **Hashing the CSPRNG bytes is formatting, not strengthening.** `SHA-256(random)` has no more entropy
  than `random`; it just yields a tidy fixed-length hex field. Fine to do, worth understanding.
- **`&` also appears in the alphabet** (0x26), so the user's own characters can contain it and the
  string cannot be unambiguously parsed back into components. That is harmless *provided nothing ever
  parses it* — we only ever hash the whole string. Do not build a parser on this format later; if the
  components ever need reading back, length-prefix them instead.

### This resolves the domain-separation question

Because the field now begins `v1&<wordCount>&`, the 12-word and 24-word strings **differ**, so their
SHA-256 digests are already unrelated. The prefix relationship from §4 disappears with no magic label
for the user to reproduce and no byte-range to look up:

- Derivation goes back to plain **`SHA-256(field)`**, truncated to 16 or 32 bytes.
- The audit stays "hash exactly the string on screen" — the separation is *in* the string, visible,
  rather than in a documented constant.
- `v1` gives us a clean way to change the scheme later without ambiguity.

This is better than either option previously on the table, and closes that decision.

### Two invariants that make mixing safe

1. **The CSPRNG prefix is generated first**, before the user starts swiping, and never regenerated
   afterwards. If the suffix could be chosen after seeing the user's input, a compromised RNG could
   adapt to cancel it. System-first removes that possibility entirely.
2. **The meter counts only user-contributed characters** (§6). Crediting the CSPRNG prefix would let
   the gate turn green before the user has swiped at all, which would quietly turn mixed mode back
   into system-only. System entropy is a bonus on top of the gate, never a way through it.

## 4. Derivation — exact and pinned

```
input   : the visible string, ASCII only
material: UTF-8 bytes of input          (ASCII ⇒ no Unicode normalisation ambiguity, ever)
digest  : SHA-256(material)             (32 bytes)
entropy : 12 words → digest[0..<16]     (128 bits)
          24 words → digest[0..<32]     (256 bits)
mnemonic: BDK  Mnemonic.fromEntropy(entropy)
```

`Mnemonic.fromEntropy(entropy: Data)` is verified present in bdk-swift 2.3.1 (binding line 5796) and
comes from the same UniFFI core as bdk-android, so both platforms share it. **BDK does the BIP39 word
mapping and checksum — we never touch either** (Golden Rule §1).

Three deliberate choices:

- **ASCII-only alphabet.** Restricting the keyboard to ASCII removes every Unicode normalisation
  question (NFC vs NFD would otherwise silently produce different wallets on different platforms).
- **SHA-256, not a KDF.** There is no secret to stretch and no salt to bind; the input is the secret.
  A KDF would add cost without adding security and would make independent verification harder.
- **Truncation for 12 words** rather than a separate hash, so a user can verify both cases from a
  single `sha256sum`.

### Auditability

A user can check our work with nothing but a shell. **The recipe has to be quoting-proof**, because
the alphabet contains `'`, `"`, `$`, `` ` `` and `\` — a naive `printf '%s' '…'` breaks the moment the
string contains a quote:

```sh
# paste the copied string into entropy.txt, then:
printf '%s' "$(cat entropy.txt)" | shasum -a 256
```

Command-substitution output is not re-parsed by the shell, so every metacharacter stays literal, and
`$( )` strips the trailing newline a text editor adds. Compare the first 32 (12 words) or 64 (24 words)
hex characters against the entropy the confirm step displays.

Ship this recipe in the UI (a "How this is derived" disclosure), not only in docs — and ship a
**copy button**, since the string is far too long to retype (§6.2a).

### ✅ Resolved: domain separation (see §3, "The field format")

As written, a 12-word wallet's entropy is a **prefix** of the 24-word entropy derived from the same
input. If a user creates both from one string, an attacker who compromises the 12-word wallet learns
half of the 24-word wallet's entropy — leaving 128 bits, still infeasible, but a real degradation of a
256-bit wallet to a 128-bit one.

Three options:

- **(a) Keep plain SHA-256** — maximally auditable (a bare `shasum -a 256` verifies it), and warn in the
  UI against reusing an input string for a second wallet.
- **(b) Domain-separate with a label** — `SHA-256("ecash.com/entropy/v1/" + wordCount + ":" + input)`.
  Removes the prefix relationship entirely. Still a shell one-liner, but the user must reproduce the
  label byte-exactly from our docs, and a typo yields a wrong answer with nothing to indicate why.
- **(c) Disjoint ranges of one SHA-512** — 12 words = `SHA-512(input)[0..<16]`, 24 words =
  `SHA-512(input)[32..<64]`. No prefix relationship, no magic string to mistype; the user runs one
  `shasum -a 512` and reads a documented byte range out of it. Neither output is computable from the
  other without inverting SHA-512.

**Resolved by the field format instead (§3).** Because the field starts `v1&<wordCount>&`, the 12- and
24-word inputs already differ, so plain `SHA-256(field)` is domain-separated with nothing extra for the
user to reproduce. Options (b) and (c) are recorded here only as the alternatives that were considered.

**Derivation is therefore plain SHA-256 over the field, truncated** — as written at the top of §4.

**Correction to an earlier claim in this doc:** changing the scheme later does *not* invalidate existing
wallets. The mnemonic is the backup, and it stays in the Keychain regardless of how it was derived.
What a later change breaks is narrower — a user who kept their input string could no longer regenerate
the same wallet from it. That is exactly the reproducibility promise this feature is sold on, so it is
still worth settling before shipping, but it is not wallet loss.

## 5. Alphabet and grid — ASCII printable (BitWindow's set)

**94 characters: ASCII `!` (0x21) through `~` (0x7E)** — every printable ASCII character except space.
This is exactly the set BitWindow uses, so the two implementations share an alphabet.

```
!"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~
```

Nominal 6.55 bits/character. Laid out as BitWindow does: **12 columns × 8 rows**, 96 cells with the
last two blank.

### Why 12 columns is fine here, despite the 44pt rule

CLAUDE.md §8 sets a 44pt minimum touch target, and 12 columns on a 390pt-wide phone gives ~32pt cells.
That rule does not apply to this grid, for a specific reason: **there is no wrong cell.** The minimum
exists so users do not mis-tap the button they meant to hit; here every cell the finger crosses is
equally valid input. A mis-hit is not an error, it is entropy.

Dense cells are in fact *better* for swiping — more transitions per unit of finger travel, so the
target is reached in less wall-clock time. Cells still need to be legible enough to read the string and
see the highlight, which ~32pt with a ~13pt glyph satisfies. Eight rows at ~40pt is ~320pt tall, which
fits in portrait beneath the field and meter.

Blank cells emit nothing and are inert to the accumulator.

### Shuffling the layout

A **Shuffle** button re-orders the 94 characters across the grid (Fisher–Yates from the CSPRNG), and
the layout is also shuffled each time the screen opens.

What this genuinely buys:

- **Shoulder-surfing and camera resistance.** With a fixed layout, anyone who films the user's finger
  recovers the exact string from the path alone. Under a shuffled layout the path is meaningless
  without the mapping, which is never displayed and never recorded.
- **Habit breaking.** A user who traces the same shape every time gets a different string each session.

What it does **not** buy, and must not be credited in the meter:

- **It adds no entropy under this feature's own threat model.** The permutation comes from the CSPRNG.
  If the CSPRNG is healthy, the layout is unpredictable — but then the system/mixed modes already had
  their entropy. If the CSPRNG is broken, which is the entire reason someone chooses paranoid mode, the
  attacker knows the permutation and the shuffle bought nothing. So it can only help in the case where
  help was not needed. Keep the §6 credit rates exactly as they are.

The permutation is deliberately **not** recorded in the field: the field stores the *characters*
produced, not the positions touched, so reproducibility is unaffected by which layout was in use.

### Consequences of a 94-character set

Two things follow that a power-of-two alphabet would have avoided, both manageable:

- **The CSPRNG fill needs rejection sampling.** 256 is not a multiple of 94 (256 = 2×94 + 68), so
  `randomByte % 94` would over-represent the first 68 characters. Draw a byte, **reject it if ≥ 188**,
  otherwise take `byte % 94`. Cheap, and it must be in the code from the start — a biased fill silently
  weakens the system and mixed modes.
- **Ambiguous glyphs are back** (`O`/`0`, `l`/`1`/`I`, `` ` ``/`'`). This only costs hand-transcription,
  which §6.2a already ruled out on length grounds — a 100–260 character string was never going to be
  copied by hand. The audit path is the clipboard.

## 6. Entropy accounting — the safety mechanism

### 6.1 Sample fast, credit per run

**Sample at the platform's full touch-move rate** (60–120 Hz) and record *every* sample, including
repeats. A finger crossing the grid therefore produces `AAABBBBCCDDDDD…`, not `ABCD`.

This is deliberate, and it is not padding. The run lengths encode how long the finger dwelt on each
key — that is, its velocity — and that velocity carries genuine noise: human motor jitter plus the
digitizer's own sampling noise. Emitting one character per cell crossing throws all of it away.

**But the accounting must change to match, or this makes things worse.** Consecutive samples over the
same key are ~95% predictable: if you are on `A` now, you are on `A` 8 ms from now. Crediting each
emitted character would let a 400-character string read as "far past 256 bits" while actually holding
perhaps 60. That is the §2 trap again, amplified by an order of magnitude.

So the accumulator decomposes the string into **runs** — `AAABBBBCC` → `(A,3) (B,4) (C,2)` — and
credits per run, never per sample:

| Component of a run | Credit | Why |
|---|---|---|
| Transition to a new cell, mid-drag | **1.5 bits** | Swipe adjacency (§2) — the next cell is one of ~3 likely neighbours. **Unchanged by the bigger alphabet**: a swipe still only reaches neighbours, so 94 cells buy nothing here. (Was 2.0 in an earlier draft, which credited *more* than §2's own analysis supports — corrected down to match it.) |
| Transition on a fresh touch-down (after a lift) | **5.0 bits** | The touch-down point is uncorrelated with the previous path, and is a genuine choice among 94 cells (nominal 6.55, discounted) |
| The run's length | **1.0 bit** | Dwell time is real but weakly distributed — swipe speed is fairly consistent within a gesture |
| Any run beyond the cap (§6.2) | **0 bits** | A finger parked on one key is not producing entropy |

So ≈ **2.5 bits per run** mid-drag (6 on a fresh stroke), against a nominal 6.55 bits per character. The run structure, not the
character count, is what moves the meter.

### 6.2 Emission and recording rules

- **Record every sample** at the native touch rate, so the string is a faithful record of the gesture.
- **Cap a single run at 12 recorded samples.** A user holding one key for thirty seconds must not
  produce three thousand characters; past the cap the run stops growing and stops crediting.
- **Require minimum travel** (≥ one cell width) before a *transition* counts — a fingertip jittering
  across a cell boundary must not farm transitions at 1.5 bits each.
- **Cap credit per gesture** so a single long swipe cannot satisfy the whole target; reaching it should
  require several separate strokes, which is where the 4-bit touch-down credits come from.

### 6.2a Consequence: the string is long

At ~2.5 bits per run and the **measured** mean run of 1.56 samples (§10), 128 bits is roughly 52 runs
≈ **80–130 characters**, and 256 bits is **160–260**. The field must be built for that: monospace,
wrapping, scrollable, grouped for legibility. Still several times BitWindow's 33-character desktop
field, and longer again on a higher-frame-rate device where runs lengthen.

That length is a feature — it is what an honest accounting of a swipe actually costs — but it does mean
hand-transcribing the string to audit it is impractical. The audit path is copy-to-clipboard, and the
confirm step should show the derived entropy hex so the check is over 64 hex characters rather than
500 base32 ones.

### 6.2b Typed / pasted entropy — inferred, not declared

**In scope for v1.** A user who rolled dice or flipped coins off-device types the result instead of
swiping. Same field, same derivation — only the accounting differs.

**An earlier design had the user declare the source** (dice / coin / hex / free text) on the reasoning
that we cannot observe provenance for typed text, so a declaration would make the credit honest.
**That reasoning was wrong.** Someone who declares "dice" and then mashes the digits 1–6 gets exactly
the credit inference would have given them. The declaration set the alphabet and the target; it never
protected against careless input. The **structural checks did, and still do.** So the picker was a
question the user had to answer for no security benefit, and it is gone.

**What replaces it: infer the alphabet from what was typed.** The only evidence of how many symbols
someone was drawing from is the set they actually used.

| Distinct symbols used | Credit per character | Why |
|---|---|---|
| **≤ 16** | `log2(k)` | A small constrained alphabet is what a mechanical source looks like, and `log2(k)` is a real ceiling there — even a human cannot beat it |
| **> 16** | **1.0 bit** | A large alphabet is what human "random" typing looks like, and is indistinguishable from a genuinely random paste |

This lands on the right answers with nothing declared: 50 d6 rolls → 129 bits, 128 coin flips → 128,
32 hex characters → 128. And it degrades safely — being wrong in the pessimistic direction costs a
careful user some extra typing; being wrong the other way costs someone their coins.

**The residual risk, stated plainly:** someone mashing hex-ish characters is credited up to 4 bits each
when they may be producing 2. The structural checks catch the worst of it, as they always did, and the
meter is presented as an estimate rather than a guarantee.

### 6.3 Structural floor (catches the realistic lazy pattern)

The credit table alone does not catch a user swiping back and forth in a straight line, which produces
a plausible-looking string from a tiny subset of the grid. Before enabling **Continue**, require:

- **≥ 16 distinct characters** used (of 32).
- **No transition bigram covering more than 15% of the runs** — catches `AB AB AB…` oscillation.
  Measured over the run sequence, not the raw string, or the repeats would swamp it.
- **A compression sanity check** over the *run sequence*: run-length + bigram-frequency estimate must
  not indicate it is materially compressible.
- **≥ 3 separate gestures**, so the whole target cannot come from one uninterrupted stroke.

These are cheap, pure, and unit-testable. They are a floor, not a proof.

### 6.4 Targets

| Word count | Entropy needed | Runs at 2.5 bits | ≈ recorded characters | ≈ seconds of swiping |
|---|---|---|---|---|
| 12 | 128 bits | ~52 | 80–130 | **~3** |
| 24 | 256 bits | ~103 | 160–260 | **~5** |

The seconds column is measured, not estimated — §10 recorded ~20 runs/second and a mean run of 1.56
samples from real human swiping. Separate strokes arrive sooner still, since each touch-down credits 5
bits rather than 1.5.

**This is faster than the pre-measurement estimate**, and the string is correspondingly shorter.
Reaching the bit target in three seconds is arguably *too* easy, which
is precisely why the §6.3 structural checks — not the bit counter — are what actually stop a lazy
input from qualifying.

**In mixed mode these targets apply to the user's contribution alone** (§3): the CSPRNG prefix does not
count toward the gate.

**In mixed mode these targets apply to the user's contribution alone** (§3): the CSPRNG prefix does not
count toward the gate.

### 6.5 Honesty about the meter

**Any entropy meter for human input is an estimate, and ours is no exception.** The numbers above are
chosen to be conservative rather than accurate. The UI must not present the meter as a guarantee: it
gates Continue, and the screen carries a plain warning that this mode is for users who understand what
they are giving up. That framing is the point of BitWindow's "You must know what you are doing", and
we should keep it.

## 7. UI and flow

Entry: **Create wallet → Advanced → "Provide your own entropy"**. Off by default; the CSPRNG path is
untouched for everyone else.

Screen layout, top to bottom:

1. **Title + warning.** Space Grotesk title; a `warning`-toned callout explaining that a weak string
   means a weak wallet, and that the app cannot verify their randomness for them.
2. **The entropy field.** JetBrains Mono, wrapping and **scrollable** — it holds 100–260 characters
   (§6.2a), not BitWindow's 33. On `bg2` with a `border` hairline. Read-only to the system: filled by
   the grid, never by the OS keyboard (§8). Carries a copy button for the audit path.
3. **Meter.** A progress bar in `accent` toward the required bits, labelled with the target word count
   (e.g. "96 / 128 bits · 24 words"). Turns `positive` at threshold. Shows the structural-check state
   if a check is failing ("use more of the grid").
4. **The grid.** 12 × 8 ASCII-printable keys (§5), `bg2` cells with `border` hairlines, `text0` glyphs,
   the key under the finger highlighted in `accent`/`accentText` — which is BitWindow's orange
   highlight, and happens to be our brand amber already.
5. **Actions.** "Generate random" (fills from CSPRNG — the non-paranoid escape hatch), **"Shuffle"**
   (§5), "Clear", and a "How this is derived" disclosure carrying the `shasum` recipe.
6. **Continue** — disabled until both the bit target and the §6.3 checks pass.

Then the existing confirm step, which should additionally **show the derived entropy hex** so the user
can check it against their own `shasum` before committing.

Everything uses `Theme.*` tokens; no raw hex, no SF Symbols (Material Symbols `.symbolset` only).

## 8. Security rules (non-negotiable)

The input string is **seed-equivalent material** and gets mnemonic-grade handling:

- **Never** logged, never in analytics or crash reports, never in an error message, never in an
  accessibility label.
- **Never persisted.** Not UserDefaults, not the wallet store, not the Keychain. It lives in view-model
  state for the duration of the screen and is zeroed on dismiss, on background, and after the mnemonic
  is produced.
- **Never through the system keyboard.** This is why the grid is custom: a system keyboard means
  autocorrect dictionaries, third-party keyboard processes, and keyboard cloud sync all see it.
  The field must not be a focusable `TextField`.
- The existing `PrivacyCover` must apply to this screen, so the app-switcher snapshot cannot show it.
- Screenshots stay unblocked, consistent with the Backup-screen decision (CLAUDE.md §7) — capturing
  your own entropy is the user's call, and the UI advises against it.

## 9. Testing (§11 bar — same PR as the code)

Pure and fast, both platforms:

- **Derivation golden vectors.** Fixed input → fixed entropy hex → fixed 12- and 24-word mnemonics.
  Pinned by hand-computed SHA-256 so the test is an independent check, not a restatement of the code.
- **Cross-platform determinism.** The same vectors must pass on the Android runner — this is the
  requirement most likely to break silently.
- **Accounting.** Mid-drag vs new-gesture credit, repeat suppression, minimum-distance and rate gating.
- **Structural checks.** A straight-line back-and-forth swipe must be **rejected**; a genuinely varied
  one accepted. This is the test that encodes §2's trap.
- **Thresholds.** 12 words gates at 128 bits, 24 at 256; Continue stays disabled below either.
- **No-leak assertion.** No error path or description includes the input string (mirrors the existing
  `WalletErrorTests` secret-scrubbing assertions).

Integration: create a wallet from a known input on both platforms and assert identical addresses.

## 10. Android drag support — mostly settled by reading SkipUI

The whole interaction depends on following a finger across the grid on Android. Reading the SkipUI
source (`Sources/SkipUI/SkipUI/System/Gesture.swift`, the `dragGestures` branch) settles most of it:
`DragGesture` maps to Compose `detectDragGesturesWithScrollAxes`, and

- ✅ **Continuous move events work.** `onDrag` is invoked per Compose `PointerInputChange` — i.e. per
  motion event from the digitizer, not just start/end. The high-rate sampling §6.1 depends on is
  available in principle.
- ✅ **Local coordinates are available.** `change.position` arrives in the gesture view's local space,
  which is exactly what cell hit-testing needs; `coordinateSpace: .global` maps through
  `layoutCoordinates.localToRoot` if ever needed.
- ✅ **`minimumDistance: 0` genuinely bypasses touch slop** — it maps to
  `shouldAwaitTouchSlop: false`, so characters register from the first touch rather than after a
  slop threshold.

### ✅ Measured on an Android emulator (2026-09-07)

A throwaway `DragSpikeView` (12×8 grid, one `DragGesture(minimumDistance: 0)` on a `GeometryReader`
container) on a `Medium_Phone_API_36.1` arm64 emulator, driven both by `adb shell input swipe` and by a
human dragging with the mouse:

| Measurement | Human drag, 12.7 s | Synthetic 3 s swipe |
|---|---|---|
| Events | 401 | 118 |
| **Rate** | **31 Hz** | 39 Hz |
| Gap p50 / p95 / max | 30 / 38 / 84 ms | 24 / 31 / 61 ms |
| Runs | 257 (~20/s) | 12 |
| Mean run length | 1.56 samples | 9.83 samples |

**Conclusions:**

1. ✅ **The design is viable — no rewrite needed.** Continuous tracking works through the Fuse bridge.
2. ✅ **Events arrive smoothly.** p95 of 38 ms against a p50 of 30 ms, max 84 ms — the bridge is not
   stalling, dropping or bunching. This was the actual risk, and it is not real.
3. ✅ **Dwell genuinely encodes velocity** — the premise the whole run-length model rests on. The same
   synthetic path at 3× the duration took mean run length from 2.00 to 9.83.
4. ⚠️ **~31 Hz, not the 60–120 Hz assumed.** Consistent across synthetic and human input, which points
   at the *emulator's* frame rate (Compose coalesces pointer events to frames) rather than the bridge.
   **Treat 31 Hz as a floor**; a real 60/120 Hz device should give proportionally more, and longer runs.
5. At 31 Hz a mean run of 1.56 makes the dwell signal coarse — most runs are 1 or 2 samples, worth
   roughly 1–1.5 bits. The 1-bit credit in §6.1 is therefore about right, and conservative at higher
   frame rates where runs lengthen.

**Still worth doing before shipping:** the same measurement on a physical device (the Saga). It only
moves the numbers in our favour, but the dwell credit should be confirmed against a real digitizer
rather than an emulated one.

### SkipUI constraints this work uncovered

Every one of these compiles on the host and fails **only** on the Android leg — `swift build` catches
none of them. Collected here because the pattern is the lesson: run `skip export` early on new UI, not
at the end.

- **`@State` properties must be internal, not private** — `private @State var` is a hard Skip Fuse
  error ("cannot be bridged to Android").
- **`.contentShape()` does not exist.** Make an area hit-testable with a filled background instead.
- **`Color.gray.opacity(0.4)` is ambiguous** in the Android pass. Use solid colours or Theme tokens.
- **Never `import Foundation` in a View** alongside SwiftUI — it makes `CGFloat`/`CGPoint` ambiguous
  ("'CGFloat' is ambiguous for type lookup"). Every view in this app imports SwiftUI alone.
- **`@Observable` needs `import Observation`**, not just `import SkipFuse` ("unknown attribute").
- **`.textSelection` is unavailable.** Use the app's cross-platform `Clipboard.copy` — which is the
  better answer anyway for a 260-character string.
- **Deeply nested `ForEach` with inline arithmetic** trips "unable to type-check this expression in
  reasonable time". Hoist the arithmetic into `let`s and split into helper views.
- **⚠️ `ForEach` over a COMPUTED range renders NOTHING on Android** — silently, with the layout space
  still reserved, so the UI is simply absent with no error, no warning and no crash. `0..<rowCount`
  and `start..<end` both produced an empty keypad on a real device while compiling clean on both
  platforms. `ForEach(0..<rows)` works only because that bound is a stored `let`, which is why the
  swipe grid rendered and the keypad did not. **Iterate a collection instead** — an `Identifiable`
  struct per row, or `ForEach(array, id: \.self)`. This one is invisible to every automated check we
  have; only looking at the screen catches it.
- In tests: `import Foundation` is required, `Data([literal])` is unavailable (use a typed array),
  `.map(String.init)` doesn't transpile (use `{ String($0) }`), and unsigned literals need explicit
  casts (`UInt8(0x0f)`).
- Crossing into BDK, `Mnemonic.fromEntropy` takes a Kotlin `ByteArray` — `entropy.platformValue`
  behind `#if SKIP`, the same seam as `TxBuilder.addData`.

### Three SkipUI constraints originally uncovered by the spike

All three compile fine on the host and fail **only** on the Android leg — `swift build` will not catch
any of them:

- **`@State` properties must be internal, not private.** `private @State var` is a hard Skip Fuse
  error ("cannot be bridged to Android").
- **`.contentShape()` does not exist in SkipUI.** Make the area hit-testable with a filled background
  instead — a `Color` behind the grid.
- **`Color.gray.opacity(0.4)` is ambiguous** in the Android pass. Use solid colours, or `Theme` tokens
  which already resolve per platform.

Also confirmed: **a tap registers as a drag event** when `minimumDistance: 0`, so the real accumulator
must distinguish a tap from a stroke rather than treating every touch-down as swipe input.

## 10a. Changes from user testing (2026-09-07)

Everything below came from actually using the feature on a device, and none of it was visible from the
plan:

- **Two screens, not one.** Options (mode, method, audit recipe, seed length read-only) then an input
  screen that is only input. The single-screen version had six controls fighting for a phone screen.
- **The source picker is gone** (§6.2b) — typed entropy infers its rate instead.
- **Seed length stays in Settings**, reversing an earlier decision.
- **The grid emits on every drag event**, so dwell actually produces runs. It was emitting once per
  cell, which silently disabled the run-length half of the model.
- **Repeats are throttled** to one per 35 ms, transitions never. Without it the string length depended
  on the device's frame rate — the same gesture recorded twice as many characters at 120 Hz as at 60.
- **The produced string auto-scrolls** to the newest characters. Two cleverer approaches came first and
  both looked wrong: windowing by character made the block appear to slide left and be eaten, and
  windowing by fixed-width line needed a guessed pixel height whose guess clipped the newest line.
- **Heights above the grid are reserved**, so the grid doesn't visibly shrink on the first character.
- **The live recovery phrase is shown while entering**, dimmed until the gate passes — watching it
  churn is what makes "every character changes the wallet" visible rather than an article of faith.
- **A seed preview step before creation**, showing the words and the derived entropy hex. Creating
  silently and revealing the phrase afterwards skipped the one step the user came for.
- **Pasting a copied field reproduces its wallet** — user testing found that Copy handed over a full
  field, which when pasted was treated as a *contribution* and nested inside a fresh one, silently
  giving different words. A pasted field is now used verbatim, carries its own word count, and is
  exempt from the entropy gate for the same reason importing a recovery phrase is.
- **Custom entropy is ON by default** — mixed mode is never weaker than the device alone, so the cost
  is a few seconds and the gain is surviving a compromised RNG. This forced the warning copy to become
  mode-dependent: "only use this if you understand what you're doing" cannot be said of the default.
- **The input is no longer wiped when the preview is pushed.** `onDisappear` fires on a forward push
  too, so going to look at your words destroyed a minute of swiping.

### The meter says what it is now

A reviewer made the sharpest criticism this feature has had: **"128 bits here is NOT the same as 128
bits of random entropy."** Correct — and §6.5 already said so while the UI contradicted it, showing a
bare bit count in green.

A CSPRNG's 128 bits is a guarantee about a process. Ours is the output of a model (1.5 bits per
transition, 1 per dwell) — a guess about human behaviour that can be wrong, and only in the dangerous
direction: people start swipes where their thumb rests, paths have characteristic curvature, and a
person's velocity is consistent enough that dwell is worth less than assumed.

The meter now reads `est. 153/128 bits` with a mode-dependent caveat beneath it. **The asymmetry is the
point:** in mixed mode the CSPRNG contributes its full 128/256 regardless, so the wallet is at least as
strong as a normal one no matter how wrong the model is — the estimate only measures what the user is
*adding*. In user-only mode the estimate is the entire security, and that line is warning-coloured.

## 11. Build order

1. ~~Spike the Android drag gesture~~ — **done** (§10); re-measure on a physical device before ship.
2. ~~Decide domain separation~~ — **resolved** by the field format (§3).

**Steps 3–6 are BUILT** (2026-09-07): `EntropyDerivation` (WalletService), `EntropyAccumulator` /
`TypedEntropySource` / `EntropyViewModel` / `EntropyGridView` (app), the `Mnemonic.fromEntropy` create
path, and the screen wired behind Create → Advanced. Builds and runs on iOS; Android APK builds clean.
554 tests green (348 app + 206 WalletService). Remaining: 7 (typed-mode polish) and 8 (confirm-step
hex display), plus the physical-device drag measurement.
3. `EntropyDerivation` — pure, golden-vector tested. No UI. ✅
4. `EntropyAccumulator` — accounting + structural checks, pure, tested. ✅
5. `WalletManager.createWallet(entropyField:)` through `Mnemonic.fromEntropy`. ✅
6. The grid view + input screen, behind Create → Advanced. ✅
7. Typed entropy with an **inferred** alphabet (§6.2b) — no source to declare. ✅
8. Confirm-step entropy-hex display and the derivation disclosure. ✅

**Screen structure (revised 2026-09-07 after using it on a device):** two screens, not one. An
**options** screen (source, method, the audit recipe, seed length read-only) then an **input** screen
that is nothing but the field, the meter and the input surface. The single-screen version put three
segmented controls, a source picker, the field, a meter, the grid and five buttons on one phone screen;
it was unusable and the keyboard covered the parts you needed to watch.

## 12. Open questions

All resolved 2026-09-07.

1. ~~Domain separation~~ — **resolved** by the field format (§3).
2. **The input string is shown only during creation.** It is seed-equivalent and the mnemonic is the
   real backup, so there is no second copy to store, protect or leak afterwards.
3. **Typed / pasted entropy IS in v1**, via declared sources (§6.2b).
4. ~~The 12/24 choice moves onto this screen.~~ **REVERSED 2026-09-07 — it stays in Settings → New
   wallets**, where it already was. Moving it made the entropy screen one control busier for a
   decision that is not per-create, and it would have left two places able to change the same
   preference. It is surfaced read-only on the options screen, since it sets the target.

### Remaining task (not a question)

Re-measure the drag event rate on a physical device (§10). It can only move the numbers in our favour,
but the run-length dwell credit should be confirmed against a real digitizer.
