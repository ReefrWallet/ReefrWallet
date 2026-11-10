import Foundation
import SwiftData

/// Coalesces requests for each account while its background refresh is running.
final class ApprovalRefreshQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<PersistentIdentifier> = []
    private var running: Set<PersistentIdentifier> = []

    func enqueue(_ account: Account, update: @escaping @Sendable (Account) async throws -> Void) {
        guard let id = account.id else {
            return
        }

        let shouldStart = lock.withLock {
            if running.insert(id).inserted {
                return true
            }

            pending.insert(id)
            return false
        }

        guard shouldStart else {
            return
        }

        Task {
            repeat {
                do {
                    try await update(account)
                } catch {
                    printError("\(account.name) approvals: \(error)")
                }
            } while lock.withLock({
                if pending.remove(id) != nil {
                    return true
                }

                running.remove(id)
                return false
            })
        }
    }
}
