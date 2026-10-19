import XCTest
import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeterHost

@MainActor
final class HostEngineTests: XCTestCase {
    /// Counts scans and can hold one open, to test refresh coalescing.
    final class ScanGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func hit() { lock.lock(); _count += 1; lock.unlock() }
    }

    private func engine(gate: ScanGate, delay: UInt64 = 0, cells: [CellKey: Cell] = [:]) throws -> (HostEngine, URL) {
        let dir = try makeTemporaryDirectory()
        let account = Account(id: "codex:plan:pro", provider: .codex, displayName: "Codex Pro", suggestedGroup: .personal, sourceDescription: "test")
        var loader = HostEngine.Loader.fixed(discovery: Discovery(accounts: [account]), scan: ScanOutput(cells: cells, scannedAt: Date()), rates: RateTable(source: "cached"))
        loader.scan = { _, _, _ in
            gate.hit()
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return ScanOutput(cells: cells, scannedAt: Date())
        }
        let engine = HostEngine(serverName: "box", scanCache: dir.appendingPathComponent("scan-cache.json"), loader: loader)
        // Usage sits in the half hour before this instant: "today" in every
        // whole-hour time zone.
        engine.clock = { ControlHarness.now }
        return (engine, dir)
    }

    private var nowMs: Int64 { Int64(ControlHarness.now.timeIntervalSince1970 * 1000) }

    func testRefreshPopulatesStateAndPlaceholders() async throws {
        let gate = ScanGate()
        let now = nowMs
        let (engine, dir) = try engine(gate: gate, cells: [
            CellKey(startMs: now - 60_000, accountId: "codex:plan:pro", model: "m"): Cell(reportedCostUsd: 2),
            CellKey(startMs: now - 120_000, accountId: "codex:plan:unknown", model: "m"): Cell(reportedCostUsd: 1),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(engine.lastScan)
        await engine.refresh()
        XCTAssertEqual(gate.count, 1)
        XCTAssertNotNil(engine.lastScan)
        XCTAssertEqual(engine.accounts.map(\.id), ["codex:plan:pro", "codex:plan:unknown"])
        XCTAssertEqual(engine.account(for: "codex:plan:unknown").displayName, "Codex (unattributed)")
        XCTAssertEqual(engine.todayTotal.costUsd, 3, accuracy: 1e-9)
        engine.groupOverrides = ["codex:plan:pro": .work]
        XCTAssertEqual(engine.group(for: engine.account(for: "codex:plan:pro")), .work)
        XCTAssertEqual(engine.hourCells.values.reduce(0) { $0 + $1.reportedCostUsd }, 3, accuracy: 1e-9)
    }

    func testConcurrentRefreshesShareOneScan() async throws {
        let gate = ScanGate()
        let (engine, dir) = try engine(gate: gate, delay: 200_000_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        async let a: Void = engine.refresh()
        async let b: Void = engine.refresh()
        async let c: Void = engine.refresh()
        _ = await (a, b, c)
        XCTAssertEqual(gate.count, 1)
        XCTAssertFalse(engine.isScanning)
        // Forcing account-wide readings runs one more pass after the current one.
        async let d: Void = engine.refresh()
        async let e: Void = engine.refresh(forceAccountUsage: true)
        _ = await (d, e)
        XCTAssertEqual(gate.count, 3)
    }

    func testRepliesWaitForTheFirstScan() async throws {
        let gate = ScanGate()
        let now = nowMs
        let (engine, dir) = try engine(gate: gate, delay: 100_000_000, cells: [CellKey(startMs: now - 60_000, accountId: "codex:plan:pro", model: "m"): Cell(reportedCostUsd: 4)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Task { await engine.start() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let reply = await engine.reply(for: RemoteRequest(method: .summary, minutes: 60))
        XCTAssertEqual(reply.summary?.total.costUsd, 4)
        await start.value
        await engine.stop()
        XCTAssertEqual(gate.count, 1)
    }

    func testOfflinePricingNeverRetries() async throws {
        let gate = ScanGate()
        let (engine, dir) = try engine(gate: gate)
        defer { try? FileManager.default.removeItem(at: dir) }
        await engine.refreshPricing()
        XCTAssertNil(engine.pricingError)
    }
}
