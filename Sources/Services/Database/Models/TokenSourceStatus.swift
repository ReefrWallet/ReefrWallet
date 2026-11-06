import Foundation
import SwiftData

/// Which pipeline a source status belongs to.
enum TokenSourceKind: String, Sendable {
    case identity
    case metadata
    case price
}

/// How a source answered for a token.
enum TokenSourceOutcome: Sendable {
    /// The source asked and has no price right now; recorded, but the source is retried normally.
    case noQuote(String)
    /// The source answered for the token.
    case success(externalId: String?)
    /// The source failed in a way that says nothing about the token.
    case transient(String)
    /// The source asked and doesn't have the token; it is skipped for `TokenSourceStatus.unavailableRetryInterval`.
    case unavailable(String)
}

struct TokenSourceStatus: Hashable, Sendable {
    /// How long a source that couldn't serve a token is skipped for it.
    static let unavailableRetryInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maxErrorLength = 200

    var externalId: String?
    let kind: String
    var lastError: String?
    var lastErrorAt: Date?
    var lastSuccessAt: Date?
    let sourceId: String
    var unavailableAt: Date?

    /// Whether the source should be skipped for the token at `now`.
    func isSkipped(at now: Date) -> Bool {
        unavailableAt.map { now.timeIntervalSince($0) < Self.unavailableRetryInterval } ?? false
    }
}

@Model
final class TokenSourceStatusModel {
    #Unique<TokenSourceStatusModel>([\.kind, \.sourceId, \.token])

    var externalId: String?
    var kind: String
    var lastError: String?
    var lastErrorAt: Date?
    var lastSuccessAt: Date?
    var sourceId: String
    var unavailableAt: Date?

    @Relationship
    var token: TokenModel?

    init(kind: String, sourceId: String, token: TokenModel?) {
        self.kind = kind
        self.sourceId = sourceId
        self.token = token
    }
}

extension TokenSourceStatus {
    init(model: TokenSourceStatusModel) {
        externalId = model.externalId
        kind = model.kind
        lastError = model.lastError
        lastErrorAt = model.lastErrorAt
        lastSuccessAt = model.lastSuccessAt
        sourceId = model.sourceId
        unavailableAt = model.unavailableAt
    }
}

extension TokenSourceStatusModel {
    func apply(_ outcome: TokenSourceOutcome, at date: Date) {
        switch outcome {
        case let .noQuote(message), let .transient(message):
            lastError = Self.truncated(message)
            lastErrorAt = date
        case let .success(externalId):
            self.externalId = externalId ?? self.externalId
            lastSuccessAt = date
            unavailableAt = nil
        case let .unavailable(message):
            lastError = Self.truncated(message)
            lastErrorAt = date
            unavailableAt = date
        }
    }

    private static func truncated(_ message: String) -> String {
        String(message.prefix(TokenSourceStatus.maxErrorLength))
    }
}

extension TokenSourceOutcome {
    /// Classifies a source failure; rate limits and unknown errors are transient.
    init(error: any Swift.Error) {
        let message = error.localizedDescription

        switch error {
        case is NoQuote:
            self = .noQuote(message)
        case _ where error.isRateLimited:
            self = .transient(message)
        case _ where error.isSourceUnavailable:
            self = .unavailable(message)
        default:
            self = .transient(message)
        }
    }
}
