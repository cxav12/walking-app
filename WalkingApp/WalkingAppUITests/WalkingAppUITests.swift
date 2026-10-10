//
//  WalkingAppUITests.swift
//  WalkingAppUITests
//
//  Created by Xavier Chamorro on 10/1/26.
//

import XCTest

final class WalkingAppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSettingsContainsProfileGoalAndHealth() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.buttons["Connect Apple Health"].exists)
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.buttons["Connect Apple Health"].waitForExistence(timeout: 5))
        app.buttons["editDailyGoal"].tap()
        XCTAssertTrue(app.textFields["dailyGoalInput"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons.containing(.staticText, identifier: "Your name").firstMatch.tap()
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 5))
        app.buttons["Not now"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect Apple Health"].exists)
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
