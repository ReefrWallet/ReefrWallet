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
        Logger.verbose("Dapp web view: navigation failed: \(error)")
        controller.updateNavigationState()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Swift.Error
    ) {
        Logger.verbose("Dapp web view: provisional navigation failed: \(error)")
        controller.updateNavigationState()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        controller.updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        controller.updateNavigationState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.verbose("Dapp web view: web content process terminated")
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
        let target = navigationAction.request.url
        Logger.verbose("Dapp web view: navigation \(navigationAction.navigationType.rawValue) → \(target?.absoluteString ?? "nil")")

        guard
            navigationAction.navigationType == .linkActivated,
            let url = target,
            !controller.isWithinDappDomain(url)
        else {
            decisionHandler(.allow)
            return
        }

        Logger.verbose("Dapp web view: opening cross-domain link externally: \(url)")
        controller.openExternally(url)
        decisionHandler(.cancel)
    }
}

#if DEBUG
/// Forwards the page's uncaught errors, unhandled rejections and
/// `console.error` calls to the log — dapps often swallow a failed request.
extension DappWebView.Coordinator: WKScriptMessageHandler {
    static let pageLogHandlerName = "reefrPageLog"

    static let pageLogScript = """
    (() => {
        const post = window.webkit.messageHandlers.\(pageLogHandlerName);
        const send = (kind, detail) => post.postMessage({ kind, detail: String(detail) });
        const describe = (value) => value instanceof Error
            ? `${value.name}: ${value.message}`
            : (typeof value === 'string' ? value : JSON.stringify(value));
        window.addEventListener('error', (event) => {
            send('error', `${event.message} (${event.filename}:${event.lineno})`);
        });
        window.addEventListener('unhandledrejection', (event) => {
            send('unhandledrejection', describe(event.reason));
        });
        const original = console.error.bind(console);
        console.error = (...args) => {
            send('console.error', args.map(describe).join(' '));
            original(...args);
        };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            return
        }

        let text = "\(body["detail"] ?? "")"
        Logger.verbose("Dapp page \(body["kind"] ?? "log"): \(text.prefix(800))")
    }
}
#endif

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
            Logger.verbose("Dapp web view: window.open without a URL ignored")
            return nil
        }

        if controller.isWithinDappDomain(url) {
            Logger.verbose("Dapp web view: window.open loaded in place: \(url)")
            webView.load(navigationAction.request)
        } else {
            Logger.verbose("Dapp web view: window.open opened externally: \(url)")
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

        #if DEBUG
        configuration.userContentController.addUserScript(
            WKUserScript(source: Coordinator.pageLogScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        configuration.userContentController.add(coordinator, name: Coordinator.pageLogHandlerName)
        #endif

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
