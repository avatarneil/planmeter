import SwiftUI
import PlanMeterCore

enum Format {
    static func usd(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value > 0, value < 0.005 { return "<$0.01" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = value >= 1000 ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fK", v / 1_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 10080: return "Weekly"
        case 300: return "5-hour"
        case 60: return "Hourly"
        case 1440: return "Daily"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Palette {
    /// Fallback series colors when account discovery provides no accent.
    static let series: [Color] = [
        Color(hex: "#4f7cff")!, Color(hex: "#f0883e")!, Color(hex: "#2fb87a")!, Color(hex: "#c06ad9")!,
        Color(hex: "#e5484d")!, Color(hex: "#0aa8a7")!, Color(hex: "#d9a400")!, Color(hex: "#8b8f98")!,
    ]

    static func color(for account: Account, index: Int) -> Color {
        if let hex = account.accentColorHex, let c = Color(hex: hex) { return c }
        return series[index % series.count]
    }

    static func color(for group: PlanGroup) -> Color {
        switch group {
        case .personal: return Color(hex: "#0891b2")!
        case .work: return Color(hex: "#7c3aed")!
        case .other: return Color(hex: "#8b8f98")!
        }
    }
}

struct StatusDot: View {
    var status: SourceStatus
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(status.rawValue)
    }
    var color: Color {
        switch status {
        case .ok: return .green
        case .partial: return .yellow
        case .missing: return .secondary
        case .failed: return .red
        }
    }
}
