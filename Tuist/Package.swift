// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        baseSettings: .settings(base: [
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "OTHER_LIBTOOLFLAGS": "-no_warning_for_no_symbols",
            "WATCHOS_DEPLOYMENT_TARGET": "9.0"
        ])
    )
#endif

let package = Package(
    name: "ReefrWallet",
    dependencies: [
        .package(url: "https://github.com/Moya/Moya.git", from: "15.0.0"),
        .package(url: "https://github.com/SwiftyBeaver/SwiftyBeaver", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "6.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.2.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1")
    ]
)
