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
                Section {
                    Toggle("Use iCloud", isOn: $model.usesCloud)
                    if model.usesCloud && !model.cloudSnapshots.isEmpty {
                        Picker("Mac", selection: $model.selectedCloudMac) {
                            Text("Choose a Mac").tag("")
                            ForEach(model.cloudSnapshots) { Text($0.name).tag($0.id) }
                        }
                    }
                } header: { Text("Connection") } footer: {
                    Text("iCloud reads usage uploaded by Macs using the same Apple Account. Enable sync in PlanMeter → Remote on your Mac. The Watch receives updates through this iPhone. Direct pairing is still available when iCloud is off.")
                }

                if let server = model.server {
                    Section("Direct pairing") {
                        LabeledContent("Name", value: server.serverName)
                        LabeledContent("Address", value: "\(server.host):\(server.port)")
                        LabeledContent("Paired", value: server.pairedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Server key") {
                            Text(fingerprint(server.serverPublicKey)).font(.caption.monospaced())
                        }
                    }
                }
                Section("This device") {
                    if !model.usesCloud {
                        LabeledContent("Device id") { Text(model.deviceId).font(.caption.monospaced()) }
                        LabeledContent("Key storage", value: model.deviceKeyIsEnclave ? "Secure Enclave" : "Software (simulator)")
                    }
                    Toggle("Require Face ID / passcode", isOn: $model.requireBiometrics)
                }
                Section {
                    Button("Refresh now") { Task { await model.refresh() } }
                    if model.server != nil {
                        Button("Unpair from this Mac", role: .destructive) { confirmUnpair = true }
                    }
                } footer: {
                    if model.server != nil {
                        Text("Unpairing deletes the saved server on this phone. Revoke the device on the Mac too to stop it from ever reconnecting with the same key.")
                    }
                }
                Section("Security") {
                    Text(model.usesCloud ? "Usage reports are read from your private iCloud database using your Apple Account. Your Mac uploads aggregate reports; prompts, transcripts, and credentials stay on the Mac." : "Transport: your tailnet (WireGuard). Payloads: ChaCha20-Poly1305 under a fresh ECDH key per request, signed by this device's key. The Mac only listens on its Tailscale address and only answers paired devices.")
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
