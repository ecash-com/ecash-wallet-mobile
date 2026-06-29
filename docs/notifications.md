# Notifications — decision record

> **Status: DECIDED (2026-06-26).** Captures two calls so they don't get re-litigated:
> **(1) server-driven push is intentionally declined**, and **(2) if notifications are ever needed,
> local-notification-on-sync via the `PlatformBridge` seam is the sanctioned path.** Relates to the
> privacy posture in README "Security model" and `docs/backends-and-endpoints.md`.

## 1. Remote push (FCM / APNs / skip-notify) — DECLINED

Server-driven push notifications are **not** a fit for an open-source, non-custodial, privacy-focused
wallet:

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
