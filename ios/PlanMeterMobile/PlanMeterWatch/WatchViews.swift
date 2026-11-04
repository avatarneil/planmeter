import Charts
import PlanMeterWatchShared
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var page: Int = {
        #if DEBUG
        return WatchDemo.initialPage ?? 0
        #else
        return 0
        #endif
    }()

    var body: some View {
        NavigationStack {
            if let payload = model.payload {
                TabView(selection: $page) {
                    SummaryPage(payload: payload).tag(0)
                    if payload.lastHour != nil || payload.today != nil {
                        ActivityPage(payload: payload).tag(1)
                    }
                    LimitsPage(payload: payload).tag(2)
                    AccountsPage(payload: payload).tag(3)
                    SourcePage(payload: payload).tag(4)
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
                .sensoryFeedback(.success, trigger: payload.updatedAt)
            } else {
                EmptyStateView()
                    .navigationTitle("PlanMeter")
            }
        }
    }
}

// MARK: - Summary

struct SummaryPage: View {
    @Environment(WatchModel.self) private var model
    var payload: WatchPayload

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .containerBackground(Palette.glow(Palette.group(dominantGroup)), for: .tabView)
    }

    private var dominantGroup: String {
        let groups = payload.todayCostByGroup ?? ["personal": payload.personalCostUsd, "work": payload.workCostUsd, "other": payload.otherCostUsd]
        return groups.max { $0.value < $1.value }?.key ?? "personal"
    }

    private func content(now: Date) -> some View {
        // An older day's total is not today's spend; show it only as history.
        let current = payload.coversToday(at: now)
        let target = payload.complicationPreferences?.target
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SpendRing(slices: current ? todaySlices : [], target: target) {
                    VStack(spacing: 0) {
                        Text(current ? "TODAY" : "NOT SYNCED")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(current ? WatchPayload.usd(payload.todayCostUsd) : "—")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: payload.todayCostUsd))
                            .lineLimit(1).minimumScaleFactor(0.5)
                        if current, let target {
                            Text(payload.todayCostUsd > target
                                 ? "\(WatchPayload.compactUsd(payload.todayCostUsd - target)) over"
                                 : "of \(WatchPayload.compactUsd(target))")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(payload.todayCostUsd > target ? Color.red : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(width: 118, height: 118)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: payload.todayCostUsd)

                if current, let lastHour = payload.lastHour, !lastHour.isEmpty {
                    let hour = lastHour.reduce(0) { $0 + $1.total }
                    Label {
                        Text("\(WatchPayload.usd(hour)) last hour").monospacedDigit()
                    } icon: {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                }

                RangeCard(payload: payload, title: current ? rangeName : "\(rangeName) to \(payload.updatedAt.formatted(.dateTime.month(.abbreviated).day()))")

                if let status = model.status {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                }
                SyncFooter(payload: payload, now: now)
            }
            .padding(.horizontal, 4)
        }
    }

    private var todaySlices: [RingSlice] {
        guard let groups = payload.todayCostByGroup else {
            return [.init(color: Palette.personal, value: payload.todayCostUsd)]
        }
        return Palette.groups.map { .init(color: Palette.group($0), value: groups[$0] ?? 0) }
    }

    private var rangeName: String {
        guard payload.days == 1 else { return "Last \(payload.days) days" }
        return payload.usesProviderDates == true ? "Day" : "Last 24 hours"
    }
}

struct RingSlice {
    var color: Color
    var value: Double
}

/// Today's spend by plan, Activity-ring style: a full lap is the daily target,
/// or with no target the ring is split by plan share.
struct SpendRing<Center: View>: View {
    typealias Slice = RingSlice

    var slices: [Slice]
    var target: Double?
    var lineWidth: CGFloat = 13
    @ViewBuilder var center: Center
    @State private var drawn = 0.0

    var body: some View {
        let total = slices.reduce(0) { $0 + max(0, $1.value) }
        let over = target.map { total > $0 } ?? false
        let lap = max(target ?? total, total, .ulpOfOne)
        GeometryReader { geo in
            let circumference = Double.pi * Double(geo.size.width - lineWidth)
            // Round caps overhang each arc; inset by half the stroke so neighbours don't overlap.
            let inset = circumference > 0 ? Double(lineWidth / 2 + 1.5) / circumference : 0
            ZStack {
                Circle()
                    .stroke((over ? Color.red : Color.white).opacity(over ? 0.35 : 0.14), lineWidth: lineWidth)
                ForEach(Array(arcs(lap: lap).enumerated()), id: \.offset) { _, arc in
                    let from = arc.from + inset
                    let to = max(from + 0.0001, arc.to - inset)
                    Circle()
                        .trim(from: from * drawn, to: to * drawn)
                        .stroke(arc.color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: arc.color.opacity(0.6), radius: 4)
                }
                center
            }
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.15)) { drawn = 1 } }
    }

    private func arcs(lap: Double) -> [(from: Double, to: Double, color: Color)] {
        var start = 0.0
        return slices.compactMap { slice in
            guard slice.value > 0 else { return nil }
            let end = start + slice.value / lap
            defer { start = end }
            return (start, end, slice.color)
        }
    }
}

/// The range totals as one stacked share bar plus a row per plan.
struct RangeCard: View {
    var payload: WatchPayload
    var title: String

    private var rows: [(group: String, cost: Double, tokens: Int64)] {
        [("personal", payload.personalCostUsd, payload.personalTokens),
         ("work", payload.workCostUsd, payload.workTokens),
         ("other", payload.otherCostUsd, 0)]
            .filter { $0.0 != "other" || $0.1 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(WatchPayload.usd(payload.totalCostUsd)).font(.footnote.weight(.semibold)).monospacedDigit()
            }
            ShareBar(parts: rows.map { (Palette.group($0.group), $0.cost) })
                .frame(height: 6)
            ForEach(rows, id: \.group) { row in
                HStack(spacing: 6) {
                    Circle().fill(Palette.group(row.group)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Palette.name(row.group)).font(.footnote.weight(.medium))
                        if row.tokens > 0 {
                            Text("\(WatchPayload.tokens(row.tokens)) tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(WatchPayload.usd(row.cost)).font(.footnote).monospacedDigit()
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ShareBar: View {
    var parts: [(color: Color, value: Double)]

    var body: some View {
        GeometryReader { geo in
            let total = parts.reduce(0) { $0 + max(0, $1.value) }
            let visible = parts.filter { $0.value > 0 }
            let spacing: CGFloat = 2
            let width = max(0, geo.size.width - spacing * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: spacing) {
                if total > 0 {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                        Capsule().fill(part.color.gradient).frame(width: max(geo.size.height, width * part.value / total))
                    }
                } else {
                    Capsule().fill(.white.opacity(0.14))
                }
            }
        }
    }
}

struct SyncFooter: View {
    var payload: WatchPayload
    var now: Date
    var showsServer = true

    var body: some View {
        let stale = payload.isStale(at: now)
        let ago = payload.updatedAt.formatted(.relative(presentation: .named))
        Label {
            Text(showsServer ? "\(payload.serverName) · \(ago)" : "Synced \(ago)")
        } icon: {
            Image(systemName: stale ? "exclamationmark.icloud" : "checkmark.icloud")
        }
        .font(.caption2)
        .foregroundStyle(stale ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Activity

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
                for group in Palette.groups {
                    let cost = bar.costs[group] ?? 0
                    let base = min(cost, bar.baselines[group] ?? 0)
                    let value = baseline ? base : cost - base
                    guard value > 0 else { continue }
                    out.append(Segment(id: "\(bar.start.timeIntervalSince1970):\(group):\(baseline)", start: bar.start,
                                       end: bar.start.addingTimeInterval(step * 0.8), low: top, high: top + value, group: group, baseline: baseline))
                    top += value
                }
            }
            return out
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let lastHour = showLastHour && payload.lastHour != nil || payload.today == nil
            let coversToday = payload.coversToday(at: context.date)
            // Yesterday's bars are not today's; show them only while they still describe today.
            let bars = (lastHour ? payload.lastHour : (coversToday ? payload.today : nil)) ?? []
            let step: TimeInterval = lastHour ? 60 : 900
            let segments = self.segments(bars, step: step)
            let total = bars.reduce(0) { $0 + $1.total }
            let peak = bars.max { $0.total < $1.total }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    pill("1H", selected: lastHour) { showLastHour = true }
                    pill("Today", selected: !lastHour) { showLastHour = false }
                }
                .disabled(payload.lastHour == nil || payload.today == nil)

                if lastHour || coversToday {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(WatchPayload.usd(total))
                            .font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                            .contentTransition(.numericText(value: total))
                        Text(lastHour ? "last hour" : pace(total, now: context.date))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !lastHour, !coversToday {
                    placeholder("Not synced yet today.", symbol: "moon.zzz")
                } else if segments.isEmpty {
                    placeholder("No usage in this window.", symbol: "leaf")
                } else {
                    Chart {
                        ForEach(segments) { segment in
                            RectangleMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                                          yStart: .value("Cost", segment.low), yEnd: .value("Cost", segment.high))
                                .foregroundStyle(Palette.group(segment.group).gradient.opacity(segment.baseline ? 0.35 : 1))
                                .cornerRadius(1.5)
                        }
                        if bars.count > 1 {
                            RuleMark(y: .value("Average", total / Double(bars.count)))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .chartYAxis(.hidden)
                    .chartXScale(domain: (bars.first?.start ?? context.date)...((bars.last?.start ?? context.date).addingTimeInterval(step)))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.12))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(lastHour ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.hour()))
                                }
                            }
                        }
                    }
                    .animation(.snappy, value: lastHour)
                    if let peak, peak.total > 0 {
                        Text("Peak \(WatchPayload.usd(peak.total)) at \(peak.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if payload.isStale(at: context.date) {
                    Text("Synced \(payload.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(LinearGradient(colors: [Palette.work.opacity(0.45), Palette.personal.opacity(0.2), .black],
                                            startPoint: .top, endPoint: .bottom), for: .tabView)
    }

    private func pace(_ total: Double, now: Date) -> String {
        let hours = max(1, now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 3600)
        return "today · \(WatchPayload.compactUsd(total / hours))/hr"
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.white.opacity(0.28) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Limits

struct LimitsPage: View {
    var payload: WatchPayload

    /// Accounts with their windows, tightest account first.
    private var accounts: [(name: String, limits: [WatchPayload.Limit])] {
        var order: [String] = []
        var byAccount: [String: [WatchPayload.Limit]] = [:]
        for limit in payload.limits {
            if byAccount[limit.account] == nil { order.append(limit.account) }
            byAccount[limit.account, default: []].append(limit)
        }
        return order.map { ($0, byAccount[$0] ?? []) }
            .sorted { ($0.limits.map(\.usedPercent).max() ?? 0) > ($1.limits.map(\.usedPercent).max() ?? 0) }
    }

    private var worst: Double { payload.limits.map(\.usedPercent).max() ?? 0 }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if payload.limits.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.0percent").font(.title2).foregroundStyle(.secondary)
                            Text("No usage windows reported.").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 20)
                    } else {
                        let near = payload.limits.filter { $0.usedPercent >= 90 }.count
                        Label(near > 0 ? "\(near) near limit" : "All within limits",
                              systemImage: near > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(near > 0 ? Color.red : Color.green)
                    }
                    ForEach(accounts, id: \.name) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Circle().fill(Palette.group(group(for: account.name))).frame(width: 6, height: 6)
                                Text(account.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 8) {
                                ForEach(account.limits) { limit in
                                    VStack(spacing: 2) {
                                        UsageRing(percent: limit.usedPercent).frame(width: 50, height: 50)
                                        Text(limit.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                        Text(limit.resetsAt > context.date ? "resets \(Self.countdown(to: limit.resetsAt, from: context.date))" : "reset")
                                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .containerBackground(Palette.glow(payload.limits.isEmpty ? .gray : Palette.usage(worst)), for: .tabView)
    }

    private func group(for account: String) -> String {
        payload.accounts.first { $0.name == account }?.group ?? "other"
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

struct UsageRing: View {
    var percent: Double
    var lineWidth: CGFloat = 6
    @State private var drawn = 0.0

    var body: some View {
        let color = Palette.usage(percent)
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.005, percent / 100)) * drawn)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.spring(duration: 0.8)) { drawn = 1 } }
    }
}

// MARK: - Accounts

struct AccountsPage: View {
    var payload: WatchPayload

    private var accounts: [WatchPayload.Account] { payload.accounts.sorted { $0.costUsd > $1.costUsd } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACCOUNTS · \(payload.rangeLabel.uppercased())")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                let top = accounts.first?.costUsd ?? 0
                ForEach(accounts) { account in
                    let color = Palette.group(account.group)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Image(systemName: Palette.symbol(provider: account.provider))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 22, height: 22)
                                .background(color.opacity(0.22), in: Circle())
                            VStack(alignment: .leading, spacing: 0) {
                                Text(account.name).font(.footnote.weight(.medium)).lineLimit(1)
                                Text("\(WatchPayload.tokens(account.tokens)) tok").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            Text(WatchPayload.usd(account.costUsd)).font(.footnote.weight(.semibold)).monospacedDigit()
                        }
                        // Relative to the biggest spender, so the leader reads as a full bar.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.1))
                                Capsule().fill(color.gradient)
                                    .frame(width: max(3, geo.size.width * (top > 0 ? account.costUsd / top : 0)))
                            }
                        }
                        .frame(height: 3)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(Palette.glow(Palette.work), for: .tabView)
    }
}

// MARK: - Source & settings

struct SourcePage: View {
    @Environment(WatchModel.self) private var model
    var payload: WatchPayload

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.title3).foregroundStyle(Palette.personal)
                    .frame(width: 40, height: 40)
                    .background(Palette.personal.opacity(0.2), in: Circle())
                Text(payload.serverName).font(.headline)
                TimelineView(.everyMinute) { context in
                    SyncFooter(payload: payload, now: context.date, showsServer: false)
                }
                if let status = model.status {
                    Text(status).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                // Also offered with a single Mac: it may not be the one shown.
                if !model.cloudChoices.isEmpty {
                    Text("MACS IN ICLOUD").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(model.cloudChoices, id: \.cloudMacID) { source in
                        Button { model.selectCloudMac(source) } label: {
                            HStack {
                                Text(source.serverName)
                                Spacer()
                                if source.cloudMacID == payload.cloudMacID { Image(systemName: "checkmark").foregroundStyle(Palette.personal) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("Watch face", systemImage: "applewatch.watchface").font(.footnote.weight(.semibold))
                    Text("Choose plans and a daily target in PlanMeter on iPhone → Settings → Watch complications.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(Palette.glow(Palette.personal), for: .tabView)
    }
}

struct EmptyStateView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "icloud")
                    .font(.title2).foregroundStyle(Palette.personal)
                    .symbolEffect(.pulse, isActive: model.isRefreshing)
                    .frame(width: 48, height: 48)
                    .background(Palette.personal.opacity(0.2), in: Circle())
                Text("Sync directly with iCloud. Enable iCloud sync in PlanMeter on your Mac.").font(.footnote).multilineTextAlignment(.center)
                if let status = model.status { Text(status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                ForEach(model.cloudChoices, id: \.cloudMacID) { source in
                    Button(source.serverName) { model.selectCloudMac(source) }
                }
                Button("Try again") { model.refresh() }
                    .font(.footnote)
                    .disabled(model.isRefreshing)
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(Palette.glow(Palette.personal), for: .navigation)
    }
}

// MARK: - Palette

enum Palette {
    static let personal = Color(red: 0.03, green: 0.57, blue: 0.70)
    static let work = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let other = Color(white: 0.62)
    static let groups = ["personal", "work", "other"]

    static func group(_ raw: String) -> Color {
        switch raw {
        case "personal": return personal
        case "work": return work
        default: return other
        }
    }

    static func name(_ raw: String) -> String {
        switch raw {
        case "personal": return "Personal"
        case "work": return "Work"
        default: return "Other"
        }
    }

    static func usage(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }

    static func symbol(provider: String) -> String {
        switch provider {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "claude": return "sparkle"
        case "grok": return "bolt.fill"
        case "opencode": return "curlybraces"
        case "antigravity": return "arrow.up.forward"
        default: return "cpu"
        }
    }

    /// A soft top glow fading to black, the watchOS 10 page background.
    static func glow(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.5), color.opacity(0.12), .black], startPoint: .top, endPoint: .bottom)
    }
}
