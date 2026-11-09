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

    func testDeletedAccountLeavesSidebarAndStaysDeletedAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        app.terminate()
        let storePath = directory.appending(path: "wallet.sqlite").path
        let storeArguments = [
            "--test", "--store-path", storePath, "--disable-transaction-sync", "--disable-price-updates"
        ]

        app.launchArguments = storeArguments + ["--mnemonic", testMnemonic, "--create-evm-accounts"]
        app.launch()

        let deletedAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Sepolia #1")
        let remainingAccount = app.firstDescendant(withIdentifier: "sidebar-account-label-Sepolia #2")
        XCTAssertTrue(deletedAccount.waitForExistence(timeout: 10))
        XCTAssertTrue(remainingAccount.waitForExistence(timeout: 10))
        deletedAccount.click()
        deletedAccount.rightClick()
        app.menuItems["Delete \"Sepolia #1\""].click()
        app.buttons["Delete"].click()

        XCTAssertTrue(deletedAccount.waitForNonExistence(timeout: 10))
        XCTAssertTrue(remainingAccount.exists)

        app.terminate()
        app.launchArguments = storeArguments
        app.launch()
        XCTAssertTrue(remainingAccount.waitForExistence(timeout: 10))
        XCTAssertFalse(deletedAccount.exists)
    }
}
