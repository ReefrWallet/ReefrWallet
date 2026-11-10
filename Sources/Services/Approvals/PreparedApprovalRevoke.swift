import Foundation
import WalletKit

struct PreparedApprovalRevoke {
    enum Transaction {
        case ethereum(UnsignedEIP1559Transaction)
        case tron(TronRawTransaction)
    }

    let approval: TokenApproval
    let fees: Fees
    let transaction: Transaction
}

struct RevokeExpiredError: LocalizedError {
    var errorDescription: String? {
        String(localized: .approvalsRevokeExpired)
    }
}
