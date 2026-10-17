import SwiftUI
import PlanMeterCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusBanner()
                SummaryRow()
                UsageChartCard()
                HStack(alignment: .top, spacing: 16) {
                    BreakdownCard()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    LimitsCard()
                        .frame(width: 320, alignment: .topLeading)
                }
                Card(title: "Threads and chats") { ThreadSpendList(rows: model.threads(), limit: 8) }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Picker("Metric", selection: $model.metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refresh(forceAccountUsage: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Refresh transcripts and account-wide usage (⌘R)")
                Button {
                    model.showAccounts = true
                } label: {
                    Label("Accounts", systemImage: "person.2")
                }
                .help("Assign accounts to Personal or Work")
                Button {
                    openWindow(id: "diagnostics")
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .help("Account readings, sources, and pricing")
                CloudSyncButton()
            }
        }
        .sheet(item: $model.usageDetail) { scope in
            UsageDetailSheet(scope: scope).environment(model)
        }
        .sheet(isPresented: $model.showAccounts) {
            AccountsSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showRemote) {
            RemoteSettingsView()
                .environment(model)
        }
        .onOpenURL { url in
            guard url.scheme == "planmeter-desktop", url.host == "dashboard" else { return }
            model.usageDetail = nil
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .navigationTitle("PlanMeter")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let last = model.lastScan else { return model.isScanning ? "Scanning…" : "" }
        if Date().timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(Format.relative(last))"
    }
}

// MARK: - Summary

struct SummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // An unused Other group adds a card of zeros; show it once it has usage.
        let summaries = model.groupSummaries.filter { $0.group != .other || $0.aggregate.totals.total > 0 || $0.aggregate.costUsd > 0 }
        let grand = model.total
        HStack(alignment: .top, spacing: 16) {
            ForEach(summaries) { summary in
                GroupCard(summary: summary, grand: grand)
            }
            if summaries.isEmpty {
                Card {
                    Text(model.isScanning ? "Scanning provider transcripts…" : "No accounts discovered. Check T3 Code's provider settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct GroupCard: View {
    @Environment(AppModel.self) private var model
    var summary: GroupSummary
    var grand: Aggregate

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(Palette.color(for: summary.group)).frame(width: 10, height: 10)
                    Text(summary.group.displayName).font(.headline)
                    Spacer()
                    Text(Format.percent(share)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.metric == .cost ? Format.usd(summary.aggregate.costUsd) : Format.tokens(summary.aggregate.totals.total))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(model.metric == .cost ? "\(Format.tokens(summary.aggregate.totals.total)) tokens" : Format.usd(summary.aggregate.costUsd))
                        .foregroundStyle(.secondary)
                }
                ShareBar(fraction: share, color: Palette.color(for: summary.group))
                Text("\(summary.aggregate.sessions) \(summary.aggregate.sessions == 1 ? "session" : "sessions") · \(Format.percent(cachedShare)) cached · \(Format.usd(summary.aggregate.cacheSavingsUsd)) saved")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Known sessions, the share of input served from cache, and what caching saved at standard model rates.")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(summary.accounts.enumerated()), id: \.element.account.id) { index, row in
                        HStack(spacing: 8) {
                            Circle().fill(model.color(for: row.account)).frame(width: 8, height: 8)
                            Text(row.account.displayName).lineLimit(1)
                            if let plan = row.account.planLabel {
                                Text(plan).font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                            Spacer()
                            Text(model.metric == .cost ? Format.usd(row.aggregate.costUsd) : Format.tokens(row.aggregate.totals.total))
                                .monospacedDigit()
                                .foregroundStyle(row.aggregate.totals.total == 0 ? .secondary : .primary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                        .onTapGesture { model.usageDetail = .account(row.account.id) }
                        .help("Explore \(row.account.displayName)")
                        .tag(index)
                    }
                    if summary.accounts.isEmpty {
                        Text("No accounts assigned").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var share: Double {
        switch model.metric {
        case .cost: return grand.costUsd > 0 ? summary.aggregate.costUsd / grand.costUsd : 0
        case .tokens: return grand.totals.total > 0 ? Double(summary.aggregate.totals.total) / Double(grand.totals.total) : 0
        }
    }

    private var cachedShare: Double {
        let input = summary.aggregate.totals.input
        return input > 0 ? Double(summary.aggregate.totals.cachedInput) / Double(input) : 0
    }

}

struct Stat: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

struct ShareBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var info: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 4) {
                    Text(title).font(.headline)
                    if let info { InfoButton(text: info) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Explanations live behind a small ⓘ instead of in the layout.
struct InfoButton: View {
    var text: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("About this")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

/// Errors that need attention; routine status stays in Diagnostics.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let messages = [model.lastError, model.pricingError, model.desktopWidgetError].compactMap { $0 }
        if !messages.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(messages, id: \.self) { Text($0).font(.callout) }
                }
                Spacer()
                Button("Details") { openWindow(id: "diagnostics") }.controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// iCloud upload state at a glance, so a paused upload doesn't go unnoticed.
struct CloudSyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.cloudSync
        let failing = sync.isEnabled && sync.status.hasPrefix("Upload failed")
        Button {
            model.showRemote = true
        } label: {
            Label("Remote", systemImage: !sync.isEnabled ? "icloud.slash" : failing ? "exclamationmark.icloud" : "icloud")
        }
        .help(sync.isEnabled ? "iCloud sync and remote access · \(sync.status)" : "iCloud sync is off · Phone and Watch won’t update without Tailscale")
    }
}
