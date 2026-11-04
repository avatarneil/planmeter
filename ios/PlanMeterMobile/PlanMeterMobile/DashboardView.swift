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
                    ForEach(model.availableRanges) { Text($0.label).tag($0) }
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
                    if model.usesCloud {
                        Label("iCloud snapshot · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "icloud")
                            .font(.caption).foregroundStyle(.secondary)
                        if Date().timeIntervalSince(summary.generatedAt) > 900 {
                            Text("Showing the last upload. Open PlanMeter on your Mac to update usage and limits.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    OverviewCard(summary: summary, timeline: model.timeline)
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
                        Text("Estimated costs: API-equivalent token prices, or workspace credits where reported.").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4)
                } else if model.isLoading {
                    ProgressView(model.usesCloud ? "Loading from iCloud…" : "Loading from your Mac…").frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ContentUnavailableView("No data yet", systemImage: "wifi.exclamationmark", description: Text(model.usesCloud ? "Enable iCloud sync in PlanMeter → Remote on your Mac using the same Apple Account. Choose your Mac in Settings if you have multiple Macs. Pull to refresh after the first upload." : "Make sure the Mac is awake, PlanMeter is running with Remote access on, and this phone is connected to Tailscale."))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .animation(.snappy, value: model.summary?.total.costUsd)
        .refreshable { await model.refresh() }
    }
}

struct CardBackground: ViewModifier {
    /// A faint wash of this color from the top-leading corner.
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        if let tint {
                            shape.fill(LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0)], startPoint: .topLeading, endPoint: .center))
                        }
                    }
            }
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
                    .contentTransition(.numericText(value: group.totals.costUsd))
                Text("\(Fmt.tokens(group.totals.tokens)) tokens").foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Palette.group(group.group).gradient).frame(width: max(0, min(1, total.costUsd > 0 ? group.totals.costUsd / total.costUsd : 0)) * geo.size.width)
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
        .modifier(CardBackground(tint: Palette.group(group.group)))
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
    /// Sticky: Swift Charts clears its selection when the finger lifts.
    @State private var selection: Date?
    @State private var scrubbing: Date?

    private struct Segment: Identifiable {
        var id: String
        var start: Date
        var end: Date
        var low: Double
        var high: Double
        var account: String
        var baseline: Bool
    }

    /// Stacked per period: untimed workspace baselines first, then timed usage.
    private var segments: [Segment] {
        let names = Dictionary(timeline.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let order = Dictionary(timeline.accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let step = RemoteTimeline.stepSeconds(timeline.resolution)
        var out: [Segment] = []
        for (period, points) in Dictionary(grouping: timeline.points, by: \.period) {
            let end = step.map { period.addingTimeInterval($0 * 0.88) }
                ?? (Calendar.current.dateInterval(of: .day, for: period)?.end ?? period.addingTimeInterval(86_400)).addingTimeInterval(-86_400 * 0.12)
            let sorted = points.sorted { (order[$0.accountId] ?? .max) < (order[$1.accountId] ?? .max) }
            var top = 0.0
            for baseline in [true, false] {
                for point in sorted {
                    let base = min(point.costUsd, point.baselineCostUsd ?? 0)
                    let value = baseline ? base : point.costUsd - base
                    guard value > 0 else { continue }
                    out.append(Segment(id: "\(point.id):\(baseline)", start: period, end: end, low: top, high: top + value,
                                       account: names[point.accountId] ?? point.accountId, baseline: baseline))
                    top += value
                }
            }
        }
        return out
    }

    /// The whole window, so a few active buckets don't zoom the axis.
    private var domain: ClosedRange<Date> {
        let first = timeline.periods.first ?? timeline.points.map(\.period).min() ?? Date()
        let last = timeline.periods.last ?? timeline.points.map(\.period).max() ?? first
        let end = RemoteTimeline.stepSeconds(timeline.resolution).map { last.addingTimeInterval($0) }
            ?? Calendar.current.dateInterval(of: .day, for: last)?.end ?? last.addingTimeInterval(86_400)
        return first...max(end, first.addingTimeInterval(60))
    }

    /// The bucket under the finger, with its span and total.
    private func selected(_ date: Date?) -> (start: Date, end: Date, cost: Double)? {
        guard let date, let start = timeline.periods.last(where: { $0 <= date }) ?? timeline.points.map(\.period).filter({ $0 <= date }).max() else { return nil }
        let end = RemoteTimeline.stepSeconds(timeline.resolution).map { start.addingTimeInterval($0) }
            ?? Calendar.current.dateInterval(of: .day, for: start)?.end ?? start.addingTimeInterval(86_400)
        guard date < end else { return nil }
        return (start, end, timeline.points.filter { $0.period == start }.reduce(0) { $0 + $1.costUsd })
    }

    private func detail(_ date: Date) -> String {
        switch timeline.resolution {
        case "minute", "5m", "15m", "hour": return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        default: return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    private func label(_ date: Date) -> String {
        switch timeline.resolution {
        case "minute", "5m": return date.formatted(.dateTime.hour().minute())
        case "15m", "hour": return timeline.days > 1 ? date.formatted(.dateTime.weekday(.abbreviated).hour()) : date.formatted(.dateTime.hour())
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let picked = selected(selection) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(detail(picked.start)).font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.usd(picked.cost)).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText(value: picked.cost))
                    }
                    Spacer()
                    Button { selection = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear selection")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Cost over time").font(.headline)
                        if !timeline.points.isEmpty {
                            Text("Tap a bar for details").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if selected(selection) == nil, model.availableGranularities.count > 1 {
                    Picker("Bucket size", selection: $model.granularity) {
                        ForEach(model.availableGranularities, id: \.self) { Text(MobileRange.label(granularity: $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            let segments = self.segments
            if timeline.points.isEmpty {
                Text("No usage in this range.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let picked = selected(selection)
                Chart {
                    ForEach(segments) { segment in
                        RectangleMark(
                            xStart: .value("Start", segment.start),
                            xEnd: .value("End", segment.end),
                            yStart: .value("Cost", segment.low),
                            yEnd: .value("Cost", segment.high)
                        )
                        .foregroundStyle(by: .value("Account", segment.account))
                        .opacity(picked == nil || picked?.start == segment.start ? (segment.baseline ? 0.35 : 1) : 0.3)
                    }
                    if let picked {
                        RuleMark(x: .value("Selected", picked.start.addingTimeInterval(picked.end.timeIntervalSince(picked.start) * 0.44)))
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXSelection(value: $scrubbing)
                // A tap, rather than the default long-press drag, which fights the scroll view.
                .chartGesture { proxy in
                    SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
                }
                .onChange(of: scrubbing) { _, date in if let date, selected(date) != nil { selection = date } }
                .onChange(of: timeline) { selection = nil }
                .sensoryFeedback(.selection, trigger: picked?.start)
                .chartForegroundStyleScale(domain: timeline.accounts.map(\.name), range: timeline.accounts.map { model.color(for: $0.id) })
                .chartXScale(domain: domain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel { if let date = value.as(Date.self) { Text(label(date)) } }
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
                // Only once the reply to that request has arrived, not while it's loading.
                if !model.usesCloud, model.requestedGranularity == model.granularity, timeline.resolution != model.granularity {
                    Text("Showing \(MobileRange.label(granularity: timeline.resolution).lowercased()) buckets; update PlanMeter on your Mac for finer ones.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if segments.contains(where: \.baseline) {
                    Text("Lighter bars: workspace credits without timing, spread evenly over the hours the provider reported.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .modifier(CardBackground())
    }
}

struct LimitsCardView: View {
    var limits: RemoteLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan limits").font(.headline)
                Spacer()
                let near = limits.accounts.flatMap(\.windows).filter { $0.usedPercent >= 90 }.count
                if near > 0 {
                    Label("\(near) near limit", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
            }
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
                                Text("\(Int(w.usedPercent.rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(Palette.usage(w.usedPercent)).monospacedDigit()
                                Text("· resets \(Fmt.relative(w.resetsAt))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                    Capsule().fill(Palette.usage(w.usedPercent).gradient)
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
            let top = rows.map(\.totals.costUsd).max() ?? 0
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
                .padding(.vertical, 2)
                .background(alignment: .bottomLeading) {
                    // Share of the top model, as a faint underline.
                    GeometryReader { geo in
                        Capsule().fill(Palette.group(row.group).opacity(0.35))
                            .frame(width: geo.size.width * (top > 0 && row.priced ? row.totals.costUsd / top : 0), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .offset(y: 3)
                }
            }
        }
        .modifier(CardBackground())
    }
}
