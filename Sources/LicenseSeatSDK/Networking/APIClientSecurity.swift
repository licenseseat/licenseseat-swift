//
//  APIClientSecurity.swift
//  LicenseSeatSDK
//
//  Redirect rejection and safe diagnostic formatting.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Debug-log sanitizer for errors that can carry request URLs. Transport errors
/// are reduced to their code; absolute URLs in other descriptions are removed.
enum LogRedaction {
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(code: \(urlError.code.rawValue))"
        }
        return redactingURLs(from: String(describing: error))
    }

    static func redactingURLs(from text: String) -> String {
        text.replacingOccurrences(
            of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>)\]]+"#,
            with: "<redacted-url>",
            options: .regularExpression
        )
    }
}

/// SDK-owned sessions stream response chunks through this delegate so an
/// undeclared or chunked response cannot be accumulated beyond the acceptance
/// limit. The delegate also refuses redirects before credentials are replayed.
final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Transfer {
        var data = Data()
        var response: URLResponse?
        let maximumBytes: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    func data(
        for request: URLRequest,
        using session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let cancellation = RequestCancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                transfers[task.taskIdentifier] = Transfer(
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
                lock.unlock()
                cancellation.activate(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let identifier = dataTask.taskIdentifier
        var failedTransfer: Transfer?

        lock.lock()
        if var transfer = transfers[identifier] {
            let declaredLength = response.expectedContentLength
            if declaredLength > Int64(transfer.maximumBytes) {
                failedTransfer = transfers.removeValue(forKey: identifier)
            } else {
                transfer.response = response
                if declaredLength > 0 {
                    transfer.data.reserveCapacity(
                        min(Int(declaredLength), transfer.maximumBytes)
                    )
                }
                transfers[identifier] = transfer
            }
        }
        lock.unlock()

        guard let failedTransfer else {
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        failedTransfer.continuation.resume(throwing: responseTooLargeError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let identifier = dataTask.taskIdentifier
        var failedTransfer: Transfer?

        lock.lock()
        if var transfer = transfers[identifier] {
            if data.count > transfer.maximumBytes - transfer.data.count {
                failedTransfer = transfers.removeValue(forKey: identifier)
            } else {
                transfer.data.append(data)
                transfers[identifier] = transfer
            }
        }
        lock.unlock()

        if let failedTransfer {
            dataTask.cancel()
            failedTransfer.continuation.resume(throwing: responseTooLargeError())
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let transfer else { return }
        if let error {
            transfer.continuation.resume(throwing: error)
        } else if let response = transfer.response {
            transfer.continuation.resume(returning: (transfer.data, response))
        } else {
            transfer.continuation.resume(
                throwing: APIError.localFailure(
                    code: "invalid_response",
                    message: "Transfer completed without an HTTP response"
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    private func responseTooLargeError() -> APIError {
        APIError.localFailure(
            code: "response_too_large",
            message: "Response exceeds the supported size"
        )
    }
}

private final class RequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func activate(_ task: URLSessionTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
