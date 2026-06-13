// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import ECashWalletMobile

/// The app-lock state machine. Invariants that matter for a wallet: a failed/cancelled auth keeps
/// the app locked, turning the setting off can't strand the user locked, turning it on never locks
/// mid-session, and backgrounding re-arms the gate. Driven through injected auth + persist seams.
@MainActor
@Suite struct AppLockModelTests {

    private final class Seams: @unchecked Sendable {
        var authResult = true
        var authCallCount = 0
        var persistedValue: Bool?
        var persistCallCount = 0
    }

    private func makeModel(enabled: Bool = true, startLocked: Bool = true)
        -> (AppLockModel, Seams) {
        let seams = Seams()
        let model = AppLockModel(
            enabled: enabled,
            startLocked: startLocked,
            authenticate: { _ in
                seams.authCallCount += 1
                return seams.authResult
            },
            persist: { value in
                seams.persistCallCount += 1
                seams.persistedValue = value
            })
        return (model, seams)
    }

    @Test func startsLockedWhenArmed() {
        let (model, _) = makeModel(enabled: true, startLocked: true)
        #expect(model.isLocked)
        #expect(model.enabled)
    }

    @Test func successfulAuthUnlocks() async {
        let (model, seams) = makeModel()
        await model.unlock()
        #expect(!model.isLocked)
        #expect(seams.authCallCount == 1)
    }

    @Test func failedAuthStaysLocked() async {
        let (model, seams) = makeModel()
        seams.authResult = false
        await model.unlock()
        #expect(model.isLocked)            // a cancelled/failed prompt must not let you in
        #expect(seams.authCallCount == 1)
    }

    @Test func disablingClearsLockAndPersists() {
        let (model, seams) = makeModel(enabled: true, startLocked: true)
        model.setEnabled(false)
        #expect(!model.enabled)
        #expect(!model.isLocked)           // turning it off can't leave you stranded locked
        #expect(seams.persistedValue == false)
    }

    @Test func enablingPersistsButDoesNotLockMidSession() {
        let (model, seams) = makeModel(enabled: false, startLocked: false)
        model.setEnabled(true)
        #expect(model.enabled)
        #expect(!model.isLocked)           // takes effect on next background/launch, not now
        #expect(seams.persistedValue == true)
    }

    @Test func togglingToSameValueIsNoOp() {
        let (model, seams) = makeModel(enabled: true, startLocked: false)
        model.setEnabled(true)
        #expect(seams.persistCallCount == 0)
    }

    @Test func backgroundReArmsLockWhenEnabled() async {
        let (model, _) = makeModel(enabled: true, startLocked: true)
        await model.unlock()
        #expect(!model.isLocked)
        model.lockOnBackground()
        #expect(model.isLocked)            // returns locked after backgrounding
    }

    @Test func backgroundIsNoOpWhenDisabled() {
        let (model, _) = makeModel(enabled: false, startLocked: false)
        model.lockOnBackground()
        #expect(!model.isLocked)
    }

    @Test func unlockIsNoOpWhenNotLocked() async {
        let (model, seams) = makeModel(enabled: true, startLocked: false)
        await model.unlock()
        #expect(seams.authCallCount == 0)  // nothing to unlock → no prompt
    }
}
