//
//  Workspace.swift
//  
//
//  Created by Andrey Yurkevich on 06.12.25.
//

import ProjectDescription

private let workspaceName = "ReefrWallet"

let workspace =  Workspace(
    name: workspaceName,
    projects: [".", "WalletKit"],
    schemes: [
        .scheme(name: "\(workspaceName)-Workspace", hidden: true),
        .scheme(name: "Generate Project", hidden: false)
    ],
    additionalFiles: [
        ".swiftlint.yml",
        "Tuist/Package.swift",
        "Tuist/ProjectDescriptionHelpers/**/*.swift",
        "Workspace.swift"
    ],
    generationOptions: .options(lastXcodeUpgradeCheck: Version(27, 2, 0))
)
