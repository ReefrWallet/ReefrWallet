//
//  URLSessionConfiguration+Proxy.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 23.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation

public extension URLSessionConfiguration {
    /// Creates a URLSessionConfiguration with optional proxy settings.
    static func withProxy(_ host: String, port: Int) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default

        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: NSNumber(value: true),
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: NSNumber(value: port),
            // Add HTTPS proxy settings if needed
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSEnable: NSNumber(value: true),
            kCFNetworkProxiesHTTPSPort: NSNumber(value: port)
        ] as CFDictionary as? [String: Any]

        return configuration
    }
}
