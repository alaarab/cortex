import XCTest

final class AutomaticSessionTests: XCTestCase {
    @MainActor
    func testProjectFindsOneSessionAndOpensWithoutEditingALink() {
        let app = launch()
        openProjectSession(app)
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Build phone app"].exists)
        XCTAssertFalse(app.staticTexts["Unrelated session"].exists)
        XCTAssertFalse(app.textFields["moshi.session"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Project session discovered without a manual Moshi link"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMultipleMatchesOfferRealSessionsInsteadOfGuessing() {
        let app = launch(extra: ["--multiple-project-sessions"])
        openProjectSession(app)
        XCTAssertTrue(app.staticTexts["Review phone changes"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Build phone app"].exists)
        XCTAssertFalse(app.alerts["Couldn't open Moshi"].exists)
        XCTAssertFalse(app.staticTexts["Unrelated session"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Choose between discovered sessions in the same project"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["discovered-session:A1000000-0000-0000-0000-000000000001:w7:w7:t10"].tap()
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["moshi.session"].exists)
    }

    @MainActor
    func testLiveRowRecognizesProjectAndGraphCanResumeItsSession() {
        let app = launch()
        app.tabBars.buttons["Agents"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Test Mac,")).firstMatch.tap()
        let graph = app.buttons["live-graph:sample/brain:phone"]
        XCTAssertTrue(graph.waitForExistence(timeout: 10))
        // This row can hand off even though no manual project/session link exists.
        app.buttons["Open in Moshi"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        graph.tap()
        XCTAssertTrue(app.webViews.staticTexts["PHONE"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Search graph"].tap()
        let search = app.textFields["Search findings, tasks, projects"]
        search.tap(); search.typeText("phone sessions")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Keep phone sessions connected")).firstMatch.tap()
        let open = app.buttons["Open in Moshi"]
        if !open.isHittable { app.collectionViews.firstMatch.swipeUp() }
        open.tap()
        XCTAssertTrue(app.alerts["Couldn't open Moshi"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["moshi.session"].exists)
    }

    @MainActor
    func testOfflineComputerDoesNotInventOrOpenASession() {
        let app = launch(extra: ["--session-discovery-offline"])
        openProjectSession(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "connection closed")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts["Couldn't open Moshi"].exists)
        XCTAssertFalse(app.staticTexts["Build phone app"].exists)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--automatic-sessions-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["project:sample/brain:phone"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func openProjectSession(_ app: XCUIApplication) {
        app.buttons["project:sample/brain:phone"].tap()
        app.buttons["Project session"].tap()
        app.buttons["Open in Moshi"].tap()
    }
}
