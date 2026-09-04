import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import PlanMeterRemote

struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var qrKind: QRKind = .web
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum QRKind: String, CaseIterable, Identifiable {
        case web = "Web"
        case app = "iOS app"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var remote = model.remote
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote access").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Enabled", isOn: $remote.isEnabled).toggleStyle(.switch)
            }
            Text("Serves the PlanMeter iOS app and a mobile web client over your tailnet only. Every request is end-to-end encrypted to this Mac's key and signed by the device's key, on top of Tailscale's WireGuard tunnel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow
                    httpsRow
                    Divider()
                    Text("Paired devices").font(.headline)
                    if remote.devices.isEmpty {
                        Text("None yet. Create a pairing code and scan it from the phone.").font(.callout).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(remote.devices) { device in
                                HStack(alignment: .top) {
                                    Image(systemName: icon(for: device))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).font(.body.weight(.medium))
                                        Text("\(device.platform) · paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                        Text(device.lastSeenAt.map { "Last seen \(Format.relative($0)) · \(device.requestCount) requests" } ?? "Not seen yet").font(.caption).foregroundStyle(.secondary)
                                        Text("Key \(device.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Button("Revoke", role: .destructive) { remote.revoke(device) }.controlSize(.small)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                    Divider()
                    Text("Activity").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(remote.events.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 110)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    Picker("Code for", selection: $qrKind) {
                        ForEach(QRKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)

                    if let invite = remote.invite, invite.expiresAt > now, let payload = payload(for: invite) {
                        if let image = qrImage(payload) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .padding(8)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text(qrKind == .web ? "Scan with the phone's camera to open the web client" : "Scan with PlanMeter on your phone").font(.caption).multilineTextAlignment(.center)
                        if qrKind == .web, let code = remote.webPairingCode {
                            VStack(spacing: 3) {
                                Text("Home Screen app already open?")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(formattedWebCode(code))
                                    .font(.title3.monospaced().weight(.semibold))
                                    .textSelection(.enabled)
                                Text("Enter this code in the app")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if qrKind == .web, !remote.httpsActive {
                            Text("Turn on Tailscale HTTPS first: browsers only allow the crypto this needs on HTTPS pages. Right now this link only works on this Mac.")
                                .font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center).frame(width: 220)
                        }
                        Text("Expires in \(Int(invite.expiresAt.timeIntervalSince(now)))s · single use").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        HStack {
                            Button("Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(payload, forType: .string)
                            }
                            Button("Cancel") { remote.cancelInvite() }
                        }
                        .controlSize(.small)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 236, height: 236)
                            .overlay(Text(remote.isListening ? "No active pairing code" : "Turn on remote access first").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding())
                        Button("New pairing code") { remote.newInvite() }
                            .disabled(!remote.isListening)
                    }
                }
                .frame(width: 250)
            }

            HStack {
                Text(remote.serverKeyIsEnclave ? "Server key: Secure Enclave" : "Server key: software, stored in Application Support").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 800, height: 640)
        .onReceive(tick) { now = $0 }
        .task { await model.remote.refreshHTTPSStatus(ensure: false) }
    }

    private func icon(for device: PairedDevice) -> String {
        let p = device.platform.lowercased()
        if p == "web" { return "safari" }
        if p.contains("ipad") { return "ipad" }
        return "iphone"
    }

    private func payload(for invite: PairingInvite) -> String? {
        switch qrKind {
        case .app: return invite.url.absoluteString
        case .web: return model.remote.webPairingURL(for: invite)?.absoluteString
        }
    }

    private func formattedWebCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4)) \(code.suffix(4))"
    }

    private var statusRow: some View {
        let remote = model.remote
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(remote.isListening ? Color.green : remote.isEnabled ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                Text(remote.status).font(.callout)
            }
            if let dns = remote.magicDNSName {
                Text("MagicDNS: \(dns)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Port").font(.caption)
                TextField("Port", value: Binding(get: { Int(remote.port) }, set: { newValue in
                    if let v = UInt16(exactly: newValue), v > 1024 {
                        remote.port = v
                        UserDefaults.standard.set(Int(v), forKey: "remotePort")
                        remote.restart()
                    }
                }), format: .number)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }
        }
    }

    private var httpsRow: some View {
        let remote = model.remote
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Tailscale HTTPS (web client)", isOn: Binding(
                    get: { remote.httpsEnabled },
                    set: { value in Task { await remote.setHTTPS(enabled: value) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(remote.isTogglingHTTPS || !remote.isListening)
                if remote.isTogglingHTTPS { ProgressView().controlSize(.small) }
            }
            if let url = remote.httpsURL {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                }
            } else if remote.httpsEnabled, let message = remote.httpsMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            } else {
                Text("Publishes the web client at https://\(remote.httpsDomain ?? "<machine>.<tailnet>.ts.net")/ via `tailscale serve`, tailnet-only, with a certificate Tailscale issues. Stays on until turned off.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
