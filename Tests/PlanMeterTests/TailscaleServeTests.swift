import XCTest
@testable import PlanMeter

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
        for domains in ["null", "[]", "[\"\"]"] {
            let status = TailscaleServe.certificateStatus(from: .init(
                ok: true, standardOutput: "{\"BackendState\":\"Running\",\"CertDomains\":\(domains)}"
            ))
            XCTAssertNil(status.domain)
            XCTAssertEqual(status.message, "Tailscale reports no HTTPS certificate domain for this Mac. Check MagicDNS and HTTPS in the Tailscale admin console.")
        }
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
