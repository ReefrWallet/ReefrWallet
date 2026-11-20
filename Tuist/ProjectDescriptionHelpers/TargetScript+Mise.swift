import ProjectDescription

public extension TargetScript {
    /// A new worktree has untrusted mise configs, which fail every `mise x` (SwiftLint, test helpers).
    /// Trusts them before the target builds.
    static let trustMise: TargetScript = .pre(
        script: """
                for dir in "$SRCROOT" "$SRCROOT/WalletKit"; do
                    [ -d "$dir" ] && $HOME/.local/bin/mise -C "$dir" trust --all --quiet
                done
                true
                """,
        name: "Trust mise",
        basedOnDependencyAnalysis: false
    )

    /// Lints `directory` of the app project, rerunning when it or the lint config changes.
    static func swiftLint(_ directory: String) -> TargetScript {
        .post(
            script: """
                    $HOME/.local/bin/mise x swiftlint -- \\
                    swiftlint --quiet --no-cache --config .swiftlint.yml \(directory)
                    """,
            name: "SwiftLint",
            inputPaths: [".mise.toml", "mise.toml", ".swiftlint.yml", "\(directory)/**/*.swift"],
            basedOnDependencyAnalysis: false
        )
    }

    /// Lints `paths` of the WalletKit project, which uses the repository's lint config.
    static func swiftLintWalletKit(_ paths: String...) -> TargetScript {
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --quiet --config ../.swiftlint.yml \(paths.joined(separator: " "))
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    }
}
