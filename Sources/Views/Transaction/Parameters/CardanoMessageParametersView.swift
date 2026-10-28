//
//  CardanoMessageParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 27.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// A CIP-8 `signData` request: site and account, which key signs for the
/// address the dapp named, then the payload.
struct CardanoMessageParametersView: View {
    let account: Account
    let keyRole: CardanoKeyRole
    let message: Data
    let site: String

    var body: some View {
#if os(macOS)
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
        }

        ParameterSection {
            FromRow(account: account, title: String(localized: .commonAccount))
            signsWithRow
        }
#else
        ParameterSection {
            ParameterRow(String(localized: .commonSite), value: site)
            FromRow(account: account, title: String(localized: .commonAccount))
            signsWithRow
        }
#endif

        ParameterBlock(
            String(localized: .commonMessage),
            text: String(data: message, encoding: .utf8) ?? message.hexEncoded
        )
    }

    private var signsWithRow: some View {
        ParameterRow(String(localized: .commonSignsWith), value: Self.keyName(keyRole))
    }

    static func keyName(_ role: CardanoKeyRole) -> String {
        switch role {
        case .payment: String(localized: .cardanoMessageParametersPaymentKey)
        case .stake: String(localized: .cardanoMessageParametersStakeKey)
        }
    }
}
