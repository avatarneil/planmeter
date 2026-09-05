import SwiftUI
import PlanMeterCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SummaryRow()
                UsageChartCard()
                HStack(alignment: .top, spacing: 20) {
                    BreakdownCard()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    LimitsCard()
                        .frame(width: 340, alignment: .topLeading)
                }
                SourcesCard()
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
                .frame(width: 320)
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
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("Rescan provider transcripts (⌘R)")
                Button {
                    model.showAccounts = true
                } label: {
                    Label("Accounts", systemImage: "person.2")
                }
                .help("Assign accounts to Personal or Work")
                Button {
                    model.showRemote = true
                } label: {
                    Label("Remote", systemImage: model.remote.isListening ? "iphone.radiowaves.left.and.right" : "iphone")
                }
                .help("Pair the iOS app over Tailscale")
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
        let summaries = model.groupSummaries
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
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Stat(label: "Sessions", value: "\(summary.aggregate.sessions)")
                        Stat(label: "Cache savings", value: Format.usd(summary.aggregate.cacheSavingsUsd))
                        Stat(label: "Cached input", value: Format.percent(cachedShare))
                    }
                }
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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}
