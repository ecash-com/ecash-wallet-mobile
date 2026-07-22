// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import QRCodeGenerator

/// Renders `content` as a QR code — crisp black modules on a white card (high contrast for scanners,
/// deliberately theme-independent so it scans in dark mode too). Generation is pure Swift
/// (`QRCodeGenerator`); the modules are drawn as a **single `Path`** (`QRModulesShape`) rather than one
/// `Rectangle` view per module. That matters: a ~30×30 QR is ~900 modules, and a view-per-module made
/// the whole Receive sheet's present animation janky on Compose (~900 composables to compose + measure
/// each frame). One filled `Path` is a single composable drawn in one pass — smooth on both platforms
/// (`Path` is fully supported in SkipUI; there's no `Canvas`).
struct QRCodeView: View {
    let content: String
    var size: CGFloat = 240
    /// White quiet-zone border (points) — scanners need it to lock on.
    private var quiet: CGFloat { size * 0.08 }

    var body: some View {
        // Medium error-correction balances density against scan robustness. Encoding can't really
        // fail for an address; if it ever did we show a blank white card rather than crash.
        let qr = try? QRCode.encode(text: content, ecl: .medium)
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.white)
            if let qr = qr {
                // Snapshot the modules into a plain Sendable matrix (Shape is Sendable, QRCode isn't).
                let count = qr.size
                let modules = (0..<count).map { y in (0..<count).map { x in qr.getModule(x: x, y: y) } }
                QRModulesShape(modules: modules)
                    .fill(Color.black)
                    .frame(width: size - quiet * 2, height: size - quiet * 2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The QR's black modules as one `Path` — every dark cell added as a rect. Simple (no
/// `AnimatableData`), so it's SkipUI-safe, and collapses hundreds of module views into a single shape.
private struct QRModulesShape: Shape {
    /// Row-major dark-module matrix (`modules[y][x]`) — a plain `[[Bool]]` so the Shape stays Sendable.
    let modules: [[Bool]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = modules.count
        guard count > 0 else { return path }
        let cell = rect.width / CGFloat(count)
        for y in 0..<count {
            let row = modules[y]
            for x in 0..<count where x < row.count && row[x] {
                path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                    width: cell, height: cell))
            }
        }
        return path
    }
}
