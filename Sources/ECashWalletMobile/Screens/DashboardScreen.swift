// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// The Dashboard tab (`docs/dashboard-plan.md`): the eCash network at a glance — ECX price, chain
/// health, news (on-chain CoinNews and eCash.com), markets, releases.
///
/// Reports on `AppState.dashboard.network` (betanet until the config says mainnet), not the selected
/// wallet's network. CoinNews is the exception: reading and posting are per-network and need a wallet
/// on that network, so the section shows only while the selected wallet is on the dashboard's network.
///
/// Layout discipline (Android Compose): a `ScrollView` of fixed cards, each preview a short `ForEach`
/// in a `VStack` (the Home recent-activity pattern, proven stable). The unbounded lists — every block,
/// every news item — live on the pushed screens, in `List`s.
struct DashboardScreen: View {
    @Environment(AppState.self) var app
    @State var infoMetric: DashboardMetric? = nil   // not `private` — Fuse bridges @State
    @State var showSidechains = false

    /// How often the screen ticks while visible. Each card decides whether its own cadence is due.
    static let tickNanoseconds: UInt64 = 60_000_000_000

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.x4) {
                    priceCard
                    networkCard
                    if showsCoinNews { coinNewsCard }
                    ecosystemNewsCard
                    marketsCard
                    releasesCard
                    if app.sidechainsAvailable { sidechainsRow }
                    linksFooter
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.x4)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await app.dashboard.refresh(force: true)
                await app.coinNews.refresh()
            }
        }
        .navigationTitle(Text("Dashboard", bundle: .module, comment: "dashboard tab title"))
        .navigationDestination(for: DashboardRoute.self) { route in
            switch route {
            case .network: DashboardNetworkScreen()
            case .news: EcosystemNewsScreen()
            case .markets: MarketsScreen()
            case .coinNews: NewsScreen()
            }
        }
        // Registered here, not on `NewsScreen`: the dashboard's CoinNews preview pushes stories too,
        // and one stack must have one destination per type.
        .navigationDestination(for: CoinNewsItem.self) { item in
            if let vm = app.makeCoinNewsDetailViewModel(item: item) {
                CoinNewsDetailView(viewModel: vm)
            }
        }
        .sheet(item: $infoMetric) { metric in
            MetricInfoSheet(metric: metric, network: app.dashboard.network)
        }
        .sheet(isPresented: $showSidechains) {
            if let vm = app.makeSidechainsViewModel() {
                SidechainsScreen(viewModel: vm)
            }
        }
        // Ticks only while the tab is on screen: `.task` is cancelled when the view goes away.
        .task {
            while !Task.isCancelled {
                await app.dashboard.refresh()
                try? await Task.sleep(nanoseconds: Self.tickNanoseconds)
            }
        }
        .task { await app.coinNews.load() }
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: - 1. Price

    /// wbECX is the only ECX price before mainnet, so it's the headline; the implied ECX price is a
    /// labelled secondary line until its ratio is confirmed (plan O2).
    private var priceCard: some View {
        let section = app.dashboard.markets
        return VStack(alignment: .leading, spacing: Theme.Space.x2) {
            DashboardSectionHeader(title: "ECX price")
            if let quote = section.value?.wbECX {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
                    Text(verbatim: DashboardFormat.usd(quote.price))
                        .font(.jbMono(34, .medium))
                        .foregroundStyle(Theme.Colors.text0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let change = quote.change24h {
                        Text(verbatim: DashboardFormat.percentChange(change))
                            .textStyle(.sm)
                            .foregroundStyle(change < 0 ? Theme.Colors.negative : Theme.Colors.positive)
                    }
                }
                Text("wbECX, wrapped Betanet ECX on Solana", bundle: .module,
                     comment: "dashboard price card: what the headline price is")
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.text1)
                if let implied = section.value?.impliedECXPrice {
                    Text("≈ \(DashboardFormat.usd(implied)) implied per ECX (wbECX × \(Int(MarketBoard.ecxPerWbECX)))",
                         bundle: .module, comment: "dashboard price card: implied ECX price; %1$@ price, %2$lld ratio")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                }
                DashboardFreshness(updatedAt: section.updatedAt, stale: section.lastAttemptFailed,
                                   source: quote.source)
            } else if section.display == .loading {
                DashboardSkeleton(rows: 2)
            } else {
                DashboardUnavailable()
            }
        }
        .dashboardCard()
    }

    // MARK: - 2. Network

    private var networkCard: some View {
        let section = app.dashboard.chain
        let snapshot = section.value
        return VStack(alignment: .leading, spacing: Theme.Space.x3) {
            DashboardSectionHeader(title: "Network", note: app.dashboard.network.displayName, route: .network)
            if section.display == .unavailable {
                DashboardUnavailable()
            } else {
                HStack(spacing: Theme.Space.x2) {
                    MetricTile(metric: .blockHeight, value: snapshot.map { DashboardFormat.integer($0.tipHeight) }) {
                        infoMetric = .blockHeight
                    }
                    MetricTile(metric: .transactions24h, value: snapshot.map { DashboardFormat.integer($0.transactions24h) }) {
                        infoMetric = .transactions24h
                    }
                }
                HStack(spacing: Theme.Space.x2) {
                    MetricTile(metric: .observedTPS, value: snapshot.map { DashboardFormat.tps($0.observedTPS) }) {
                        infoMetric = .observedTPS
                    }
                    MetricTile(metric: .mempool, value: snapshot.map { DashboardFormat.integer($0.mempoolCount) }, unit: "tx") {
                        infoMetric = .mempool
                    }
                }
                if let snapshot, !snapshot.blocks.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.x2) {
                        Text("Activity by block", bundle: .module, comment: "dashboard: tx-per-block chart title")
                            .textStyle(.xs)
                            .foregroundStyle(Theme.Colors.text2)
                        BlockActivityBars(blocks: snapshot.blocks)
                    }
                    .padding(.top, Theme.Space.x1)
                }
                DashboardFreshness(updatedAt: section.updatedAt, stale: section.lastAttemptFailed)
            }
        }
        .dashboardCard()
    }

    // MARK: - 3. CoinNews

    /// Coin News appears only while the selected wallet is ON the dashboard's network (betanet now,
    /// mainnet after the config flip). From a Bitcoin, Signet, alphanet or Thunder wallet the section
    /// would describe some other chain's board under the betanet dashboard, so it's left out entirely.
    private var showsCoinNews: Bool {
        guard let walletNetwork = app.dashboard.network.walletNetwork else { return false }
        return app.selectedWallet?.network == walletNetwork
    }

    @ViewBuilder private var coinNewsCard: some View {
        let vm = app.coinNews
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            DashboardSectionHeader(title: "Coin News", note: walletNetworkName,
                                   route: app.coinNewsAvailable ? .coinNews : nil)
            if !app.coinNewsAvailable {
                Text("Coin News isn't live on \(walletNetworkName) yet. It's the on-chain bulletin board: posts are written to the blockchain and readable by anyone.",
                     bundle: .module, comment: "dashboard: CoinNews not available on this network; %@ is the network")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text2)
            } else if vm.items.isEmpty {
                switch vm.state {
                case .failed:
                    DashboardUnavailable()
                case .loaded:
                    Text("No posts yet. Be the first.", bundle: .module, comment: "dashboard: CoinNews empty")
                        .textStyle(.sm)
                        .foregroundStyle(Theme.Colors.text2)
                default:
                    DashboardSkeleton()
                }
            } else {
                ForEach(Array(vm.items.prefix(3))) { item in
                    NavigationLink(value: item) {
                        CoinNewsPreviewRow(item: item, topicName: vm.topicName(for: item.topicHex))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .dashboardCard()
    }

    /// CoinNews follows the selected wallet's network (see the type note), so it names that network.
    private var walletNetworkName: String {
        guard let network = app.selectedWallet?.network else { return "" }
        return NetworkRegistry.params(for: network).displayName
    }

    // MARK: - 4. eCash.com news

    private var ecosystemNewsCard: some View {
        let section = app.dashboard.news
        return VStack(alignment: .leading, spacing: Theme.Space.x3) {
            DashboardSectionHeader(title: "From the ecosystem", route: section.value == nil ? nil : .news)
            switch section.display {
            case .loading: DashboardSkeleton()
            case .unavailable: DashboardUnavailable()
            case .ready:
                ForEach(Array((section.value ?? []).prefix(3))) { item in
                    newsLink(item)
                }
            }
        }
        .dashboardCard()
    }

    @ViewBuilder private func newsLink(_ item: EcosystemNewsItem) -> some View {
        if let url = URL(string: item.link) {
            Link(destination: url) { EcosystemNewsRow(item: item) }
                .buttonStyle(.plain)
        } else {
            EcosystemNewsRow(item: item)
        }
    }

    // MARK: - 5. Markets

    private var marketsCard: some View {
        let section = app.dashboard.markets
        return VStack(alignment: .leading, spacing: Theme.Space.x3) {
            DashboardSectionHeader(title: "Markets", route: section.value == nil ? nil : .markets)
            switch section.display {
            case .loading: DashboardSkeleton(rows: 4)
            case .unavailable: DashboardUnavailable()
            case .ready:
                ForEach(section.value?.quotes ?? []) { quote in
                    MarketRow(quote: quote)
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - 6. Releases

    @ViewBuilder private var releasesCard: some View {
        let section = app.dashboard.releases
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            DashboardSectionHeader(title: "Releases")
            switch section.display {
            case .loading: DashboardSkeleton(rows: 2)
            case .unavailable: DashboardUnavailable()
            case .ready:
                if let node = section.value?.node {
                    releaseRow(title: "eCash node", value: "\(node.channel) v\(node.version) · \(node.commitShort)",
                               url: node.pageURL)
                }
                if let wallet = section.value?.wallet {
                    releaseRow(title: "eCash.com Wallet", value: "v\(wallet.displayVersion)", url: wallet.url)
                }
            }
        }
        .dashboardCard()
    }

    @ViewBuilder private func releaseRow(title: LocalizedStringKey, value: String, url: String) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: Theme.Space.x3) {
            Text(title, bundle: .module)
                .textStyle(.sm)
                .foregroundStyle(Theme.Colors.text1)
            Spacer(minLength: Theme.Space.x2)
            Text(verbatim: value)
                .font(.jbMono(13, .regular))
                .foregroundStyle(Theme.Colors.text0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        if let link = URL(string: url) {
            Link(destination: link) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: - 7. Sidechains, links

    private var sidechainsRow: some View {
        Button { showSidechains = true } label: {
            HStack(spacing: Theme.Space.x3) {
                Image(icon: Icon.sidechains).resizable().scaledToFit().frame(width: 20, height: 20)
                    .foregroundStyle(Theme.Colors.accent)
                Text("Sidechains", bundle: .module, comment: "dashboard: open sidechains")
                    .textStyle(.sm)
                    .foregroundStyle(Theme.Colors.text0)
                Spacer(minLength: Theme.Space.x2)
                Image(icon: Icon.disclosure).resizable().scaledToFit().frame(width: 14, height: 14)
                    .foregroundStyle(Theme.Colors.text2)
            }
            .dashboardCard()
        }
        .buttonStyle(.plain)
    }

    /// Project links. No exchange or swap links, deliberately (App Review 3.1.5 — plan §3.6).
    private var linksFooter: some View {
        VStack(spacing: Theme.Space.x2) {
            HStack(spacing: Theme.Space.x4) {
                footerLink("ecash.com", "https://ecash.com")
                footerLink("News", "https://news.ecash.com")
                footerLink("Telegram", "https://t.me/ecashcom_official")
                footerLink("Discord", "https://discord.gg/swyE78UPw")
            }
            Text("Public sources. Tap a metric for its definition.", bundle: .module,
                 comment: "dashboard footer")
                .textStyle(.xs)
                .foregroundStyle(Theme.Colors.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.x2)
    }

    @ViewBuilder private func footerLink(_ title: String, _ url: String) -> some View {
        if let link = URL(string: url) {
            Link(destination: link) {
                Text(verbatim: title)
                    .textStyle(.xs)
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
    }
}
