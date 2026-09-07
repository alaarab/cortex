import XCTest

final class GraphInteractionTests: XCTestCase {
    @MainActor
    func testFocusSaveAndRestoreGraphView() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let graph = app.buttons["Memory graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 15))
        graph.tap()
        // The native search is available before WKWebView has mounted its
        // graph. Wait for rendered content before issuing camera commands.
        XCTAssertTrue(app.webViews.staticTexts["DEMO"].firstMatch.waitForExistence(timeout: 20))
        let search = app.buttons["Search graph"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let field = app.textFields["Search findings, tasks, projects"]
        field.tap()
        field.typeText("offline")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cache repeated requests")).firstMatch.tap()
        let focus = app.buttons["Focus connections"]
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        focus.tap()
        XCTAssertTrue(app.buttons["Show full view"].waitForExistence(timeout: 5))
        app.buttons["Graph options"].tap()
        app.buttons["Save this view"].tap()
        let name = "Offline view \(UUID().uuidString.prefix(6))"
        let nameField = app.alerts.textFields.firstMatch
        nameField.tap()
        nameField.typeText(name)
        XCTAssertEqual(nameField.value as? String, name)
        app.alerts.buttons["Save"].tap()
        app.buttons["Show full view"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(graph.waitForExistence(timeout: 15))
        graph.tap()
        app.buttons["Store: sample/brain"].tap()
        app.buttons["team/brain"].tap()
        XCTAssertTrue(app.buttons["Store: team/brain"].waitForExistence(timeout: 5))
        app.buttons["Graph options"].tap()
        app.buttons["Saved views"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.tap()
        XCTAssertTrue(app.buttons["Show full view"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Store: sample/brain"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Saved graph connections"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSkillAvailabilityStartsUnknownAndCanBeEnabledAndDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["Skills"].waitForExistence(timeout: 15))
        app.buttons["Skills"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "audit")).firstMatch.tap()
        let enable = app.buttons["Enable on linked computers"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()
        let toggle = app.switches["Enabled for agents"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI exposes the whole row and the control as separate switches.
        // Target the visible control rather than the label's center.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let disabled = NSPredicate(format: "value == '0'")
        expectation(for: disabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }
}
