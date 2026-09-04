import PlanMeterWatchShared
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let payload = model.payload {
                TabView {
                    SummaryPage(payload: payload).tag(0)
                    LimitsPage(payload: payload).tag(1)
                    AccountsPage(payload: payload).tag(2)
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
                VStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(.secondary)
                    Text("Open PlanMeter on your iPhone to sync.").font(.footnote).multilineTextAlignment(.center)
                    if let status = model.status { Text(status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Button("Try again") { model.refresh() }.font(.footnote)
                }
                .padding()
                .navigationTitle("PlanMeter")
            }
        }
    }
}

struct SummaryPage: View {
    @Environment(WatchModel.self) private var model
    var payload: WatchPayload

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Today").font(.caption2).foregroundStyle(.secondary)
                    Text(WatchPayload.usd(payload.todayCostUsd))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                Text("Last \(payload.days) days").font(.caption2).foregroundStyle(.secondary)
                GroupRow(name: "Personal", cost: payload.personalCostUsd, tokens: payload.personalTokens, total: payload.totalCostUsd, color: Palette.personal)
                GroupRow(name: "Work", cost: payload.workCostUsd, tokens: payload.workTokens, total: payload.totalCostUsd, color: Palette.work)
                if payload.otherCostUsd > 0 {
                    GroupRow(name: "Other", cost: payload.otherCostUsd, tokens: 0, total: payload.totalCostUsd, color: Palette.other)
                }
                if let status = model.status {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                }
                Text("Synced \(payload.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GroupRow: View {
    var name: String
    var cost: Double
    var tokens: Int
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
