import SwiftUI
import PlanMeterCore

struct LimitsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Subscription limits", info: "Codex records its rate-limit windows in each session transcript, so these reflect the last turn each account ran. Claude Code limits come from its CLI and Antigravity quotas from Google, refreshed at most every five minutes.") {
            // Placeholder accounts never carry limit readings.
            let configured = Set(model.discovery.accounts.map(\.id))
            let codex = model.accounts.filter { account in
                account.provider == .codex && (configured.contains(account.id)
                    || model.rateLimits[account.id.replacingOccurrences(of: "codex:plan:", with: "")] != nil)
            }
            let providers = model.accounts.filter { model.planLimits[$0.id] != nil }
            if codex.isEmpty && providers.isEmpty {
                Text("No Codex, Claude Code, or Antigravity accounts configured.").foregroundStyle(.secondary)
            }
            ForEach(codex) { account in
                let plan = account.id.replacingOccurrences(of: "codex:plan:", with: "")
                VStack(alignment: .leading, spacing: 8) {
                    LimitsHeader(account: account, plan: account.planLabel)
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
            ForEach(providers) { account in
                if let snapshot = model.planLimits[account.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        LimitsHeader(account: account, plan: snapshot.plan ?? account.planLabel)
                        ForEach(snapshot.windows) { window in
                            LimitBar(usedPercent: window.usedPercent, label: window.label, resetDate: window.resetsAt, windowStart: window.windowStart)
                        }
                        if let message = snapshot.message {
                            Text(message).font(.caption).foregroundStyle(snapshot.status == .failed || snapshot.status == .partial ? .orange : .secondary)
                        }
                        if let fetchedAt = snapshot.fetchedAt {
                            Text("As of \(Format.relative(fetchedAt))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func creditsText(_ s: RateLimitSnapshot) -> String {
        if s.unlimitedCredits == true { return "No windows reported; unlimited credits." }
        if s.hasCredits == true { return "No windows reported; billed against credits\(s.creditsBalance.map { " (balance \($0))" } ?? "")." }
        return "No usage windows reported for this plan."
    }
}

private struct LimitsHeader: View {
    @Environment(AppModel.self) private var model
    var account: Account
    var plan: String?

    var body: some View {
        HStack {
            Circle().fill(Palette.color(for: model.group(for: account))).frame(width: 8, height: 8)
            Text(account.displayName).font(.subheadline.weight(.medium))
            if let plan {
                Text(plan).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct LimitBar: View {
    var usedPercent: Double
    var label: String
    /// Nil when the provider reports no reset time.
    var resetDate: Date?
    /// Nil when the window has no fixed length, which hides the pace marker.
    var windowStart: Date?

    init(usedPercent: Double, label: String, resetDate: Date?, windowStart: Date?) {
        self.usedPercent = usedPercent
        self.label = label
        self.resetDate = resetDate
        self.windowStart = windowStart
    }

    init(window: RateLimitWindow, label: String) {
        self.init(usedPercent: window.usedPercent, label: label, resetDate: window.resetDate, windowStart: window.windowStart)
    }

    var body: some View {
        let now = Date()
        let used = max(0, min(1, usedPercent / 100))
        let elapsed: Double? = {
            guard let resetDate, let windowStart else { return nil }
            let span = resetDate.timeIntervalSince(windowStart)
            return span > 0 ? max(0, min(1, now.timeIntervalSince(windowStart) / span)) : 0
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(usedPercent.rounded()))% used").font(.caption).monospacedDigit()
                if let elapsed {
                    Image(systemName: pace(used: used, elapsed: elapsed).icon)
                        .font(.caption2)
                        .foregroundStyle(pace(used: used, elapsed: elapsed).color)
                        .help(pace(used: used, elapsed: elapsed).help)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(used > 0.9 ? Color.red : used > 0.7 ? Color.orange : Color.accentColor)
                        .frame(width: used * geo.size.width)
                    if let elapsed {
                        Rectangle().fill(Color.primary.opacity(0.6))
                            .frame(width: 1.5)
                            .offset(x: elapsed * geo.size.width)
                    }
                }
            }
            .frame(height: 8)
            if let resetDate {
                Text(resetDate > now ? "Resets \(Format.relative(resetDate))" : "Reset pending")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
        Card(title: "Sources", info: "Transcript folders and databases PlanMeter reads. Workspace readings use the provider's credit conversion instead of token prices.") {
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
                if let error = model.pricingError ?? model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Divider()
                HStack {
                    Text(pricingText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isRefreshingPricing ? "Refreshing pricing…" : "Refresh pricing") { Task { await model.refreshPricing() } }
                        .disabled(model.isRefreshingPricing)
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
        if model.rates.isEmpty { return "Token prices unavailable" }
        let when = model.rates.fetchedAt.map { Format.relative($0) } ?? "unknown time"
        return "\(model.rates.knownModels) model prices from \(model.rates.source), fetched \(when)"
    }
}
