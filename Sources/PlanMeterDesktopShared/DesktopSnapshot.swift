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
                limit: Double?, warningPercent: Double = 80, providers: [Provider]) {
        self.scannedAt = scannedAt; self.generatedAt = generatedAt
        self.rangeID = rangeID; self.rangeName = rangeName; self.groups = groups
        self.cost = cost; self.tokens = tokens; self.unpricedTokens = unpricedTokens
        self.limit = limit; self.warningPercent = warningPercent; self.providers = providers
    }

    public var isValid: Bool {
        version == 1 && cost.isFinite && cost >= 0 && tokens >= 0 && unpricedTokens >= 0
            && (limit == nil || (limit!.isFinite && limit! > 0))
            && warningPercent.isFinite && (1...99).contains(warningPercent)
            && providers.allSatisfy { $0.cost.isFinite && $0.cost >= 0 }
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
        providers: [.init(id: "codex", name: "Codex", cost: 28.25), .init(id: "claude", name: "Claude Code", cost: 14.25)]
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
