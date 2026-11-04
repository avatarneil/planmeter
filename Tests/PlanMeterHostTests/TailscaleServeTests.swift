import XCTest
@testable import PlanMeterHost

final class TailscaleServeTests: XCTestCase {
    func testCertificateDomainSurvivesCLIWarning() {
        let result = TailscaleServe.run([
            "-c", "printf '%s' '{\"BackendState\":\"Running\",\"CertDomains\":[\"mac.example.ts.net\"]}'; printf '%s' 'Warning: client/server version mismatch' >&2",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.standardError, "Warning: client/server version mismatch")
        XCTAssertFalse(result.standardOutput.contains("Warning"))
        let status = TailscaleServe.certificateStatus(from: result)
        XCTAssertEqual(status.domain, "mac.example.ts.net")
        XCTAssertNil(status.message)
    }

    func testFailedCommandPreservesDiagnostic() {
        let result = TailscaleServe.run([
            "-c", "printf '%s' 'permission denied' >&2; exit 1",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertFalse(result.ok)
        let status = TailscaleServe.certificateStatus(from: result)
        XCTAssertNil(status.domain)
        XCTAssertEqual(status.message, "Could not read Tailscale status: permission denied")
    }

    /// A CLI that never exits (the macOS app binary can come up as a GUI
    /// app) must not hang the caller: app launch waited on this forever.
    func testHungCommandTimesOutAndIsStopped() {
        let start = Date()
        let result = TailscaleServe.run([
            "-c", "printf 'partial'; printf 'starting' >&2; exec sleep 30",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"), timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.standardOutput, "partial")
        XCTAssertTrue(result.standardError.hasPrefix("starting\n"), result.standardError)
        XCTAssertTrue(result.standardError.contains("did not finish within"), result.standardError)
    }

    func testCommandIgnoringTerminateIsKilled() {
        let start = Date()
        let result = TailscaleServe.run([
            "-c", "trap '' TERM; while :; do sleep 0.1; done",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"), timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(result.ok)
    }

    /// A descendant that inherits stdout keeps the pipe open after the child
    /// exits; the wait for end of file is bounded too.
    func testInheritedPipeDoesNotBlockPastTimeout() {
        let start = Date()
        let result = TailscaleServe.run([
            "-c", "sleep 5 & echo started",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"), timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.standardOutput, "started")
    }

    func testLargeOutputOnBothStreamsIsDrained() {
        let result = TailscaleServe.run([
            "-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b >&2",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertTrue(result.ok, result.standardError)
        XCTAssertEqual(result.standardOutput.count, 300_000)
        XCTAssertEqual(result.standardError.count, 300_000)
    }

    #if os(macOS)
    /// The Tailscale app's binary picks CLI or GUI behavior on its own; as a
    /// GUI it never exits. Every run forces CLI behavior.
    func testRunForcesCLIBehavior() {
        let result = TailscaleServe.run(["-c", "printf '%s' \"$TAILSCALE_BE_CLI:${HOME:+home}\""],
                                        executableURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.standardOutput, "true:home", "forced, and the rest of the environment is kept")
    }
    #endif

    func testMagicDNSNameFromStatus() {
        let named = #"{"BackendState":"Running","Self":{"DNSName":"mac.tail1234.ts.net."}}"#
        XCTAssertEqual(TailscaleInfo.magicDNSName(fromStatus: .init(ok: true, standardOutput: named)), .some("mac.tail1234.ts.net"))
        let unnamed = #"{"BackendState":"NeedsLogin","Self":{}}"#
        XCTAssertEqual(TailscaleInfo.magicDNSName(fromStatus: .init(ok: true, standardOutput: unnamed)), .some(nil))
        XCTAssertNil(TailscaleInfo.magicDNSName(fromStatus: .init(ok: false, standardError: "The Tailscale CLI did not finish within 10 seconds.")))
    }

    func testInvalidJSONIsNotReportedAsDisabledCertificates() {
        let status = TailscaleServe.certificateStatus(from: .init(ok: true, standardOutput: "not JSON"))
        XCTAssertNil(status.domain)
        XCTAssertEqual(status.message, "Could not read Tailscale status: invalid JSON response.")
    }

    func testDisconnectedStatusIsNotReportedAsDisabledCertificates() {
        for state in ["Stopped", "Starting", "NeedsLogin", "NeedsMachineAuth"] {
            let status = TailscaleServe.certificateStatus(from: .init(
                ok: true, standardOutput: "{\"BackendState\":\"\(state)\",\"CertDomains\":null}"
            ))
            XCTAssertNil(status.domain)
            XCTAssertEqual(status.message, "Tailscale is not connected (\(state)). Connect Tailscale and try again.")
        }
    }

    func testMissingCertificateDomainHasSpecificDiagnostic() {
        #if os(macOS)
        XCTAssertEqual(TailscaleServe.machineNoun, "this Mac", "the Mac app's wording is unchanged")
        #endif
        for domains in ["null", "[]", "[\"\"]"] {
            let status = TailscaleServe.certificateStatus(from: .init(
                ok: true, standardOutput: "{\"BackendState\":\"Running\",\"CertDomains\":\(domains)}"
            ))
            XCTAssertNil(status.domain)
            XCTAssertEqual(status.message, "Tailscale reports no HTTPS certificate domain for \(TailscaleServe.machineNoun). Check MagicDNS and HTTPS in the Tailscale admin console.")
        }
    }

    /// The listener binds what Tailscale reports for this node, not whatever
    /// interface happens to carry a 100.64.0.0/10 address.
    func testNodeAddressesComeFromTailscaleStatus() throws {
        let running = """
        {"BackendState":"Running","TailscaleIPs":["100.101.102.103"],
         "Self":{"DNSName":"devbox.tail1234.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::1234","100.101.102.103","10.0.0.4"]}}
        """
        let node = try XCTUnwrap(TailscaleInfo.node(fromStatus: .init(ok: true, standardOutput: running)))
        XCTAssertEqual(node.addresses, ["100.101.102.103", "fd7a:115c:a1e0::1234"], "IPv4 first, tailnet ranges only")
        XCTAssertEqual(node.dnsName, "devbox.tail1234.ts.net")

        let topLevelOnly = #"{"BackendState":"Running","TailscaleIPs":["100.64.0.9"],"Self":{}}"#
        XCTAssertEqual(TailscaleInfo.node(fromStatus: .init(ok: true, standardOutput: topLevelOnly))?.addresses, ["100.64.0.9"])

        let stopped = #"{"BackendState":"Stopped","Self":{"DNSName":"devbox.tail1234.ts.net.","TailscaleIPs":["100.101.102.103"]}}"#
        let down = try XCTUnwrap(TailscaleInfo.node(fromStatus: .init(ok: true, standardOutput: stopped)))
        XCTAssertEqual(down.addresses, [], "a stopped client has no usable address")
        XCTAssertEqual(down.dnsName, "devbox.tail1234.ts.net")

        XCTAssertNil(TailscaleInfo.node(fromStatus: .init(ok: false, standardError: "failed to connect to local tailscaled")))
        XCTAssertNil(TailscaleInfo.node(fromStatus: .init(ok: true, standardOutput: "{}")))
    }

    func testOnlyTailscaleInterfacesCount() {
        XCTAssertTrue(TailscaleInfo.isTailscaleInterface("tailscale0"))
        XCTAssertTrue(TailscaleInfo.isTailscaleInterface("utun4"))
        XCTAssertFalse(TailscaleInfo.isTailscaleInterface("eth0"))
        XCTAssertFalse(TailscaleInfo.isTailscaleInterface("en0"))
        XCTAssertFalse(TailscaleInfo.isTailscaleInterface("cni0"))
    }

    func testLargeDiagnosticsDoNotBlockStatusOutput() {
        let result = TailscaleServe.run([
            "-c", "head -c 262144 /dev/zero >&2; printf '%s' '{}'",
        ], executableURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.standardOutput, "{}")
        XCTAssertEqual(result.standardError.utf8.count, 262144)
    }
}
