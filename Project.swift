import ProjectDescription

let wallet: Target = .target(
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

let macOSTests: Target = .target(
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

let iosTests: Target = .target(
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

let walletScheme: Scheme = .scheme(
    name: "ReefrWallet",
    shared: true,
    buildAction: .buildAction(targets: [.target("ReefrWallet")]),
    runAction: .runAction(
        executable: .executable(.target("ReefrWallet")),
        arguments: .arguments(launchArguments: [
            .launchArgument(name: "--drop-accounts", isEnabled: false)
        ])
    )
)

let project = Project(
    name: "ReefrWallet",
    settings: .settings(base: [
        "ENABLE_MODULE_VERIFIER": true,
        "ENABLE_USER_SCRIPT_SANDBOXING": false,
        "OTHER_LDFLAGS": ["-lc++"]
    ]),
    targets: [wallet, macOSTests], // TODO: iOS tests need signing configured
    schemes: [walletScheme],
    additionalFiles: [
        "Makefile",
        "Project.swift",
        "*.md"
    ]
)
