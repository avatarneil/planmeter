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
        // Forcing account-wide readings runs one more pass after the current
        // one. Start the unforced pass first: `async let` children may start
        // in either order, and a forced pass that happens to go first
        // satisfies the unforced call by itself.
        let d = Task { await engine.refresh() }
        while gate.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        await engine.refresh(forceAccountUsage: true)
        await d.value
        XCTAssertEqual(gate.count, 3)
    }

    /// A forced refresh may find that someone else (the 30-second loop, an
    /// RPC) started the next pass first; joining it is only enough when it is
    /// forced too.
    func testForcedRefreshAlwaysGetsAForcedPass() async throws {
        final class Passes: @unchecked Sendable {
            private let lock = NSLock()
            private var _forced = 0
            var forced: Int { lock.lock(); defer { lock.unlock() }; return _forced }
            func record(_ force: Bool) { lock.lock(); if force { _forced += 1 }; lock.unlock() }
        }
        let gate = ScanGate()
        let passes = Passes()
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var loader = HostEngine.Loader.fixed(discovery: Discovery(), scan: ScanOutput(scannedAt: Date()), rates: RateTable(source: "cached"))
        loader.scan = { _, _, _ in
            gate.hit()
            try? await Task.sleep(nanoseconds: 5_000_000)
            return ScanOutput(scannedAt: Date())
        }
        loader.accountUsage = { _, force in passes.record(force); return [] }
        let engine = HostEngine(serverName: "box", scanCache: dir.appendingPathComponent("scan-cache.json"), loader: loader)
        // Unforced refreshes back to back, so one is usually starting the
        // moment the previous pass ends.
        let background = Task { @MainActor in
            while !Task.isCancelled { await engine.refresh() }
        }
        for round in 0..<10 {
            let before = passes.forced
            await engine.refresh(forceAccountUsage: true)
            XCTAssertGreaterThan(passes.forced, before, "round \(round)")
        }
        background.cancel()
        await background.value
    }

    func testPlanLimitsReachTheLimitsReply() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = Account(id: "claude:home:/h/.claude/projects", provider: .claude, displayName: "Claude Max", suggestedGroup: .personal, sourceDescription: "test")
        var discovery = Discovery(accounts: [claude])
        discovery.planLimitTargets = [PlanLimitTarget(accountId: claude.id, provider: .claude)]
        var loader = HostEngine.Loader.fixed(discovery: discovery, scan: ScanOutput(), rates: RateTable(source: "cached"))
        let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        loader.planLimits = { targets, _ in
            targets.map { target in
                var snapshot = PlanLimitSnapshot(target: target)
                snapshot.windows = [
                    PlanLimitWindow(id: "five_hour", label: "5-hour", usedPercent: 42, windowMinutes: 300, resetsAt: resetsAt),
                    PlanLimitWindow(id: "credits", label: "Credits", usedPercent: 10),
                ]
                snapshot.status = .ok
                snapshot.fetchedAt = resetsAt
                return snapshot
            }
        }
        let engine = HostEngine(serverName: "box", scanCache: dir.appendingPathComponent("scan-cache.json"), loader: loader)
        await engine.refresh()
        XCTAssertEqual(engine.planLimits[claude.id]?.windows.count, 2)
        let limits = await engine.reply(for: RemoteRequest(method: .limits)).limits
        let row = try XCTUnwrap(limits?.accounts.first { $0.id == claude.id })
        // Untimed quotas stay out of remote replies, as from the Mac.
        XCTAssertEqual(row.windows.map(\.label), ["5-hour"])
        XCTAssertEqual(row.asOf, resetsAt)
        XCTAssertEqual(row.note, "Quotas without a reset time aren't shown here.")
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
