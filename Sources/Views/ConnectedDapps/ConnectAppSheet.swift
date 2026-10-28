//
//  ConnectAppSheet.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 17.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI

/// Pairs a dapp from a pasted `wc:` URI (or a scanned QR code on iOS).
struct ConnectAppSheet: View {
    @State private var isScanning = false
    @State private var isWorking = false
    @State private var uri = ""

    @Environment(\.dismiss) private var dismiss

    private let walletConnect = DI.injectOrFail(WalletConnectService.self)

    var body: some View {
        if isPhone {
            phoneBody
        } else {
            macBody
        }
    }

    private var isConnectDisabled: Bool {
        uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking
    }

    private var phoneBody: some View {
        Form {
            Section {
                HStack {
                    Text(.connectAppLink)

                    TextField("", text: $uri, prompt: Text("wc:…"))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connect-app-uri-field")
                        .onSubmit(connect)

                    Button(.connectAppPaste, action: paste)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("connect-app-paste-button")
                }
            } header: {
                Text(.connectAppInstructions)
                    .textCase(nil)
            }

            #if os(iOS)
            Section {
                Button {
                    isScanning = true
                } label: {
                    Label(.connectAppScanQrCode, systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("connect-app-scan-button")
            }
            #endif
        }
        .phoneSheet(
            .commonConnectApp,
            onCancel: { dismiss() },
            confirmTitle: .commonConnect,
            confirmId: "connect-app-connect-button",
            isConfirmEnabled: !isConnectDisabled,
            onConfirm: connect
        )
        #if os(iOS)
        .sheet(isPresented: $isScanning) {
            QRScannerView { code in
                isScanning = false
                uri = code
                connect()
            }
        }
        #endif
    }

    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.commonConnectApp)
                .style(.largeHeader)

            Text(.connectAppInstructions)
                .style(.small, foreground: .secondary)

            HStack {
                TextField("", text: $uri, prompt: Text("wc:…").foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connect-app-uri-field")
                    .onSubmit(connect)

                Button(.connectAppPaste, action: paste)
                    .accessibilityIdentifier("connect-app-paste-button")
            }

#if os(iOS)
            Button {
                isScanning = true
            } label: {
                Label(.connectAppScanQrCode, systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("connect-app-scan-button")
#endif

            Spacer()

            HStack {
                Spacer()

                Button(.commonCancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(.commonConnect, action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    .accessibilityIdentifier("connect-app-connect-button")
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 200)
#if os(iOS)
        .sheet(isPresented: $isScanning) {
            QRScannerView { code in
                isScanning = false
                uri = code
                connect()
            }
        }
#endif
    }
}

private extension ConnectAppSheet {
    func connect() {
        isWorking = true

        Task {
            await walletConnect.pair(uri: uri)
            dismiss()
        }
    }

    func paste() {
#if os(macOS)
        uri = NSPasteboard.general.string(forType: .string) ?? uri
#else
        uri = UIPasteboard.general.string ?? uri
#endif
    }
}
