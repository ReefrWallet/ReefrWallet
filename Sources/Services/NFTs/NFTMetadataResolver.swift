//
//  NFTMetadataResolver.swift
//  Reefr Wallet
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Resolves NFT metadata JSON (name, image) from `https`, `ipfs` and `data`
/// URIs. Best effort: a failure is recorded on the row and retried a day later.
struct NFTMetadataResolver: Sendable {
    struct Metadata: Equatable, Sendable {
        let image: String?
        let name: String?
    }

    static let ipfsGateway = "https://ipfs.io/ipfs/"
    static let retryInterval: TimeInterval = 24 * 3600
    private static let maxBytes = 1_000_000

    var session: URLSession = .shared

    /// An `http(s)` URL for `uri`, rewriting `ipfs://` and `ar://`; `data:` is kept.
    static func displayURL(_ uri: String) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("ipfs://") {
            let path = trimmed.dropFirst("ipfs://".count)
            return URL(string: ipfsGateway + (path.hasPrefix("ipfs/") ? String(path.dropFirst(5)) : String(path)))
        }

        if trimmed.hasPrefix("ar://") {
            return URL(string: "https://arweave.net/" + trimmed.dropFirst("ar://".count))
        }

        guard let url = URL(string: trimmed), ["data", "http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }

        return url
    }

    func resolve(_ uri: String) async throws -> Metadata {
        guard let url = Self.displayURL(uri) else {
            throw URLError(.unsupportedURL)
        }

        let data: Data
        if url.scheme == "data" {
            data = try Self.decodeDataURI(url.absoluteString)
        } else {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (body, response) = try await session.data(for: request)

            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw URLError(.badServerResponse)
            }

            data = body.prefix(Self.maxBytes)
        }

        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Metadata {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let image = (json["image"] as? String) ?? (json["image_url"] as? String) ?? (json["imageUrl"] as? String)
        return Metadata(image: image, name: json["name"] as? String)
    }

    /// The payload of a `data:` URI, base64 or percent-encoded.
    static func decodeDataURI(_ uri: String) throws -> Data {
        guard let comma = uri.firstIndex(of: ",") else {
            throw URLError(.cannotDecodeContentData)
        }

        let header = uri[..<comma]
        let payload = String(uri[uri.index(after: comma)...])

        if header.hasSuffix(";base64") {
            guard let data = Data(base64Encoded: payload) else {
                throw URLError(.cannotDecodeContentData)
            }

            return data
        }

        return Data((payload.removingPercentEncoding ?? payload).utf8)
    }
}
