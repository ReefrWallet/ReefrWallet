//
//  Workspace.swift
//  
//
//  Created by Andrey Yurkevich on 06.12.25.
//

import ProjectDescription

let workspace =  Workspace(
    name: "ReefrWallet",
    projects: [".", "WalletKit"],
    additionalFiles: [
        ".github/**/*",
        ".swiftlint.yml",
        "Tuist/Package.swift",
        "Tuist/ProjectDescriptionHelpers/**/*.swift",
        "Workspace.swift"
    ]
)
