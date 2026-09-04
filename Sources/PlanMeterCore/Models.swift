import Foundation

/// Token counts for one or more model calls. Mirrors the shape T3 Code uses so
/// numbers line up with its Usage page where the inputs are the same.
public struct TokenTotals: Codable, Hashable, Sendable {
    public var uncachedInput: Int
    public var cachedInput: Int
    public var cacheCreation: Int
    public var output: Int
    /// Subset of `output`; never added to the total again.
    public var reasoning: Int

    public init(uncachedInput: Int = 0, cachedInput: Int = 0, cacheCreation: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheCreation = cacheCreation
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = TokenTotals()

    public var total: Int { uncachedInput + cachedInput + cacheCreation + output }
    public var input: Int { uncachedInput + cachedInput + cacheCreation }
    public var isEmpty: Bool { total == 0 }

    public mutating func add(_ other: TokenTotals) {
        uncachedInput += other.uncachedInput
        cachedInput += other.cachedInput
        cacheCreation += other.cacheCreation
        output += other.output
        reasoning += other.reasoning
    }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        var out = lhs
        out.add(rhs)
        return out
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case grok
    case opencode

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok Build"
        case .opencode: return "OpenCode"
        }
    }

    /// The T3 Code driver kind that maps onto this provider.
    public var t3Driver: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claudeAgent"
        case .grok: return "grok"
        case .opencode: return "opencode"
        }
    }

    public static func from(t3Driver: String) -> ProviderKind? {
        allCases.first { $0.t3Driver == t3Driver }
    }
}

public enum PlanGroup: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case personal
    case work
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .personal: return "Personal"
        case .work: return "Work"
        case .other: return "Other"
        }
    }
}

/// One billable identity: a subscription or API account on one provider.
///
/// `id` doubles as the attribution key written into scan cells, so it has to be
/// derivable from the transcript alone (Codex plan type, Claude home dir).
public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var provider: ProviderKind
    public var displayName: String
    public var email: String?
    public var planLabel: String?
    public var organization: String?
    public var accentColorHex: String?
    public var suggestedGroup: PlanGroup
    /// Where the data came from, for the Sources panel.
    public var sourceDescription: String

    public init(id: String, provider: ProviderKind, displayName: String, email: String? = nil, planLabel: String? = nil, organization: String? = nil, accentColorHex: String? = nil, suggestedGroup: PlanGroup = .other, sourceDescription: String) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.email = email
        self.planLabel = planLabel
        self.organization = organization
        self.accentColorHex = accentColorHex
        self.suggestedGroup = suggestedGroup
        self.sourceDescription = sourceDescription
    }

    public static func codexId(planType: String) -> String { "codex:plan:\(planType)" }
    public static func claudeId(transcriptDir: String) -> String { "claude:home:\(transcriptDir)" }
    public static let grokDefaultId = "grok:default"
    public static let openCodeLocalId = "opencode:local"

    /// Placeholder for usage the scanner attributed to a key no configured
    /// account claims (for example a Codex plan type with no matching login).
    public static func placeholder(id: String) -> Account {
        let provider: ProviderKind
        let name: String
        if id.hasPrefix("codex:") {
            provider = .codex
            let plan = id.replacingOccurrences(of: "codex:plan:", with: "")
            name = plan == "unknown" ? "Codex (unattributed)" : "Codex (\(plan))"
        } else if id.hasPrefix("claude:") {
            provider = .claude
            name = "Claude Code (unattributed)"
        } else if id.hasPrefix("grok:") {
            provider = .grok
            name = "Grok Build"
        } else {
            provider = .opencode
            name = "OpenCode"
        }
        return Account(id: id, provider: provider, displayName: name, suggestedGroup: .other, sourceDescription: "Discovered from transcripts only")
    }
}

/// One usage event parsed from a provider transcript.
public struct UsageRecord: Hashable, Sendable {
    public var provider: ProviderKind
    public var timestampMs: Int64
    public var model: String
    public var sessionId: String
    public var totals: TokenTotals
    public var reportedCostUsd: Double?
    /// Cross-record de-duplication key, or nil when inherently unique.
    public var dedupeKey: String?
    /// Codex only: the subscription plan the event was billed to.
    public var planType: String?

    public init(provider: ProviderKind, timestampMs: Int64, model: String, sessionId: String, totals: TokenTotals, reportedCostUsd: Double? = nil, dedupeKey: String? = nil, planType: String? = nil) {
        self.provider = provider
        self.timestampMs = timestampMs
        self.model = model
        self.sessionId = sessionId
        self.totals = totals
        self.reportedCostUsd = reportedCostUsd
        self.dedupeKey = dedupeKey
        self.planType = planType
    }
}

public struct RateLimitWindow: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Int64

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Int64) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var resetDate: Date { Date(timeIntervalSince1970: TimeInterval(resetsAt)) }
    public var windowStart: Date { resetDate.addingTimeInterval(-TimeInterval(windowMinutes) * 60) }
}

/// Latest subscription-window reading Codex wrote into a transcript.
public struct RateLimitSnapshot: Codable, Hashable, Sendable {
    public var planType: String
    public var timestampMs: Int64
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public var hasCredits: Bool?
    public var unlimitedCredits: Bool?
    public var creditsBalance: String?

    public init(planType: String, timestampMs: Int64, primary: RateLimitWindow?, secondary: RateLimitWindow?, hasCredits: Bool?, unlimitedCredits: Bool?, creditsBalance: String?) {
        self.planType = planType
        self.timestampMs = timestampMs
        self.primary = primary
        self.secondary = secondary
        self.hasCredits = hasCredits
        self.unlimitedCredits = unlimitedCredits
        self.creditsBalance = creditsBalance
    }
}

/// Aggregation key: UTC hour, attribution key, model.
public struct CellKey: Hashable, Codable, Sendable {
    public var hourStartMs: Int64
    public var accountId: String
    public var model: String

    public init(hourStartMs: Int64, accountId: String, model: String) {
        self.hourStartMs = hourStartMs
        self.accountId = accountId
        self.model = model
    }

    public static func hourStart(forMs ms: Int64) -> Int64 {
        let hour: Int64 = 3_600_000
        return (ms / hour) * hour
    }
}

/// Pre-aggregated usage for one cell. Costs the provider reported are kept
/// separately from tokens that still need pricing so the two never mix.
public struct Cell: Codable, Hashable, Sendable {
    public var totals: TokenTotals
    public var unpricedTotals: TokenTotals
    public var reportedCostUsd: Double
    public var records: Int
    public var sessionIds: Set<String>

    public init(totals: TokenTotals = .zero, unpricedTotals: TokenTotals = .zero, reportedCostUsd: Double = 0, records: Int = 0, sessionIds: Set<String> = []) {
        self.totals = totals
        self.unpricedTotals = unpricedTotals
        self.reportedCostUsd = reportedCostUsd
        self.records = records
        self.sessionIds = sessionIds
    }

    public mutating func add(_ record: UsageRecord) {
        totals.add(record.totals)
        if let cost = record.reportedCostUsd, cost.isFinite {
            reportedCostUsd += cost
        } else {
            unpricedTotals.add(record.totals)
        }
        records += 1
        if !record.sessionId.isEmpty { sessionIds.insert(record.sessionId) }
    }

    public mutating func merge(_ other: Cell) {
        totals.add(other.totals)
        unpricedTotals.add(other.unpricedTotals)
        reportedCostUsd += other.reportedCostUsd
        records += other.records
        sessionIds.formUnion(other.sessionIds)
    }
}

public enum CostSource: String, Codable, Hashable, Sendable {
    case providerReported
    case modelPriced
    case mixed
    case unpriced
}

public enum SourceStatus: String, Codable, Hashable, Sendable {
    case ok
    case missing
    case partial
    case failed
}

public struct SourceReport: Identifiable, Hashable, Sendable {
    public var id: String { "\(provider.rawValue):\(path)" }
    public var provider: ProviderKind
    public var path: String
    public var status: SourceStatus
    public var scannedFiles: Int
    public var reusedFiles: Int
    public var skippedFiles: Int
    public var message: String?

    public init(provider: ProviderKind, path: String, status: SourceStatus, scannedFiles: Int, reusedFiles: Int, skippedFiles: Int, message: String? = nil) {
        self.provider = provider
        self.path = path
        self.status = status
        self.scannedFiles = scannedFiles
        self.reusedFiles = reusedFiles
        self.skippedFiles = skippedFiles
        self.message = message
    }
}
