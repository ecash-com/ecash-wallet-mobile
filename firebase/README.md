# Firebase Hosting — wallet backend-endpoint config

This folder hosts a small **static JSON** that tells the eCash.com Wallet app which
Electrum/Esplora backends (and explorer/faucet/CoinNews URLs) to use per network. Hosting it
remotely lets us **rotate an endpoint without shipping an app update**.

It reuses the existing Firebase project (`ecash-wallet-3b5c9`, the same one used for FCM push).
There is **no Cloud Function** — this is a plain file served from Firebase Hosting's CDN.

## Layout

```
firebase/
├─ .firebaserc        # pins the Firebase project (ecash-wallet-3b5c9) — project id only, not a secret
├─ firebase.json      # Hosting config: public dir + Cache-Control headers
├─ public/            # everything under here is served publicly
│  └─ wallet-endpoints/
│     └─ v1.json      # the endpoints payload (schema_version 1)
└─ README.md          # this file
```

Public URL once deployed:

```
https://ecash-wallet-3b5c9.web.app/wallet-endpoints/v1.json
```

## What this file is (and is NOT)

**Everything here is public and safe to commit** — this repo is public on GitHub.

`v1.json` carries **rotatable, non-consensus data ONLY**:

- backend endpoints (`kind` = `electrum` / `esplora`, `url`, `priority`)
- explorer URL template, faucet URL/amount, CoinNews indexer URL

> A `min_app_version` "please update" nag is a natural future addition here, but it is **not
> implemented** — the app doesn't read it — so the field is intentionally omitted rather than
> shipped with a placeholder value. Add it back (and the client-side check) together when that
> feature exists.

It must **NEVER** carry consensus/derivation params — coin-type, address HRP, unit label,
network magic. Those are compiled into the app's `NetworkRegistry` (Golden Rule §1/§4). A server
must not be able to change how addresses are derived. **Endpoints from the network, params from
the code.**

Networks are keyed by `WalletNetwork` rawValue: `bitcoin`, `signet`, `ecash`.

> `ecash` is currently the **drynet2** dry-run chain. Its Esplora serves the REST API at the
> **root path** — the URL has **no `/api` suffix** (a suffix would 404 the BDK client).

### Client contract

The app treats this config as **advisory**:

1. Ships the compiled `NetworkRegistry` values as the **bundled fallback** — if the fetch fails,
   times out, or the `schema_version` is unknown, the app keeps working offline on the defaults.
2. Overlays **only** the endpoint/service/explorer fields from this file onto the registry.
   Consensus params are always taken from code, never from the payload.
3. A user's per-network **Settings override wins over everything** (both this file and the
   bundled default).

Keep `refresh_after_seconds` in the payload roughly in line with the `Cache-Control` `max-age` in
`firebase.json` so clients and the CDN expire on a similar cadence.

## Editing the config

1. Edit `public/wallet-endpoints/v1.json`.
2. Bump `generated_at`.
3. Only add endpoints you've **verified reachable** (don't invent URLs). Quick checks:
   - Esplora: `curl https://<host>/blocks/tip/height` → returns a number.
   - Electrum: it's a TCP/SSL server, not HTTP — verify with an Electrum client, not curl.
   - Explorer: `curl -I https://<host>/tx/<a-known-txid>` → HTTP 200.
4. Open a PR. Changes go through review because wallets depend on this file.

### Breaking changes

Bump the filename, not just `schema_version`: add `public/wallet-endpoints/v2.json` and leave
`v1.json` in place so already-shipped app versions keep resolving their pinned path.

## Deploying

You need the Firebase CLI and access to the `ecash-wallet-3b5c9` project.

```bash
# one-time: install the CLI
npm install -g firebase-tools    # or: curl -sL https://firebase.tools | bash

# from THIS folder
cd firebase

# interactive login (run it yourself in the terminal):
#   ! firebase login
firebase login

# preview locally before publishing
firebase emulators:start --only hosting     # serves at http://localhost:5000/wallet-endpoints/v1.json

# publish
firebase deploy --only hosting

# optional: a shareable preview channel that expires, instead of going live
firebase hosting:channel:deploy preview --expires 7d
```

Run from the repo root instead of `cd firebase` with:

```bash
firebase deploy --only hosting --config firebase/firebase.json
```

### CI deploys (no interactive login)

Use a **service-account key** provided as a CI secret — never commit it. `.gitignore` already
blocks `**/firebase-service-account*.json` and `**/*-firebase-adminsdk-*.json`.

```bash
# CI: point the CLI at the service account via env, then deploy non-interactively
export GOOGLE_APPLICATION_CREDENTIALS="$RUNNER_TEMP/firebase-sa.json"   # written from a CI secret at runtime
firebase deploy --only hosting --project ecash-wallet-3b5c9 --non-interactive
```

(Mint the key in Firebase console → Project settings → Service accounts, grant it the
**Firebase Hosting Admin** role, and store it as a base64 CI secret — same pattern as
`GOOGLE_SERVICES_JSON_BASE64`.)

## Secrets policy (public repo)

- ✅ Commit: `.firebaserc`, `firebase.json`, `public/**` — none are secret.
- ❌ Never commit: any service-account / admin-SDK JSON (already gitignored). Deploy creds live in
  CI secrets only.
- The Firebase **project id** (`ecash-wallet-3b5c9`) is **not** a secret — it ships in every
  client app and appears in API URLs; Firebase security comes from rules/API restrictions.
