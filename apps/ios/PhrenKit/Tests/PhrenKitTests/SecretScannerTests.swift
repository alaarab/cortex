import XCTest
@testable import PhrenKit

/// The scanner is the last thing standing between a pasted credential and a
/// public commit, and only one of its patterns had any coverage.
final class SecretScannerTests: XCTestCase {

    func testDetectsRepresentativeCredentials() {
        let cases: [(String, String)] = [
            ("AKIAIOSFODNN7EXAMPLE", "AWS access key"),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
             "JWT token"),
            ("postgres://user:hunter2@db.internal:5432/app", "connection string with credentials"),
            ("-----BEGIN RSA PRIVATE KEY-----", "SSH private key"),
            ("ghp_" + String(repeating: "a", count: 36), "GitHub personal access token"),
            ("xoxb-123456789-abcdefGHIJKL", "Slack bot token"),
            ("sk_live_" + String(repeating: "b", count: 24), "Stripe secret key"),
            ("npm_" + String(repeating: "c", count: 36), "npm access token"),
            ("\"private_key_id\": \"abcdefghijklmnopqrstuvwxyz12\"", "GCP service account key"),
            ("api_key = \"abcdefghijklmnopqrstuvwxyz123\"", "API key or secret"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SecretScanner.scan(text), expected, "missed: \(expected)")
        }
    }

    func testOrdinaryFindingTextIsClean() {
        XCTAssertNil(SecretScanner.scan("Always validate JWT expiry before refresh"))
        XCTAssertNil(SecretScanner.scan("Use biquad~ instead of svf~ in Live 12"))
    }

    /// A bare 40-char lowercase hex string is a git sha, not a secret — the
    /// exemption that lets people cite commits.
    func testGitShaIsNotFlagged() {
        XCTAssertNil(SecretScanner.scan("b2b8a355b2b8a355b2b8a355b2b8a355b2b8a355"))
        XCTAssertNil(SecretScanner.scan(String(repeating: "a", count: 40)))
    }

    /// Expectations here were taken from the CLI's own `scanForSecrets`, not
    /// from reading the regex: the first blob I assumed would trip it is passed
    /// clean by both implementations, which is the agreement that matters.
    func testLongBase64BlobMatchesCLI() {
        XCTAssertEqual(SecretScanner.scan("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP+/QRSTUV=="),
                       "long base64 secret")
        XCTAssertNil(SecretScanner.scan("aGVsbG8gd29ybGQrL2Jhc2U2NCBibG9iIHRoYXQgaXMgcXVpdGUgbG9uZytJbmRlZWQ="))
    }

    /// The base64 check has to keep running between the JWT and connection
    /// string patterns, as it does in dedup.ts. It was previously positioned by
    /// a hardcoded index, so any insertion into `checks` moved it silently.
    func testBase64CheckStillRunsAfterJWT() {
        // A JWT is itself base64-ish; it must report as a JWT, not as a blob.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(SecretScanner.scan(jwt), "JWT token")
    }
}
