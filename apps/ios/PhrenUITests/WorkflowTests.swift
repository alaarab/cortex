import XCTest

final class WorkflowTests: XCTestCase {
    @MainActor
    func testBacklogIsOptionalAndLongTasksStayScannable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Agents"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.buttons["Review"].exists)
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["No tasks marked active"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["task-detail:sample/brain/demo/dead0001"].exists)
        let activeScreenshot = XCTAttachment(screenshot: app.screenshot())
        activeScreenshot.name = "Calm active tasks state"
        activeScreenshot.lifetime = .keepAlways
        add(activeScreenshot)
        app.buttons["View backlog (6)"].tap()
        let long = app.buttons["task-detail:sample/brain/demo/dead0001"]
        XCTAssertTrue(long.waitForExistence(timeout: 5))
        XCTAssertLessThan(long.frame.height, 180)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Scannable backlog with full task details on demand"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        long.tap()
        XCTAssertTrue(app.navigationBars["Task details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "END OF PLAN")).firstMatch.exists)
        app.navigationBars.buttons["Done"].tap()
        app.segmentedControls.buttons["Active"].tap()
        XCTAssertTrue(app.staticTexts["No tasks marked active"].waitForExistence(timeout: 5))
        app.buttons["View agents"].tap()
        XCTAssertTrue(app.navigationBars["Live sessions"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMaintenanceGroupsByStoreAndOffersAnAgentRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()
        let maintenance = app.buttons["Memory maintenance"]
        if !maintenance.isHittable { app.swipeUp() }
        XCTAssertTrue(maintenance.waitForExistence(timeout: 5))
        maintenance.tap()
        let personal = app.buttons["maintenance-project:sample/brain:demo"]
        let team = app.buttons["maintenance-project:team/brain:demo"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertTrue(team.exists)
        XCTAssertFalse(app.staticTexts["Candidate for team memory"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Optional maintenance grouped by project and store"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        team.tap()
        XCTAssertTrue(app.staticTexts["Candidate for team memory"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Candidate for sample memory"].exists)
        XCTAssertFalse(app.buttons["Triage"].exists)
        app.staticTexts["Candidate for team memory"].tap()
        XCTAssertTrue(app.navigationBars["Memory entry"].waitForExistence(timeout: 5))
        app.navigationBars["Memory entry"].buttons["Done"].tap()
        app.buttons["Copy request for my agent"].tap()
        XCTAssertTrue(app.buttons["Agent request copied"].waitForExistence(timeout: 5))
        app.buttons["Select"].tap()
        XCTAssertTrue(app.staticTexts["None selected"].waitForExistence(timeout: 5))
        app.staticTexts["Candidate for team memory"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Memory entry"].exists)
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["3 selected"].waitForExistence(timeout: 5))
        app.buttons["Deselect All"].tap()
        XCTAssertTrue(app.staticTexts["None selected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Candidate for team memory"].exists)
    }
}
