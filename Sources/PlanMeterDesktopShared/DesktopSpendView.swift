#if os(macOS)
import SwiftUI
import Charts

/// Shared with the Mac's snapshot renderer for visual verification at widget sizes.
public struct DesktopSpendView: View {
    public var snapshot: DesktopSnapshot?
    public var date: Date
    public enum Size { case small, medium, large, extraLarge }
    public var size: Size
    private var medium: Bool { size == .medium }

    public init(snapshot: DesktopSnapshot?, date: Date, size: Size) {
        self.snapshot = snapshot; self.date = date; self.size = size
    }

    private let teal = Color(red: 0.10, green: 0.72, blue: 0.63)
    private let amber = Color(red: 0.96, green: 0.63, blue: 0.16)
    private let coral = Color(red: 0.96, green: 0.34, blue: 0.40)

    public var body: some View {
        if let snapshot, size == .large || size == .extraLarge {
            HStack(alignment: .top, spacing: 24) {
                largeOverview(snapshot).frame(maxWidth: .infinity)
                if size == .extraLarge {
                    Rectangle().fill(.primary.opacity(0.10)).frame(width: 1)
                    accountBreakdown(snapshot).frame(maxWidth: .infinity)
                }
            }
        } else if let snapshot {
            HStack(alignment: .top, spacing: 20) {
                summary(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if medium {
                    Rectangle().fill(.primary.opacity(0.10)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("YOUR TOOLS").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                        ForEach(Array(snapshot.providers.prefix(3).enumerated()), id: \.element.id) { index, provider in
                            VStack(spacing: 3) {
                                HStack {
                                    Text(provider.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(usd(provider.cost)).monospacedDigit()
                                }
                                .font(.system(size: 10, weight: .medium))
                                meter(snapshot.cost > 0 ? provider.cost / snapshot.cost : 0,
                                      color: index == 0 ? teal : index == 1 ? .purple : .orange)
                            }
                        }
                        if snapshot.providers.count > 3 {
                            Text("+\(snapshot.providers.count - 3) more in PlanMeter").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(snapshot.groups.joined(separator: " + "))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("PlanMeter", systemImage: "sparkles").font(.headline).foregroundStyle(teal)
                Text("Your spend, at a glance.").font(.subheadline.weight(.semibold))
                Text("Open PlanMeter to load your usage.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func summary(_ snapshot: DesktopSnapshot) -> some View {
        let stale = snapshot.isStale(at: date)
        let fraction = snapshot.fraction ?? 0
        let color = fraction >= 1 ? coral : fraction >= snapshot.warningPercent / 100 ? amber : teal
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").foregroundStyle(color)
                Text("PLANMETER").tracking(1)
            }
            .font(.system(size: 9, weight: .bold))
            Text(stale ? "Last snapshot" : snapshot.rangeName)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(usd(snapshot.cost))
                .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.55).lineLimit(1)
            if let limit = snapshot.limit {
                meter(fraction, color: color)
                Text(snapshot.cost >= limit
                     ? (snapshot.cost == limit ? "Right at your limit" : "\(usd(snapshot.cost - limit)) over limit")
                     : "\(usd(limit - snapshot.cost)) room to go")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                Text("of \(usd(limit)) · \(fraction.formatted(.percent.precision(.fractionLength(0)))) used")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Estimated usage cost").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("Set a limit in the menu bar").font(.system(size: 9)).foregroundStyle(teal).lineLimit(1).minimumScaleFactor(0.7)
            }
            if !medium {
                Text(snapshot.groups.joined(separator: " + "))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if stale {
                Text("Open app to refresh").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            } else if snapshot.unpricedTokens > 0 {
                Text("Some tokens unpriced").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text(snapshot.scannedAt, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityLabel("Usage updated at \(snapshot.scannedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    private func largeOverview(_ snapshot: DesktopSnapshot) -> some View {
        let fraction = snapshot.fraction ?? 0
        let tint = fraction >= 1 ? coral : fraction >= snapshot.warningPercent / 100 ? amber : teal
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PLANMETER", systemImage: "sparkles").foregroundStyle(tint)
                    .font(.system(size: 10, weight: .bold))
                Spacer()
                Text(snapshot.isStale(at: date) ? "Last snapshot" : snapshot.rangeName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                Text(usd(snapshot.cost)).font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if let limit = snapshot.limit {
                        Text(snapshot.cost > limit ? "\(usd(snapshot.cost - limit)) over" : "\(usd(limit - snapshot.cost)) left")
                            .foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
                        Text("of \(usd(limit)) limit").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("Your AI spend").font(.system(size: 12, weight: .semibold))
                        Text("Set a limit in the app").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.6)
            }
            if snapshot.limit != nil { meter(fraction, color: tint) }
            HStack {
                detailStat("TOKENS", compactTokens(snapshot.tokens))
                Spacer(minLength: 8)
                detailStat("CACHED INPUT", snapshot.detail.map { $0.cachedInputShare.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                Spacer(minLength: 8)
                detailStat("CACHE SAVINGS", snapshot.detail.map { usd($0.cacheSavings) } ?? "–")
            }
            if let detail = snapshot.detail {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SPEND OVER TIME · \(detail.hourly ? "HOURLY" : "DAILY")")
                        Spacer()
                        Text("Peak \(usd(detail.trend.map(\.cost).max() ?? 0))")
                    }
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Chart(detail.trend, id: \.date) { point in
                        BarMark(x: .value("Time", point.date, unit: detail.hourly ? .hour : .day), y: .value("Cost", point.cost))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint], startPoint: .bottom, endPoint: .top))
                            .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(detail.hourly ? .dateTime.hour() : .dateTime.month(.abbreviated).day()))
                                        .font(.system(size: 8))
                                }
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 92)
                    .accessibilityLabel("Estimated spending over the selected period")
                }
            } else {
                Text("Open PlanMeter to load the trend and cache stats.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 92)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Array(snapshot.providers.enumerated()), id: \.element.id) { index, provider in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(provider.name).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(usd(provider.cost)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .font(.system(size: 10, weight: .medium))
                        meter(snapshot.cost > 0 ? provider.cost / snapshot.cost : 0,
                              color: [teal, Color.purple, Color.orange, Color.blue][index % 4])
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(snapshot.groups.joined(separator: " + ")).lineLimit(1)
                Spacer(minLength: 4)
                Text(snapshot.isStale(at: date) ? "Open app to refresh" : "Est. cost · \(snapshot.scannedAt.formatted(date: .omitted, time: .shortened))")
                    .lineLimit(1)
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            if snapshot.unpricedTokens > 0 {
                Text("Some tokens are unpriced").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func detailStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func accountBreakdown(_ snapshot: DesktopSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHERE IT WENT").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            if let detail = snapshot.detail {
                ForEach(Array(detail.accounts.prefix(6).enumerated()), id: \.element.id) { index, account in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(usd(account.cost)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                        HStack {
                            Text(account.provider)
                            Spacer()
                            Text("\(compactTokens(account.tokens)) tokens")
                        }
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        meter(snapshot.cost > 0 ? account.cost / snapshot.cost : 0,
                              color: [teal, Color.purple, Color.orange, Color.blue][index % 4])
                    }
                }
                if detail.accounts.count > 6 {
                    Text("+\(detail.accounts.count - 6) more accounts in the app").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if detail.accounts.isEmpty {
                    Text("No accounts in this selection.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Open PlanMeter to load account details.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Updated \(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func compactTokens(_ tokens: Int) -> String {
        let value = Double(tokens)
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(tokens)"
    }

    private func meter(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 1000 ? 0 : 2)))
    }
}
#endif
