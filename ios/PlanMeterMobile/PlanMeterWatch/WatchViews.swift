import Charts
import PlanMeterWatchShared
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let payload = model.payload {
                TabView {
                    SummaryPage(payload: payload).tag(0)
                    if payload.lastHour != nil || payload.today != nil {
                        ActivityPage(payload: payload).tag(4)
                    }
                    LimitsPage(payload: payload).tag(1)
                    AccountsPage(payload: payload).tag(2)
                    ScrollView {
                    VStack(spacing: 8) {
                        if let status = model.status { Text(status).font(.caption2) }
                        ForEach(model.cloudChoices, id: \.cloudMacID) { source in
                            Button(source.serverName) { model.selectCloudMac(source) }
                        }
                        Text("Watch face settings").font(.headline)
                        Text("Choose plans and a daily target in PlanMeter on iPhone → Settings → Watch complications.")
                            .font(.footnote).multilineTextAlignment(.center)
                        Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding()
                    }.tag(3)
                }
                .tabViewStyle(.verticalPage)
                .navigationTitle("PlanMeter")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.refresh()
                        } label: {
                            if model.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .disabled(model.isRefreshing)
                    }
                }
            } else {
                ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "icloud").font(.title2).foregroundStyle(.secondary)
                    Text("Sync directly with iCloud. Enable iCloud sync in PlanMeter on your Mac.").font(.footnote).multilineTextAlignment(.center)
                    if let status = model.status { Text(status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    ForEach(model.cloudChoices, id: \.cloudMacID) { source in
                        Button(source.serverName) { model.selectCloudMac(source) }
                    }
                    Button("Try again") { model.refresh() }.font(.footnote)
                }
                .padding()
                }
                .navigationTitle("PlanMeter")
            }
        }
    }
}

struct SummaryPage: View {
    @Environment(WatchModel.self) private var model
    var payload: WatchPayload

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        // An older day's total is not today's spend; show it only as history.
        let current = payload.coversToday(at: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(current ? "Today" : "Today · not synced yet").font(.caption2).foregroundStyle(.secondary)
                    Text(current ? WatchPayload.usd(payload.todayCostUsd) : "—")
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                Text(current ? rangeName : "\(rangeName) to \(payload.updatedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption2).foregroundStyle(.secondary)
                GroupRow(name: "Personal", cost: payload.personalCostUsd, tokens: payload.personalTokens, total: payload.totalCostUsd, color: Palette.personal)
                GroupRow(name: "Work", cost: payload.workCostUsd, tokens: payload.workTokens, total: payload.totalCostUsd, color: Palette.work)
                if payload.otherCostUsd > 0 {
                    GroupRow(name: "Other", cost: payload.otherCostUsd, tokens: 0, total: payload.totalCostUsd, color: Palette.other)
                }
                if let status = model.status {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                }
                Text("Synced \(payload.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(payload.isStale(at: now) ? Color.orange : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeName: String {
        guard payload.days == 1 else { return "Last \(payload.days) days" }
        return payload.usesProviderDates == true ? "Day" : "Last 24 hours"
    }
}

/// Spend over the last hour by minute, or today by 15 minutes, stacked by plan.
struct ActivityPage: View {
    var payload: WatchPayload
    @State private var showLastHour = true

    private struct Segment: Identifiable {
        var id: String
        var start: Date
        var end: Date
        var low: Double
        var high: Double
        var group: String
        var baseline: Bool
    }

    private func segments(_ bars: [WatchPayload.Bar], step: TimeInterval) -> [Segment] {
        bars.flatMap { bar -> [Segment] in
            var top = 0.0
            var out: [Segment] = []
            for baseline in [true, false] {
                for group in ["personal", "work", "other"] {
                    let cost = bar.costs[group] ?? 0
                    let base = min(cost, bar.baselines[group] ?? 0)
                    let value = baseline ? base : cost - base
                    guard value > 0 else { continue }
                    out.append(Segment(id: "\(bar.start.timeIntervalSince1970):\(group):\(baseline)", start: bar.start,
                                       end: bar.start.addingTimeInterval(step * 0.85), low: top, high: top + value, group: group, baseline: baseline))
                    top += value
                }
            }
            return out
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let lastHour = showLastHour && payload.lastHour != nil || payload.today == nil
            // Yesterday's bars are not today's; show them only while they still describe today.
            let bars = (lastHour ? payload.lastHour : (payload.coversToday(at: context.date) ? payload.today : nil)) ?? []
            let step: TimeInterval = lastHour ? 60 : 900
            let segments = self.segments(bars, step: step)
            let total = bars.reduce(0) { $0 + $1.total }
            VStack(alignment: .leading, spacing: 4) {
                Button { showLastHour.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(lastHour ? "Last hour · 1 min" : "Today · 15 min").font(.caption2.weight(.semibold))
                        Image(systemName: "arrow.left.arrow.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(payload.lastHour == nil || payload.today == nil)
                if lastHour || payload.coversToday(at: context.date) {
                    Text(WatchPayload.usd(total)).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                }
                if !lastHour, !payload.coversToday(at: context.date) {
                    Text("Not synced yet today.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if segments.isEmpty {
                    Text("No usage in this window.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Chart(segments) { segment in
                        RectangleMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                                      yStart: .value("Cost", segment.low), yEnd: .value("Cost", segment.high))
                            .foregroundStyle(Palette.group(segment.group).opacity(segment.baseline ? 0.35 : 1))
                    }
                    .chartYAxis(.hidden)
                    .chartXScale(domain: (bars.first?.start ?? context.date)...((bars.last?.start ?? context.date).addingTimeInterval(step)))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(lastHour ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.hour()))
                                }
                            }
                        }
                    }
                }
                Text(payload.isStale(at: context.date) ? "Synced \(payload.updatedAt.formatted(.relative(presentation: .named)))" : "Updated \(payload.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(payload.isStale(at: context.date) ? Color.orange : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct GroupRow: View {
    var name: String
    var cost: Double
    var tokens: Int64
    var total: Double
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.footnote.weight(.medium))
                Spacer()
                Text(WatchPayload.usd(cost)).font(.footnote.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(color).frame(width: max(0, min(1, total > 0 ? cost / total : 0)) * geo.size.width)
                }
            }
            .frame(height: 5)
            if tokens > 0 {
                Text("\(WatchPayload.tokens(tokens)) tokens").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LimitsPage: View {
    var payload: WatchPayload

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Codex limits").font(.headline)
                if payload.limits.isEmpty {
                    Text("No usage windows reported.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(payload.limits) { limit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(limit.account).font(.footnote.weight(.medium))
                        Gauge(value: min(100, max(0, limit.usedPercent)), in: 0...100) {
                            Text(limit.label)
                        } currentValueLabel: {
                            Text("\(Int(limit.usedPercent.rounded()))%")
                        }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(limit.usedPercent > 90 ? .red : limit.usedPercent > 70 ? .orange : .blue)
                        Text("\(limit.label) · resets \(limit.resetsAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountsPage: View {
    var payload: WatchPayload

    var body: some View {
        List {
            ForEach(payload.accounts) { account in
                HStack(spacing: 6) {
                    Circle().fill(Palette.group(account.group)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.name).font(.footnote).lineLimit(1)
                        Text(WatchPayload.tokens(account.tokens) + " tok").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(WatchPayload.usd(account.costUsd)).font(.footnote).monospacedDigit()
                }
            }
        }
    }
}

enum Palette {
    static let personal = Color(red: 0.03, green: 0.57, blue: 0.70)
    static let work = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let other = Color.gray

    static func group(_ raw: String) -> Color {
        switch raw {
        case "personal": return personal
        case "work": return work
        default: return other
        }
    }
}
