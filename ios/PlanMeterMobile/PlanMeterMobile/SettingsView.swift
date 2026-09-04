import CryptoKit
import PlanMeterRemote
import SwiftUI

struct SettingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if let server = model.server {
                    Section("Mac") {
                        LabeledContent("Name", value: server.serverName)
                        LabeledContent("Address", value: "\(server.host):\(server.port)")
                        LabeledContent("Paired", value: server.pairedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Server key") {
                            Text(fingerprint(server.serverPublicKey)).font(.caption.monospaced())
                        }
                    }
                }
                Section("This device") {
                    LabeledContent("Device id") { Text(model.deviceId).font(.caption.monospaced()) }
                    LabeledContent("Key storage", value: model.deviceKeyIsEnclave ? "Secure Enclave" : "Software (simulator)")
                    Toggle("Require Face ID / passcode", isOn: $model.requireBiometrics)
                }
                Section {
                    Button("Refresh now") { Task { await model.refresh() } }
                    Button("Unpair from this Mac", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Unpairing deletes the saved server on this phone. Revoke the device on the Mac too to stop it from ever reconnecting with the same key.")
                }
                Section("Security") {
                    Text("Transport: your tailnet (WireGuard). Payloads: ChaCha20-Poly1305 under a fresh ECDH key per request, signed by this device's key. The Mac only listens on its Tailscale address and only answers paired devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpair from this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            }
        }
    }

    private func fingerprint(_ key: Data) -> String {
        let hash = Data(SHA256.hash(data: key)).base64URLEncodedString()
        return String(hash.prefix(16))
    }
}
