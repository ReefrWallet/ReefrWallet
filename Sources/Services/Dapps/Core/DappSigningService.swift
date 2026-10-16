//
//  DappSigningService.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKit

/// Signs a ``SignableMessage`` on behalf of a dapp request, reusing
/// ``TransactionService``'s account → ``Signer`` construction rather than
/// re-deriving keys or reconnecting hardware devices itself. Registered
/// in `InjectCore.registerCore`.
///
/// `@unchecked Sendable`: a DI-injected singleton whose only stored
/// property is set once at init, like every other service in `Sources/Services`
/// — none of them are `Sendable`-annotated, but they're all called from
/// concurrent contexts today. Needed here only because ``DappRequestContext``
/// (`Sendable`) stores one.
final class DappSigningService: @unchecked Sendable {
    private let transactionService: TransactionService

    /// Defaults to the global DI container; tests pass their own
    /// isolated `TransactionService` (mirroring that type's own
    /// `init(databaseService:)` override convention).
    init(transactionService: TransactionService? = nil) {
        self.transactionService = transactionService ?? DI.injectOrFail(TransactionService.self)
    }

    /// Signs `message` with `account`'s key.
    ///
    /// - Throws: ``DappError/unauthorized`` for a watch-only account, or
    ///   ``DappError/internalError(_:)`` if `account`'s signer doesn't
    ///   support message signing (no chain but Ethereum does yet) or
    ///   signing otherwise fails.
    func signMessage(_ message: SignableMessage, account: Account) async throws(DappError) -> Data {
        let signer: any Signer
        do {
            signer = try await transactionService.makeSigner(for: account)
        } catch ReefrError.notSupported {
            throw DappError.unauthorized
        } catch {
            throw DappError.internalError("\(error)")
        }

        guard let messageSigner = signer as? any MessageSigner else {
            throw DappError.internalError("this account's signer does not support message signing")
        }

        do {
            return try await messageSigner.sign(message: message)
        } catch {
            throw DappError.internalError("\(error)")
        }
    }
}
