import XCTest
@testable import PlanMeterHost

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String, complete: Bool = false) -> HTTPRequestParser.Outcome {
        HTTPRequestParser.parse(Data(text.utf8), isComplete: complete, remoteHost: "100.64.0.9")
    }

    func testParsesRequestLineHeadersAndBody() throws {
        guard case .request(let request) = parse("POST /v1/rpc?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\nX-Forwarded-For:  100.64.0.2 \r\n\r\nbody") else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/rpc")
        XCTAssertEqual(request.headers["content-length"], "4")
        XCTAssertEqual(request.headers["x-forwarded-for"], "100.64.0.2")
        XCTAssertEqual(request.body, Data("body".utf8))
        XCTAssertEqual(request.remoteHost, "100.64.0.9")
    }

    func testWaitsForHeadersAndBody() {
        guard case .incomplete = parse("GET / HTTP/1.1\r\nHost: a\r\n") else { return XCTFail("headers incomplete") }
        guard case .incomplete = parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") else { return XCTFail("body incomplete") }
    }

    func testPeerClosingEarly() {
        guard case .close = parse("GET / HTTP/1.1\r\n", complete: true) else { return XCTFail("closed before headers") }
        guard case .failure(400, "truncated body") = parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc", complete: true) else {
            return XCTFail("closed mid-body")
        }
    }

    func testHeaderLimit() {
        let big = String(repeating: "a", count: HTTPLimits.maxHeaderBytes + 1)
        guard case .failure(431, _) = parse("GET / HTTP/1.1\r\nX: \(big)") else { return XCTFail("unterminated oversized headers") }
        // Oversized headers that arrive complete in one read are refused too.
        guard case .failure(431, _) = parse("GET / HTTP/1.1\r\nX: \(big)\r\n\r\n") else { return XCTFail("terminated oversized headers") }
        let fits = String(repeating: "a", count: HTTPLimits.maxHeaderBytes - 100)
        guard case .request = parse("GET / HTTP/1.1\r\nX: \(fits)\r\n\r\n") else { return XCTFail("headers within the limit") }
    }

    func testBodyLimitAndInvalidLengths() {
        guard case .failure(413, "body too large") = parse("POST / HTTP/1.1\r\nContent-Length: \(HTTPLimits.maxBodyBytes + 1)\r\n\r\n") else {
            return XCTFail("oversized body")
        }
        guard case .failure(400, _) = parse("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\nabc") else { return XCTFail("negative length") }
        // An unparseable length reads as no body, as before.
        guard case .request(let request) = parse("POST / HTTP/1.1\r\nContent-Length: lots\r\n\r\n") else { return XCTFail("bad length") }
        XCTAssertTrue(request.body.isEmpty)
    }

    func testMalformedRequestLine() {
        guard case .failure(400, "bad request") = parse("GARBAGE\r\n\r\n") else { return XCTFail("one-word request line") }
        let invalid = Data([0x47, 0x45, 0x54, 0x20, 0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])
        guard case .failure(400, _) = HTTPRequestParser.parse(invalid, isComplete: false, remoteHost: "x") else { return XCTFail("non-UTF-8 head") }
    }

    func testResponseFraming() {
        let response = HTTPResponse(status: 403, body: Data("{}".utf8), headers: ["X-B": "2", "X-A": "1"])
        let text = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertEqual(text, "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 2\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-A: 1\r\nX-B: 2\r\nConnection: close\r\n\r\n{}")
        XCTAssertEqual(String(decoding: HTTPResponse.error(404, "not found").body, as: UTF8.self), "{\"error\":\"not found\"}")
    }
}
