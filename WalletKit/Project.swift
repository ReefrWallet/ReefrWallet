import ProjectDescription

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

let project = Project(
    name: "WalletKit",
    targets: [
        .target(
            name: "WalletKit",
            destinations: [.mac, .iPhone, .iPad],
            product: .staticFramework,
            bundleId: "xyz.reefr.wallet.walletkit",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            buildableFolders: ["Sources"],
            scripts: [
                .post(
                    script: """
                        $HOME/.local/bin/mise x -C $SRCROOT
                            --
                            swiftlint --config ../.swiftlint.yml
                    """,
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [.xcframework(path: "Frameworks/WalletKit.xcframework")]
        ),
        .target(
            name: "WalletKitTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "xyz.reefr.wallet.walletkit.tests",
            deploymentTargets: .multiplatform(macOS: "15.0"),
            infoPlist: .default,
            resources: ["TestVectors/**/*"],
            buildableFolders: ["Tests"],
            scripts: [
                .post(
                    script: """
                        $HOME/.local/bin/mise x -C $SRCROOT
                            --
                            swiftlint --config ../.swiftlint.yml
                    """,
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [.target(name: "WalletKit")]
        )
    ],
    additionalFiles: [
        "Docs/**/*",
        "Rust/walletkit-ffi/**/*",
        "Rust/Cargo.toml",
        "Rust/README.md",
        "Makefile",
        "Project.swift"
    ]
)
