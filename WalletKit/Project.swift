import ProjectDescription
import ProjectDescriptionHelpers

let walletKitRust: Target = .target(
    name: "WalletKitRust",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.rust",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Generated/Bindings"],
    dependencies: [
        .xcframework(path: "Frameworks/WalletKit.xcframework")
    ]
)

let walletKitGRPC: Target = .target(
    name: "WalletKitGRPC",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.grpc",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Generated/gRPC"],
    dependencies: [
        .external(name: "SwiftProtobuf"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .external(name: "GRPCProtobuf")
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
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .target(name: "WalletKitGRPC"),
        .target(name: "WalletKitRust")
    ],
    // grpc-swift-nio-transport pulls in swift-nio-ssl's CNIOBoringSSL, a C++
    // library — its final link step needs libc++, which Xcode only links
    // in automatically for a target that itself has Objective-C++/C++
    // sources. This target has none, so any consumer that actually calls
    // into SuiGRPCClient (and so keeps CNIOBoringSSL's symbols live rather
    // than dead-stripped) fails to link without this.
    settings: .settings(base: ["OTHER_LDFLAGS": ["-lc++"]])
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
        .target(name: "WalletKitRust"),
        .target(name: "WalletKitGRPC")
    ],
    // See the matching comment on `walletKit` above — this target links
    // SuiGRPCClient's own test bundle, independently of WalletKit's link
    // settings.
    settings: .settings(base: ["OTHER_LDFLAGS": ["-lc++"]])
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
    targets: [walletKitRust, walletKitGRPC, walletKit, /*walletKitTestsIOS,*/ walletKitTestsMac],
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
