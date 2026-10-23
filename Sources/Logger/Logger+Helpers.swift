//
//  Logger+Helpers.swift
//  Reefr Common
//
//  Created by Andrey Yurkevich on 21.12.25.
//  Copyright © 2025 Reefr Wallet. All rights reserved.
//

import Foundation

public func printDebug(
    _ message: @autoclosure () -> Any,
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: Int = #line
) {
    Logger.debug(message(), file, function, line)
}

public func printInfo(
    _ message: @autoclosure () -> Any,
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: Int = #line
) {
    Logger.info(message(), file, function, line)
}

public func printWarning(
    _ message: @autoclosure () -> Any,
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: Int = #line
) {
    Logger.warning(message(), file, function, line)
}

public func printError(
    _ message: @autoclosure () -> Any,
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: Int = #line
) {
    Logger.error(message(), file, function, line)
}

public func printVerbose(
    _ message: @autoclosure () -> Any,
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: Int = #line
) {
    Logger.verbose(message(), file, function, line)
}
