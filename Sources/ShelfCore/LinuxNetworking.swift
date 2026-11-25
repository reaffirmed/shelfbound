#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

// swift-corelibs-foundation has no async `data(for:)`. This only exists so the
// packages build and test on Linux; Apple platforms use the system method.
extension URLSession {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
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
    }
}
#endif
