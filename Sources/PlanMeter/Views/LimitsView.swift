import SwiftUI
import PlanMeterCore

struct LimitsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Subscription limits") {
            let codex = model.accounts.filter { $0.provider == .codex }
            if codex.isEmpty {
                Text("No Codex accounts configured.").foregroundStyle(.secondary)
            }
            ForEach(codex) { account in
                let plan = account.id.replacingOccurrences(of: "codex:plan:", with: "")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(Palette.color(for: model.group(for: account))).frame(width: 8, height: 8)
                        Text(account.displayName).font(.subheadline.weight(.medium))
                        if let label = account.planLabel {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if let snapshot = model.rateLimits[plan] {
                        if let primary = snapshot.primary {
                            LimitBar(window: primary, label: Format.windowName(minutes: primary.windowMinutes))
                        }
                        if let secondary = snapshot.secondary {
                            LimitBar(window: secondary, label: Format.windowName(minutes: secondary.windowMinutes))
                        }
                        if snapshot.primary == nil && snapshot.secondary == nil {
                            Text(creditsText(snapshot)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("As of \(Format.relative(Date(timeIntervalSince1970: TimeInterval(snapshot.timestampMs) / 1000)))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text("No limit readings in scanned sessions yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()
            Text("Codex writes its rate-limit windows into every session transcript, so these reflect the last turn each account ran. Claude Code does not store limits locally; use T3 Code's Limits view or the Claude app for those.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func creditsText(_ s: RateLimitSnapshot) -> String {
        if s.unlimitedCredits == true { return "No windows reported; unlimited credits." }
        if s.hasCredits == true { return "No windows reported; billed against credits\(s.creditsBalance.map { " (balance \($0))" } ?? "")." }
        return "No usage windows reported for this plan."
    }
}

struct LimitBar: View {
    var window: RateLimitWindow
    var label: String

    var body: some View {
        let now = Date()
        let used = max(0, min(1, window.usedPercent / 100))
        let span = window.resetDate.timeIntervalSince(window.windowStart)
        let elapsed = span > 0 ? max(0, min(1, now.timeIntervalSince(window.windowStart) / span)) : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used").font(.caption).monospacedDigit()
                Image(systemName: pace(used: used, elapsed: elapsed).icon)
                    .font(.caption2)
                    .foregroundStyle(pace(used: used, elapsed: elapsed).color)
                    .help(pace(used: used, elapsed: elapsed).help)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(used > 0.9 ? Color.red : used > 0.7 ? Color.orange : Color.accentColor)
                        .frame(width: used * geo.size.width)
                    Rectangle().fill(Color.primary.opacity(0.6))
                        .frame(width: 1.5)
                        .offset(x: elapsed * geo.size.width)
                }
            }
            .frame(height: 8)
            Text(window.resetDate > now ? "Resets \(Format.relative(window.resetDate))" : "Reset pending")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pace(used: Double, elapsed: Double) -> (icon: String, color: Color, help: String) {
        let diff = used - elapsed
        if diff > 0.1 { return ("arrow.up.right", .orange, "Ahead of even pace") }
        if diff < -0.1 { return ("arrow.down.right", .green, "Under even pace") }
        return ("arrow.right", .secondary, "On pace")
    }
}

struct SourcesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Sources") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.sources) { source in
                    HStack(spacing: 8) {
                        StatusDot(status: source.status)
                        Text(source.provider.displayName).frame(width: 90, alignment: .leading)
                        Text(source.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(detail(source)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                ForEach(model.discovery.unsupported) { item in
                    HStack(spacing: 8) {
                        StatusDot(status: .missing)
                        Text(item.displayName).frame(width: 90, alignment: .leading)
                        Text(item.reason).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                ForEach(model.discovery.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.desktopWidgetError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Divider()
                HStack {
                    Text(pricingText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh pricing") { Task { await model.refreshPricing() } }
                        .controlSize(.small)
                }
            }
        }
    }

    private func detail(_ s: SourceReport) -> String {
        switch s.status {
        case .missing: return s.message ?? "missing"
        case .failed: return s.message ?? "failed"
        default:
            var parts = ["\(s.scannedFiles) parsed", "\(s.reusedFiles) cached"]
            if let m = s.message { parts.append(m) }
            return parts.joined(separator: " · ")
        }
    }

    private var pricingText: String {
        if model.rates.isEmpty { return "No pricing loaded; costs show $0 until LiteLLM rates are fetched." }
        let when = model.rates.fetchedAt.map { Format.relative($0) } ?? "unknown time"
        return "Pricing: \(model.rates.knownModels) models from \(model.rates.source), fetched \(when). Subscription billing is separate from these API-equivalent costs."
    }
}
