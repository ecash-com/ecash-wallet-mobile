// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

// iOS camera QR scanner (AVFoundation). SkipQRCode 0.0.1 ships only an Android scanner
// (`AndroidBarcodeScanner`), so this covers Apple; the Send screen routes Android to SkipQRCode and
// iOS to this view. Entirely `#if os(iOS)` — UIKit/AVFoundation are Apple-only and never transpile.
#if os(iOS)
import SwiftUI
import AVFoundation
import AudioToolbox

/// Full-screen live camera preview that decodes a QR code and reports the string exactly once.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

// `@preconcurrency` on the delegate conformance: the metadata callback is delivered on the main
// queue (we set `queue: .main` below), so touching this @MainActor controller's state is safe —
// the attribute tells Swift 6 not to flag the (correct) main-actor crossing.
final class QRScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        // startRunning() blocks; keep it off the main thread (Apple's guidance).
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        didScan = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onScan?(value)
    }
}
#endif
