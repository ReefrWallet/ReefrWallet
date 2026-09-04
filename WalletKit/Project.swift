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
                    swiftlint --quiet --config ../.swiftlint.yml Sources/Static Project.swift
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
                    swiftlint --quiet --config ../.swiftlint.yml Tests
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
    settings: .settings(base: [
        "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": ["gnu11", "gnu++14"],
        "ENABLE_MODULE_VERIFIER": true,
        "ENABLE_USER_SCRIPT_SANDBOXING": false,
        "OTHER_LDFLAGS[sdk=macosx*]": [
            "-lc++",
            "-L/opt/homebrew/opt/libusb/lib",
            "-L/usr/local/opt/libusb/lib",
            "-lusb-1.0"
        ]
    ]),
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
