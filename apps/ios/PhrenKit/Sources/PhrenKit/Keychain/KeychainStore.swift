import Foundation
#if canImport(Security)
import Security
#endif

/// GitHub token storage. On Apple platforms this is the Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the token never
/// leaves the device or lands in backups). The non-Apple fallback exists only
/// so PhrenKit's parser tests run on Linux CI; the app never uses it.
public enum KeychainStore {
    static let service = "com.phren.ios.github"
    static let account = "github-token"

    public enum TokenKind: String, Codable, Sendable {
        case oauth
        case pat
    }

    public struct StoredToken: Codable, Equatable, Sendable {
        public let token: String
        public let kind: TokenKind
        public init(token: String, kind: TokenKind) {
            self.token = token
            self.kind = kind
        }
    }

#if canImport(Security)
    public static func save(_ stored: StoredToken) throws {
        let data = try JSONEncoder().encode(stored)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PhrenKitError.validation("Keychain save failed (\(status)).")
        }
    }

    public static func load() -> StoredToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        // Deliberately NOT a versioned/quarantined document, unlike everything
        // in Persistence/: this is a credential, not user data. Nothing is
        // lost if it can't be read — the user signs in again and gets a new
        // token — and copying a token to a quarantine file to preserve it
        // would be strictly worse than dropping it.
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
#else
    // Linux CI fallback: in-memory only. Never used by the iOS app.
    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: StoredToken?
        func get() -> StoredToken? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: StoredToken?) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
    private static let memory = MemoryBox()

    public static func save(_ stored: StoredToken) throws { memory.set(stored) }
    public static func load() -> StoredToken? { memory.get() }
    public static func delete() { memory.set(nil) }
#endif
}
