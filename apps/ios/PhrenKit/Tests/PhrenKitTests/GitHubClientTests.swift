import XCTest
@testable import PhrenKit

/// Canned-response `URLProtocol`: routes are matched by substring of the
/// request URL and consumed in order, so pagination and follow-up requests can
/// be scripted. The last response for a route is sticky.
final class StubURLProtocol: URLProtocol {
    struct Stubbed {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Stubbed]] = [:]
    nonisolated(unsafe) private static var log: [(method: String, url: String)] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        log = []
    }

    static func stub(_ urlContains: String, status: Int,
                     headers: [String: String] = [:], body: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        routes[urlContains, default: []].append(Stubbed(status: status, headers: headers, body: body))
    }

    static var requests: [(method: String, url: String)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func take(url: String, method: String) -> Stubbed {
        lock.lock(); defer { lock.unlock() }
        log.append((method, url))
        // Longest match wins ("contents/phren.root.yaml" beats "repos/"), with
        // alphabetical order breaking ties so routing never depends on the
        // dictionary's iteration order.
        let key = routes.keys
            .filter { url.contains($0) }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .first
        guard let key, var queued = routes[key], !queued.isEmpty else {
            return Stubbed(status: 404, headers: [:], body: #"{"message":"Not Found"}"#)
        }
        let next = queued.removeFirst()
        routes[key] = queued.isEmpty ? [next] : queued
        return next
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stubbed = Self.take(url: request.url?.absoluteString ?? "",
                                method: request.httpMethod ?? "GET")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stubbed.status,
                                             httpVersion: "HTTP/1.1", headerFields: stubbed.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stubbed.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Error wording (what a user is told to fix) and the request classification
/// that decides which wording applies.
final class GitHubErrorMessageTests: XCTestCase {
    func testNotFoundOnRepoPathBlamesTokenScopeNotAMissingRepo() {
        let error = GitHubError.http(status: 404, message: "Not Found", method: "GET",
                                     path: "repos/octo/phren-store/contents/phren.root.yaml")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("octo/phren-store"), description)
        XCTAssertTrue(description.contains("Repository access"), description)
        XCTAssertTrue(description.contains("Contents: Read and write"), description)
        XCTAssertTrue(description.contains("Metadata: Read"), description)
        XCTAssertFalse(description.contains("GitHub API error"), description)
    }

    func testForbiddenWriteNamesTheRepoAndTheMissingPermission() {
        let error = GitHubError.http(status: 403, message: "Resource not accessible",
                                     method: "PUT", path: "repos/octo/phren-store/contents/myproj/tasks.md")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("can't write to octo/phren-store"), description)
        XCTAssertTrue(description.contains("Contents: Read and write"), description)
    }

    func testForbiddenReadKeepsTheGenericMessage() {
        let error = GitHubError.http(status: 403, message: "Forbidden", method: "GET",
                                     path: "repos/octo/phren-store/git/trees/abc")
        XCTAssertEqual(error.errorDescription, "GitHub API error 403: Forbidden")
    }

    func testUnauthorizedAlwaysMeansTheTokenIsDead() {
        let error = GitHubError.http(status: 401, message: "Bad credentials", method: "GET", path: "user")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("expired or been revoked"), description)
        XCTAssertTrue(description.contains("Sign out"), description)
    }

    func testNonRepoPathsFallBackToTheGenericMessage() {
        let error = GitHubError.http(status: 404, message: "Not Found", method: "GET", path: "user/repos")
        XCTAssertEqual(error.errorDescription, "GitHub API error 404: Not Found")
        XCTAssertNil(GitHubError.repoSlug(from: "user"))
        XCTAssertEqual(GitHubError.repoSlug(from: "repos/o/r/git/trees/x?recursive=1"), "o/r")
    }

    func testRateLimitDescriptionCarriesTheDelay() {
        let secondary = GitHubError.rateLimited(resetAt: nil, retryAfter: 45)
        XCTAssertEqual(secondary.errorDescription,
                       "GitHub is throttling requests (secondary rate limit) — retry in 45 seconds.")
        let primary = GitHubError.rateLimited(resetAt: Date().addingTimeInterval(600), retryAfter: nil)
        XCTAssertTrue((primary.errorDescription ?? "").contains("10 minutes"))
    }
}

/// Throttle classification: which 403s are rate limits and which are real
/// permission failures.
final class GitHubClientTests: XCTestCase {
    private func makeClient() -> GitHubClient {
        GitHubClient(session: StubURLProtocol.session(), token: "test-token")
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Rate limits

    func testSecondaryRateLimitIsReportedAsThrottlingNotPermissions() async {
        StubURLProtocol.stub("user/repos", status: 403,
                             headers: ["retry-after": "60", "x-ratelimit-remaining": "4987"],
                             body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        do {
            _ = try await makeClient().listRepos()
            XCTFail("expected a rate-limit error")
        } catch let error as GitHubError {
            guard case .rateLimited(_, let retryAfter) = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 60)
            XCTAssertTrue((error.errorDescription ?? "").contains("throttling"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSecondaryRateLimitWithoutRetryAfterIsStillThrottling() async {
        StubURLProtocol.stub("user/repos", status: 403,
                             headers: ["x-ratelimit-remaining": "4987"],
                             body: #"{"message":"You have exceeded a secondary rate limit. Please wait."}"#)
        do {
            _ = try await makeClient().listRepos()
            XCTFail("expected a rate-limit error")
        } catch let error as GitHubError {
            guard case .rateLimited = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPrimaryRateLimitCarriesTheResetTime() async {
        let reset = Date().addingTimeInterval(300).timeIntervalSince1970
        StubURLProtocol.stub("user/repos", status: 403,
                             headers: ["x-ratelimit-remaining": "0",
                                       "x-ratelimit-reset": "\(Int(reset))"],
                             body: #"{"message":"API rate limit exceeded"}"#)
        do {
            _ = try await makeClient().listRepos()
            XCTFail("expected a rate-limit error")
        } catch let error as GitHubError {
            guard case .rateLimited(let resetAt, _) = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
            XCTAssertNotNil(resetAt)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// A permissions 403 must survive the rate-limit checks: every response
    /// carries x-ratelimit-reset, so only remaining/retry-after may classify.
    func testPermissionForbiddenStaysAnHTTPErrorWithTheRequestAttached() async {
        let reset = Date().addingTimeInterval(1800).timeIntervalSince1970
        StubURLProtocol.stub("contents/myproj/tasks.md", status: 403,
                             headers: ["x-ratelimit-remaining": "4987",
                                       "x-ratelimit-reset": "\(Int(reset))"],
                             body: #"{"message":"Resource not accessible by personal access token"}"#)
        do {
            _ = try await makeClient().putFile(owner: "octo", repo: "phren-store",
                                               path: "myproj/tasks.md", branch: "main",
                                               content: Data("x".utf8), message: "m", sha: nil)
            XCTFail("expected an http error")
        } catch let error as GitHubError {
            guard case .http(let status, _, let method, let path) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(method, "PUT")
            XCTAssertEqual(path, "repos/octo/phren-store/contents/myproj/tasks.md")
            XCTAssertTrue((error.errorDescription ?? "").contains("can't write to octo/phren-store"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
