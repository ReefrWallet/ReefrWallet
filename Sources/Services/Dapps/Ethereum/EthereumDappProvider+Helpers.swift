import WalletKit

func hexQuantity(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

func parseQuantity(_ hex: String) -> BigUInt? {
    let trimmed = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
    return BigUInt(trimmed, radix: 16)
}

func decodeHexData(_ hex: String) -> Data? {
    let trimmed = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
    guard trimmed.count.isMultiple(of: 2) else {
        return nil
    }

    var data = Data(capacity: trimmed.count / 2)
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
        let next = trimmed.index(index, offsetBy: 2)
        guard let byte = UInt8(trimmed[index..<next], radix: 16) else {
            return nil
        }

        data.append(byte)
        index = next
    }

    return data
}

extension Data {
    var hexEncoded: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}

func jsonString(_ value: JSONValue) -> String {
    (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

extension EthereumDappProvider {
    /// The approved fees (the user's edits, if any) are final; nothing
    /// from the original request is applied on top of them.
    static func feeOverride(
        approval: DappApprovalResult, previewFees: Fees, gasLimit: BigUInt
    ) throws(DappError) -> BlockchainTransactionBuilderOptions {
        let finalFees: Fees
        switch approval {
        case .approved:
            finalFees = previewFees
        case let .approvedWithFees(editedFees):
            finalFees = editedFees
        case .rejected:
            throw .userRejected
        }

        guard
            let maxFee = finalFees.ethereumMaxFee.flatMap({ BigUInt($0) }),
            let maxPriorityFee = finalFees.ethereumMaxPriorityFee.flatMap({ BigUInt($0) })
        else {
            throw .internalError("approved fees are invalid")
        }

        return .ethereumFeeOverride(maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriorityFee, gasLimit: gasLimit)
    }
}
