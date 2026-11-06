import SwiftData
import WalletKit

/// One source's answer for one token.
struct TokenSourceResult: Sendable {
    let outcome: TokenSourceOutcome
    let sourceId: String
    let token: Token
}

extension DatabaseService {
    /// Tokens that no identity source has confirmed yet and whose retry time has passed, never-tried
    /// and oldest first. Covers every non-native token on a chain with an account.
    func fetchTokensDueForIdentity(now: Date, limit: Int) throws -> [Token] {
        let blockchains = try accountBlockchains()

        return try modelContext.fetch(FetchDescriptor<TokenModel>())
            .filter { model in
                guard !model.isNativeToken,
                      model.isWhitelisted != true,
                      let serialized = model.blockchain?.serialized,
                      blockchains.contains(serialized)
                else {
                    return false
                }

                return model.identityRetryAt.map { $0 <= now } ?? true
            }
            .sorted { ($0.identityRetryAt ?? .distantPast) < ($1.identityRetryAt ?? .distantPast) }
            .prefix(limit)
            .map(Token.init(model:))
    }

    /// Identified tokens without an image whose retry time has passed, never-tried and oldest first.
    func fetchTokensDueForMetadata(now: Date, limit: Int) throws -> [Token] {
        let blockchains = try accountBlockchains()

        return try modelContext.fetch(FetchDescriptor<TokenModel>())
            .filter { model in
                guard !model.isNativeToken,
                      model.isWhitelisted == true,
                      model.imageURL == nil,
                      let serialized = model.blockchain?.serialized,
                      blockchains.contains(serialized)
                else {
                    return false
                }

                return model.metadataRetryAt.map { $0 <= now } ?? true
            }
            .sorted { ($0.metadataRetryAt ?? .distantPast) < ($1.metadataRetryAt ?? .distantPast) }
            .prefix(limit)
            .map(Token.init(model:))
    }

    /// Statuses of `kind` for each token, aligned with `tokens`; empty for tokens not stored.
    func fetchTokenSourceStatuses(kind: TokenSourceKind, for tokens: [Token]) throws -> [[TokenSourceStatus]] {
        try tokens.map { token in
            guard let model = try existingTokenModel(for: token) else {
                return []
            }

            return (model.sourceStatuses ?? [])
                .filter { $0.kind == kind.rawValue }
                .map(TokenSourceStatus.init(model:))
        }
    }

    /// Stamps `token` as identified: whitelists it and makes its price due at once, undoing any
    /// earlier failure or skip of the pass that ran before it could be priced.
    func markTokenIdentified(_ token: Token, coinGeckoId: String?) throws {
        guard let model = try existingTokenModel(for: token) else {
            return
        }

        model.coinGeckoId = coinGeckoId ?? model.coinGeckoId
        model.hasPriceFetchError = false
        model.identityRetryAt = nil
        model.isWhitelisted = true
        model.priceUpdatedAt = nil

        for status in model.sourceStatuses ?? [] where status.kind == TokenSourceKind.price.rawValue {
            status.unavailableAt = nil
        }

        try modelContext.save()
    }

    /// Schedules the next identification attempt for a token no source identified.
    func setTokenIdentityRetry(_ token: Token, at date: Date) throws {
        guard let model = try existingTokenModel(for: token) else {
            return
        }

        model.identityRetryAt = date
        try modelContext.save()
    }

    /// Stores the token's image, or schedules the next lookup when `imageURL` is `nil`.
    func setTokenMetadata(_ token: Token, imageURL: URL?, retryAt: Date?) throws {
        guard let model = try existingTokenModel(for: token) else {
            return
        }

        if let imageURL {
            model.imageURL = imageURL
            model.metadataRetryAt = nil
        } else {
            model.metadataRetryAt = retryAt
        }

        try modelContext.save()
    }

    /// Makes every unidentified token due for identification now, and forgets that sources lacked
    /// it, since the sources' data changed.
    func resetTokenIdentityRetries() throws {
        for model in try modelContext.fetch(FetchDescriptor<TokenModel>()) {
            model.identityRetryAt = nil

            for status in model.sourceStatuses ?? [] where status.kind == TokenSourceKind.identity.rawValue {
                status.unavailableAt = nil
            }
        }

        try modelContext.save()
    }

    /// Applies `results` to the tokens' `kind` statuses in one save. Tokens that aren't stored are ignored.
    func recordTokenSourceResults(kind: TokenSourceKind, _ results: [TokenSourceResult], at date: Date) throws {
        for result in results {
            guard let model = try existingTokenModel(for: result.token) else {
                continue
            }

            let existing = (model.sourceStatuses ?? []).first {
                $0.kind == kind.rawValue && $0.sourceId == result.sourceId
            }

            let status = existing
                ?? TokenSourceStatusModel(kind: kind.rawValue, sourceId: result.sourceId, token: model)

            if existing == nil {
                modelContext.insert(status)
            }

            status.apply(result.outcome, at: date)
        }

        try modelContext.save()
    }
}

private extension DatabaseService {
    func accountBlockchains() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<AccountModel>()).map(\.blockchain.serialized))
    }

    /// `nil` when the token isn't stored.
    func existingTokenModel(for token: Token) throws -> TokenModel? {
        do {
            return try tokenModel(for: token)
        } catch ReefrError.notFound, ReefrError.invalidData {
            return nil
        }
    }
}
