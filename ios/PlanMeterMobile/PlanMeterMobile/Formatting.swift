import SwiftUI

enum Fmt {
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

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func groupName(_ raw: String) -> String {
        switch raw {
        case "personal": return "Personal"
        case "work": return "Work"
        default: return "Other"
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self = Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

enum Palette {
    static let series: [Color] = [
        Color(hex: "#4f7cff")!, Color(hex: "#f0883e")!, Color(hex: "#2fb87a")!, Color(hex: "#c06ad9")!,
        Color(hex: "#e5484d")!, Color(hex: "#0aa8a7")!, Color(hex: "#d9a400")!, Color(hex: "#8b8f98")!,
    ]

    static func group(_ raw: String) -> Color {
        switch raw {
        case "personal": return Color(hex: "#0891b2")!
        case "work": return Color(hex: "#7c3aed")!
        default: return Color(hex: "#8b8f98")!
        }
    }
}
