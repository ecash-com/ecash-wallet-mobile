# Notifications — decision record

> **Status: SUPERSEDED (2026-06-29) — push is now ENABLED.** The original decision (below) declined
> server push because "you got paid" would need a backend that learns user addresses. That reasoning
> still holds for *transactional* push. But for **manual broadcast announcements** there's no such
> backend and no wallet data involved, so push was adopted via **`skip-firebase` (FCM, both
> platforms)** — verified working on Android + iOS, one Firebase-console send reaches all devices.
> Full setup + gotchas: memory `push-notifications-setup`. The §1–2 below are the *original* record,
> kept for the rationale.
>
> **What changed vs. the original "if needed, do local-notification-on-sync":** that was the fallback
> when we wanted zero server involvement. We accepted Firebase (Google in the path) specifically for
> *broadcast announcements* — payloads must still carry **no** amounts/addresses/wallet data.

## 1. Remote push (FCM / APNs / skip-notify) — original concern (still true for *transactional* push)

Server-driven *transactional* push ("you received a payment") is **not** a fit for an open-source,
non-custodial, privacy-focused wallet:

- **Requires a server that learns each user's addresses.** The app talks directly to
  Electrum/Esplora/the CoinNews indexer; there is no backend that knows when *you* get paid. To send
  "payment received," something server-side must watch the chain for the user's addresses — which
  means that infrastructure (and thus us) learns the user's address set. That quietly contradicts the
  "we can't see your funds" posture.
- **Third parties in the path.** Push routes through Google (FCM) and Apple (APNs); payloads must
  never carry amounts/addresses/balances.
- **New infra + ops + cost** for a backend we otherwise don't have.

`skip.dev/docs/modules/skip-notify` (remote-push-only; manages FCM/APNs tokens, needs a sender
backend) was evaluated and set aside for these reasons. Credentials it would need (a company-owned
Firebase project → Sender ID + service-account for Android; an APNs `.p8` auth key for iOS) are cheap
and easy — but the *backend that knows user addresses* is the real, declined cost.

## 2. Local notifications (on-device) — SANCTIONED PATH if/when needed

If notifications are ever requested, use **local notifications** triggered by the app's own sync —
no server, no FCM/APNs, no third party beyond the Electrum/Esplora backend the user already trusts,
nothing leaves the device.

- **No Skip module for this** — skip-notify is remote-only and Skip has no local-notification
  framework. Implement via the existing platform seam (`Packages/WalletService/Sources/WalletService/Platform.swift`
  `PlatformBridge`, same pattern as `setSecureScreen` / `authenticateUser`):
  - **iOS:** `UserNotifications` (`UNUserNotificationCenter`) — native in Fuse.
  - **Android:** `NotificationManager` / `NotificationCompat` in the `#elseif SKIP import android.…`
    branch.
  - Sketch: `PlatformBridge.requestNotificationPermission()` + `PlatformBridge.showLocalNotification(title:body:)`.
- **Permissions:** iOS `requestAuthorization`; **Android 13+ (API 33+)** runtime `POST_NOTIFICATIONS`
  (minSdk 28 / target 36 → declare + prompt).
- **Timing is the real limitation, not the API.** Foreground / just-opened notifications are
  reliable; firing while the app is closed depends on best-effort background sync
  (`BGProcessingTask` / `WorkManager`), same mobile constraint as the churn scheduler in
  `docs/transaction-deniability.md`. Set expectations: "you'll see it next background window or on
  open," not real-time.

## Bottom line
No push backend. Local-notification-on-sync is the privacy-clean fallback — a small `PlatformBridge`
addition, zero credentials, zero CEO ask — to reach for only if users actually need it.

---

## Phase 2 — in-app alert sheet (BUILT 2026-06-29)

Tapping an announcement push opens the app to an in-app **alert sheet** (`AlertSheet`) showing the
push content: a brand mark, a title, and a **Markdown** body (bold/italic/links — links open in the
browser; only inline Markdown, no headings/lists — same `LocalizedStringKey` path as CoinNews).

**How it's wired:** `NotificationDelegate.didReceive` (tap handler) → `PushRouter.shared.handle(...)`
→ sets `pendingAlert` → `RootView`'s `.sheet(item:)` presents `AlertSheet`. `kind` is the switch:
only a recognized `kind` opens a sheet; anything else just shows the system banner. Announcements
are company-only and carry **no wallet data**, so links render + open directly (no phishing gate).

### Step-by-step: sending from the Firebase console

There are two ways to send. **A test message** targets one device by FCM token (fast, no setup —
use this to verify) and shows up immediately. **A campaign** targets the app or the `announcements`
topic (reaches everyone) but is the "Notifications" composer with a Review/Publish flow.

**Quick test send (one device, recommended for verifying):**
1. Get the device's FCM token: in the app **Settings**, in the developer section, tap **Register
   for push notifications** if not already registered, then **Copy push token** (the token is shown
   below the button).
2. Firebase console → project **`ecash-wallet-3b5c9`** → left nav **Run → Messaging** (a.k.a. Cloud
   Messaging).
3. Click **Create your first campaign** / **New campaign** → choose **Firebase Notification
   messages** → **Create**.
4. Fill **Notification title** + **Notification text** (the tray text — see the table below).
5. Click **Send test message** (top-right of the compose card). Paste the FCM token from step 1,
   click **+** to add it, then **Test**. It arrives on that device within seconds.
   - ⚠️ The **Send test message** dialog only sends the *notification* block — it does **not**
     include custom data. To test the in-app sheet's `kind`/`title`/`body`, use a campaign (below)
     or the HTTP v1 API. The notification title/text alone still opens the sheet via the fallback,
     so a test send is enough to confirm tap→sheet works; use a campaign to exercise custom `body`.

**Campaign send (all devices — the real announcement path):**
1. Console → **Messaging** → **New campaign** → **Firebase Notification messages**.
2. **Notification:** fill title + text (tray text).
3. **Target:** **App** = `com.layertwolabs.mobile.ecashwallet` (iOS) / `ecash.wallet.mobile`
   (Android). Optionally narrow to the **`announcements`** topic (every install subscribes to it).
4. **Scheduling:** **Now**.
5. **Additional options (optional):** expand → **Custom data** → add the `kind` / `title` / `body`
   rows (the table below). This is what drives the rich in-app sheet.
6. **Review** → **Publish**. (Topic/app sends can take a few minutes to fan out.)

### What to enter (Notification block + Custom data)

The FCM message has two parts: the **Notification** block (the tray text the OS shows) and the
**Additional options → Custom data** block (key/value pairs that drive the in-app sheet).

**Notification block** (always set these — this is what shows in the system tray / banner):

| Field | Value |
|---|---|
| Notification title | the tray title, e.g. `eCash.com Wallet` |
| Notification text | the tray body, e.g. `New update available` |

**Custom data (key/value)** — these control the in-app sheet:

| Key | Value | Required? |
|---|---|---|
| `kind` | `alert` | **Yes** — the switch. Without `kind=alert`, tapping shows the banner only, no sheet. |
| `title` | sheet title (plain text) | Optional — falls back to the Notification **title** if omitted. |
| `body` | sheet body, **Markdown** (`**bold**`, `*italic*`, `[link](https://…)`) | Optional — falls back to the Notification **text** if omitted. |

**Minimal send (reuses tray text for the sheet):** Notification title/text + one custom key
`kind = alert`. The sheet shows the tray title/body, no Markdown.

**Rich send (Markdown sheet):** Notification title/text (plain, for the tray) + custom data:
```
kind  = alert
title = eCash 0.1.1 is out
body  = We shipped **push notifications** and bug fixes. [Read the notes](https://ecash.com/blog/0-1-1)
```
The tray shows the plain Notification text; tapping opens the sheet with the bold + tappable link.

**Notes / gotchas:**
- **200-character cap per custom-data value** (Firebase console limit). So `title` and especially
  `body` are each ≤200 chars. This is short for an announcement — design for it: a one/two-sentence
  teaser + a `[Read more](https://…)` link out to the full content (the link URL counts toward the
  200 too, so keep URLs short). For anything longer than a couple sentences, link out rather than
  trying to fit the whole post in `body`.
- Markdown is **inline only** — `**bold**`, `*italic*`, `` `code` ``, `[text](url)`. Headings (`#`),
  bullet/numbered lists, blockquotes, and code fences render as literal text (Fuse Android has no
  `AttributedString(markdown:)`; we use `LocalizedStringKey` parsing). Fake a list with line breaks +
  a bullet character if needed.
- Custom-data values are **strings** — paste Markdown directly into the `body` value field.
- The sheet presents over whatever is on screen (incl. the lock screen) — safe, since announcements
  carry no wallet data.
- Foreground behavior: an arriving push shows the system banner even when the app is open
  (`willPresent` → `[.banner, .sound]`); the sheet opens only on **tap** (no auto-pop).
- Adding a future route (e.g. a deep-link `kind`) is one `case` in `PushRouter.handle` — no change to
  the send format beyond a new `kind` value.
