import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    /// `data(for:)` on every platform. FoundationNetworking's async `data(for:)`
    /// can deadlock when the awaiting task is cancelled while the transfer
    /// completes, as when an `async let` sibling throws: its cancellation
    /// handler waits for the session's work queue while holding the task's
    /// status lock, and the completion, running on that queue, waits for the
    /// lock. The completion-handler API registers no cancellation handler; the
    /// request's timeout bounds the transfer instead.
    func portableData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(Darwin)
        return try await data(for: request)
        #else
        return try await withCheckedThrowingContinuation { continuation in
            dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
        #endif
    }
}
