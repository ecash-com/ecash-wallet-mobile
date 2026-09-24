// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SkipFuse   // @Observable must drive the Android (Compose) UI in Fuse
import WalletService

/// Drives "Copy to network": pick a network that shares this wallet's keys, then create the
/// same wallet there from its stored secret (`docs/copy-wallet-to-network.md`). The secret never
/// reaches this layer — `copy` runs entirely inside WalletService. A network the wallet is already
/// on is listed as "Added" and can't be chosen (a second copy would double-count its coins).
@MainActor
@Observable
final class CopyWalletViewModel {
    enum Phase: Equatable {
        case choosing
        case copying
        case failed(String)
    }

    /// One network on offer. `existingWalletId` is set when the wallet is already on it.
    struct Target: Equatable, Identifiable {
        let network: WalletNetwork
        let existingWalletId: String?
        var id: String { network.rawValue }
        var isAdded: Bool { existingWalletId != nil }
    }

    let walletLabel: String
    let targets: [Target]
    /// The network the user tapped, awaiting confirm. Only ever a target without an existing copy.
    private(set) var selected: WalletNetwork?
    private(set) var phase: Phase = .choosing
    private(set) var authorizing = false

    private let copy: (WalletNetwork) async throws -> Void
    private let authorize: (String) async -> Bool

    init(walletLabel: String,
         targets: [Target],
         copy: @escaping (WalletNetwork) async throws -> Void,
         authorize: @escaping (String) async -> Bool) {
        self.walletLabel = walletLabel
        self.targets = targets
        self.copy = copy
        self.authorize = authorize
    }

    var isBusy: Bool { phase == .copying || authorizing }
    var errorMessage: String? {
        if case .failed(let m) = phase { return m }
        return nil
    }
    /// Copying onto a real-money network gets its own warning on the confirm step (Golden Rule §6).
    var selectedIsRealMoney: Bool { selected?.isMainnet == true }

    /// Tap a network row to select it for confirm. An added network can't be chosen.
    func choose(_ target: Target) {
        guard !isBusy, !target.isAdded else { return }
        selected = target.network
        if case .failed = phase { phase = .choosing }
    }

    /// Confirm → device-auth → copy. On success the caller has already selected the new wallet.
    func confirm() async {
        guard let network = selected, !isBusy else { return }
        authorizing = true
        let approved = await authorize("Authorize copying this wallet to another network")
        authorizing = false
        guard approved else { return }
        phase = .copying
        do {
            try await copy(network)
            phase = .choosing
        } catch let error as WalletError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(WalletError.copyMismatch.userMessage)
        }
    }
}
