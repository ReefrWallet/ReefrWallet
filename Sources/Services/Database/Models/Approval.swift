//
//  Approval.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import SwiftData
import WalletKit

// MARK: - TokenApproval

/// An active ERC-20 allowance an account has granted to a spender.
struct TokenApproval: Equatable, Hashable, Identifiable, Sendable {
    /// At or above this, an allowance is shown as "Unlimited" (2^255).
    static let unlimitedThreshold = BigUInt(1) << 255

    let allowance: BigUInt
    let approvedAt: Date?
    let id: PersistentIdentifier
    let spender: String
    let token: Token

    var isUnlimited: Bool {
        allowance >= Self.unlimitedThreshold
    }
}

// MARK: - ApprovalUpdate

struct ApprovalUpdate: Sendable {
    let allowance: BigUInt
    let approvedAt: Date?
    let spender: String
    let token: Token
}

// MARK: - ApprovalCandidate

/// A (token, spender) pair found by a scan, to be confirmed against its live allowance.
struct ApprovalCandidate: Sendable {
    let approvedAt: Date?
    let spender: String
    let token: String
}

// MARK: - ApprovalModel

@Model
final class ApprovalModel: Identifiable {
    var approvedAt: Date?
    var serializedAllowance: Data
    var spender: String

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    @Relationship
    var token: TokenModel

    init(account: AccountModel, allowance: BigUInt, approvedAt: Date?, spender: String, token: TokenModel) {
        self.account = account
        self.approvedAt = approvedAt
        self.serializedAllowance = allowance.serialize()
        self.spender = spender
        self.token = token
    }
}

extension ApprovalModel {
    var allowance: BigUInt {
        get { BigUInt(serializedAllowance) }

        set { serializedAllowance = newValue.serialize() }
    }
}

extension TokenApproval {
    init(model: ApprovalModel) {
        allowance = model.allowance
        approvedAt = model.approvedAt
        id = model.persistentModelID
        spender = model.spender
        token = Token(model: model.token)
    }
}

// MARK: - ApprovalScanState

/// How far an account's approval log scan has got, keyed by ``ApprovalScanState/allTokensKey``
/// (one Etherscan scan covers every token).
struct ApprovalScanState: Equatable, Sendable {
    static let allTokensKey = "*"

    /// Newest block (EVM) or block timestamp in ms (Tron) scanned; `nil` before the first scan.
    var block: UInt64?
}

// MARK: - ApprovalScanModel

@Model
final class ApprovalScanModel {
    var scannedBlock: Int64?
    var tokenAddress: String

    @Relationship(deleteRule: .noAction)
    var account: AccountModel

    init(account: AccountModel, state: ApprovalScanState, tokenAddress: String) {
        self.account = account
        self.scannedBlock = state.block.map(Int64.init)
        self.tokenAddress = tokenAddress
    }
}

// MARK: - Blockchain

extension Blockchain {
    /// Chains with a token-approval (allowance) model: EVM and Tron.
    var supportsApprovals: Bool {
        switch self {
        case .evm, .tron:
            true
        default:
            false
        }
    }
}
