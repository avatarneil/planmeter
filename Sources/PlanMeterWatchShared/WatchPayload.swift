import Foundation

/// The compact summary the iPhone relays to the watch. The watch never talks to
/// the Mac or holds pairing keys; it only ever sees this derived payload, sent
/// over Apple's encrypted Watch Connectivity link, and caches it in the shared
/// app group so the complication can read it.
public struct WatchPayload: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var group: String
        public var provider: String
        public var costUsd: Double
        public var tokens: Int
        public var id: String { "\(provider):\(name)" }

        public init(name: String, group: String, provider: String, costUsd: Double, tokens: Int) {
            self.name = name
            self.group = group
            self.provider = provider
            self.costUsd = costUsd
            self.tokens = tokens
        }
    }

    public struct Limit: Codable, Equatable, Sendable, Identifiable {
        public var account: String
        public var label: String
        public var usedPercent: Double
        public var resetsAt: Date
        public var id: String { "\(account):\(label)" }

        public init(account: String, label: String, usedPercent: Double, resetsAt: Date) {
            self.account = account
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var updatedAt: Date
    public var days: Int
    public var serverName: String
    public var personalCostUsd: Double
    public var workCostUsd: Double
    public var otherCostUsd: Double
    public var personalTokens: Int
    public var workTokens: Int
    public var todayCostUsd: Double
    public var accounts: [Account]
    public var limits: [Limit]

    public init(updatedAt: Date, days: Int, serverName: String, personalCostUsd: Double, workCostUsd: Double, otherCostUsd: Double, personalTokens: Int, workTokens: Int, todayCostUsd: Double, accounts: [Account], limits: [Limit]) {
        self.updatedAt = updatedAt
        self.days = days
        self.serverName = serverName
        self.personalCostUsd = personalCostUsd
        self.workCostUsd = workCostUsd
        self.otherCostUsd = otherCostUsd
        self.personalTokens = personalTokens
        self.workTokens = workTokens
        self.todayCostUsd = todayCostUsd
        self.accounts = accounts
        self.limits = limits
    }

    public var totalCostUsd: Double { personalCostUsd + workCostUsd + otherCostUsd }

    // MARK: Transport and shared storage

    public static let appGroup = "group.com.neilgoldader.planmeter"
    public static let contextKey = "payload"
    static let defaultsKey = "watchPayload.v1"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() -> Data? { try? Self.encoder.encode(self) }

    public static func decode(_ data: Data) -> WatchPayload? { try? decoder.decode(WatchPayload.self, from: data) }

    /// Shared defaults for the watch app and its complication; falls back to
    /// standard defaults when the app group entitlement is missing.
    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    public static func load() -> WatchPayload? {
        guard let data = sharedDefaults().data(forKey: defaultsKey) else { return nil }
        return decode(data)
    }

    public func save() {
        guard let data = encoded() else { return }
        Self.sharedDefaults().set(data, forKey: Self.defaultsKey)
    }

    // MARK: Formatting shared by watch views and the complication

    public static func usd(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.0f", value) }
        if value >= 100 { return String(format: "$%.0f", value) }
        if value > 0, value < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    public static func compactUsd(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "$%.0fK", value / 1000) }
        if value >= 1000 { return String(format: "$%.1fK", value / 1000) }
        if value >= 10 { return String(format: "$%.0f", value) }
        return String(format: "$%.1f", value)
    }

    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return "\(value)"
    }
}
