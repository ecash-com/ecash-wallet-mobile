# Chain backends & custom endpoints

> Decision record for how the wallet fetches chain data and how users point it at their own server.
> **Status:** v1 **SHIPPED (2026-06-14)** — user-selectable **Electrum OR Esplora** custom endpoint
> per network (Settings → Network), verified on both platforms.
> **SOCKS5/Tor proxy: built but UI HIDDEN (2026-06-15).** The plumbing is complete end-to-end
> (`setProxy` → `WalletEngine` clients carry the proxy on sync/broadcast/test), but the Settings row
> is commented out so it doesn't confuse users: there's no bundled Tor, it needs a user-run SOCKS5
> (Orbot on Android; nothing reachable on iOS), and the real Tor route + `.onion` remote-DNS is
> **unverified**. Re-enable by uncommenting the Privacy section in `NetworkSettingsScreen` once
> verified (§7). **CBF** (own-node, P2P) and **embedded Tor** are **v2**. See CLAUDE.md §6 and
> [[wallet-and-network-model]].

## 1. How sync works today

A BDK wallet is descriptor-based and watch-only ([[key-storage-model]] §3). To sync it asks a backend
for the history/UTXOs of its scriptPubKeys. We use BDK's **`ElectrumClient`** or **`EsploraClient`**
for sync (`fullScan` first time, `sync`/revealed-spks after) and broadcast — the engine branches on
the configured `WalletBackend.kind`. Each `WalletNetwork` has a default endpoint in `NetworkRegistry`;
a per-network override (kind + url + optional SOCKS5) threads through `WalletManager` → the factory's
`engine(…, backendKind:backendURL:backendProxy:…)` → `WalletEngine` (the old single-string
`electrumURLOverride` param was generalized to these backend primitives).

**Electrum ≠ full-node RPC.** An Electrum server (electrs/Fulcrum/ElectrumX) is an **address-indexing
server in front of** a full node — it maintains a `scriptPubKey → history` index BDK can query.
Bitcoin Core's JSON-RPC has **no general address index**, so a descriptor wallet can't sync off raw
Core RPC. All backends return the **same chain data** (same UTXOs/txs — it's one blockchain); they
differ in *mechanism* and *privacy*.

## 2. Backend choices in BDK (bdk-swift 2.3.1 binding)

The FFI binding exposes three clients — **no bitcoind-RPC client**:

| Backend | Client | URL form | Notes |
|---|---|---|---|
| **Electrum** ← shipped | `ElectrumClient(url:, socks5:)` | `ssl://host:port`, `tcp://host:port` | index server; SOCKS5 (Tor) supported |
| **Esplora** | `EsploraClient(url:, proxy:)` | `https://host/...` (HTTP API) | index server; proxy (Tor) supported |
| **CBF** (v2) | `CbfBuilder`/`CbfClient` | P2P peers | compact block filters (BIP157/158), trustless, no index server, SOCKS5/Tor |

The two index clients differ at exactly three call sites (so the engine branches there):
- **construct:** `ElectrumClient(url:, socks5:)` vs `EsploraClient(url:, proxy:)`
- **scan/sync:** Electrum `fullScan(request:, stopGap:, batchSize:, fetchPrevTxouts:)` / `sync(request:, batchSize:, fetchPrevTxouts:)` vs Esplora `fullScan(request:, stopGap:, parallelRequests:)` / `sync(request:, parallelRequests:)`
- **broadcast:** Electrum `transactionBroadcast(tx:)` vs Esplora `broadcast(transaction:)`

## 3. Decision

- **v1 — user-selectable Electrum *or* Esplora, custom endpoint per network.** Both are index servers
  and trivially supported by the binding; letting the user run their **own** server is the privacy +
  reliability win (a public server sees all your addresses).
- **v2 — CBF (use your own full node, no index server).** The trustless/private option BDK actually
  gives us (Core-RPC-alone is not viable). Bigger feature: peer config, filter download, longer sync.

## 4. Design

### Backend abstraction
Replace the engine's `electrumURL: String` with a typed backend value:

```
enum WalletBackendKind { case electrum, esplora }          // (+ .cbf in v2)
struct WalletBackend { let kind: WalletBackendKind; let url: String }
```

> **Non-BDK kinds (2026-09-01).** `WalletBackend.Kind` also carries `thunder` and `thunder-esplora`.
> Neither is a BDK backend: Thunder wallets are served by the Fuse-native `ThunderService`, which
> picks its wire layer from the kind (`ThunderBackendFactory`) — the node's JSON-RPC, or a
> drivechain-esplora index. They live in this enum because `resolvedBackend` funnels every override
> through `Kind.from`, and a kind it doesn't recognise makes a user's Settings override *silently*
> fall through to the bundled default. The four BDK call sites that switch on `kind` therefore carry
> an explicit "Thunder never reaches BDK" arm rather than a `default`. See
> `docs/thunder-sidechain-support.md` §8e.

- `NetworkRegistry` `defaultBackend` becomes a `WalletBackend` (kind + url). Kind can also be inferred
  from the scheme (`ssl://`/`tcp://` → Electrum, `http(s)://` → Esplora) so a single string stays the
  canonical form if preferred.
- `WalletEngine` holds a `WalletBackend` and branches at the three call sites above. (Implementation
  option: keep a thin `BackendClient` wrapper so `sync`/`fullScan`/`broadcast` have one Swift-facing
  signature and the `#if SKIP` BDK branch is tiny — same pattern as the rest of the seam.)

### User override (Settings → per-network)
- Persist a per-network override `{ kind, url }` (UserDefaults keyed by network, or the
  `FileWalletStore`). `nil` → fall back to `NetworkRegistry.defaultBackend`.
- `WalletManager`/`AppState` reads the override and passes it to the factory → engine (the old
  `electrumURLOverride` param was generalized to `backendKind`/`backendURL`/`backendProxy` primitives,
  resolved from per-network UserDefaults keys; changing it evicts cached engines).
- **Settings UI:** per network — a segmented **Electrum / Esplora** picker + a URL field (mono,
  `.textFieldStyle(.plain)`), **Test connection** (validate before saving), **Save**, and **Reset to
  default**. Show the active backend on the network row.
- **Validation:** lightweight probe before accepting — Electrum `server.version` / get-tip; Esplora
  `GET /blocks/tip/height`. Reject unreachable/malformed; never block the UI (off-main, like sync).

### Privacy & SOCKS5 / Tor (v1)
A **public** index server learns your whole address set; routing over **Tor** (or any SOCKS5 proxy)
hides your IP and unlocks `.onion` endpoints. Both BDK clients already take a proxy arg
(`ElectrumClient(url:, socks5:)`, `EsploraClient(url:, proxy:)`), so this is **carried on
`WalletBackend`**, not a separate mechanism:

```
struct WalletBackend { let kind: WalletBackendKind; let url: String; let socks5: String? }
```

- **Settings (Network privacy):** an app-level **"Route through a SOCKS5 proxy"** toggle + a proxy
  `host:port` field (e.g. `127.0.0.1:9050` for Orbot/local Tor). When set, it's passed to whichever
  client the engine builds; `.onion` Electrum/Esplora URLs become usable.
- **No bundled Tor in v1** — there's no system Tor on iOS/Android, so v1 relies on the user running a
  SOCKS5 provider (Orbot on Android, a local/again-self-run Tor, or an SSH tunnel). That's the
  pragmatic "Tor support" and needs zero new native dependencies — just the proxy string.
- **Embedded Tor is v2** (below): the app ships its own Tor engine so `.onion` "just works" with no
  external app.

## 5. v1 scope — SHIPPED (2026-06-14)

- [x] `WalletBackend` (kind + url + `socks5`) — internal value type (kept off the bridged surface; the
      factory protocol takes primitives so it never appears in a public signature).
- [x] `WalletEngine` branches Electrum/Esplora at construct + scan/sync + broadcast, passing `socks5`
      to the client init.
- [x] Per-network override: persist `{kind,url}` in UserDefaults; resolved through `WalletManager` →
      factory → engine; default-fallback when unset; cached engines evicted on change.
- [~] **SOCKS5/Tor:** app-level "route through SOCKS5 proxy" toggle + `host:port`, threaded onto the
      backend (sync/broadcast/test all carry it). **UI hidden 2026-06-15** pending the verification in
      §7 below — plumbing stays, the Settings row is commented out.
- [x] Settings → Network: per-network Electrum/Esplora picker + URL + Test connection + Save + Reset;
      the proxy setting alongside (clean Android inputs — `.textFieldStyle(.plain)` + `fieldBoxInset()`).
- [x] Tests: backend selection/fallback + the mock factory's `testBackend` probe. Verified by host
      build + `skip export --debug` (both platforms) + WalletService tests green.

## 5a. SOCKS5/Tor proxy — to re-enable (un-hide the UI)

The toggle is hidden (status block above). Before bringing it back, verify it actually works rather
than just compiles:

- [ ] **Verified Tor round-trip on Android** — run Orbot (`127.0.0.1:9050`), point the proxy at it,
      confirm a sync succeeds *and* the exit IP is Tor (not the device's).
- [ ] **`.onion` endpoint works** — confirms BDK does *remote* DNS through the proxy (SOCKS5h); if it
      resolves locally, `.onion` silently fails.
- [ ] **`host:port` input validation** + a clear "proxy unreachable / is Orbot running?" error
      (today a bad/absent proxy just shows the generic connection error).
- [ ] **iOS story** — no local SOCKS5 provider is reachable on iOS; either gate the row to Android or
      wait for embedded Tor (§6). Don't show a dead toggle on iOS.

Code to restore: uncomment the Privacy `Section` + `proxyValueLabel` in `NetworkSettingsScreen`
(`ProxySettingsEditor` is already in place; the engine plumbing never left).

## 6. v2 / future

- **Embedded Tor** — bundle a Tor engine so `.onion` works with no external SOCKS5 provider. Heavy:
  a native Tor lib per platform (e.g. `Tor.framework`/`arti` on iOS, `tor-android`/`arti` on Android)
  with bootstrap + lifecycle, integrated outside BDK. Cross-platform under Skip is the hard part —
  it's a native dependency, likely wired through the transpiled `WalletService` glue or app-module
  native libs (verify feasibility before committing). v1's SOCKS5 field covers the meantime.
- **CBF** ("use your own node", P2P, BIP158) — `CbfBuilder` with peers, `scanType`, `dataDir`,
  SOCKS5. Trustless + private, heavier sync. Own milestone (pairs well with embedded Tor).

## 7. Open questions

1. Persist overrides in **UserDefaults** (simple, app-owned) or the `FileWalletStore`? (Leaning
   UserDefaults — it's app config, not wallet data.)
2. Validation depth — a cheap reachability probe vs. a full test sync before saving.
3. Default `kind` inference by scheme vs. an explicit stored `kind` field (leaning scheme-inference
   for the canonical form, explicit picker in the UI).
