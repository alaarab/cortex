import CryptoKit
import Foundation

extension GitBlob {
    /// Git's content identity for a file: `sha1("blob <byteCount>\0" + bytes)`,
    /// hex-encoded — the same value the Contents API returns as a file's `sha`.
    ///
    /// Computing it locally lets the sync engine recognise that the bytes it
    /// is about to PUT are the bytes the remote already has (GitHub records an
    /// empty commit for a byte-identical PUT rather than rejecting it).
    public static func sha(of text: String) -> String {
        sha(of: Data(text.utf8))
    }

    public static func sha(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\u{0}".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
