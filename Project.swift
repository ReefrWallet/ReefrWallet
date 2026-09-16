import Foundation
import ProjectDescription

private let wallet: Target = .target(
    name: "ReefrWallet",
    destinations: [.mac, .iPhone, .iPad],
    product: .app,
    bundleId: "xyz.reefr.wallet",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    resources: ["Resources/**/*"],
    buildableFolders: ["Sources"],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --config .swiftlint.yml Sources",
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "Moya"),
        .external(name: "SwiftyBeaver"),
        .project(target: "WalletKit", path: "WalletKit")
    ]
)

private let macOSTests: Target = .target(
    name: "ReefrWalletTests-macOS",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.tests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --config .swiftlint.yml Tests",
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [.target(name: "ReefrWallet")]
)

private let iosTests: Target = .target(
    name: "ReefrWalletTests-iOS",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.tests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --config .swiftlint.yml Tests",
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [.target(name: "ReefrWallet")]
)

private let macOSUITests: Target = .target(
    name: "ReefrWalletUITests-macOS",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "xyz.reefr.wallet.uitests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    buildableFolders: ["UITests"],
    scripts: [
        .post(
            script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --quiet --config .swiftlint.yml UITests",
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [.target(name: "ReefrWallet")],
    settings: .settings(base: [
        "TEST_TARGET_NAME": "ReefrWallet"
    ])
)

private let walletScheme: Scheme = .scheme(
    name: wallet.name,
    shared: true,
    buildAction: .buildAction(targets: [.target(wallet.name)]),
    runAction: .runAction(
        executable: .executable(.target(wallet.name)),
        arguments: .arguments(launchArguments: [
            .launchArgument(name: "--drop-accounts", isEnabled: false),
            .launchArgument(name: "--drop-balances", isEnabled: false),
            .launchArgument(name: "--drop-tokens", isEnabled: false)
        ])
    )
)

private let macOSTestsScheme: Scheme = .scheme(
    name: macOSTests.name,
    shared: true,
    buildAction: .buildAction(targets: [.target(macOSTests.name)]),
    testAction: .targets(
        [.testableTarget(target: .target(macOSTests.name))],
        arguments: .arguments(launchArguments: [
            .launchArgument(name: "--test", isEnabled: true)
        ])
    )
)

private let macOSUITestsScheme: Scheme = .scheme(
    name: macOSUITests.name,
    shared: true,
    buildAction: .buildAction(targets: [.target(macOSUITests.name)]),
    testAction: .targets(
        [.testableTarget(target: .target(macOSUITests.name))]
    )
)

private let libUsbPathFlag = if FileManager.default.fileExists(atPath: "/usr/local/opt/libusb/lib") {
    "-L/usr/local/opt/libusb/lib"
} else {
    "-L/opt/homebrew/opt/libusb/lib"
}

let project = Project(
    name: "ReefrWallet",
    settings: .settings(base: [
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": true,
        "ENABLE_MODULE_VERIFIER": true,
        "ENABLE_USER_SCRIPT_SANDBOXING": false,
        "OTHER_LDFLAGS[sdk=macosx*]": ["-lc++", libUsbPathFlag, "-lusb-1.0"],
        "STRING_CATALOG_GENERATE_SYMBOLS": true
    ]),
    targets: [wallet, macOSTests, macOSUITests], // TODO: iOS tests need signing configured
    schemes: [walletScheme, macOSTestsScheme, macOSUITestsScheme],
    additionalFiles: [
        "Makefile",
        "Project.swift",
        "*.md"
    ]
)
