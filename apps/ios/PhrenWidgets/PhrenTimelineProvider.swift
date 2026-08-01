import WidgetKit

/// A single current-state entry — no need for multiple future entries since
/// the app itself proactively reloads the timeline via
/// `WidgetCenter.shared.reloadAllTimelines()` whenever the snapshot content
/// changes while the app is running (see `Phren/WidgetBridge.swift`). The
/// `.after(15 minutes)` policy below is just the backstop for when the app
/// hasn't run in a while.
struct PhrenEntry: TimelineEntry {
    let date: Date
    /// `nil` means "no snapshot on disk yet" — first install, or the app has
    /// never completed a refresh. Views must render an "open phren" state
    /// for this, not a blank or placeholder-with-fake-numbers.
    let snapshot: WidgetSnapshot?
}

struct PhrenTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhrenEntry {
        PhrenEntry(date: .now, snapshot: WidgetDataStore.load())
    }

    func getSnapshot(in context: Context, completion: @escaping (PhrenEntry) -> Void) {
        completion(PhrenEntry(date: .now, snapshot: WidgetDataStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhrenEntry>) -> Void) {
        let entry = PhrenEntry(date: .now, snapshot: WidgetDataStore.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}
