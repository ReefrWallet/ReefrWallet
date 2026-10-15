// Unit tests for DappScripts — the injected `bridge.js` gets the wallet
// icon from `dapp-icon.svg` as a `data:` URI, and every enabled
// namespace's scripts are found in the app bundle.

import Foundation
import Testing
@testable import ReefrWallet

struct DappScriptsTests {
    @Test func bridgeAnnouncesTheBundledSVGIconAsADataURI() throws {
        let source = try #require(DappScripts.source(resource: "bridge"))
        let iconURL = try #require(Bundle.main.url(forResource: "dapp-icon", withExtension: "svg"))
        let expected = try "data:image/svg+xml;base64," + Data(contentsOf: iconURL).base64EncodedString()

        #expect(!source.contains(DappScripts.iconPlaceholder))
        #expect(source.contains("var ICON = '\(expected)';"))
    }

    @Test func iconDecodesToAnSVGDocument() throws {
        let uri = try #require(DappScripts.iconDataURI)
        let prefix = "data:image/svg+xml;base64,"
        #expect(uri.hasPrefix(prefix))

        let data = try #require(Data(base64Encoded: String(uri.dropFirst(prefix.count))))
        let svg = try #require(String(data: data, encoding: .utf8))
        #expect(svg.hasPrefix("<svg"))
    }

    /// `WKUserScript` is main-actor bound.
    @MainActor
    @Test func userScriptsIncludeBridgeCoreAndEveryProvider() {
        let scripts = DappScripts.userScripts(for: DappNamespace.allCases)
        let expectedCount = 2 + DappNamespace.allCases.reduce(0) { $0 + $1.scriptNames.count }

        #expect(scripts.count == expectedCount)
        #expect(scripts.allSatisfy { !$0.source.contains(DappScripts.iconPlaceholder) })
    }
}
