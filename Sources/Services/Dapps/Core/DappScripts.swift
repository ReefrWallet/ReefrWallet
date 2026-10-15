//
//  DappScripts.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WebKit

/// Builds the `WKUserScript`s for the enabled dapp namespaces —
/// `bridge.js` (chain-agnostic transport/event bus) plus each enabled
/// namespace's vendored libraries (`vendor/`) and own provider scripts
/// (`providers/`). Source files live under `Resources/Browser/` for
/// organization, but Tuist/Xcode's default `Copy Bundle Resources` phase
/// flattens individual file references into the bundle's top level
/// (subdirectories are only preserved for folder references), so they're
/// looked up there — every script's filename must stay unique across
/// `providers/` and `vendor/`.
/// All injected at document start, main frame only, in the `.page`
/// content world, so the page's own scripts see `window.__reefr`/
/// `window.ethereum` as if they were part of the page itself.
struct DappScripts {
    static func userScripts(for namespaces: [DappNamespace]) -> [WKUserScript] {
        var scripts: [WKUserScript] = []

        if let bridge = userScript(resource: "bridge") {
            scripts.append(bridge)
        }

        if let walletStandardCore = userScript(resource: "wallet-standard-core") {
            scripts.append(walletStandardCore)
        }

        for namespace in namespaces {
            for resourceName in namespace.scriptNames {
                if let provider = userScript(resource: resourceName) {
                    scripts.append(provider)
                }
            }
        }

        return scripts
    }

    /// The placeholder in `bridge.js` that ``iconDataURI`` replaces.
    static let iconPlaceholder = "__REEFR_ICON__"

    /// `dapp-icon.svg` as the `data:` URI EIP-6963, TIP-6963 and Wallet
    /// Standard require for the announced wallet icon. Kept as a separate
    /// resource because the page-world script can't read the bundle.
    static let iconDataURI: String? = {
        guard
            let url = Bundle.main.url(forResource: "dapp-icon", withExtension: "svg"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        return "data:image/svg+xml;base64," + data.base64EncodedString()
    }()

    static func source(resource: String) -> String? {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        guard resource == "bridge" else {
            return source
        }

        // No assertionFailure here: it traps whatever process hosts this
        // code (test runner, SwiftUI previews) before anything can report
        // it. A missing icon is caught by DappScriptsTests instead.
        guard let iconDataURI else {
            return source
        }

        return source.replacingOccurrences(of: iconPlaceholder, with: iconDataURI)
    }

    private static func userScript(resource: String) -> WKUserScript? {
        source(resource: resource).map {
            WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        }
    }
}
