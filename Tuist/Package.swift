// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    // Release builds of swift-atomics and swift-nio crash at launch (null deref in `ManagedAtomic` and
    // `NIOSingletons`) unless both are compiled at -Onone in single-file mode. See ADR-067.
    let unoptimizedTargets = [
        "Atomics", "NIO", "NIOConcurrencyHelpers", "NIOCore", "NIOEmbedded", "NIOHPACK", "NIOHTTP1",
        "NIOHTTP2", "NIOPosix", "NIOTLS", "_NIOBase64", "_NIODataStructures"
    ]
    let unoptimizedSettings: Settings = .settings(base: [
        "SWIFT_COMPILATION_MODE": "singlefile",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone"
    ])

    let packageSettings = PackageSettings(
        baseSettings: .settings(base: [
            "ENABLE_MODULE_VERIFIER": true,
            "ENABLE_USER_SCRIPT_SANDBOXING": true,
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "OTHER_LIBTOOLFLAGS": "-no_warning_for_no_symbols",
            "WATCHOS_DEPLOYMENT_TARGET": "9.0"
        ]),
        targetSettings: Dictionary(uniqueKeysWithValues: unoptimizedTargets.map { ($0, unoptimizedSettings) })
    )
#endif

let package = Package(
    name: "ReefrWallet",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/Moya/Moya", from: "15.0.0"),
        .package(url: "https://github.com/SwiftyBeaver/SwiftyBeaver", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
        .package(url: "https://github.com/attaswift/BigInt", from: "6.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.9.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.4.0"),
        .package(url: "https://github.com/kervich/reown-swift", branch: "reefr/macos-walletkit")
    ]
)
