//
//  DappWebViewController.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owns the `WKWebView` reference for ``DappWebView`` (an
/// `NSViewRepresentable`/`UIViewRepresentable`, so it can't hold state of
/// its own across updates) — navigation controls
/// (back/forward/reload/load) and the navigation-state SwiftUI reads for
/// the toolbar.
@MainActor
@Observable
final class DappWebViewController {
    let bridge: DappBridge

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var currentURLString = ""
    private(set) var isLoading = false

    fileprivate weak var webView: WKWebView?

    @ObservationIgnored private var lastCrashReload: ContinuousClock.Instant?

    init(bridge: DappBridge) {
        self.bridge = bridge
    }

    /// Loads `text` as a URL, defaulting to `https://` when no scheme is
    /// given — what the address bar's submit action calls.
    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let string = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: string) else {
            return
        }

        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    /// Reloads the page after its web content process died (e.g. a WebKit
    /// crash), which otherwise leaves it blank. A second death within
    /// ``crashReloadInterval`` of that reload leaves the page as is, so a
    /// page that keeps crashing doesn't loop.
    func webContentProcessDidTerminate() {
        defer { updateNavigationState() }

        let now = ContinuousClock.now
        if let lastCrashReload, now - lastCrashReload < Self.crashReloadInterval {
            printDebug("Web content process terminated again; not reloading")
            return
        }

        lastCrashReload = now
        if webView?.reload() == nil {
            load(currentURLString)
        }
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        updateNavigationState()
    }

    func updateNavigationState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        isLoading = webView?.isLoading ?? false
        if let url = webView?.url {
            currentURLString = url.absoluteString
        }
    }

    /// Whether `url` shares its host with the page currently loaded —
    /// the bar for "same dApp" that keeps link navigation inside this
    /// browser instead of handing off to the system browser.
    func isWithinDappDomain(_ url: URL) -> Bool {
        url.host != nil && url.host == webView?.url?.host
    }

    /// Hands a cross-domain link off to the system browser instead of
    /// loading it into the in-app dApp WebView.
    ///
    /// Web schemes only. The page decides what lands here — a script's
    /// `window.open` reaches it with no user gesture — and the system opener
    /// acts on far more than web URLs: a `file:` URL opens a local file in its
    /// default app, and a custom scheme launches whatever app registered it.
    /// Anything else is dropped rather than handed to the OS.
    func openExternally(_ url: URL) {
        guard Self.externallyOpenableSchemes.contains(url.scheme?.lowercased() ?? "") else {
            printDebug("Refusing to open \(url.scheme ?? "scheme-less") URL externally")
            return
        }

        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private static let crashReloadInterval = Duration.seconds(10)
    private static let externallyOpenableSchemes: Set<String> = ["http", "https"]
}
