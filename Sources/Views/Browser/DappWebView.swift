//
//  DappWebView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 25.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WebKit

/// Hosts a `WKWebView` wired up to a ``DappBridge`` — the injected
/// providers' scripts (``DappScripts``), the `reefr` message handler, and
/// navigation-state reporting back to ``DappWebViewController``.
struct DappWebView {
    let controller: DappWebViewController
    let initialURL: URL

    final class Coordinator: NSObject {
        let controller: DappWebViewController

        init(controller: DappWebViewController) {
            self.controller = controller
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }
}

extension DappWebView.Coordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        controller.updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Swift.Error) {
        controller.updateNavigationState()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Swift.Error
    ) {
        controller.updateNavigationState()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        controller.updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        controller.updateNavigationState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller.webContentProcessDidTerminate()
    }

    /// Keeps in-dApp-domain link clicks navigating inside this WebView;
    /// hands cross-domain links off to the system browser instead of
    /// letting the dApp browser navigate away from the dApp.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard
            navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url,
            !controller.isWithinDappDomain(url)
        else {
            decisionHandler(.allow)
            return
        }

        controller.openExternally(url)
        decisionHandler(.cancel)
    }
}

extension DappWebView.Coordinator: WKUIDelegate {
    /// `target="_blank"`/`window.open` links have no window to open
    /// into by default, so WebKit silently drops them. Same-domain
    /// requests load into this WebView; cross-domain ones go to the
    /// system browser.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        if controller.isWithinDappDomain(url) {
            webView.load(navigationAction.request)
        } else {
            controller.openExternally(url)
        }

        return nil
    }
}

private extension DappWebView {
    @MainActor
    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        for script in DappScripts.userScripts(for: DappNamespace.allCases) {
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if os(macOS)
        webView.underPageBackgroundColor = .windowBackgroundColor
        #else
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        #endif
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        controller.bridge.attach(to: webView)
        controller.attach(to: webView)
        webView.load(URLRequest(url: initialURL))
        return webView
    }
}

#if os(macOS)
extension DappWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension DappWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
