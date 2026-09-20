//
//  Project+Extensions.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 20.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import ProjectDescription

public extension Project {
    static let bundleIdPrefix = "xyz.reefr"
    static let deploymentTargets = DeploymentTargets.multiplatform(iOS: "18.0", macOS: "15.0")
    static let organizationName = "Reefr Wallet"

    static let commonInfoPlist: [String: Plist.Value] = [
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleShortVersionString": "\(currentVersion)",
        "CFBundleVersion": "\(currentBuildNumber)",
        "NSHumanReadableCopyright": "Copyright © \(currentYear) Reefr Wallet"
    ]
}

private extension Project {
    static var currentYear: String {
        Date.now.formatted(.dateTime.year())
    }
}
