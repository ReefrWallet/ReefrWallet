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

        var proxyDictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable: NSNumber(value: true),
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: NSNumber(value: port)
        ]

        #if os(macOS) // Add HTTPS proxy settings if needed
        proxyDictionary[kCFNetworkProxiesHTTPSProxy] = host
        proxyDictionary[kCFNetworkProxiesHTTPSEnable] = NSNumber(value: true)
        proxyDictionary[kCFNetworkProxiesHTTPSPort] = NSNumber(value: port)
        #endif

        configuration.connectionProxyDictionary = proxyDictionary

        return configuration
    }
}
