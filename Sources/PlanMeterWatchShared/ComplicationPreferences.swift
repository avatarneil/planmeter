import Foundation

/// Shared by the phone's settings screen and the watch's cached summary.
public struct ComplicationPreferences: Codable, Equatable, Sendable {
    public var personal = true
    public var work = true
    public var other = true
    public var dailyTarget: Double = 0

    public init() {}

    public var target: Double? {
        dailyTarget.isFinite && (0.01...1_000_000_000).contains(dailyTarget) ? dailyTarget : nil
    }

    public static func parseTarget(_ text: String, locale: Locale = .current) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: separator))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              text.components(separatedBy: separator).count <= 2 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        guard let value = formatter.number(from: text)?.doubleValue,
              value.isFinite, (0.01...1_000_000_000).contains(value) else { return nil }
        return value
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "watch.complicationPreferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "watch.complicationPreferences")
    }
}
