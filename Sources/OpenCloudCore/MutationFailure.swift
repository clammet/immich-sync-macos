import Foundation

/// Describes what is known about a failed change, without promising that the
/// server's earlier content survived an uncertain or partially completed request.
public enum MutationOutcome: String, Codable, Sendable {
    case notSent, rejected, interrupted, expired, uncertain, uploaded

    public var title: String {
        switch self {
        case .notSent: return "Change not sent"
        case .rejected: return "Change rejected"
        case .interrupted: return "Upload interrupted"
        case .expired: return "Upload session unavailable"
        case .uncertain: return "Server result uncertain"
        case .uploaded: return "Upload complete; changes pending"
        }
    }
    private var explanation: String {
        switch self {
        case .notSent: return "This attempt did not send a change to OpenCloud."
        case .rejected: return "OpenCloud rejected the request."
        case .interrupted: return "The upload was interrupted before completion was confirmed."
        case .expired: return "The upload session expired or is no longer available. Its completion could not be confirmed."
        case .uncertain: return "The change may have reached OpenCloud, but its final result could not be confirmed."
        case .uploaded: return "The file content was uploaded, but the remaining changes could not be confirmed."
        }
    }
    func message(detail: String, recoveryAvailable: Bool) -> String {
        explanation + " " + detail + (recoveryAvailable ? " Your pending edit is preserved in Recovery." : "")
    }
}

/// Serializable context for a pending operation, including after app restart.
public struct MutationIssue: Codable, Sendable {
    public let outcome: MutationOutcome
    public let message: String
    public let recoveryAvailable: Bool
}

/// Retain the original error so transport retries, authentication, cancellation
/// and File Provider error mapping keep their existing behavior.
public struct MutationFailure: Error, LocalizedError {
    public let outcome: MutationOutcome
    public let underlyingError: Error
    public let recoveryAvailable: Bool

    public init(outcome: MutationOutcome, underlyingError: Error, recoveryAvailable: Bool = false) {
        self.outcome = outcome; self.underlyingError = Self.cause(of: underlyingError); self.recoveryAvailable = recoveryAvailable
    }
    public var errorDescription: String? {
        let cancelled = underlyingError is CancellationError || (underlyingError as? URLError)?.code == .cancelled
        return outcome.message(detail: cancelled ? "The operation was cancelled." : underlyingError.localizedDescription,
                               recoveryAvailable: recoveryAvailable)
    }
    public var issue: MutationIssue {
        MutationIssue(outcome: outcome,message: localizedDescription,recoveryAvailable: recoveryAvailable)
    }
    public static func cause(of error: Error) -> Error {
        (error as? MutationFailure).map { cause(of: $0.underlyingError) } ?? error
    }
    static func wrapping(_ error: Error, outcome: MutationOutcome) -> MutationFailure {
        (error as? MutationFailure) ?? MutationFailure(outcome: outcome,underlyingError: error)
    }
    /// A definitive rejection describes this request, not the fate of any
    /// previous chunks or a different client's revision.
    static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        do { return try HTTPClient.validate(response) }
        catch {
            if let status = (response as? HTTPURLResponse)?.statusCode,
               (400..<500).contains(status), status != 408 {
                throw MutationFailure(outcome: .rejected,underlyingError: error)
            }
            throw error
        }
    }
}
