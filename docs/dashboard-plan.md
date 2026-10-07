# Dashboard tab — plan

> Status: **BUILT** (2026-10-07) — P1–P5 done, verified on the iOS simulator and Android emulator
> against live sources. Replaces the News tab with a native **Dashboard** modelled on
> <https://ecx-dashboard.vercel.app>, with CoinNews as one section inside it. Code: `Sources/…/Dashboard/`,
> `Screens/Dashboard*.swift`, `EcosystemNewsScreen`, `MarketsScreen`. §10 lists where the build
> departed from this plan.

## 1. Decisions (made)

| # | Decision |
|---|---|
| D1 | The **News** tab becomes **Dashboard**. CoinNews stays, as a **section inside** the dashboard. |
| D2 | **No eCash.com API.** Every number comes from a public source the app calls directly. |
| D3 | The dashboard shows **one network**: **betanet now, mainnet as soon as it goes live**. No picker, not tied to the selected wallet. The switch is a remote-config value, so it flips at the fork with no app update (§4.6). |
| D4 | **No CoinGecko.** Prices come from exchange/DEX tickers (§4.2). |

## 2. What we're recreating

The reference site (server-rendered Next.js, no JSON API) has these blocks. ✅ = in the app plan.

| Reference block | Plan | Notes |
|---|---|---|
| Network switcher (Beta / Alpha / Mainnet) | ➖ | Dropped (D3): one live network, chosen by config. The network name shows in the section header |
| Market prices table | ✅ | Price, 24h %, volume. **Market cap dropped** — exchanges don't publish supply (§4.2) |
| Network metrics (height, tx 24h, TPS, mempool) + methodology | ✅ | Each metric has an ⓘ sheet with its definition, like the site |
| Activity by block (bar chart) | ✅ | Bars from plain `Rectangle`s — no `Canvas` on Skip |
| Latest blocks table | ✅ | Height, time, tx, size, miner |
| News ("From the ecosystem") | ✅ | From `news.ecash.com/rss.xml` |
| Official releases | ✅ | Node release from `releases.ecash.com`, wallet release from GitHub |
| Observation-status matrix | ➖ | Folded into per-card "updated 2 min ago" / "unavailable" states |
| Sidechains | ✅ (link) | Reuses the existing `SidechainsScreen` |
| Links (ecash.com, Telegram, Discord, YouTube) | ✅ | Small footer section |
| Adoption / Ecosystem / Development tabs | ⬜ later | Revisit once we know their data sources |

## 3. UI design

Native-first (memory: platform-idiomatic design): stock nav bar and tab bar, brand only through
`Theme` tokens, fonts and the domain cards. Every card uses the existing card chrome (`bg1` fill,
hairline `border`, `Radius.md`) — the same look as `TxDetailSheet`'s cards.

### 3.1 Tab bar

`Wallet · Activity · Dashboard · Settings` — the News slot is renamed, with a dashboard/grid icon
(Material Symbols `space_dashboard`, `.symbolset`, outline + fill pair like the other tabs).

### 3.2 Dashboard root (scrolling)

```
┌──────────────────────────────────────┐
│ Dashboard                            │  large nav title
│                                      │
│ ECX                                  │  ── 1. Hero price card
│ $128.31            ▼ 18.80%          │     implied ECX price (wbECX × ratio, §4.2), big mono
│ wbECX $2.57 · Orca · 24h vol $4.5K   │     source line, small text2
│ updated 15:25                    ⓘ   │
│                                      │
│ NETWORK · BETANET                    │  ── 2. Network metrics: 2×2 grid (header names the live
│                                      │     network; reads MAINNET after the fork)
│ ┌───────────────┐ ┌───────────────┐  │
│ │ Block height  │ │ Tx · 24h      │  │     label (sm, text2) + value (mono 20)
│ │ 971,335       │ │ 97,726        │  │     each tile tappable → methodology sheet
│ └───────────────┘ └───────────────┘  │
│ ┌───────────────┐ ┌───────────────┐  │
│ │ Observed TPS  │ │ Mempool       │  │
│ │ 1.131         │ │ 1,627 tx      │  │
│ └───────────────┘ └───────────────┘  │
│                                      │
│ Activity by block              See ›│  ── 3. Bar chart, last ~24 blocks
│ ▁▃▇▅▁▆▇▂▃▅▇▆ ...                     │     bar height = tx_count, accent; tap → Network detail
│                                      │
│ COIN NEWS                      See ›│  ── 4. CoinNews: top 3 posts (title, votes, age)
│ • Post title …            ▲12 · 2h   │     "See ›" pushes the existing NewsScreen
│ • …                                  │
│                                      │
│ FROM THE ECOSYSTEM             See ›│  ── 5. eCash.com news: latest 3 RSS items
│ 05 Oct  CoinCarp Adds eCash (ECX) …  │     date (mono, text2) + title (2 lines) + source
│         CoinCarp · Market Data       │
│ 02 Oct  Sidecoin Ships First …       │
│                                      │
│ MARKETS                        See ›│  ── 6. Compact market list (BTC, BCH, BSV, XEC, BTCB2)
│ Bitcoin   BTC   $83,196   ▼ 3.7%     │     one row each: name, ticker, price, 24h %
│ Bitcoin Cash BCH  $301.4  ▼ 4.7%     │
│ …                                    │
│                                      │
│ RELEASES                             │  ── 7. Node + wallet versions
│ L1 node  betanet v31.1.0 · ca64033   │
│ Wallet   v1.3.0                      │
│                                      │
│ Sidechains                        ›  │  ── 8. Row → existing SidechainsScreen
│                                      │
│ ecash.com · Telegram · Discord · YT  │  ── 9. Links footer
│ Data from public sources. Every     │
│ metric has a definition (ⓘ).        │
└──────────────────────────────────────┘
```

Order follows what a wallet user cares about first: the ECX price, then chain health, then news.

### 3.3 Detail screens (pushed from "See ›")

| Screen | Content |
|---|---|
| **Network** | All four metrics with methodology inline, the bar chart (larger), latest 10 blocks as a `List` (height · time · tx · size · miner). Row tap opens the block in the explorer (system browser). |
| **News** | Full RSS timeline as a `List`, grouped by month. Row = date, title, 2-line description, source + first category chip. Tap opens the item's link in the system browser. Pull to refresh. |
| **Markets** | Full table: name, ticker, price, 24h %, 24h volume, source. Footnote explaining the ECX implied-price formula. |
| **CoinNews** | The existing `NewsScreen` unchanged (feed, topics, composer, threads). |

### 3.4 States (per card, independent)

Each section loads and fails **on its own** — a down price source never blanks the network card.

- **First load, nothing cached:** skeleton rows (grey `bg2` bars at the real row height, no spinners in cards).
- **Cached data, refreshing:** show the cache; the "updated …" line reads "updating…".
- **Refresh failed, cache present:** keep the numbers, the line turns `warning`: "updated 2 h ago · couldn't refresh".
- **Failed, no cache:** one-line "Unavailable" in `text2` with a retry. No zeros: a missing number must never render as `0`.
- **CoinNews with no indexer on this network:** "CoinNews isn't live on Betanet yet." (see §8, O1).

### 3.5 Methodology sheet

Tapping a metric tile opens a small sheet (same pattern as tx detail: no nav bar, swipe to dismiss):
definition, formula, source URL, refresh cadence, and limitations (e.g. "Betanet is not mainnet
activity" and "block times are set by miners"). Text mirrors the reference site's methodology blocks.

### 3.6 Skip / platform constraints that shape the design

- **No `Canvas`** → the bar chart is an `HStack` of `Rectangle`s with computed heights.
- **Dynamic rows use `List`** (memory: Android tx-list Compose crash), not `ForEach` in a `VStack`, on the detail screens. The root's 3-row previews are fixed-count and safe in a `VStack`.
- **No SF Symbols** — new icons (`space_dashboard`, `monitoring`, `newspaper` if needed) as `.symbolset`s.
- **Localization:** every label via `Text(_, bundle: .module, comment:)`; numbers, tickers and titles via `Text(verbatim:)`.
- **Uniform flat lists:** follow the `flat-list-uniform-background` recipe for the detail `List`s.
- **App Review (3.1.5):** show prices only. **No links to swap/trade pages** (Orca pool, NonKYC
  market, `swap.beta.ecash.com`). The reference site links them, but in-app they'd re-trigger the
  exchange-services question we just answered. Market rows are not tappable.

## 4. Data

All public, keyless, HTTPS JSON (or RSS). Requests go through `URLSession` (Fuse-Android needs
`import FoundationNetworking`, memory `fuse-networking-and-pricing`).

### 4.1 Network metrics — chain explorer (mempool-style API)

Base: the **live dashboard network's** explorer — today betanet `https://explorer.beta.ecash.ninja`
(verified), mainnet's at the fork (§4.6). Alphanet is not shown.

| Metric | Endpoint | Derivation |
|---|---|---|
| Block height | `GET /api/blocks/tip/height` (plain text) | as-is |
| Latest blocks | `GET /api/v1/blocks` (10 per page; `GET /api/v1/blocks/{height}` for older pages) | height, `timestamp`, `tx_count`, `size`, `extras.pool.name` (miner label, e.g. "avonpool") |
| Tx · 24h | page `/api/v1/blocks` back until `timestamp < now − 86400` | Σ (`tx_count` − 1) over those blocks — minus 1 drops the coinbase, matching the site's "non-coinbase" definition |
| Observed TPS | derived | Tx·24h ÷ (newest − oldest block timestamp in the window) — the confirmed rate over the actual span, not ÷ 86400 |
| Mempool | `GET /api/mempool` | `count` (also `vsize`, `total_fee` for the detail screen) |
| Activity bars | same block pages | last 24 blocks' `tx_count` |

Block spacing on betanet is currently irregular (minutes to an hour), so the 24h window is usually
1–3 pages. Cap at 20 pages to bound a pathological case. Refresh: on appear, pull-to-refresh, and
every 5 min while the tab is visible (the site's cadence).

### 4.2 Market prices

| Asset | Source | Endpoint | Fields |
|---|---|---|---|
| BTC, BCH, BSV, XEC | **Gate.io** spot tickers | `GET https://api.gateio.ws/api/v4/spot/tickers?currency_pair=BTC_USDT` (one call per pair, or one call with no pair and filter) | `last`, `change_percentage`, `quote_volume` |
| BTCB2 | **NonKYC** | `GET https://api.nonkyc.io/api/v2/market/getbysymbol/BTCB2_USDT` | `lastPrice`, `yesterdayPrice` (→ 24h %), `volume` |
| wbECX → ECX | **DexScreener** (Orca pool) | `GET https://api.dexscreener.com/latest/dex/pairs/solana/nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM` | `priceUsd`, `priceChange.h24`, `volume.h24`, `liquidity.usd` |

All verified live 2026-10-07. Notes:

- **Quotes are in USDT (Gate, NonKYC) and USD/USDC (DexScreener).** Show "$" and say "USDT-quoted"
  in the Markets footnote rather than converting.
- **Market cap is dropped.** Exchanges don't publish circulating supply, and computing it ourselves
  per chain is a project of its own. Volume and 24h % are what the tickers give us.
- **ECX implied price** = wbECX price × ratio. The reference uses ×50 ("using 20M ECX") — **confirm
  the ratio and its meaning before shipping** (O2). Shown as the headline with the wbECX price and
  source underneath, so the derivation is never hidden.
- The existing `PriceProvider`/Bitfinex path (wallet fiat display) is **untouched**. The dashboard's
  market data is separate: different assets, different purpose.
- Refresh: on appear + pull + every 60 s while visible. Gate allows 200 req/10 s and DexScreener
  300/min, so per-device polling is far below the limits.

### 4.3 News — `news.ecash.com/rss.xml`

RSS 2.0, ~60 items, `ttl` 15 min. Per item: `title`, `link`, `guid`, `pubDate` (RFC 822),
`description`, `source`, multiple `category`. Map to a `NewsItem` value; sort by `pubDate` desc.

- **Parsing risk:** `XMLParser` lives in `FoundationXML` on non-Apple platforms. Whether it's
  available in the Fuse Android SDK is unverified → **spike first** (S1). Fallback: a small, tested
  RSS item extractor for this one feed (it's machine-generated and regular).
- Tap → `item.link` in the system browser (most links are third-party sites). The `guid` anchors
  into news.ecash.com and is the fallback when `link` is missing.
- Refresh: on appear + pull, honouring the feed's 15-min `ttl`.

### 4.4 CoinNews

Unchanged client (`CoinNewsV1Client` via `CoinNewsEndpointRegistry`). The section shows the top 3 of
the "Top" feed for the **dashboard's** network. Betanet currently publishes no indexer
(`coinnews: null` in the live config) → empty-state copy until one is turned on via remote config (O1).
At the fork it follows the dashboard to mainnet like everything else.

### 4.5 Releases

- Node: parse the newest entry of `https://releases.ecash.com/L1-ecash-bitcoin/<network>/` (an HTML
  directory index → version + short commit). If parsing is brittle, ask L2L for a `latest.json` there.
- Wallet: `GET https://api.github.com/repos/ecash-com/ecash-wallet-mobile/releases/latest` (unauthenticated: 60 req/h per IP; cache 1 h). Show "Update available" when it's newer than the running build.

### 4.6 Which network, and where the URLs live

One remote-config value picks the dashboard's network: `dashboard.network` in the existing config
(`drivechain.dev/config`), bundled default **betanet**. At mainnet launch L2L sets it to the mainnet
id (plus the mainnet explorer base) and every installed app switches on its next config fetch — no
release needed, and no window where users see betanet numbers labelled as mainnet.

- Bundled defaults live in one `DashboardSources` registry; the remote config overlays them the same
  way backends and CoinNews are overlaid today.
- An unknown network id in the config falls back to the bundled default rather than showing nothing.
- Caches are keyed by network, so the first post-fork open never flashes betanet's cached numbers
  under a mainnet header.
- **Fork-day checklist:** add the mainnet explorer + `dashboard.network` to
  `docs/real-ecash-fork-transition.md`.

## 5. Architecture

```
Dashboard/                          (app module, Fuse native — no WalletService/BDK involvement)
  DashboardNetwork.swift            the live network (betanet → mainnet via config) → explorer base, display name
  DashboardSources.swift            bundled URLs + remote-config overlay
  ChainStatsClient.swift            explorer API → ChainSnapshot (pure decode + derive, tested)
  MarketClient.swift                protocol MarketSource; GateSource, NonKYCSource, DexScreenerSource
  NewsFeedClient.swift              RSS → [NewsItem]
  ReleasesClient.swift
  DashboardModel.swift              @Observable: one SectionState<T> per card (idle/loading/loaded(T, at)/failed(cached?))
  DashboardCache.swift              last good snapshot per section+network, JSON in Caches/
Screens/
  DashboardScreen.swift             root (replaces NewsHubScreen)
  NetworkDetailScreen.swift, EcosystemNewsScreen.swift, MarketsScreen.swift, MetricInfoSheet.swift
Components/
  MetricTile, BlockBars, NewsRow, MarketRow, SectionHeader (title + "See ›")
```

- Each client is a protocol with a live and a fixture implementation, so `DashboardModel` is tested without the network.
- Sections refresh **concurrently** but independently (`async let` per section). One slow source never blocks the others.
- Derivations (tx 24h, TPS, implied price, 24h % from yesterday's price) are **pure functions** with unit tests against recorded JSON fixtures.
- Timers: a single 60 s tick while the Dashboard is on screen (`.task` + `scenePhase`); each section decides whether its own cadence has elapsed. Nothing polls in the background.
- `NewsHubScreen` + `WebNewsScreen` are removed. The embedded web view is no longer needed once news is native.

## 6. Phases

| Phase | Scope | Rough size |
|---|---|---|
| **S1 — spikes** | `FoundationXML` on Fuse-Android; confirm the ECX ratio (O2); confirm no swap links are OK with the business | ½ day |
| **P1 — skeleton** | Tab rename + icon, `DashboardScreen`, config-driven network, section scaffolding, card states, cache | 1–2 days |
| **P2 — network** | Explorer client + derivations + tests, metric grid, methodology sheets, bar chart, Network detail | 2 days |
| **P3 — news** | RSS client + tests, news section + timeline screen; CoinNews section wired to the existing feed | 1–2 days |
| **P4 — markets** | Gate/NonKYC/DexScreener clients + tests, hero price card, Markets screen | 1–2 days |
| **P5 — releases + links + polish** | Releases card, footer, remote-config overlay, both-platform screenshots, App Review check | 1 day |

Ship gate per phase: unit tests for every client/derivation, then verify on the iOS sim **and** the
Android emulator (fonts, bars and `List`s fail silently on Android — check by screenshot).

## 7. Testing

- **Fixtures:** record one real response per endpoint into `Tests/…/Fixtures/` (explorer blocks page, mempool, Gate, NonKYC, DexScreener, RSS).
- **Pure derivations:** tx-24h window edges (block exactly at `now − 86400`, irregular spacing, the 20-page cap), TPS over the real span, implied price, NonKYC 24h % from `yesterdayPrice`.
- **RSS:** dates (RFC 822, GMT), multiple categories, missing `link` → `guid`, HTML entities in descriptions.
- **Model:** one failing source leaves the other sections loaded; cache shown on cold start; a config flip betanet → mainnet never shows betanet's cached numbers under the mainnet header.

## 8. Open questions

| # | Question | Default if unanswered |
|---|---|---|
| O1 | **CoinNews on betanet:** there's no indexer, so the section is empty on the default network. Stand one up, or have the CoinNews section follow the *selected wallet's* network instead of the dashboard's network? | Follow the dashboard's network; show "not live on Betanet yet" |
| O2 | **ECX implied price:** what exactly does "wbECX × 50, using 20M ECX" mean, and is it a number we want headlining the dashboard? | Show wbECX price as the headline, implied price as a secondary line |
| O3 | Mainnet explorer URL at the fork (Oct 31) — needed for the config flip | Stay on betanet until the config says otherwise |
| O4 | Should the Wallet tab's fiat price for eCash wallets use the same wbECX source? | No — out of scope here |
| O5 | Attribution: do Gate/DexScreener/NonKYC terms require visible credit? | Credit each source in the Markets footnote |

## 9. Out of scope

Market cap, price history charts, push alerts on price moves, the reference site's Adoption /
Ecosystem / Development tabs, and any buy/swap/trade entry point (§3.6).

## 10. As built — departures from the plan

- **TPS = tx·24h ÷ 86,400**, not ÷ the window's span (§4.1). That's the reference dashboard's
  definition (97,726 → 1.131), so the two agree.
- **CoinNews follows the selected wallet's network**, not the dashboard's (O1). Reading and posting are
  per-network and need a wallet on that network; `NewsScreen` already binds to it. On betanet it shows
  the "isn't live yet" copy until an indexer is in the config.
- **RSS is parsed by hand** (`RSSFeedParser`), not `XMLParser` — S1 was settled by not depending on
  `FoundationXML` on Android at all.
- **The embedded web news screen and the SkipWeb dependency are gone** (news is native now).
- **Refreshes are detached from the view** (`DashboardModel.refresh`): pushing a detail screen cancels
  the root's `.task`, and a cancelled fetch left a card stuck "in flight" while the pushed screen
  skipped refreshing. A cancellation is also never recorded as a failure.
- **Config key:** top-level `dashboard: {network_id, display_name, explorer_url, releases_channel}`
  (`RemoteEndpointConfig.resolvedDashboardNetwork`). Needs `network_id` + an http(s) `explorer_url`;
  anything else keeps betanet.
- **Android gotchas found:** `accessibilityElement(children:)` is unavailable in SkipFuseUI;
  `NumberFormatter` ignores `maximumFractionDigits` (values are rounded before formatting); Compose
  ignores `.firstTextBaseline` in `HStack`s (news rows use `.top`).
- **Open still:** O2 (the ×50 ratio — shown as a labelled secondary line), O3 (mainnet explorer URL for
  the config flip), O5 (attribution — sources are credited inline).
