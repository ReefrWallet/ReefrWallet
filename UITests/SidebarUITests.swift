//
//  SidebarUITests.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 16.09.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import XCTest
import XCUIAutomation

final class SidebarUITests: XCTestCase {
    func testWindowAppears() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.terminate()
    }
}
