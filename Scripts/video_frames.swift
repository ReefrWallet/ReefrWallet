#!/usr/bin/env swift
// Extracts every Nth frame of a video as PNG (for debugging animations).
// Usage: Scripts/video_frames.swift <video.mp4> [every-n-frames=1] [out-dir]
// Output: <out-dir>/frame_<index>_<time>.png (default out-dir: <video>-frames)

import AVFoundation
import AppKit

func write(_ message: String, to handle: FileHandle) {
    handle.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    write("error: \(message)", to: .standardError)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: video_frames.swift <video.mp4> [every-n-frames=1] [out-dir]")
}

let videoUrl = URL(fileURLWithPath: args[1])
let step = args.count > 2 ? Int(args[2]) ?? 0 : 1
guard step > 0 else {
    fail("every-n-frames must be a positive integer")
}

let outUrl = args.count > 3
    ? URL(fileURLWithPath: args[3])
    : videoUrl.deletingPathExtension().appendingPathExtension("frames")
try FileManager.default.createDirectory(at: outUrl, withIntermediateDirectories: true)

let asset = AVURLAsset(url: videoUrl)
guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    fail("no video track in \(videoUrl.path)")
}

let fps = try await track.load(.nominalFrameRate)
let duration = try await asset.load(.duration)
guard fps > 0 else {
    fail("unknown frame rate")
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let timescale = CMTimeScale(fps * 1000)
let frameCount = Int(duration.seconds * Double(fps))
var saved = 0

for index in stride(from: 0, to: frameCount, by: step) {
    let time = CMTime(value: CMTimeValue(Double(index) / Double(fps) * Double(timescale)), timescale: timescale)
    guard let image = try? await generator.image(at: time).image else {
        write("skip frame \(index)", to: .standardError)
        continue
    }

    let name = String(format: "frame_%05d_%07.3fs.png", index, time.seconds)
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    try png?.write(to: outUrl.appendingPathComponent(name))
    saved += 1
}

write("\(saved) frames (\(fps) fps, every \(step)) → \(outUrl.path)", to: .standardOutput)
