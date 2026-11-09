//
//  WebImageView.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 12.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import ImageIO
import SwiftUI

struct WebImageView: View {
    let url: URL?

    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        Group {
            if let loaded, loaded.url == url {
                Image(decorative: loaded.image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderView
            }
        }
        .task(id: url) {
            guard let url, loaded?.url != url else {
                return
            }

            if let image = await TokenImageCache.shared.image(at: url), !Task.isCancelled {
                loaded = (url, image)
            }
        }
    }
}

private actor TokenImageCache {
    static let shared = TokenImageCache()

    private let images = NSCache<NSURL, CGImage>()
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        images.totalCostLimit = 16 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            directory: .cachesDirectory.appending(path: "TokenImages", directoryHint: .isDirectory)
        )

        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func image(at url: URL) async -> CGImage? {
        let key = url as NSURL
        if let image = images.object(forKey: key) {
            return image
        }

        if let task = inFlight[url] {
            return await task.value
        }

        let session = session
        let task = Task<CGImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 128
            ]

            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }

        return image
    }
}

private extension WebImageView {
    var placeholderView: some View {
        ZStack(alignment: .center) {
            Color.secondary

            Text("?")
                .style(.largeHeader, foreground: .secondary)
        }
    }
}
