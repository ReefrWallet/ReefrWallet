//
//  SidebarUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 16.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

private let testMnemonic = "test test test test test test test test test test test junk"

final class SidebarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication(bundleIdentifier: "xyz.reefr.wallet")
        app.launchArguments = ["--test", "--mnemonic", testMnemonic]
        app.launch()
        app.activate()
    }

    func testWindowAppears() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
