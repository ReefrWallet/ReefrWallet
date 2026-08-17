// swift-tools-version: 5.9
import PackageDescription

#if TUIST
    import ProjectDescription

    // attaswift/BigInt's own Package.swift declares `.macOS(.v10_13)`,
    // below the minimum deployment target current Xcode accepts (12.0) —
    // override just that build setting on the generated package target
    // rather than waiting on upstream to bump it.
    let packageSettings = PackageSettings(
        targetSettings: [
            "BigInt": .settings(base: ["MACOSX_DEPLOYMENT_TARGET": "15.0"])
        ]
    )
#endif

let package = Package(
    name: "ReefrWallet",
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "6.0.0")
    ]
)
