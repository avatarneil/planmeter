import Charts
import PlanMeterRemote
import SwiftUI

struct DashboardView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $model.range) {
                    ForEach(MobileRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                if let summary = model.summary {
                    ForEach(summary.groups) { group in
                        GroupCardView(group: group, total: summary.total)
                    }
                    if let timeline = model.timeline {
                        TimelineCard(timeline: timeline)
                    }
                    if let limits = model.limits, !limits.accounts.isEmpty {
                        LimitsCardView(limits: limits)
                    }
                    if !model.models.isEmpty {
                        ModelsCard(rows: model.models)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From \(summary.serverName)").font(.caption).foregroundStyle(.secondary)
                        if let updated = model.lastUpdated {
                            Text("Updated \(Fmt.relative(updated)) · data as of \(Fmt.relative(summary.generatedAt))").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("API-equivalent token prices, not subscription charges.").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4)
                } else if model.isLoading {
                    ProgressView("Loading from your Mac…").frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ContentUnavailableView("No data yet", systemImage: "wifi.exclamationmark", description: Text("Make sure the Mac is awake, PlanMeter is running with Remote access on, and this phone is connected to Tailscale."))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.refresh() }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct GroupCardView: View {
    @Environment(MobileModel.self) private var model
    var group: RemoteGroupUsage
    var total: RemoteTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Palette.group(group.group)).frame(width: 10, height: 10)
                Text(Fmt.groupName(group.group)).font(.headline)
                Spacer()
                Text(Fmt.percent(total.costUsd > 0 ? group.totals.costUsd / total.costUsd : 0)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.usd(group.totals.costUsd)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("\(Fmt.tokens(group.totals.tokens)) tokens").foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Palette.group(group.group)).frame(width: max(0, min(1, total.costUsd > 0 ? group.totals.costUsd / total.costUsd : 0)) * geo.size.width)
                }
            }
            .frame(height: 6)
            HStack(spacing: 16) {
                stat("Sessions", "\(group.totals.sessions)")
                stat("Cache savings", Fmt.usd(group.totals.cacheSavingsUsd))
                stat("Cached", Fmt.percent(group.totals.cachedShare))
            }
            Divider()
            ForEach(group.accounts) { row in
                HStack(spacing: 8) {
                    Circle().fill(model.color(for: row.account.id)).frame(width: 8, height: 8)
                    Text(row.account.name).lineLimit(1)
                    if let plan = row.account.plan {
                        Text(plan).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    Spacer()
                    Text(Fmt.usd(row.totals.costUsd)).monospacedDigit()
                        .foregroundStyle(row.totals.tokens == 0 ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
        .modifier(CardBackground())
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

struct TimelineCard: View {
    @Environment(MobileModel.self) private var model
    var timeline: RemoteTimeline

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost over time").font(.headline)
            if timeline.points.isEmpty {
                Text("No usage in this range.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let names = Dictionary(uniqueKeysWithValues: timeline.accounts.map { ($0.id, $0.name) })
                Chart(timeline.points) { point in
                    BarMark(
                        x: .value("Period", point.period, unit: timeline.resolution == "hour" ? .hour : .day),
                        y: .value("Cost", point.costUsd)
                    )
                    .foregroundStyle(by: .value("Account", names[point.accountId] ?? point.accountId))
                }
                .chartForegroundStyleScale(domain: timeline.accounts.map(\.name), range: timeline.accounts.map { model.color(for: $0.id) })
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(timeline.resolution == "hour" ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.month(.abbreviated).day()))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.usd(v)) } }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
                .frame(height: 220)
            }
        }
        .modifier(CardBackground())
    }
}

struct LimitsCardView: View {
    var limits: RemoteLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex limits").font(.headline)
            ForEach(limits.accounts) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(Palette.group(entry.account.group)).frame(width: 8, height: 8)
                        Text(entry.account.name).font(.subheadline.weight(.medium))
                        if let plan = entry.account.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let asOf = entry.asOf { Text(Fmt.relative(asOf)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    ForEach(entry.windows, id: \.label) { w in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(w.label).font(.caption)
                                Spacer()
                                Text("\(Int(w.usedPercent.rounded()))% · resets \(Fmt.relative(w.resetsAt))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                    Capsule().fill(w.usedPercent > 90 ? Color.red : w.usedPercent > 70 ? Color.orange : Color.accentColor)
                                        .frame(width: max(0, min(1, w.usedPercent / 100)) * geo.size.width)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.bottom, 4)
            }
            Text(limits.note).font(.caption2).foregroundStyle(.tertiary)
        }
        .modifier(CardBackground())
    }
}

struct ModelsCard: View {
    var rows: [RemoteModelRow]
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("By model").font(.headline)
                Spacer()
                if rows.count > 6 {
                    Button(showAll ? "Show less" : "Show all \(rows.count)") { showAll.toggle() }.font(.caption)
                }
            }
            ForEach(showAll ? rows : Array(rows.prefix(6))) { row in
                HStack(spacing: 8) {
                    Circle().fill(Palette.group(row.group)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.model).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(row.accountName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.priced ? Fmt.usd(row.totals.costUsd) : "unpriced").font(.callout).monospacedDigit()
                        Text(Fmt.tokens(row.totals.tokens)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .modifier(CardBackground())
    }
}
