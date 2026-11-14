import Foundation
import ProjectDescription
import ProjectDescriptionHelpers

/// Live-network credentials forwarded from the generating shell into the test
/// targets.
///
/// Tuist only passes `TUIST_`-prefixed variables through to a manifest, so the
/// generating shell must export each one as `TUIST_<NAME>` too. The values are
/// written in plain text into the generated (git-ignored) schemes.
private let testEnvironmentVariables: [String: EnvironmentVariable] = {
    let keys = [
        "APTOS_API_KEY",
        "BLOCKFROST_MAINNET_PROJECT_ID",
        "BLOCKFROST_PREPROD_PROJECT_ID",
        "COINGECKO_API_KEY",
        "ETHERSCAN_API_KEY",
        "REEFR_TESTNET_MNEMONIC",
        "TRONGRID_API_KEY"
    ]

    return keys.reduce(into: [:]) { variables, key in
        guard let value = ProcessInfo.processInfo.environment["TUIST_\(key)"], !value.isEmpty else {
            return
        }

        variables[key] = .environmentVariable(value: value, isEnabled: true)
    }
}()

// MARK: Targets

private let walletInfoPlist: [String: Plist.Value] = Project.commonInfoPlist.merging([
    "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
    "CFBundleURLTypes": .array([
        .dictionary([
            "CFBundleTypeRole": "Viewer",
            "CFBundleURLName": "xyz.reefr.wallet.walletconnect",
            "CFBundleURLSchemes": .array(["wc", "reefr"])
        ])
    ]),
    "NSCameraUsageDescription": "Reefr Wallet uses the camera to scan WalletConnect QR codes.",
    "NSFaceIDUsageDescription": "Reefr Wallet uses Face ID to unlock your local keys.",
    "UIApplicationSceneManifest": .dictionary(["UIApplicationSupportsMultipleScenes": true]),
    "UILaunchStoryboardName": "LaunchScreen",
    "UISupportedInterfaceOrientations~ipad": .array([
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight"
    ])
]) { $1 }

private let wallet: Target = .target(
    name: "ReefrWallet",
    destinations: [.mac, .iPhone, .iPad],
    product: .app,
    bundleId: "xyz.reefr.wallet",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .dictionary(walletInfoPlist),
    resources: [
        .glob(pattern: "Resources/**/*", excluding: ["Resources/LaunchScreen.storyboard"]),
        .glob(pattern: "Resources/LaunchScreen.storyboard", inclusionCondition: .when([.ios]))
    ],
    buildableFolders: ["Sources"],
    entitlements: .dictionary([
        "com.apple.security.application-groups": .array([.string("group.xyz.reefr.wallet")])
    ]),
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --no-cache --config .swiftlint.yml Sources",
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "Sources/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "Moya"),
        .external(name: "WalletConnect"),
        .external(name: "SwiftyBeaver"),
        .project(target: "WalletKit", path: "WalletKit")
    ]
)

/// Tests that need WalletKitTesting, which is macOS-only for now.
private let iosTestExclusions: [String] = [
    "AnvilTestSupport.swift",
    "AptosTransactionServiceTests.swift",
    "BalancesServiceTests.swift",
    "DatabaseServiceDeleteAllTests.swift",
    "EthereumDappProviderTests.swift",
    "RelaunchBalanceSyncTests.swift",
    "SolanaDappProviderFixture.swift",
    "SolanaDappProviderTests.swift",
    "TransactionServiceTests.swift",
    "TransactionSyncServiceTests.swift"
]

private let iosTests: Target = .target(
    name: "ReefrWalletTests-iOS",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.tests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    resources: ["TestVectors/**/*"],
    buildableFolders: [.folder("Tests", exceptions: .exceptions([.exception(excluded: iosTestExclusions)]))],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --no-cache --config .swiftlint.yml Tests",
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "Tests/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .target(name: "ReefrWallet")
    ],
    environmentVariables: testEnvironmentVariables
)

/// UI tests that need WalletKitTesting or subprocesses, which are macOS-only for now.
private let iosUITestExclusions: [String] = [
    "AnvilTransactionHistoryUITests.swift",
    "BitcoinForwardSyncUITests.swift",
    "BrowserAccountSelectorUITests.swift",
    "DappBrowserUITests.swift",
    "DappConnectionUITests.swift",
    "EthereumForwardSyncUITests.swift",
    "LocalDappServer.swift",
    "RelaunchBalanceSyncUITests.swift",
    "SeedPhraseFieldMacUITests.swift",
    "SolanaForwardSyncUITests.swift",
    "SolanaStakingUITests.swift",
    "SuiForwardSyncUITests.swift",
    "SuiTransactionHistoryUITests.swift",
    "TronTRXTransferUITests.swift",
    "TronUSDTTransferUITests.swift",
    "UniswapConnectionUITests.swift",
    "WatchOnlySuiAccountUITests.swift"
]

private let iosUITests: Target = .target(
    name: "ReefrWalletUITests-iOS",
    destinations: [.iPhone, .iPad],
    product: .uiTests,
    bundleId: "xyz.reefr.wallet.uitests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    resources: ["TestVectors/**/*"],
    buildableFolders: [.folder("UITests", exceptions: .exceptions([.exception(excluded: iosUITestExclusions)]))],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --no-cache --config .swiftlint.yml UITests",
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "UITests/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .target(name: "ReefrWallet"),
        .external(name: "BigInt"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .external(name: "SwiftProtobuf"),
        .external(name: "GRPCProtobuf")
    ],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "ReefrWallet"
    ]),
    environmentVariables: testEnvironmentVariables
)

private let macOSTests: Target = .target(
    name: "ReefrWalletTests-macOS",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.tests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    resources: ["TestVectors/**/*"],
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --no-cache --config .swiftlint.yml Tests",
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "Tests/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .target(name: "ReefrWallet"),
        .project(target: "WalletKitTesting", path: "WalletKit")
    ],
    environmentVariables: testEnvironmentVariables
)

private let macOSUITests: Target = .target(
    name: "ReefrWalletUITests-macOS",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "xyz.reefr.wallet.uitests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    resources: ["TestVectors/**/*"],
    buildableFolders: ["UITests"],
    entitlements: .dictionary([
        "com.apple.security.network.server": .boolean(true)
    ]),
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --no-cache --config .swiftlint.yml UITests",
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "UITests/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .target(name: "ReefrWallet"),
        .project(target: "WalletKitTesting", path: "WalletKit"),
        .external(name: "BigInt"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .external(name: "SwiftProtobuf"),
        .external(name: "GRPCProtobuf")
    ],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "ReefrWallet"
    ]),
    environmentVariables: testEnvironmentVariables
)

// MARK: Schemes

private let walletScheme: Scheme = .scheme(
    name: wallet.name,
    shared: true,
    buildAction: .buildAction(targets: [.target(wallet.name)]),
    testAction: .targets(
        ["\(iosTests.name)", "\(macOSTests.name)", "\(macOSUITests.name)"],
        arguments: .arguments(environmentVariables: testEnvironmentVariables),
        options: .options(coverage: true, codeCoverageTargets: ["\(wallet.name)"])
    ),
    runAction: .runAction(
        executable: .executable(.target(wallet.name)),
        arguments: .arguments(launchArguments: [
            .launchArgument(name: "--drop-accounts", isEnabled: false),
            .launchArgument(name: "--drop-balances", isEnabled: false),
            .launchArgument(name: "--drop-tokens", isEnabled: false),
            .launchArgument(name: "--drop-transactions", isEnabled: false),
            .launchArgument(name: "--verbose", isEnabled: true)
        ])
    )
)

// MARK: - Project

private let libUsbPathFlag = if FileManager.default.fileExists(atPath: "/usr/local/opt/libusb/lib") {
    "-L/usr/local/opt/libusb/lib"
} else {
    "-L/opt/homebrew/opt/libusb/lib"
}

let project = Project(
    name: "ReefrWallet",
    organizationName: Project.organizationName,
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "V785L3L8JT",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": true,
        "ENABLE_MODULE_VERIFIER": true,
        "ENABLE_USER_SCRIPT_SANDBOXING": true,
        "OTHER_LDFLAGS[sdk=iphone*]": ["-lc++"],
        "OTHER_LDFLAGS[sdk=macosx*]": ["-lc++", libUsbPathFlag, "-lusb-1.0"],
        "REGISTER_APP_GROUPS": true,
        "STRING_CATALOG_GENERATE_SYMBOLS": true
    ]),
    targets: [wallet, macOSTests, iosTests, iosUITests, macOSUITests],
    schemes: [walletScheme],
    additionalFiles: [
        ".github/**/*",
        "docs/**/*",
        "Makefile",
        "Project.swift",
        "*.md"
    ]
)
