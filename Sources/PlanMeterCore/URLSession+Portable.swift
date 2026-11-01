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

    /// `portableData(for:)` that never follows a redirect, for requests that
    /// carry credentials: a bearer token must not reach another host.
    /// FoundationNetworking has no per-task delegates and skips the session
    /// delegate for completion-handler tasks, so off Apple platforms each
    /// request gets a one-off session whose delegate refuses redirects.
    func portableDataWithoutRedirects(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(Darwin)
        return try await data(for: request, delegate: RedirectRefusal.shared)
        #else
        let task = RedirectRefusingTask()
        let session = URLSession(configuration: configuration, delegate: task, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            task.continuation = continuation
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
        #endif
    }
}

#if canImport(Darwin)
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectRefusal()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#else
/// Collects one data task's reply. The session calls it serially on its
/// delegate queue, and resumes the continuation exactly once, on completion.
private final class RedirectRefusingTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    var body = Data()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (body, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
#endif
