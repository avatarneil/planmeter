import Foundation

public struct CodexThreadReference: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var parentThreadId: String?
    public var origin: String
    public var updatedAt: Double?
    public var kind: String?
}

public struct CodexThreadUsageGroup: Codable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var speed: String?
    public var estimatedUsageCreditsMicros: Int
    public var netNewInputTokens: Int?
    public var cachedInputTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    /// A standard token-rate valuation, separate from the service's billing estimate.
    public func tokenRateCost(rates: RateTable) -> Double? {
        guard let model, let cached = cachedInputTokens, let output = outputTokens else { return nil }
        let uncached = netNewInputTokens ?? inputTokens.flatMap { $0 >= cached ? $0 - cached : nil }
        guard let uncached else { return nil }
        return rates.price(model: model, totals: TokenTotals(uncachedInput: uncached, cachedInput: cached, output: output))
    }
}

public struct CodexServiceThreadUsage: Codable, Sendable, Identifiable {
    public var reference: CodexThreadReference
    public var id: String { reference.id }
    public var estimatedUsageCreditsMicros: Int
    public var estimatedUsageUsdMicros: Int?
    public var groups: [CodexThreadUsageGroup]
    public var scope: String = "lifetime"

    public var serviceCostUsd: Double? { estimatedUsageUsdMicros.map { Double($0) / 1_000_000 } }
    public var totalTokens: Int? {
        guard !groups.isEmpty else { return nil }
        var total = 0
        for group in groups {
            guard let tokens = group.totalTokens else { return nil }
            let sum = total.addingReportingOverflow(tokens)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
    public func tokenRateCost(rates: RateTable) -> Double? {
        guard !groups.isEmpty else { return nil }
        var total = 0.0
        for group in groups {
            guard let cost = group.tokenRateCost(rates: rates) else { return nil }
            total += cost
        }
        return total.isFinite ? total : nil
    }
}

/// The desktop cache is a partial inventory, scoped by the account that owns it.
/// It includes cloud dots and their spawned tasks, which have no local rollouts.
public enum CodexThreadUsage {
    public static func references(target: CodexUsageTarget, limit: Int = 100) -> [CodexThreadReference] {
        var refs: [String: CodexThreadReference] = [:]
        func add(_ ref: CodexThreadReference) {
            guard UUID(uuidString: ref.id) != nil else { return }
            if refs[ref.id] == nil { refs[ref.id] = ref }
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: target.home + "/.codex-global-state.json")),
           let root = JSON.object(data), let atoms = JSON.object(root["electron-persisted-atom-state"]) {
            let cache = JSON.object(atoms["cloud-aeon-sidebar-cache-v1"])
            let userId = CodexIdentity.read(homePath: target.home).userId
            let userMatches = userId == nil || JSON.string(cache?["userId"]) == userId
            if let cache, userMatches, JSON.string(cache["accountId"]) == target.serviceAccountId {
                var parents: [String: String] = [:]
                for attachment in cache["attachments"] as? [[String: Any]] ?? [] {
                    if let id = JSON.string(attachment["thread_id"]), let parent = JSON.string(attachment["parent_thread_id"]) {
                        parents[id] = parent
                    }
                }
                for thread in cache["threads"] as? [[String: Any]] ?? [] {
                    guard let id = JSON.string(thread["id"]) else { continue }
                    add(CodexThreadReference(id: id, title: JSON.string(thread["name"]) ?? JSON.string(thread["preview"]),
                        parentThreadId: JSON.string(thread["parentThreadId"]) ?? parents[id], origin: "cloud",
                        updatedAt: JSON.double(thread["updatedAt"]), kind: JSON.string(thread["threadSource"])))
                }
            }
            if userMatches, let byAccount = JSON.object(atoms["aeon-subtasks-by-account-v1"]),
               let tasks = JSON.object(byAccount[target.serviceAccountId]) {
                for (key, value) in tasks {
                    guard let pair = try? JSONSerialization.jsonObject(with: Data(key.utf8)) as? [String],
                          pair.count == 2, pair[0] == "durable" else { continue }
                    let parent = pair[1]
                    add(CodexThreadReference(id: parent, origin: "cloud", kind: "aeon"))
                    for child in value as? [String] ?? [] {
                        add(CodexThreadReference(id: child, parentThreadId: parent, origin: "cloud", kind: "aeon_child"))
                        if refs[child]?.parentThreadId == nil { refs[child]?.parentThreadId = parent }
                    }
                }
            }
        }
        // Modern local threads carry an exact service account ID. Older rows
        // without it are deliberately excluded from service billing lookups.
        ThreadCatalog.read(path: target.home + "/state_5.sqlite", sql: "SELECT id, title, creator_account_id, updated_at FROM threads") { columns in
            guard columns.count == 4, columns[2] == target.serviceAccountId,
                  let updated = Double(columns[3]), updated >= Date().timeIntervalSince1970 - 30 * 86_400 else { return }
            add(CodexThreadReference(id: columns[0], title: columns[1], origin: "local", updatedAt: updated))
        }
        return Array(refs.values.sorted {
            if $0.origin != $1.origin { return $0.origin == "cloud" }
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            return $0.id < $1.id
        }.prefix(max(0, limit)))
    }

    static func decode(_ result: [String: Any], reference: CodexThreadReference) throws -> CodexServiceThreadUsage? {
        guard let raw = result["threadUsage"], !(raw is NSNull) else { return nil }
        guard let value = JSON.object(raw), JSON.string(value["threadId"]) == reference.id,
              let groups = value["groups"] as? [[String: Any]] else { throw UsageError.unsupported }
        let credits = try count(value["estimatedUsageCreditsMicros"], required: true)!
        let usd = try count(value["estimatedUsageUsdMicros"])
        let decoded = try groups.map { group in
            let netNew = try count(group["netNewInputTokens"]), cached = try count(group["cachedInputTokens"])
            let input = try count(group["inputTokens"]), output = try count(group["outputTokens"]), total = try count(group["totalTokens"])
            if let input, let cached, cached > input { throw UsageError.unsupported }
            if let netNew, let cached, netNew.addingReportingOverflow(cached).overflow { throw UsageError.unsupported }
            if let input, let output, input.addingReportingOverflow(output).overflow { throw UsageError.unsupported }
            return CodexThreadUsageGroup(model: JSON.string(group["model"]), reasoningEffort: JSON.string(group["reasoningEffort"]),
                speed: JSON.string(group["speed"]), estimatedUsageCreditsMicros: try count(group["estimatedUsageCreditsMicros"], required: true)!,
                netNewInputTokens: netNew, cachedInputTokens: cached, inputTokens: input, outputTokens: output, totalTokens: total)
        }
        return CodexServiceThreadUsage(reference: reference, estimatedUsageCreditsMicros: credits, estimatedUsageUsdMicros: usd, groups: decoded)
    }

    private static func count(_ value: Any?, required: Bool = false) throws -> Int? {
        guard let value, !(value is NSNull) else {
            if required { throw UsageError.unsupported }
            return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { throw UsageError.unsupported }
        return number.intValue
    }
}
