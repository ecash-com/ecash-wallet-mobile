// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// Overrides Skip's auto-generated test harness. ECashWalletMobile is a Fuse (native) module:
// its Android tests run natively via `skip android test`, NOT through the Lite Gradle/Robolectric
// harness (skip-testing skill: "the auto-generated XCSkipTests harness does not apply to Fuse").
// Providing this file suppresses the generated harness so `swift test` runs only the native host
// XCTest suite cleanly. Run the Android side with: `skip android test`.

#if os(macOS)
import XCTest

final class XCSkipTests: XCTestCase {
    func testSkipModule() throws {
        throw XCTSkip("Fuse module — run Android tests with `skip android test`, not the Gradle harness")
    }
}
#endif
