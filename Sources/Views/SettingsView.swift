//
//  SettingsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 12.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("ProxyHost") private var proxyHost: String = ""
    @AppStorage("ProxyPort") private var proxyPort: Int = 9090
    @AppStorage("UseProxy") private var useProxy: Bool = false

    @AppStorage("EtherscanAPIKey") private var etherscanAPIKey: String = ""
    @AppStorage("BlockfrostMainnetProjectID") private var blockfrostMainnetProjectID: String = ""
    @AppStorage("BlockfrostPreprodProjectID") private var blockfrostPreprodProjectID: String = ""
    @AppStorage("TronGridAPIKey") private var tronGridAPIKey: String = ""

    var body: some View {
        Form {
            Section(header: Text("Transaction History")) {
                TextField("Etherscan API Key", text: $etherscanAPIKey)

                Text("Used for EVM history backfill. Falls back to Blockscout when empty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("TronGrid API Key", text: $tronGridAPIKey)

                Text("Used for TronGrid account data, history, and transaction requests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Blockfrost Mainnet Project ID", text: $blockfrostMainnetProjectID)
                TextField("Blockfrost Preprod Project ID", text: $blockfrostPreprodProjectID)

                Text("Used for Cardano account data, native assets, and transaction requests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Proxy Settings")) {
                Toggle("Use Proxy", isOn: $useProxy)

                TextField("Proxy Hostname", text: $proxyHost)
                    .disabled(!useProxy)

                TextField("Proxy Port", value: $proxyPort, format: .number.grouping(.never))
                    .disabled(!useProxy)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
