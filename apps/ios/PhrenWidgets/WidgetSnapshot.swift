import Foundation

/// The JSON contract between the app and the widget extension.
///
/// Mirrors `WidgetSnapshot` in the app target's `Phren/WidgetBridge.swift`
/// field-for-field. The widget extension can't link PhrenKit or the app
/// target (Apple's own sandboxing keeps extensions dependency-thin, and the
/// task brief keeps it that way deliberately) — this hand-kept duplicate,
/// plus the JSON file written to the shared App Group container, is the
/// *entire* contract between the two targets. If you add a field here, add
/// it there too.
struct WidgetSnapshot: Codable, Equatable {
    struct StoreCount: Codable, Equatable, Identifiable {
        var storeName: String
        var count: Int
        var id: String { storeName }
    }

    struct TopTask: Codable, Equatable {
        var text: String
        var project: String
    }

    var memoryCount: Int? = nil
    var projectCount: Int? = nil
    var totalReviewCount: Int
    var storeBreakdown: [StoreCount]
    var topTask: TopTask?
    var lastSyncedAt: Date?
}

/// Reads the snapshot the app last wrote to `group.com.phren.ios`. Returns
/// `nil` before the app has ever run (first install) — callers must render
/// a sensible empty state, never crash or blank out, in that case.
enum WidgetDataStore {
    static let appGroupID = "group.com.phren.ios"
    private static let filename = "widget-snapshot.json"

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> WidgetSnapshot? {
        guard
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
                .appendingPathComponent(filename),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
