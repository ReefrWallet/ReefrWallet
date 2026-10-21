//
//  PreferredBrowser.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 21.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opens web URLs in the browser picked in Settings, or the system default
/// when none is picked or it is no longer installed (ADR-038).
enum PreferredBrowser {
    static let bundleIdKey = "PreferredBrowserBundleId"

    /// Opens `url` unless its scheme isn't http(s): dapp metadata is untrusted.
    @MainActor
    static func open(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            printDebug("Refusing to open \(url.scheme ?? "scheme-less") URL in browser")
            return
        }

        #if os(macOS)
        let bundleId = UserDefaults.standard.string(forKey: bundleIdKey) ?? ""
        guard !bundleId.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else {
            NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

#if os(macOS)
extension PreferredBrowser {
    struct App: Identifiable {
        let bundleId: String
        let name: String

        var id: String {
            bundleId
        }
    }

    /// Installed apps that open https URLs, sorted by name.
    static var installedApps: [App] {
        guard let probe = URL(string: "https://example.com") else {
            return []
        }

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { appURL -> App? in
            guard let bundle = Bundle(url: appURL),
                  let bundleId = bundle.bundleIdentifier
            else {
                return nil
            }

            let name = FileManager.default.displayName(atPath: appURL.path(percentEncoded: false))
            return App(bundleId: bundleId, name: (name as NSString).deletingPathExtension)
        }

        var seen = Set<String>()
        return apps
            .filter { seen.insert($0.bundleId).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
