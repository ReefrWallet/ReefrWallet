//
//  EthereumTypedDataParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// An `eth_signTypedData_v4` payload: site and account, the EIP-712 domain fields, then
/// the pretty-printed message.
struct EthereumTypedDataParametersView: View {
    let account: Account
    let site: String
    let summary: EthereumTypedDataSummary

    var body: some View {
        SignerSection(account: account, site: site)

        ParameterSection("Domain") {
            ForEach(domainRows, id: \.label) { row in
                ParameterRow(row.label, value: row.value)
            }

            // Not in Penpot: the primary type selects which struct is signed.
            ParameterRow("Primary type", value: summary.primaryType)
        }

        ParameterBlock("Message", text: Self.prettyPrinted(summary.messageJSON))

        // Not in Penpot: type definitions are part of the signed payload, as
        // they determine how each domain/message field is encoded.
        ParameterBlock("Types", text: Self.prettyPrinted(summary.typesJSON))
    }
}

// MARK: - Logic

extension EthereumTypedDataParametersView {
    struct Row {
        let label: String
        let value: String
    }

    /// The standard EIP-712 domain fields present in `domainJSON`, in spec order.
    var domainRows: [Row] {
        guard let domain = (try? summary.domainJSON.decoded() as JSONValue)?.objectValue else {
            return [Row(label: "Domain", value: summary.domainJSON)]
        }

        let fields = [
            ("name", "Name"),
            ("version", "Version"),
            ("chainId", "Chain ID"),
            ("verifyingContract", "Verifying Contract"),
            ("salt", "Salt")
        ]

        return fields.compactMap { key, label in
            domain[key].flatMap(Self.text).map { Row(label: label, value: $0) }
        }
    }

    static func prettyPrinted(_ json: String) -> String {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return json
        }

        return prettyString
    }

    /// `42161` rather than `42161.0` for integral numbers.
    static func text(_ value: JSONValue) -> String? {
        switch value {
        case let .bool(value):
            "\(value)"
        case let .number(value):
            value.rounded() == value && abs(value) < 1e15 ? "\(Int64(value))" : "\(value)"
        case let .string(value):
            value
        case .array, .null, .object:
            nil
        }
    }
}
