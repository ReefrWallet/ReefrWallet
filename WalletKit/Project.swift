import ProjectDescription
import ProjectDescriptionHelpers

// WalletKit is split across two targets:
//
// - WalletKitRust wraps what `make walletkit-ffi` already produced (see
//   ../Makefile): the UniFFI-generated Swift bindings in Sources/Generated,
//   linked against the prebuilt Rust core in Frameworks/WalletKit.xcframework.
//   Its public surface is raw UniFFI output — object types with a `*Ffi`
//   suffix (wrapped by WalletKit below) plus plain generated value types
//   used as-is (`Curve`, `Blockchain`, `DerivationPath`, ...).
// - WalletKit (Sources/Static) is the hand-written Swift wrapper that GUI
//   code actually imports. It `import WalletKitRust` and hides every
//   `*Ffi` type behind its own wrapper; code that needs to name a plain
//   generated value type directly (`DerivationPath(string:)`, a `Curve`
//   case, ...) still needs its own `import WalletKitRust` too, since
//   Swift has no way to re-export just those symbols.
//
// This manifest only assembles what `make walletkit-ffi` already produced
// into targets — it doesn't invoke Rust/UniFFI itself, so run
// `make walletkit-ffi` at least once (and after any Rust change) before
// (re)generating this project.
//
// Frameworks/WalletKit.xcframework already contains macOS + iOS device +
// iOS simulator slices, so `destinations` below covers both macOS and iOS
// to match ReefrWallet.

let walletKitRust: Target = .target(
    name: "WalletKitRust",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.rust",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Generated"],
    dependencies: [
        .xcframework(path: "Frameworks/WalletKit.xcframework")
    ]
)

let walletKit: Target = .target(
    name: "WalletKit",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Static"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --config ../.swiftlint.yml Sources/Static Docs/Design\\ Specifications Project.swift
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "BigInt"),
        .target(name: "WalletKitRust")
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
        .target(name: "WalletKit"),
        .target(name: "WalletKitRust")
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
    targets: [walletKitRust, walletKit, /*walletKitTestsIOS,*/ walletKitTestsMac],
    schemes: schemes,
    additionalFiles: [
        "*.md",
        "Docs/**/*",
        "Rust/walletkit-ffi/**/*",
        "Rust/Cargo.toml",
        "Rust/README.md",
        "Makefile",
        "Project.swift"
    ]
)
