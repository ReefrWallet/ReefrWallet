import ProjectDescription

let project = Project(
    name: "ReefrWallet",
    targets: [
        .target(
            name: "ReefrWallet",
            destinations: [.mac, .iPhone, .iPad],
            product: .app,
            bundleId: "xyz.reefr.wallet",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            buildableFolders: ["Sources"],
            scripts: [
                .post(
                    script: "$HOME/.local/bin/mise x -C $SRCROOT -- swiftlint --config .swiftlint.yml",
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [.project(target: "WalletKit", path: "WalletKit")]
        ),
        .target(
            name: "ReefrWalletTests",
            destinations: [.mac, .iPhone, .iPad],
            product: .unitTests,
            bundleId: "xyz.reefr.wallet.tests",
            deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
            infoPlist: .default,
            buildableFolders: ["Tests"],
            dependencies: [.target(name: "ReefrWallet")]
        )
    ],
    additionalFiles: [
        "Docs/**/*",
        "Tuist.swift",
        "Makefile",
        "Project.swift",
        ".swiftlint.yml"
    ]
)
