// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import WalletService

/// Receive screen for the selected wallet: the next unused address as a QR + monospace text, the
/// network it belongs to (Golden Rule §6 — never hand out an address for the wrong network), and
/// Share / New-address actions. Each visit reveals a fresh address (BDK advances + persists).
struct ReceiveScreen: View {
    @Environment(AppState.self) var app
    @State var address: AddressInfo?   // not `private` — Fuse bridges @State to Compose (skip-fuse rule)
    @State var copied = false

    var body: some View {
        // No NavigationStack/toolbar/title: `.sheet` (from WalletHomeScreen) is swipe-down
        // dismissible, and a toolbar renders a grey Material top app bar on Android. Edge-to-edge
        // on `bg0`; the SIGNET badge + QR + address are self-explanatory without a title.
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Show the current UNUSED address on appear — repeat opens do NOT advance the index
        // (every revealed index widens the address space sync must cover; advancing on each
        // open is how funds ended up beyond the scan gap). "New address" below advances.
        .task { if address == nil { address = await app.nextUnusedAddress() } }
    }

    @ViewBuilder
    private var content: some View {
        if let wallet = app.selectedWallet, let info = address {
            let params = NetworkRegistry.params(for: wallet.network)
            VStack(spacing: Theme.Space.x5) {
                NetworkBadge(network: wallet.network)

                QRCodeView(content: info.address)

                VStack(spacing: Theme.Space.x2) {
                    // Full address, monospaced, wrapped — the source of truth to copy/scan.
                    Text(info.address)
                        .font(.jbMono(14, .regular))
                        .foregroundStyle(Theme.Colors.text0)
                        .multilineTextAlignment(.center)
                    Text("Only send \(params.unitLabel) on \(params.displayName) to this address.",
                         bundle: .module, comment: "receive warning; %1$@ is the unit, %2$@ the network")
                        .textStyle(.xs)
                        .foregroundStyle(Theme.Colors.text2)
                        .multilineTextAlignment(.center)
                }

                // `.frame(maxWidth: .infinity)` on EACH wrapper (not just the label) so the two
                // split the row evenly — `ShareLink` doesn't propagate its label's width, so without
                // this the Copy button greedily fills and Share spills off-screen.
                HStack(spacing: Theme.Space.x3) {
                    Button {
                        Clipboard.copy(info.address)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        actionLabel(icon: copied ? Icon.check : Icon.copy,
                                    title: copied
                                        ? "Copied"
                                        : "Copy")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    // ShareLink is the portable share-sheet action (send to a faucet, AirDrop, etc.).
                    ShareLink(item: info.address) {
                        actionLabel(icon: Icon.share, title: "Share")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    Task { address = await app.nextReceiveAddress() }
                    copied = false
                } label: {
                    HStack(spacing: Theme.Space.x1) {
                        Image(icon: Icon.refresh).resizable().scaledToFit().frame(width: 14, height: 14)
                        Text("New address", bundle: .module, comment: "receive: reveal a fresh address").textStyle(.sm)
                    }
                    .foregroundStyle(Theme.Colors.text1)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.gutter)
        } else {
            PlaceholderScreen(heading: "Receive",
                              note: "No wallet selected.")
        }
    }

    /// A bordered, full-width action chip (matches the secondary `WalletButton` look).
    private func actionLabel(icon: Icon, title: LocalizedStringKey) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image(icon: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            Text(title, bundle: .module).textStyle(.button)
        }
        .foregroundStyle(Theme.Colors.text0)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.x3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.bg2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
    }
}
