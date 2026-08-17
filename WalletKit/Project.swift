import ProjectDescription
import ProjectDescriptionHelpers

// Builds the WalletKit Swift module from what `make walletkit-ffi` already
// produced (see ../Makefile): the UniFFI-generated Swift bindings in
// Sources, linked against the prebuilt Rust core in
// Frameworks/WalletKit.xcframework. This manifest only assembles those
// outputs into a target — it doesn't invoke Rust/UniFFI itself, so run
// `make walletkit-ffi` at least once (and after any Rust change) before
// (re)generating this project.
//
// Frameworks/WalletKit.xcframework already contains macOS + iOS device +
// iOS simulator slices, so `destinations` below covers both macOS and iOS
// to match ReefrWallet.

let walletKit: Target = .target(
    name: "WalletKit",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --config ../.swiftlint.yml Sources Docs/Design\\ Specifications Project.swift
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "BigInt"),
        .xcframework(path: "Frameworks/WalletKit.xcframework")
    ]
)

let walletKitTestsMac: Target = .target(
    name: "WalletKitTests-macOS",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.walletkit.tests-mac",
    deploymentTargets: .macOS("15.0"),
    resources: ["TestVectors/**/*"],
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --config ../.swiftlint.yml Tests
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "BigInt"),
        .xcframework(path: "Frameworks/WalletKit.xcframework")
    ]
)

/* let walletKitTestsIOS: Target = .target(
    name: "WalletKitTests-iOS",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.walletkit.tests-ios",
    deploymentTargets: .iOS("18.0"),
    resources: ["TestVectors/**/*"],
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --config ../.swiftlint.yml Tests
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ]
) */

let schemes: [Scheme] = [
    .scheme(
        name: walletKit.name,
        buildAction: .buildAction(targets: ["\(walletKit.name)"]),
        testAction: .targets(
            ["\(walletKitTestsMac.name)"/*, "\(walletKitTestsIOS.name)"*/],
            options: .options(coverage: true, codeCoverageTargets: ["\(walletKit.name)"])
        )
    )
]

let project = Project(
    name: "WalletKit",
    organizationName: Project.organizationName,
    targets: [walletKit, /*walletKitTestsIOS,*/ walletKitTestsMac],
    schemes: schemes,
    additionalFiles: [
        "Docs/**/*",
        "Rust/walletkit-ffi/**/*",
        "Rust/Cargo.toml",
        "Rust/README.md",
        "Makefile",
        "Project.swift"
    ]
)
