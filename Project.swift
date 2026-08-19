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
            resources: ["Resources/**/*"],
            buildableFolders: ["Sources"],
            scripts: [
                .post(
                    script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --config .swiftlint.yml",
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [
                .external(name: "Moya"),
                .external(name: "SwiftyBeaver"),
                .project(target: "WalletKit", path: "WalletKit")
            ],
            settings: .settings(base: ["OTHER_LDFLAGS": ["-lc++"]])
        ),
        .target(
            name: "ReefrWalletTests-macOS",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "xyz.reefr.wallet.tests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            buildableFolders: ["Tests"],
            scripts: [
                .post(
                    script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --config .swiftlint.yml",
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [.target(name: "ReefrWallet")]
        ) /*,
        .target(
            name: "ReefrWalletTests-iOS",
            destinations: [.iPhone, .iPad],
            product: .unitTests,
            bundleId: "xyz.reefr.wallet.tests",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .default,
            buildableFolders: ["Tests"],
            scripts: [
                .post(
                    script: "$HOME/.local/bin/mise x swiftlint -- swiftlint --config .swiftlint.yml",
                    name: "SwiftLint",
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [.target(name: "ReefrWallet")]
        ) */
    ],
    additionalFiles: [
        "Makefile",
        "Project.swift",
        "README.md"
    ]
)
