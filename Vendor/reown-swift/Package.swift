// swift-tools-version:5.5

import PackageDescription

// Vendored from reown-com/reown-swift 2.4.0: only the Sign SDK, with
// the Yttrium-based modules removed (no macOS slice) and
// LinkEnvelopesDispatcher fixed to build on macOS. See ADR-035.
let package = Package(
    name: "reown",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(name: "WalletConnect", targets: ["WalletConnectSign"])
    ],
    targets: [
        .target(
            name: "WalletConnectSign",
            dependencies: ["WalletConnectPairing", "WalletConnectVerify", "WalletConnectSigner", "Events"],
            path: "Sources/WalletConnectSign",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]),
        .target(
            name: "WalletConnectRelay",
            dependencies: ["WalletConnectJWT"],
            path: "Sources/WalletConnectRelay",
            resources: [.copy("PackageConfig.json"), .process("Resources/PrivacyInfo.xcprivacy")]),
        .target(
            name: "WalletConnectKMS",
            dependencies: ["WalletConnectUtils"],
            path: "Sources/WalletConnectKMS"),
        .target(
            name: "WalletConnectPairing",
            dependencies: ["WalletConnectNetworking", "Events"],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]),
        .target(
            name: "WalletConnectSigner",
            dependencies: ["WalletConnectNetworking"]),
        .target(
            name: "WalletConnectJWT",
            dependencies: ["WalletConnectKMS"]),
        .target(
            name: "WalletConnectUtils",
            dependencies: ["JSONRPC"]),
        .target(
            name: "JSONRPC",
            dependencies: ["Commons"]),
        .target(
            name: "Commons",
            dependencies: []),
        .target(
            name: "HTTPClient",
            dependencies: []),
        .target(
            name: "WalletConnectNetworking",
            dependencies: ["HTTPClient", "WalletConnectRelay"]),
        .target(
            name: "WalletConnectVerify",
            dependencies: ["WalletConnectUtils", "WalletConnectNetworking", "WalletConnectJWT"],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]),
        .target(
            name: "Events",
            dependencies: ["WalletConnectUtils", "WalletConnectNetworking"])
    ],
    swiftLanguageVersions: [.v5]
)
