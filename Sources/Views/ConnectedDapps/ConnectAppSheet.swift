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
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect App")
                .style(.largeHeader)

            Text("Paste the WalletConnect link from the app, or scan its QR code.")
                .style(.small, foreground: .secondary)

            HStack {
                TextField("wc:…", text: $uri)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connect-app-uri-field")
                    .onSubmit(connect)

                Button("Paste", action: paste)
                    .accessibilityIdentifier("connect-app-paste-button")
            }

#if os(iOS)
            Button {
                isScanning = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("connect-app-scan-button")
#endif

            Spacer()

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect", action: connect)
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
