import Foundation
import XCTest
@testable import PhrenKit

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name)))
    }
}

/// Byte-level comparison with a readable first-difference diagnostic.
func assertSameContent(_ actual: String, _ expected: String,
                       _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    guard actual != expected else { return }
    let actualLines = actual.components(separatedBy: "\n")
    let expectedLines = expected.components(separatedBy: "\n")
    for i in 0..<max(actualLines.count, expectedLines.count) {
        let a = i < actualLines.count ? actualLines[i] : "<missing>"
        let e = i < expectedLines.count ? expectedLines[i] : "<missing>"
        if a != e {
            XCTFail("\(label): first difference at line \(i + 1)\n  actual:   \(a)\n  expected: \(e)",
                    file: file, line: line)
            return
        }
    }
    XCTFail("\(label): contents differ (whitespace-only difference)", file: file, line: line)
}
