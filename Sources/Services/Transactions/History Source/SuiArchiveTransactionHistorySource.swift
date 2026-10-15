import WalletKit

struct SuiArchiveTransactionHistorySource: TransactionHistorySource {
    func supports(_ account: Account) -> Bool {
        supports(account.blockchain)
    }

    func supports(_ blockchain: Blockchain) -> Bool {
        archiveHost(for: blockchain) != nil
    }

    func transactionHistory(
        account: Account,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        guard let archiveHost = archiveHost(for: account.blockchain) else {
            throw URLError(.unsupportedURL)
        }

        let address = try SuiAddress(string: account.address)
        let client = SuiGRPCClient(host: archiveHost)
        return try await client.transactionHistory(address, request: request)
    }
}

private extension SuiArchiveTransactionHistorySource {
    func archiveHost(for blockchain: Blockchain) -> String? {
        guard case let .sui(network) = blockchain else {
            return nil
        }

        switch network {
        case .mainnet:
            return "archive.mainnet.sui.io"
        case .testnet:
            return "archive.testnet.sui.io"
        }
    }
}
