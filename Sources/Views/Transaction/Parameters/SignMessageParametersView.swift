//
//  SignMessageParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// The Sign Message parameters shared by every chain: From, then the message.
struct SignMessageParametersView: View {
    let account: Account
    let message: String

    /// A raw message as UTF-8 text, or hex if the bytes aren't valid UTF-8.
    init(account: Account, message: Data) {
        self.account = account
        self.message = String(data: message, encoding: .utf8) ?? message.hexEncoded
    }

    init(account: Account, message: String) {
        self.account = account
        self.message = message
    }

    var body: some View {
        ParameterSection {
            FromRow(account: account)
        }

        ParameterBlock("Message", text: message)
    }
}
