import XCTest

final class MoshiSessionTests: XCTestCase {
    @MainActor
    func testOptionalSessionLinkPersistsAndIsAvailableFromGraph() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let project = app.buttons["project:sample/brain:demo"]
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        app.buttons["Project session"].tap()
        // Leave repeat runs independent of a previously saved test shortcut.
        if app.buttons["Edit Moshi link"].exists {
            app.buttons["Edit Moshi link"].tap()
            app.swipeUp()
            app.buttons["Remove link"].tap()
            app.buttons["Project session"].tap()
        }
        app.buttons["Add Moshi link"].tap()
        let session = app.textFields["moshi.session"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save link"].isEnabled)
        session.tap()
        session.typeText("phone-work")
        app.buttons["Save link"].tap()
        app.buttons["Project session"].tap()
        app.buttons["Open in Moshi"].tap()
        // The isolated test simulator has no Moshi handler. A failed handoff
        // keeps the user in Phren and preserves the shortcut.
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.terminate()
        app.launch()
        let graph = app.buttons["Memory graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 15))
        graph.tap()
        XCTAssertTrue(app.webViews.staticTexts["DEMO"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Search graph"].tap()
        let search = app.textFields["Search findings, tasks, projects"]
        search.tap()
        search.typeText("offline")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cache repeated requests")).firstMatch.tap()
        let edit = app.buttons["Edit Moshi link"]
        if !edit.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.buttons["Open in Moshi"].tap()
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        edit.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertEqual(session.value as? String, "phone-work")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Optional Moshi session setup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.swipeUp()
        app.buttons["Remove link"].tap()
        XCTAssertTrue(app.buttons["Add Moshi link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open in Moshi"].exists)
    }
}
