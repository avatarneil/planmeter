import XCTest
import PlanMeterHost
import PlanMeterRemote
@testable import PlanMeter

@MainActor
final class RemoteStateTests: XCTestCase {
    /// Holds the first probe until the test releases it.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    /// A refresh that began before a restart (stop) must not overwrite the
    /// name and serve state a later refresh found.
    func testRefreshFromBeforeRestartIsDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planmeter-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SoftwareAgreementKey()
        let service = RemoteService(serverName: "test", serverKey: key, store: FileSecretStore(directory: directory), version: "test")
        let gate = Gate()
        let calls = Calls()
        let remote = RemoteState(serverName: "test", serverKey: key, serverKeyIsEnclave: false, service: service) { _, _ in
            if calls.next() == 1 {
                await gate.wait()
                return .init(dnsName: .some("old.tail1.ts.net"), domain: "old.tail1.ts.net", active: true, message: nil)
            }
            return .init(dnsName: .some("new.tail2.ts.net"), domain: "new.tail2.ts.net", active: false, message: nil)
        }

        let stale = Task { await remote.refreshHTTPSStatus(ensure: false) }
        while calls.count == 0 { await Task.yield() }
        remote.stop()
        await remote.refreshHTTPSStatus(ensure: false)
        await gate.open()
        await stale.value

        XCTAssertEqual(remote.magicDNSName, "new.tail2.ts.net")
        XCTAssertEqual(remote.httpsDomain, "new.tail2.ts.net")
        XCTAssertFalse(remote.httpsActive)
    }
}
