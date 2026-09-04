import AVFoundation
import SwiftUI

struct PairingView: View {
    @Environment(MobileModel.self) private var model
    @State private var manualLink = ""
    @State private var scanned = false
    @State private var cameraAvailable = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pair with your Mac").font(.title2.weight(.semibold))
                        Text("On the Mac, open PlanMeter → Remote and create a pairing code. Both devices need to be on your tailnet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if cameraAvailable {
                        QRScannerView { code in
                            guard !scanned else { return }
                            scanned = true
                            Task {
                                await model.pair(text: code)
                                scanned = false
                            }
                        }
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.2)))
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .frame(height: 140)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "camera.fill").foregroundStyle(.secondary)
                                    Text("No camera here. Paste the pairing link instead.").font(.footnote).foregroundStyle(.secondary)
                                }
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or paste the pairing link").font(.subheadline.weight(.medium))
                        TextField("planmeter://pair?…", text: $manualLink)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            Task { await model.pair(text: manualLink) }
                        } label: {
                            if model.isPairing { ProgressView() } else { Text("Pair") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualLink.isEmpty || model.isPairing)
                    }

                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Pairing codes are single use and expire in 5 minutes.", systemImage: "clock")
                        Label("Your key stays in this device's Secure Enclave; the Mac pins it.", systemImage: "key.fill")
                        Label("Every request is end-to-end encrypted on top of Tailscale.", systemImage: "lock.shield")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("PlanMeter")
        }
    }
}

/// Camera preview that reports QR payloads.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {
        uiViewController.onCode = onCode
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var lastCode: String?
        private var lastTime = Date.distantPast

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted, let self else { return }
                DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = object.stringValue else { return }
            // Debounce: the camera reports the same code many times per second.
            if value == lastCode, Date().timeIntervalSince(lastTime) < 3 { return }
            lastCode = value
            lastTime = Date()
            onCode?(value)
        }
    }
}
