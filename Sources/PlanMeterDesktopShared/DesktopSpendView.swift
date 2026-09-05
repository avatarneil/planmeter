#if os(macOS)
import SwiftUI

/// Shared with the Mac's snapshot renderer for visual verification at widget sizes.
public struct DesktopSpendView: View {
    public var snapshot: DesktopSnapshot?
    public var date: Date
    public var medium: Bool

    public init(snapshot: DesktopSnapshot?, date: Date, medium: Bool) {
        self.snapshot = snapshot; self.date = date; self.medium = medium
    }

    private let teal = Color(red: 0.10, green: 0.72, blue: 0.63)
    private let amber = Color(red: 0.96, green: 0.63, blue: 0.16)
    private let coral = Color(red: 0.96, green: 0.34, blue: 0.40)

    public var body: some View {
        if let snapshot {
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
