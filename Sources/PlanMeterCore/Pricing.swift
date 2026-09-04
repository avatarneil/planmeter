import Foundation

/// USD per token for one model.
public struct ModelRate: Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheCreation: Double
}

/// Rate table built from LiteLLM's `model_prices_and_context_window.json`,
/// the same document T3 Code prices against. Lookup rules are ported so the
/// two agree on which models are priced and at what tier.
public struct RateTable: Sendable {
    public private(set) var rates: [String: ModelRate]
    public var source: String
    public var fetchedAt: Date?

    public init(rates: [String: ModelRate] = [:], source: String = "none", fetchedAt: Date? = nil) {
        self.rates = rates
        self.source = source
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { rates.isEmpty }
    public var knownModels: Int { rates.count }

    static let unpriceable: Set<String> = ["<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"]

    public static func from(liteLLMDocument doc: [String: Any], source: String, fetchedAt: Date?) -> RateTable {
        var table: [String: ModelRate] = [:]
        for (name, raw) in doc {
            guard name != "sample_spec", let entry = raw as? [String: Any] else { continue }
            guard let input = JSON.double(entry["input_cost_per_token"]), let output = JSON.double(entry["output_cost_per_token"]) else { continue }
            let key = normalizeKey(name)
            let rate = ModelRate(
                input: input,
                output: output,
                cacheRead: JSON.double(entry["cache_read_input_token_cost"]) ?? input,
                cacheCreation: JSON.double(entry["cache_creation_input_token_cost"]) ?? input
            )
            // First writer wins on exact duplicates after normalization.
            if table[key] == nil { table[key] = rate }
        }
        // Alias bare names ("gpt-5") only when every provider-prefixed entry
        // agrees on the rate; conflicting rates leave the bare name unpriced.
        var aliasCandidates: [String: ModelRate?] = [:]
        for (key, rate) in table {
            let alias = bareName(key)
            if alias.isEmpty || alias == key || table[alias] != nil { continue }
            if let held = aliasCandidates[alias] {
                if held != rate { aliasCandidates[alias] = .some(nil) }
            } else {
                aliasCandidates[alias] = rate
            }
        }
        for (alias, rate) in aliasCandidates {
            if let rate { table[alias] = rate }
        }
        return RateTable(rates: table, source: source, fetchedAt: fetchedAt)
    }

    static func normalizeKey(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func bareName(_ key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    /// Drops a bracketed variant such as `claude-fable-5-1[1m]`.
    static func stripVariant(_ key: String) -> String {
        guard let bracket = key.firstIndex(of: "[") else { return key }
        return String(key[..<bracket])
    }

    public func lookup(_ model: String) -> ModelRate? {
        let key = Self.stripVariant(Self.normalizeKey(model))
        let bare = Self.bareName(key)
        if bare.isEmpty || Self.unpriceable.contains(bare) { return nil }
        if let exact = rates[key] { return exact }
        // Transcripts may carry `provider/model` for a provider LiteLLM files
        // under a different prefix; fall back to the bare name alias.
        return rates[bare]
    }

    public func price(model: String, totals: TokenTotals) -> Double? {
        guard let rate = lookup(model) else { return nil }
        return Double(totals.uncachedInput) * rate.input
            + Double(totals.cachedInput) * rate.cacheRead
            + Double(totals.cacheCreation) * rate.cacheCreation
            + Double(totals.output) * rate.output
    }

    public func cacheSavings(model: String, totals: TokenTotals) -> Double {
        guard let rate = lookup(model) else { return 0 }
        return Double(totals.cachedInput) * (rate.input - rate.cacheRead)
    }
}

/// Loads pricing from T3 Code's cached copy when present, then from the app's
/// own cache, then from LiteLLM directly.
public enum PricingLoader {
    public static let liteLLMURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    public static func t3CachePath() -> String {
        T3Settings.defaultHome().appendingPathComponent("userdata/usage-model-rates.json").path
    }

    public static func appCachePath() -> String {
        AppPaths.supportDirectory().appendingPathComponent("model-rates.json").path
    }

    public static func loadCached() -> RateTable? {
        if let table = load(fromT3Cache: t3CachePath()) { return table }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appCachePath())), let doc = JSON.object(data) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: appCachePath())
            return RateTable.from(liteLLMDocument: doc, source: "PlanMeter cache", fetchedAt: attrs?[.modificationDate] as? Date)
        }
        return nil
    }

    static func load(fromT3Cache path: String) -> RateTable? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let root = JSON.object(data) else { return nil }
        guard let doc = JSON.object(root["document"]) else { return nil }
        let fetched = JSON.double(root["fetchedAtMs"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return RateTable.from(liteLLMDocument: doc, source: "T3 Code pricing cache", fetchedAt: fetched)
    }

    public static func fetch() async throws -> RateTable {
        let (data, _) = try await URLSession.shared.data(from: liteLLMURL)
        guard let doc = JSON.object(data) else { throw URLError(.cannotParseResponse) }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory(), withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: appCachePath()), options: .atomic)
        return RateTable.from(liteLLMDocument: doc, source: "LiteLLM", fetchedAt: Date())
    }
}

public enum AppPaths {
    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlanMeter", isDirectory: true)
    }
}
