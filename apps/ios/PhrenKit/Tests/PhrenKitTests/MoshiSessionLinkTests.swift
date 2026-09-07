import XCTest
@testable import PhrenKit

final class MoshiSessionLinkTests: XCTestCase {
    func testNamesAreEncodedWithoutInjectingParametersOrChangingPlusSigns() throws {
        let name = "my project + café &pane=9#100%"
        let link = try MoshiSessionLink(multiplexer: .tmux, session: name, window: "3", pane: "%5")
        let url = try link.url()
        XCTAssertEqual(url.scheme, "moshi")
        XCTAssertEqual(url.host, "tmux")
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [URLQueryItem(name: "session", value: name), URLQueryItem(name: "window", value: "3"), URLQueryItem(name: "pane", value: "%5")])
    }

    func testHerdrDefaultsAndStableWorkspaceTabAndPaneIDs() throws {
        let link = try MoshiSessionLink(multiplexer: .herdr, session: "", workspace: "w/api", tab: "w1:t1", pane: "w1:p2")
        XCTAssertEqual(try link.url().absoluteString, "moshi://herdr?session=default&workspace=w%2Fapi&tab=w1%3At1&pane=w1%3Ap2")
        let named = try MoshiSessionLink(multiplexer: .herdr, session: " work ")
        XCTAssertEqual(try named.url().absoluteString, "moshi://herdr?session=work")
        XCTAssertFalse(try named.url().absoluteString.contains("hostId"))
    }

    func testRejectsUnsupportedWindowPaneAndControlCharacters() {
        XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .tmux, session: " "))
        for window in ["10", "-1", "a", "1&pane=2"] {
            XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .tmux, session: "work", window: window))
        }
        for pane in ["%", "1.2", "pane-1", "1; exit"] {
            XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .tmux, session: "work", pane: pane))
        }
        for session in ["one\ntwo", "work\u{0}session", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .herdr, session: session))
        }
        XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .herdr, session: "work", window: "1"))
        XCTAssertThrowsError(try MoshiSessionLink(multiplexer: .tmux, session: "work", workspace: "w1"))
    }

    func testLinksStaySeparateAcrossStoresAndSurviveEditingAndRemoval() throws {
        let personal = try MoshiSessionLink(multiplexer: .tmux, session: "personal")
        let team = try MoshiSessionLink(multiplexer: .herdr, session: "team", workspace: "w1")
        let other = try MoshiSessionLink(multiplexer: .tmux, session: "other")
        var data = try ProjectSessionLinks.setting(personal, storeID: "me/brain", project: "app", in: Data())
        data = try ProjectSessionLinks.setting(team, storeID: "team/brain", project: "app", in: data)
        data = try ProjectSessionLinks.setting(other, storeID: "me/brain", project: "other", in: data)
        let restored = try ProjectSessionLinks.read(data)
        XCTAssertEqual(restored.link(storeID: "me/brain", project: "app"), personal)
        XCTAssertEqual(restored.link(storeID: "team/brain", project: "app"), team)
        XCTAssertNil(restored.link(storeID: "third/brain", project: "app"))
        data = try ProjectSessionLinks.setting(team, storeID: "me/brain", project: "app", in: data)
        XCTAssertEqual(try ProjectSessionLinks.read(data).entries.count, 3)
        data = try ProjectSessionLinks.setting(nil, storeID: "me/brain", project: "app", in: data)
        let removed = try ProjectSessionLinks.read(data)
        XCTAssertNil(removed.link(storeID: "me/brain", project: "app"))
        XCTAssertEqual(removed.link(storeID: "team/brain", project: "app"), team)
        XCTAssertEqual(removed.link(storeID: "me/brain", project: "other"), other)
    }

    func testVersionOneFixtureAndUnreadableDocumentsArePreserved() throws {
        let fixture = #"{"schemaVersion":1,"entries":[{"storeID":"me/brain","project":"app","link":{"multiplexer":"herdr","session":"work","workspace":"w1","window":"","tab":"w1:t1","pane":"w1:p2"}}]}"#
        let document = try ProjectSessionLinks.read(Data(fixture.utf8))
        XCTAssertEqual(try document.link(storeID: "me/brain", project: "app")?.url().absoluteString,
                       "moshi://herdr?session=work&workspace=w1&tab=w1%3At1&pane=w1%3Ap2")
        for content in ["broken", "[]", #"{"schemaVersion":2,"entries":[]}"#,
                        fixture.replacingOccurrences(of: "herdr", with: "unknown"),
                        fixture.replacingOccurrences(of: #""window":"""#, with: #""window":"12""#)] {
            let original = Data(content.utf8)
            XCTAssertThrowsError(try ProjectSessionLinks.setting(nil, storeID: "me/brain", project: "app", in: original))
            XCTAssertEqual(String(decoding: original, as: UTF8.self), content)
        }
    }
}
