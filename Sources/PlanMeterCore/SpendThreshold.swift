import Foundation

/// A personal target for estimated usage cost, not a provider-enforced cap.
public struct SpendThreshold: Codable, Equatable {
    public var limit: Double
    public var warningPercent: Double

    public init(limit: Double, warningPercent: Double = 80) {
        self.limit = limit
        self.warningPercent = warningPercent
    }

    public var isValid: Bool {
        limit.isFinite && limit >= 0.01 && limit <= 1_000_000_000
            && warningPercent.isFinite && (1...99).contains(warningPercent)
    }

    public enum Status { case comfortable, approaching, reached }

    public func status(spend: Double) -> Status {
        if spend >= limit { return .reached }
        if spend >= limit * warningPercent / 100 { return .approaching }
        return .comfortable
    }

    public func fraction(spend: Double) -> Double {
        guard isValid, spend.isFinite else { return 0 }
        return max(0, spend / limit)
    }

    public static func load(from defaults: UserDefaults) -> [String: SpendThreshold] {
        guard let data = defaults.data(forKey: "menuBarSpendThresholds"),
              let values = try? JSONDecoder().decode([String: SpendThreshold].self, from: data) else { return [:] }
        return values.filter { $0.value.isValid }
    }

    public static func save(_ values: [String: SpendThreshold], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(values.filter { $0.value.isValid }) else { return }
        defaults.set(data, forKey: "menuBarSpendThresholds")
    }
}
