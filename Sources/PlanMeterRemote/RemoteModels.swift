import Foundation

/// JSON coding shared by both ends of the wire: ISO-8601 dates, base64 data,
/// stable key order so signatures over encoded bodies are reproducible.
public enum RemoteJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum RemoteMethod: String, Codable, CaseIterable, Sendable {
    case summary
    case models
    case timeline
    case limits
    case accounts
}

/// What the phone asks for. One RPC shape keeps the encrypted channel simple.
public struct RemoteRequest: Codable, Sendable, Equatable {
    public var method: RemoteMethod
    public var days: Int?
    /// "minute", "5m", "15m", "hour", or "day"; timeline only. Older Macs
    /// understand only "hour" and "day".
    public var resolution: String?
    /// Account filter for `models`.
    public var account: String?
    /// A window shorter than a day, in minutes, ending now; overrides `days`.
    public var minutes: Int?

    public init(method: RemoteMethod, days: Int? = nil, resolution: String? = nil, account: String? = nil, minutes: Int? = nil) {
        self.method = method
        self.days = days
        self.resolution = resolution
        self.account = account
        self.minutes = minutes
    }
}

public struct RemoteTotals: Codable, Sendable, Equatable {
    public var costUsd: Double
    public var tokens: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var sessions: Int
    public var cacheSavingsUsd: Double

    public init(costUsd: Double = 0, tokens: Int = 0, inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, sessions: Int = 0, cacheSavingsUsd: Double = 0) {
        self.costUsd = costUsd
        self.tokens = tokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.sessions = sessions
        self.cacheSavingsUsd = cacheSavingsUsd
    }

    public var cachedShare: Double { inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : 0 }
}

public struct RemoteAccount: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var provider: String
    public var providerName: String
    public var group: String
    public var email: String?
    public var plan: String?
    public var accentColorHex: String?

    public init(id: String, name: String, provider: String, providerName: String, group: String, email: String? = nil, plan: String? = nil, accentColorHex: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.providerName = providerName
        self.group = group
        self.email = email
        self.plan = plan
        self.accentColorHex = accentColorHex
    }
}

public struct RemoteAccountUsage: Codable, Sendable, Equatable, Identifiable {
    public var account: RemoteAccount
    public var totals: RemoteTotals
    public var id: String { account.id }

    public init(account: RemoteAccount, totals: RemoteTotals) {
        self.account = account
        self.totals = totals
    }
}

public struct RemoteGroupUsage: Codable, Sendable, Equatable, Identifiable {
    public var group: String
    public var totals: RemoteTotals
    public var accounts: [RemoteAccountUsage]
    public var id: String { group }

    public init(group: String, totals: RemoteTotals, accounts: [RemoteAccountUsage]) {
        self.group = group
        self.totals = totals
        self.accounts = accounts
    }
}

public struct RemoteSummary: Codable, Sendable, Equatable {
    public var days: Int
    public var from: Date
    public var to: Date
    public var groups: [RemoteGroupUsage]
    public var total: RemoteTotals
    public var todayCostUsd: Double
    public var generatedAt: Date
    public var serverName: String
    public var pricingSource: String
    public var usesProviderDates: Bool?
    /// Set for windows shorter than a day.
    public var minutes: Int?

    public init(days: Int, from: Date, to: Date, groups: [RemoteGroupUsage], total: RemoteTotals, todayCostUsd: Double, generatedAt: Date, serverName: String, pricingSource: String, usesProviderDates: Bool? = nil, minutes: Int? = nil) {
        self.minutes = minutes
        self.days = days
        self.from = from
        self.to = to
        self.groups = groups
        self.total = total
        self.todayCostUsd = todayCostUsd
        self.generatedAt = generatedAt
        self.serverName = serverName
        self.pricingSource = pricingSource
        self.usesProviderDates = usesProviderDates
    }
}

public struct RemoteModelRow: Codable, Sendable, Equatable, Identifiable {
    public var accountId: String
    public var accountName: String
    public var group: String
    public var provider: String
    public var model: String
    public var totals: RemoteTotals
    public var priced: Bool
    public var id: String { "\(accountId):\(model)" }

    public init(accountId: String, accountName: String, group: String, provider: String, model: String, totals: RemoteTotals, priced: Bool) {
        self.accountId = accountId
        self.accountName = accountName
        self.group = group
        self.provider = provider
        self.model = model
        self.totals = totals
        self.priced = priced
    }
}

public struct RemoteTimelinePoint: Codable, Sendable, Equatable, Identifiable {
    public var period: Date
    public var accountId: String
    public var costUsd: Double
    public var tokens: Int
    /// The part of `costUsd` from workspace credits without timing, spread evenly
    /// over the hours the provider reported. Charts can draw it as a lighter baseline.
    public var baselineCostUsd: Double?
    public var id: String { "\(period.timeIntervalSince1970):\(accountId)" }

    public init(period: Date, accountId: String, costUsd: Double, tokens: Int, baselineCostUsd: Double? = nil) {
        self.period = period
        self.accountId = accountId
        self.costUsd = costUsd
        self.tokens = tokens
        self.baselineCostUsd = baselineCostUsd
    }
}

public struct RemoteTimeline: Codable, Sendable, Equatable {
    public var days: Int
    public var resolution: String
    public var periods: [Date]
    public var points: [RemoteTimelinePoint]
    public var accounts: [RemoteAccount]
    /// Set for windows shorter than a day.
    public var minutes: Int?

    public init(days: Int, resolution: String, periods: [Date], points: [RemoteTimelinePoint], accounts: [RemoteAccount], minutes: Int? = nil) {
        self.days = days
        self.resolution = resolution
        self.periods = periods
        self.points = points
        self.accounts = accounts
        self.minutes = minutes
    }

    /// Bucket length in seconds for fixed-step resolutions; nil for calendar days.
    public static func stepSeconds(_ resolution: String) -> TimeInterval? {
        switch resolution {
        case "minute": return 60
        case "5m": return 300
        case "15m": return 900
        case "hour": return 3600
        default: return nil
        }
    }

    /// Whether a fixed-step timeline can be re-bucketed into `target`.
    public static func coarsens(_ source: String, to target: String) -> Bool {
        guard let step = stepSeconds(source), let wide = stepSeconds(target) else { return false }
        return wide > step && wide.truncatingRemainder(dividingBy: step) == 0
    }

    /// Re-buckets a fixed-step timeline into a coarser fixed step, e.g. 5m into
    /// 15m or hour. Returns nil when the target is not a whole multiple.
    public func rebucketed(to target: String) -> RemoteTimeline? {
        guard target != resolution else { return self }
        guard let step = Self.stepSeconds(resolution), let wide = Self.stepSeconds(target), wide > step,
              wide.truncatingRemainder(dividingBy: step) == 0 else { return nil }
        func floor(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / wide).rounded(.down) * wide) }
        struct Key: Hashable { var period: Date; var account: String }
        var merged: [Key: RemoteTimelinePoint] = [:]
        for point in points {
            let key = Key(period: floor(point.period), account: point.accountId)
            var value = merged[key] ?? RemoteTimelinePoint(period: key.period, accountId: point.accountId, costUsd: 0, tokens: 0)
            value.costUsd += point.costUsd
            value.tokens += point.tokens
            if let baseline = point.baselineCostUsd { value.baselineCostUsd = (value.baselineCostUsd ?? 0) + baseline }
            merged[key] = value
        }
        var periods: [Date] = []
        for period in self.periods.map(floor) where periods.last != period { periods.append(period) }
        return RemoteTimeline(days: days, resolution: target, periods: periods,
                              points: merged.values.sorted { $0.period == $1.period ? $0.accountId < $1.accountId : $0.period < $1.period },
                              accounts: accounts, minutes: minutes)
    }
}

extension RemoteTimeline {
    /// Cost per period by plan group, with the untimed workspace baseline kept apart.
    public struct GroupBar: Sendable, Equatable {
        public var start: Date
        public var costs: [String: Double]
        public var baselines: [String: Double]
    }

    /// Every period (zero-filled), optionally limited to one local calendar day.
    public func groupBars(on day: Date? = nil, calendar: Calendar = .current) -> [GroupBar] {
        let groups = Dictionary(accounts.map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        var bars = Dictionary(periods.map { ($0, GroupBar(start: $0, costs: [:], baselines: [:])) }, uniquingKeysWith: { first, _ in first })
        for point in points {
            let group = groups[point.accountId] ?? "other"
            var bar = bars[point.period] ?? GroupBar(start: point.period, costs: [:], baselines: [:])
            bar.costs[group, default: 0] += point.costUsd
            if let baseline = point.baselineCostUsd { bar.baselines[group, default: 0] += baseline }
            bars[point.period] = bar
        }
        return bars.values.filter { day == nil || calendar.isDate($0.start, inSameDayAs: day!) }.sorted { $0.start < $1.start }
    }

    /// Sum the calendar day's buckets, excluding earlier hours in a rolling 24h report.
    public func costByGroup(on date: Date, calendar: Calendar = .current) -> [String: Double] {
        let groups = Dictionary(accounts.map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        return points.filter { calendar.isDate($0.period, inSameDayAs: date) }
            .reduce(into: [String: Double]()) { result, point in
                result[groups[point.accountId] ?? "other", default: 0] += point.costUsd
            }
    }
}

public struct RemoteLimitWindow: Codable, Sendable, Equatable {
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date

    public init(label: String, usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct RemoteAccountLimits: Codable, Sendable, Equatable, Identifiable {
    public var account: RemoteAccount
    public var windows: [RemoteLimitWindow]
    public var note: String?
    public var asOf: Date?
    public var id: String { account.id }

    public init(account: RemoteAccount, windows: [RemoteLimitWindow], note: String? = nil, asOf: Date? = nil) {
        self.account = account
        self.windows = windows
        self.note = note
        self.asOf = asOf
    }
}

public struct RemoteLimits: Codable, Sendable, Equatable {
    public var accounts: [RemoteAccountLimits]
    public var note: String

    public init(accounts: [RemoteAccountLimits], note: String) {
        self.accounts = accounts
        self.note = note
    }
}

public struct RemoteSource: Codable, Sendable, Equatable, Identifiable {
    public var provider: String
    public var path: String
    public var status: String
    public var id: String { "\(provider):\(path)" }

    public init(provider: String, path: String, status: String) {
        self.provider = provider
        self.path = path
        self.status = status
    }
}

public struct RemoteAccounts: Codable, Sendable, Equatable {
    public var accounts: [RemoteAccount]
    public var sources: [RemoteSource]
    public var scannedAt: Date?

    public init(accounts: [RemoteAccount], sources: [RemoteSource], scannedAt: Date?) {
        self.accounts = accounts
        self.sources = sources
        self.scannedAt = scannedAt
    }
}

/// Union reply: exactly one payload field is set for a successful call.
public struct RemoteReply: Codable, Sendable, Equatable {
    public var summary: RemoteSummary?
    public var models: [RemoteModelRow]?
    public var timeline: RemoteTimeline?
    public var limits: RemoteLimits?
    public var accounts: RemoteAccounts?
    public var error: String?

    public init(summary: RemoteSummary? = nil, models: [RemoteModelRow]? = nil, timeline: RemoteTimeline? = nil, limits: RemoteLimits? = nil, accounts: RemoteAccounts? = nil, error: String? = nil) {
        self.summary = summary
        self.models = models
        self.timeline = timeline
        self.limits = limits
        self.accounts = accounts
        self.error = error
    }
}

/// Unauthenticated `GET /v1/info`: enough for a client to recognize a
/// PlanMeter server, nothing about the data behind it.
public struct ServerInfo: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var serverName: String
    public var protocolVersion: Int

    public init(app: String = "planmeter", version: String, serverName: String, protocolVersion: Int = SecureChannel.protocolVersion) {
        self.app = app
        self.version = version
        self.serverName = serverName
        self.protocolVersion = protocolVersion
    }
}
