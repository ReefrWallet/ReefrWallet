//
//  WalletApp.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 13.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import SwiftData
import SwiftUI
import WalletKit

@main struct WalletApp: App {
    var databaseService: DatabaseService!
    var transactionSyncService: TransactionSyncService!
#if DEBUG
    var accountService: AccountService!
    var keyStoreService: KeyStoreService!
#endif

    init() {
        processPreStartupOptions()
        databaseService = DI.injectOrFail(DatabaseService.self)
        transactionSyncService = DI.injectOrFail(TransactionSyncService.self)
#if DEBUG
        accountService = DI.injectOrFail(AccountService.self)
        keyStoreService = DI.injectOrFail(KeyStoreService.self)
#endif
        let accountService = accountService!
        let keyStoreService = keyStoreService!
        let persistedDatabaseService = databaseService!
        let syncService = transactionSyncService!
        let tokenPriceScheduler = DI.injectOrFail(TokenPriceScheduler.self)
        let approvalService = DI.injectOrFail(ApprovalService.self)
        Task {
            await Self.processPostStartupOptions(
                accountService: accountService,
                databaseService: persistedDatabaseService,
                keyStoreService: keyStoreService
            )

#if DEBUG
            if !Self.commandLineFlag("--disable-price-updates") {
                await tokenPriceScheduler.start()
            }

            guard !Self.commandLineFlag("--disable-transaction-sync") else {
                return
            }
#else
            await tokenPriceScheduler.start()
#endif

            await syncService.startAll()
            await approvalService.refreshAll()
        }
    }

    static let defaultBrowserURL = URL(string: "https://app.uniswap.org")!

    /// A local dapp URL to auto-open the browser to, for UI tests —
    /// `--dapp-url`, DEBUG-only like every other launch-argument override.
    static var dappURL: URL? {
#if DEBUG
        commandLineURL(after: "--dapp-url")
#else
        nil
#endif
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commandsRemoved()
        .modelContainer(databaseService.modelContainer)

#if os(macOS)
        WindowGroup("Browser", id: "browser", for: URL.self) { $url in
            let initialURL = url ?? Self.dappURL ?? Self.defaultBrowserURL
            BrowserView(initialURL: initialURL)
                .accessibilityIdentifier("browser-window")
        }
        .defaultSize(width: 1100, height: 700)
        .modelContainer(databaseService.modelContainer)

        Settings {
            SettingsView()
        }
#endif
    }
}

#if DEBUG

private extension WalletApp {
    // swiftlint:disable:next function_body_length
    static func processPostStartupOptions(
        accountService: AccountService,
        databaseService: DatabaseService,
        keyStoreService: KeyStoreService
    ) async {
        do {
            if commandLineFlag("--drop-accounts") {
                printInfo("Deleting all accounts.")
                try await databaseService.deleteAllAccounts()
            }

            if commandLineFlag("--drop-transactions") {
                printInfo("Deleting all transactions and sync state.")
                try await databaseService.deleteAllTransactions()
            }

            if commandLineFlag("--drop-tokens") {
                printInfo("Deleting all tokens and balances.")
                try await databaseService.deleteAllTokens()
            } else if commandLineFlag("--drop-balances") {
                printInfo("Deleting all balances.")
                try await databaseService.deleteAllBalances()
            }
        } catch {
            printError(error)
        }

        if let seedPhrase = commandLineValue(after: "--mnemonic") {
            printInfo("Using seed phrase from command-line arguments.")

            do {
                let mnemonic = try Mnemonic.fromPhrase(seedPhrase)

                guard let keyStore = try await keyStoreService.addLocalKey(mnemonic) else {
                    fatalError("Cannot add key store.")
                }

                printInfo("Initialized testing key store.")

                let accountConfigurations: [TestAccountConfiguration] = [
                    TestAccountConfiguration(
                        blockchain: .aptos(.testnet),
                        rpcURL: commandLineURL(after: "--aptos-rpc-url"),
                        creationFlag: "--create-aptos-accounts"
                    ),
                    TestAccountConfiguration(
                        blockchain: .bitcoin(.regtest),
                        rpcURL: commandLineURL(after: "--bitcoin-rpc-url"),
                        bitcoinBackend: .esplora,
                        bitcoinScriptType: .p2wpkh,
                        creationFlag: "--create-bitcoin-accounts"
                    ),
                    TestAccountConfiguration(
                        blockchain: .evm(.ethereum(.sepolia)),
                        rpcURL: commandLineURL(after: "--evm-rpc-url"),
                        creationFlag: "--create-evm-accounts"
                    ),
                    TestAccountConfiguration(
                        blockchain: .solana(.devnet),
                        rpcURL: commandLineURL(after: "--solana-rpc-url"),
                        creationFlag: "--create-solana-accounts"
                    ),
                    TestAccountConfiguration(
                        blockchain: .sui(.testnet),
                        rpcURL: commandLineURL(after: "--sui-rpc-url"),
                        creationFlag: "--create-sui-accounts"
                    ),
                    TestAccountConfiguration(
                        blockchain: .tron(.testnet),
                        rpcURL: commandLineURL(after: "--tron-rpc-url"),
                        creationFlag: "--create-tron-accounts"
                    )
                ]

                for configuration in accountConfigurations {
                    guard commandLineFlag(configuration.creationFlag) else {
                        continue
                    }

                    for _ in 0 ..< 2 {
                        try await accountService.makeAccount(
                            configuration.blockchain,
                            keyStore: keyStore,
                            rpcURLOverride: configuration.rpcURL,
                            bitcoinScriptType: configuration.bitcoinScriptType,
                            bitcoinBackend: configuration.bitcoinBackend
                        )
                    }
                }

                printInfo("Initialized local testnet accounts.")
            } catch {
                printError(error)
            }
        }
    }

    func processPreStartupOptions() {
#if os(macOS)
        // Otherwise AppKit treats unpaired `--flags` as files to open, and SwiftUI skips the initial window.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
#endif

        if let storePath = Self.commandLineValue(after: "--store-path") {
            Inject.storeURLOverride = URL(fileURLWithPath: storePath)
        }

        if Self.commandLineFlag("--test") || isRunningXCTest {
            printDebug("Using test service injection mode.")
            Inject.mode = .test
        }
    }

    /// Xcode sets this environment variable on any process it launches to host XCTest,
    /// including plain unit tests that don't receive the app's own launch arguments.
    /// Detecting it here keeps every test run off the real on-disk store automatically.
    var isRunningXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func commandLineFlag(_ parameter: String) -> Bool {
        CommandLine.arguments.contains(parameter)
    }

    static func commandLineURL(after argument: String) -> URL? {
        guard let value = commandLineValue(after: argument) else {
            return nil
        }

        return URL(string: value)
    }

    static func commandLineValue(after argument: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: argument),
              CommandLine.arguments.count > index + 1 else {
            return nil
        }

        return CommandLine.arguments[index + 1]
    }
}

/// One entry in the `--mnemonic` bootstrap table. Each blockchain only gets
/// its 2 test accounts created when its own `creationFlag` is passed, so a
/// UI test that only exercises one chain doesn't pay for (or risk failing on)
/// the other chains' account creation.
private struct TestAccountConfiguration {
    let blockchain: Blockchain
    let rpcURL: URL?
    var bitcoinBackend: BitcoinBackendKind?
    var bitcoinScriptType: BitcoinScriptType?
    let creationFlag: String
}

#endif
