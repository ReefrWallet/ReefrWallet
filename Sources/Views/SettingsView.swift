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

    @AppStorage("AptosAPIKey") private var aptosAPIKey: String = ""
    @AppStorage("EtherscanAPIKey") private var etherscanAPIKey: String = ""
    @AppStorage("BlockfrostMainnetProjectID") private var blockfrostMainnetProjectId: String = ""
    @AppStorage("BlockfrostPreprodProjectID") private var blockfrostPreprodProjectId: String = ""
    @AppStorage("CoinGeckoAPIKey") private var coinGeckoAPIKey: String = ""
    @AppStorage("TronGridAPIKey") private var tronGridAPIKey: String = ""

    @AppStorage(PreferredBrowser.bundleIdKey) private var preferredBrowserBundleId: String = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        form
            .phoneSheet(.commonSettings, cancelTitle: .commonDone, onCancel: { dismiss() })
    }

    private var form: some View {
        Form {
            #if os(macOS)
            Section(header: Text(.settingsDapps)) {
                Picker(.settingsOpenDappsIn, selection: $preferredBrowserBundleId) {
                    Text(.settingsSystemDefaultBrowser).tag("")

                    ForEach(PreferredBrowser.installedApps) { app in
                        Text(verbatim: app.name).tag(app.bundleId)
                    }
                }
                .accessibilityIdentifier("settings-preferred-browser-picker")
            }
            #endif

            Section(header: Text(.settingsTransactionHistory)) {
                optionalField(.settingsAptosLabsApiKey, text: $aptosAPIKey)

                Text(.settingsAptosKeyFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                optionalField(.settingsEtherscanApiKey, text: $etherscanAPIKey)

                Text(.settingsEtherscanKeyFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                optionalField(.settingsTrongridApiKey, text: $tronGridAPIKey)

                Text(.settingsTronGridKeyFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                optionalField(.settingsBlockfrostMainnetProjectId, text: $blockfrostMainnetProjectId)
                optionalField(.settingsBlockfrostPreprodProjectId, text: $blockfrostPreprodProjectId)

                Text(.settingsCardanoKeyFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text(.settingsMarketData)) {
                optionalField(.settingsCoingeckoDemoApiKey, text: $coinGeckoAPIKey)

                Text(.settingsCoinGeckoKeyFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text(.settingsProxySettings)) {
                Toggle(.settingsUseProxy, isOn: $useProxy)

                TextField(String(localized: .settingsProxyHostname), text: $proxyHost)
                    .disabled(!useProxy)

                TextField(.settingsProxyPort, value: $proxyPort, format: .number.grouping(.never))
                    .disabled(!useProxy)
            }
        }
        .formStyle(.grouped)
    }
}

private extension SettingsView {
    /// iPhone: label left, "Optional" value right; macOS keeps the plain field.
    @ViewBuilder
    func optionalField(_ title: LocalizedStringResource, text: Binding<String>) -> some View {
        if isIOS {
            LabeledContent {
                TextField("", text: text, prompt: Text(.settingsOptional))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } label: {
                Text(title)
            }
        } else {
            TextField(title.string, text: text)
        }
    }
}

#Preview {
    SettingsView()
}
