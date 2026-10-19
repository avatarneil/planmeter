import XCTest

extension XCTestCase {
    /// An instance of another suite, used only for its fixtures and never run
    /// (for example `AccountUsageTests.fixture().now`). swift-corelibs-xctest
    /// has no plain `init()`, only `init(name:testClosure:)`.
    static func fixture() -> Self {
        #if canImport(Darwin)
        return self.init()
        #else
        return self.init(name: "fixture", testClosure: { _ in })
        #endif
    }
}
