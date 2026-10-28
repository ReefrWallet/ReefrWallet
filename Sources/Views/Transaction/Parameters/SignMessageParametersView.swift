//
//  SignMessageParametersView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftUI

/// The Sign Message parameters shared by every chain: site and account, then the message.
struct SignMessageParametersView: View {
    let account: Account
    let message: String
    let site: String

    /// A raw message as UTF-8 text, or hex if the bytes aren't valid UTF-8.
    init(account: Account, message: Data, site: String) {
        self.account = account
        self.message = String(data: message, encoding: .utf8) ?? message.hexEncoded
        self.site = site
    }

    init(account: Account, message: String, site: String) {
        self.account = account
        self.message = message
        self.site = site
    }

    var body: some View {
        SignerSection(account: account, site: site)

        ParameterBlock(String(localized: .commonMessage), text: message)
    }
}
