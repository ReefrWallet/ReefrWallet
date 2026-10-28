import Foundation

/// Serves a single local HTML fixture over plain HTTP (loopback is exempt
/// from ATS) via Python's built-in `http.server` — a static file server,
/// so no new production networking code is needed just for this test.
struct LocalDappServer {
    let url: URL
    private let process: Process
    private let directory: URL

    static func start(html fixtureHTML: String) async throws -> LocalDappServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dapp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixtureHTML.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let port = UInt16.random(in: 51000 ... 51999)
        let process = Process()
        // Homebrew's real Python binary, not `/usr/bin/python3` — that
        // one is an `xcrun`-dispatching shim (Command Line Tools), and
        // `xcrun` refuses to run at all inside the UI test runner's App
        // Sandbox ("xcrun: error: cannot be used within an App
        // Sandbox."). The absolute path also sidesteps needing `env` to
        // resolve `python3` through a `PATH` the sandboxed runner may
        // not share.
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", directory.path]
        process.currentDirectoryURL = directory
        let logURL = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        let url = URL(string: "http://127.0.0.1:\(port)/index.html")! // swiftlint:disable:this force_unwrapping
        do {
            try await waitUntilReady(url: url)
        } catch {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
            throw NSError(domain: "LocalDappServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "\(error) — isRunning=\(process.isRunning), log:\n\(log)"
            ])
        }

        return LocalDappServer(url: url, process: process, directory: directory)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Polls asynchronously (never blocking the run loop) — a UI test's
    /// `setUp()` runs early in the runner process's life, and blocking
    /// it synchronously here can starve XCTest's own automation-mode
    /// handshake.
    private static func waitUntilReady(url: URL) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        var lastError: Error?

        while Date.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                lastError = error
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw lastError ?? NSError(domain: "LocalDappServer", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "fixture server at \(url) never became ready"
        ])
    }
}
