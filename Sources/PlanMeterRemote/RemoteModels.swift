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
    /// "day" or "hour"; timeline only.
    public var resolution: String?
    /// Account filter for `models`.
    public var account: String?

    public init(method: RemoteMethod, days: Int? = nil, resolution: String? = nil, account: String? = nil) {
        self.method = method
        self.days = days
        self.resolution = resolution
        self.account = account
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

    public init(days: Int, from: Date, to: Date, groups: [RemoteGroupUsage], total: RemoteTotals, todayCostUsd: Double, generatedAt: Date, serverName: String, pricingSource: String) {
        self.days = days
        self.from = from
        self.to = to
        self.groups = groups
        self.total = total
        self.todayCostUsd = todayCostUsd
        self.generatedAt = generatedAt
        self.serverName = serverName
        self.pricingSource = pricingSource
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
    public var id: String { "\(period.timeIntervalSince1970):\(accountId)" }

    public init(period: Date, accountId: String, costUsd: Double, tokens: Int) {
        self.period = period
        self.accountId = accountId
        self.costUsd = costUsd
        self.tokens = tokens
    }
}

public struct RemoteTimeline: Codable, Sendable, Equatable {
    public var days: Int
    public var resolution: String
    public var periods: [Date]
    public var points: [RemoteTimelinePoint]
    public var accounts: [RemoteAccount]

    public init(days: Int, resolution: String, periods: [Date], points: [RemoteTimelinePoint], accounts: [RemoteAccount]) {
        self.days = days
        self.resolution = resolution
        self.periods = periods
        self.points = points
        self.accounts = accounts
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
