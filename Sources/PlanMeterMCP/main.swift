import Foundation
import PlanMeterCore

// planmeter-mcp: a stdio MCP server exposing PlanMeter's per-account usage.
//
// Speaks JSON-RPC 2.0, one message per line, and implements the MCP methods
// agents actually use: initialize, ping, tools/list, tools/call. Everything is
// read-only against the same transcripts and cache the app uses.

let serverVersion = "0.3.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
}

let daysProperty: [String: Any] = [
    "type": "integer", "minimum": 1, "maximum": 365, "default": 30,
    "description": "How many local calendar days to include, counting today.",
]

let tools: [Tool] = [
    Tool(
        name: "usage_summary",
        description: "Usage and API-equivalent cost split by plan group (personal, work, other) and by account, across Codex, Claude Code, Grok Build and OpenCode. Use this first for any 'how much have I spent / used' question.",
        schema: ["type": "object", "properties": ["days": daysProperty], "additionalProperties": false]
    ),
    Tool(
        name: "usage_by_model",
        description: "Per-model usage rows (account, model, cost, tokens, cache share, sessions), sorted by cost. Optionally filter to one account by id, name substring, or provider (codex, claude, grok, opencode).",
        schema: ["type": "object", "properties": ["days": daysProperty, "account": ["type": "string", "description": "Account id, display-name substring, or provider key to filter on."]], "additionalProperties": false]
    ),
    Tool(
        name: "usage_timeline",
        description: "Cost and tokens per period, with a per-account and per-group breakdown for each period. Daily by default; hourly is only sensible for 1-3 days.",
        schema: ["type": "object", "properties": ["days": daysProperty, "resolution": ["type": "string", "enum": ["day", "hour"], "default": "day"]], "additionalProperties": false]
    ),
    Tool(
        name: "codex_limits",
        description: "Latest Codex subscription rate-limit windows (weekly / 5-hour used percent and reset time) per Codex account, read from the most recent session each account ran.",
        schema: ["type": "object", "properties": [:], "additionalProperties": false]
    ),
    Tool(
        name: "accounts",
        description: "The accounts PlanMeter discovered from standard provider homes or optional T3 Code provider instances (email, plan, personal/work group), plus the transcript sources it scanned and their status.",
        schema: ["type": "object", "properties": [:], "additionalProperties": false]
    ),
]

// MARK: - IO

let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError
let ioLock = NSLock()

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
    ioLock.lock()
    stdout.write(data)
    stdout.write(Data([0x0A]))
    ioLock.unlock()
}

func log(_ text: String) {
    stderr.write(Data("planmeter-mcp: \(text)\n".utf8))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func textResult(_ payload: [String: Any], isError: Bool = false) -> [String: Any] {
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return [
        "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
        "structuredContent": payload,
        "isError": isError,
    ]
}

// MARK: - Tool execution

let cache = ScanCache()
var cacheLoaded = false

func intArg(_ args: [String: Any], _ key: String, default def: Int, range: ClosedRange<Int>) -> Int {
    let raw = (args[key] as? Int) ?? (args[key] as? Double).map(Int.init) ?? def
    return min(max(raw, range.lowerBound), range.upperBound)
}

func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
    if !cacheLoaded { await cache.load(); cacheLoaded = true }
    switch name {
    case "usage_summary":
        let days = intArg(arguments, "days", default: 30, range: 1...365)
        let ctx = await Report.load(days: days, cache: cache)
        return textResult(Report.summary(ctx, days: days))
    case "usage_by_model":
        let days = intArg(arguments, "days", default: 30, range: 1...365)
        let ctx = await Report.load(days: days, cache: cache)
        return textResult(Report.models(ctx, days: days, accountFilter: arguments["account"] as? String))
    case "usage_timeline":
        let days = intArg(arguments, "days", default: 30, range: 1...365)
        let resolution: Resolution = (arguments["resolution"] as? String) == "hour" ? .hour : .day
        let ctx = await Report.load(days: days, cache: cache)
        return textResult(Report.timeline(ctx, days: days, resolution: resolution))
    case "codex_limits":
        let ctx = await Report.load(days: 7, cache: cache)
        return textResult(Report.limits(ctx))
    case "accounts":
        let ctx = await Report.load(days: 7, cache: cache)
        return textResult(Report.accounts(ctx))
    default:
        return textResult(["error": "unknown tool \(name)"], isError: true)
    }
}

// MARK: - Dispatch

func handle(_ message: [String: Any]) async {
    let method = message["method"] as? String
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]

    guard let method else {
        // A response to a server-initiated request; we never send any.
        return
    }

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[1]
        guard let id else { return }
        reply(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "planmeter", "version": serverVersion],
            "instructions": "PlanMeter reports local AI coding-agent usage split by personal vs work subscription. Start with usage_summary; drill into usage_by_model or usage_timeline; codex_limits shows remaining Codex quota. Costs are API-equivalent estimates, not subscription charges.",
        ])
    case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
        return
    case "ping":
        if let id { reply(id: id, result: [:]) }
    case "tools/list":
        guard let id else { return }
        reply(id: id, result: ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
    case "tools/call":
        guard let id else { return }
        guard let name = params["name"] as? String else {
            replyError(id: id, code: -32602, message: "tools/call requires a name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard tools.contains(where: { $0.name == name }) else {
            replyError(id: id, code: -32602, message: "unknown tool \(name)")
            return
        }
        let result = await callTool(name: name, arguments: arguments)
        reply(id: id, result: result)
    case "resources/list":
        if let id { reply(id: id, result: ["resources": []]) }
    case "prompts/list":
        if let id { reply(id: id, result: ["prompts": []]) }
    default:
        if let id { replyError(id: id, code: -32601, message: "method not found: \(method)") }
    }
}

// MARK: - Main loop

let done = DispatchSemaphore(value: 0)
Task {
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        if let batch = parsed as? [[String: Any]] {
            for message in batch { await handle(message) }
        } else if let message = parsed as? [String: Any] {
            await handle(message)
        }
    }
    done.signal()
}
done.wait()
