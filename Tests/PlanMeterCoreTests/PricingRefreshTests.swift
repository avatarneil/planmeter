import Foundation
import XCTest
@testable import PlanMeterCore

final class PricingRefreshTests: XCTestCase {
    private let document = "{\"test-model\":{\"input_cost_per_token\":0.000001,\"output_cost_per_token\":0.000002}}"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNewestCacheWinsInEitherDirection() throws {
        let dir = try directory()
        let app = dir.appendingPathComponent("app.json")
        let t3 = dir.appendingPathComponent("t3.json")
        try Data(document.utf8).write(to: app)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: app.path)
        try Data("{\"fetchedAtMs\":1000000,\"document\":\(document)}".utf8).write(to: t3)
        XCTAssertEqual(PricingLoader.loadCached(t3Path: t3.path, appPath: app.path)?.source, "PlanMeter cache")
        try Data("{\"fetchedAtMs\":3000000,\"document\":\(document)}".utf8).write(to: t3)
        XCTAssertEqual(PricingLoader.loadCached(t3Path: t3.path, appPath: app.path)?.source, "T3 Code pricing cache")
    }

    func testEmptyOrUndatedT3CacheDoesNotHideUsableAppCache() throws {
        let dir = try directory()
        let app = dir.appendingPathComponent("app.json")
        let t3 = dir.appendingPathComponent("t3.json")
        try Data(document.utf8).write(to: app)
        for content in ["{\"document\":{}}", "{\"document\":\(document)}", "invalid"] {
            try Data(content.utf8).write(to: t3)
            XCTAssertEqual(PricingLoader.loadCached(t3Path: t3.path, appPath: app.path)?.source, "PlanMeter cache")
        }
    }

    func testBadDownloadsPreserveOfflineCache() async throws {
        let cache = try directory().appendingPathComponent("app.json")
        try Data(document.utf8).write(to: cache)
        for (status, body) in [(503, document), (200, "{}"), (200, "not json"), (200, "{\"bad\":{\"input_cost_per_token\":-1,\"output_cost_per_token\":1}}") ] {
            let session = session(status: status, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await PricingLoader.fetch(session: session, cacheURL: cache)
                XCTFail("Invalid pricing response was accepted")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: cache), Data(document.utf8))
        }
    }

    func testFreshDownloadReplacesCache() async throws {
        let cache = try directory().appendingPathComponent("app.json")
        let session = session(status: 200, body: document)
        defer { session.invalidateAndCancel() }
        let table = try await PricingLoader.fetch(session: session, cacheURL: cache)
        XCTAssertEqual(table.source, "LiteLLM")
        XCTAssertNotNil(table.lookup("test-model"))
        XCTAssertNotNil(table.fetchedAt)
        XCTAssertEqual(try Data(contentsOf: cache), Data(document.utf8))
    }

    private func session(status: Int, body: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PricingResponseStub.self]
        config.httpAdditionalHeaders = ["X-Test-Status": String(status), "X-Test-Body": body]
        return URLSession(configuration: config)
    }
}

private final class PricingResponseStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "500") ?? 500
        let body = request.value(forHTTPHeaderField: "X-Test-Body") ?? ""
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
