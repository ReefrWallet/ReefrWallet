//
//  Logger.swift
//  Reefr Common
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation
import SwiftyBeaver

final class Logger {
    static let shared = Logger()

    /// Whether verbose messages are logged: pass `--verbose` on the command line.
    static let isVerbose = CommandLine.arguments.contains("--verbose")

    private init() {
        let console = ConsoleDestination()
        console.levelString.verbose = "VERBOSE"
        console.levelString.debug = "DEBUG"
        console.levelString.info = "INFO"
        console.levelString.warning = "WARNING"
        console.levelString.error = "ERROR"

        console.format = "$DHH:mm:ss.SSS$d $C$L: $T $N.$F: $M (at $n:$l)"
        console.minLevel = .verbose
        console.asynchronously = false
        SwiftyBeaver.addDestination(console)
    }

    static func trace(
        _ level: SwiftyBeaver.Level,
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
        Logger.shared.custom(level, message(), file, function, line: line, context: nil)
    }

    func custom(
        _ level: SwiftyBeaver.Level,
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        line: Int = #line,
        context: Any? = nil
    ) {
#if DEBUG
        guard level != .verbose || Self.isVerbose else {
            return
        }

        SwiftyBeaver.custom(
            level: level,
            message: "\(message())",
            file: String(describing: file),
            function: String(describing: function),
            line: line,
            context: nil
        )
#endif
    }

    // MARK: Levels

    /// Logs a trace message (lowest priority)
    static func verbose(
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        _ line: Int = #line,
        context: Any? = nil
    ) {
        Logger.trace(.verbose, message(), file, function, line: line, context: context)
    }

    /// Logs a debugging message (low priority)
    static func debug(
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        _ line: Int = #line,
        context: Any? = nil
    ) {
        Logger.trace(.debug, message(), file, function, line: line, context: context)
    }

    /// Logs an informational message (normal priority)
    static func info(
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        _ line: Int = #line,
        context: Any? = nil
    ) {
        Logger.trace(.info, message(), file, function, line: line, context: context)
    }

    /// Logs a warning (high priority)
    static func warning(
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        _ line: Int = #line,
        context: Any? = nil
    ) {
        Logger.trace(.warning, message(), file, function, line: line, context: context)
    }

    /// Logs an error (highest priority)
    static func error(
        _ message: @autoclosure () -> Any,
        _ file: StaticString = #file,
        _ function: StaticString = #function,
        _ line: Int = #line,
        context: Any? = nil
    ) {
        Logger.trace(.error, message(), file, function, line: line, context: context)
    }
}
