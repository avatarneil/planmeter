import Foundation

/// A derived summary only: widget extensions never read transcripts or credentials.
public struct DesktopSnapshot: Codable, Equatable, Sendable {
    public struct Provider: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var cost: Double
        public init(id: String, name: String, cost: Double) {
            self.id = id; self.name = name; self.cost = cost
        }
    }

    public struct Detail: Codable, Equatable, Sendable {
        public struct Point: Codable, Equatable, Sendable {
            public var date: Date
            public var cost: Double
            public init(date: Date, cost: Double) { self.date = date; self.cost = cost }
        }
        public struct Account: Codable, Equatable, Identifiable, Sendable {
            public var id: String
            public var name: String
            public var provider: String
            public var cost: Double
            public var tokens: Int
            public init(id: String, name: String, provider: String, cost: Double, tokens: Int) {
                self.id = id; self.name = name; self.provider = provider; self.cost = cost; self.tokens = tokens
            }
        }
        public var hourly: Bool
        public var trend: [Point]
        public var accounts: [Account]
        public var cacheSavings: Double
        public var cachedInputShare: Double
        public init(hourly: Bool, trend: [Point], accounts: [Account], cacheSavings: Double, cachedInputShare: Double) {
            self.hourly = hourly; self.trend = trend; self.accounts = accounts
            self.cacheSavings = cacheSavings; self.cachedInputShare = cachedInputShare
        }
        public var isValid: Bool {
            cacheSavings.isFinite && cacheSavings >= 0
                && cachedInputShare.isFinite && (0...1).contains(cachedInputShare)
                && trend.allSatisfy { $0.cost.isFinite && $0.cost >= 0 }
                && accounts.allSatisfy { $0.cost.isFinite && $0.cost >= 0 && $0.tokens >= 0 }
                && Set(accounts.map(\.id)).count == accounts.count
                && Set(trend.map(\.date)).count == trend.count
        }
    }

    /// Optional so snapshots written by the first widget build remain readable.
    public var detail: Detail?
    public var version = 1
    public var scannedAt: Date
    public var generatedAt: Date
    public var rangeID: String
    public var rangeName: String
    public var groups: [String]
    public var cost: Double
    public var tokens: Int
    public var unpricedTokens: Int
    public var limit: Double?
    public var warningPercent: Double
    public var providers: [Provider]

    public init(scannedAt: Date, generatedAt: Date = Date(), rangeID: String, rangeName: String,
                groups: [String], cost: Double, tokens: Int, unpricedTokens: Int = 0,
                limit: Double?, warningPercent: Double = 80, providers: [Provider], detail: Detail? = nil) {
        self.scannedAt = scannedAt; self.generatedAt = generatedAt
        self.rangeID = rangeID; self.rangeName = rangeName; self.groups = groups
        self.cost = cost; self.tokens = tokens; self.unpricedTokens = unpricedTokens
        self.limit = limit; self.warningPercent = warningPercent; self.providers = providers
        self.detail = detail
    }

    public var isValid: Bool {
        version == 1 && cost.isFinite && cost >= 0 && tokens >= 0 && unpricedTokens >= 0
            && (limit == nil || (limit!.isFinite && limit! > 0))
            && warningPercent.isFinite && (1...99).contains(warningPercent)
            && providers.allSatisfy { $0.cost.isFinite && $0.cost >= 0 }
            && (detail?.isValid ?? true)
    }

    public var fraction: Double? { limit.map { cost / $0 } }

    public func isStale(at now: Date, calendar: Calendar = .current) -> Bool {
        now.timeIntervalSince(scannedAt) >= 15 * 60
            || (rangeID == "today" && !calendar.isDate(generatedAt, inSameDayAs: now))
    }

    public static func decode(_ data: Data) -> DesktopSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.isValid else { return nil }
        return snapshot
    }

    public static let preview = DesktopSnapshot(
        scannedAt: Date(), rangeID: "today", rangeName: "Today", groups: ["Personal", "Work"],
        cost: 42.50, tokens: 12_400_000, limit: 75,
        providers: [.init(id: "codex", name: "Codex", cost: 28.25), .init(id: "claude", name: "Claude Code", cost: 14.25)],
        detail: Detail(hourly: true,
                       trend: [1.5, 0, 3, 2, 5, 1, 0, 7, 4, 2, 6, 11.0].enumerated().map {
                           .init(date: Date().addingTimeInterval(Double($0.offset - 11) * 3600), cost: $0.element)
                       },
                       accounts: [.init(id: "personal-codex", name: "Personal Codex", provider: "Codex", cost: 18.25, tokens: 5_000_000),
                                  .init(id: "work-claude", name: "Work Claude", provider: "Claude Code", cost: 14.25, tokens: 4_400_000),
                                  .init(id: "work-codex", name: "Work Codex", provider: "Codex", cost: 10, tokens: 3_000_000)],
                       cacheSavings: 87.20, cachedInputShare: 0.82)
    )
}

public enum DesktopWidgetStore {
    public static let kind = "com.neilgoldader.planmeter.desktop.spend"
    public static let filename = "desktop-spend-v1.json"

    public static var container: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PlanMeterAppGroup") as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func load(from directory: URL? = container) -> DesktopSnapshot? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        return DesktopSnapshot.decode(data)
    }

    public static func save(_ snapshot: DesktopSnapshot, to directory: URL) throws {
        guard snapshot.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
