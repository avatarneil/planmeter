import Foundation
import PlanMeterCore

// planmeter-cli [--days N] [--json]
// Prints the same numbers the app shows for scripting and diagnostics.

var days = 30
var json = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--days": days = Int(args.next() ?? "") ?? days
    case "--json": json = true
    case "-h", "--help":
        print("usage: planmeter-cli [--days N] [--json]")
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
}

func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
func tokens(_ v: Int) -> String {
    let d = Double(v)
    if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
    return "\(v)"
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    let settings = T3Settings.load()
    let discovery = AccountDiscovery.discover(settings: settings)
    let rates = PricingLoader.loadCached() ?? RateTable()
    let cache = ScanCache()
    await cache.load()

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let to = calendar.date(byAdding: .day, value: 1, to: today)!
    let from = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
    let sinceMs = Int64(from.timeIntervalSince1970 * 1000) - 86_400_000

    let started = Date()
    let output = await Scanner.scan(sources: discovery.sources, openCodeDatabase: discovery.openCodeDatabase, sinceMs: sinceMs, cache: cache)
    let buckets = Aggregation.buckets(cells: output.cells, rates: rates, from: from, to: to, resolution: .day, calendar: calendar)
    let elapsed = Date().timeIntervalSince(started)

    var accounts = discovery.accounts
    let known = Set(accounts.map(\.id))
    for id in Set(output.cells.keys.map(\.accountId)).subtracting(known).sorted() { accounts.append(Account.placeholder(id: id)) }
    let byAccount = Aggregation.byAccount(buckets)

    if json {
        var out: [String: Any] = [:]
        out["days"] = days
        out["accounts"] = accounts.map { a -> [String: Any] in
            let agg = byAccount[a.id] ?? Aggregate()
            return [
                "id": a.id, "name": a.displayName, "provider": a.provider.rawValue, "email": a.email ?? "",
                "plan": a.planLabel ?? "", "group": a.suggestedGroup.rawValue, "accent": a.accentColorHex ?? "",
                "costUsd": agg.costUsd, "tokens": agg.totals.total, "sessions": agg.sessions, "cacheSavingsUsd": agg.cacheSavingsUsd,
            ]
        }
        out["sources"] = output.sources.map { ["provider": $0.provider.rawValue, "path": $0.path, "status": $0.status.rawValue, "parsed": $0.scannedFiles, "cached": $0.reusedFiles, "message": $0.message ?? ""] }
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("PlanMeter · last \(days) days · pricing: \(rates.knownModels) models from \(rates.source)")
        print("scan: \(String(format: "%.1fs", elapsed)), \(output.cells.count) cells")
        print("")
        for group in PlanGroup.allCases {
            let members = accounts.filter { $0.suggestedGroup == group }
            if members.isEmpty { continue }
            var agg = Aggregate()
            for b in buckets where members.contains(where: { $0.id == b.accountId }) { agg.add(b) }
            print("\(group.displayName.uppercased())  \(usd(agg.costUsd))  \(tokens(agg.totals.total)) tokens  \(agg.sessions) sessions")
            for a in members {
                let x = byAccount[a.id] ?? Aggregate()
                let who = [a.email, a.planLabel].compactMap { $0 }.joined(separator: ", ")
                print(String(format: "  %-28@ %-14@ %10@  %8@ tok  %4d sess   %@", a.displayName as NSString, a.provider.displayName as NSString, usd(x.costUsd) as NSString, tokens(x.totals.total) as NSString, x.sessions, who as NSString))
            }
            print("")
        }
        print("MODELS")
        for (model, agg) in Aggregation.byModel(buckets).sorted(by: { $0.value.costUsd > $1.value.costUsd || ($0.value.costUsd == $1.value.costUsd && $0.value.totals.total > $1.value.totals.total) }) {
            let priced = rates.lookup(model) == nil ? "  (unpriced)" : ""
            print(String(format: "  %-40@ %10@  %8@ tok%@", model as NSString, usd(agg.costUsd) as NSString, tokens(agg.totals.total) as NSString, priced as NSString))
        }
        print("")
        print("SOURCES")
        for s in output.sources {
            print("  [\(s.status.rawValue)] \(s.provider.displayName): \(s.path)  parsed=\(s.scannedFiles) cached=\(s.reusedFiles) \(s.message ?? "")")
        }
        for u in discovery.unsupported { print("  [skip] \(u.displayName) (\(u.driver)): \(u.reason)") }
        for n in discovery.notes { print("  note: \(n)") }
        if !output.rateLimits.isEmpty {
            print("")
            print("CODEX LIMITS")
            for (plan, s) in output.rateLimits.sorted(by: { $0.key < $1.key }) {
                let p = s.primary.map { "primary \(Int($0.usedPercent))% of \($0.windowMinutes)m resets \(Date(timeIntervalSince1970: TimeInterval($0.resetsAt)).formatted())" } ?? "primary: none"
                let sec = s.secondary.map { "secondary \(Int($0.usedPercent))% of \($0.windowMinutes)m" } ?? ""
                print("  \(plan): \(p) \(sec) credits=\(s.hasCredits.map(String.init) ?? "?")")
            }
        }
    }
    semaphore.signal()
}
semaphore.wait()
