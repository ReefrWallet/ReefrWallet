//
//  SettingsView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 12.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("MoralisAPIKey") private var moralisAPIKey: String = ""
    @AppStorage("ProxyHost") private var proxyHost: String = ""
    @AppStorage("ProxyPort") private var proxyPort: Int = 9090
    @AppStorage("UseProxy") private var useProxy: Bool = false

    var body: some View {
        Form {
            Section(header: Text("Proxy Settings")) {
                Toggle("Use Proxy", isOn: $useProxy)

                TextField("Proxy Hostname", text: $proxyHost)
                    .disabled(!useProxy)

                TextField("Proxy Port", value: $proxyPort, format: .number.grouping(.never))
                    .disabled(!useProxy)
            }

            Section(header: Text("API Keys")) {
                TextField("Moralis.io", text: $moralisAPIKey)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
