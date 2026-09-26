import Foundation

/// Compact summary received through Watch Connectivity or derived from iCloud.
/// Cached in the shared app group for the watch app and complications.
public struct WatchPayload: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var group: String
        public var provider: String
        public var costUsd: Double
        public var tokens: Int64
        public var id: String { "\(provider):\(name)" }

        public init(name: String, group: String, provider: String, costUsd: Double, tokens: Int64) {
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
    public var personalTokens: Int64
    public var workTokens: Int64
    public var todayCostUsd: Double
    public var cloudMacID: String?
    public var complicationPreferences: ComplicationPreferences?
    public var todayCostByGroup: [String: Double]?
    public var accounts: [Account]
    public var limits: [Limit]

    public init(updatedAt: Date, days: Int, serverName: String, personalCostUsd: Double, workCostUsd: Double, otherCostUsd: Double, personalTokens: Int64, workTokens: Int64, todayCostUsd: Double, accounts: [Account], limits: [Limit], todayCostByGroup: [String: Double]? = nil, complicationPreferences: ComplicationPreferences? = nil, cloudMacID: String? = nil) {
        self.cloudMacID = cloudMacID
        self.complicationPreferences = complicationPreferences
        self.updatedAt = updatedAt
        self.days = days
        self.serverName = serverName
        self.personalCostUsd = personalCostUsd
        self.workCostUsd = workCostUsd
        self.otherCostUsd = otherCostUsd
        self.personalTokens = personalTokens
        self.workTokens = workTokens
        self.todayCostUsd = todayCostUsd
        self.todayCostByGroup = todayCostByGroup
        self.accounts = accounts
        self.limits = limits
    }

    /// Legacy caches cannot supply a filtered calendar-day total.
    public func todayCost(groups: Set<String>) -> Double? {
        if groups.isEmpty { return 0 }
        if groups == Set(["personal", "work", "other"]) { return todayCostUsd }
        guard let todayCostByGroup else { return nil }
        return groups.reduce(0) { $0 + (todayCostByGroup[$1] ?? 0) }
    }

    public var totalCostUsd: Double { personalCostUsd + workCostUsd + otherCostUsd }

    public var rangeLabel: String { days == 1 ? "24h" : "\(days)d" }

    /// A cached "today" total must not silently become tomorrow's total.
    public func isStale(at date: Date, calendar: Calendar = .current) -> Bool {
        date.timeIntervalSince(updatedAt) >= 15 * 60 || !calendar.isDate(updatedAt, inSameDayAs: date)
    }

    public func nextWidgetRefresh(after date: Date, calendar: Calendar = .current) -> Date {
        let fallback = date.addingTimeInterval(15 * 60)
        let expiry = updatedAt.addingTimeInterval(15 * 60)
        let midnight = calendar.dateInterval(of: .day, for: date)?.end ?? fallback
        return min(fallback, midnight, expiry > date ? expiry : fallback)
    }

    // MARK: Transport and shared storage

    public static let appGroup = "group.com.neilgoldader.planmeter"
    public static let contextKey = "payload"
    public static let clearContextKey = "clearPayload"

    public static func clear() { sharedDefaults().removeObject(forKey: defaultsKey) }
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

    public static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return "\(value)"
    }
}
