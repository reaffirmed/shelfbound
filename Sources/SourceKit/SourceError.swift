import Foundation

public enum SourceError: Error, LocalizedError, Equatable {
    case scriptFailed(String)
    case missingFunction(String)
    case callFailed(function: String, message: String)
    case timedOut(function: String)
    case domainNotAllowed(String)
    case badRequest(String)
    case badResult(function: String, message: String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case let .scriptFailed(m): "The source script failed to load: \(m)"
        case let .missingFunction(f): "The source doesn't implement \(f)."
        case let .callFailed(f, m): "\(f) failed: \(m)"
        case let .timedOut(f): "\(f) took too long."
        case let .domainNotAllowed(h): "The source tried to reach \(h), which it didn't declare."
        case let .badRequest(m): "Bad request from source: \(m)"
        case let .badResult(f, m): "\(f) returned data the app couldn't read: \(m)"
        case .unavailable: "The source runtime was shut down."
        }
    }
}
