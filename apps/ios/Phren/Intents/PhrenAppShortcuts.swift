import AppIntents
import PhrenKit

/// The phrases Siri answers to out of the box — no setup in the Shortcuts app.
///
/// Every phrase has to contain `\(.applicationName)`; Siri keys on the app
/// name to route the utterance, and a phrase without it is rejected at build
/// time. The app name it accepts is not only "Phren": `INAlternativeAppNames`
/// in Info.plist adds "Fren" and "Friend", because that is what dictation
/// hears roughly every other time.
///
/// The parameterized variants ("…to alpha lens in phren") resolve the project
/// through `ProjectEntityQuery.entities(matching:)`; the plain ones fall back
/// to the last project anything was captured into.
struct PhrenAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPhrenTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "Add a \(.applicationName) task",
                "New \(.applicationName) task",
                "Queue a task in \(.applicationName)",
                "Add a task to \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Add Task",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: AddPhrenNoteIntent(),
            phrases: [
                "Add a note to \(.applicationName)",
                "Add a \(.applicationName) note",
                "New \(.applicationName) note",
                "Capture a thought in \(.applicationName)",
                "Add a note to \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
        )
    }
}

extension PhrenAppShortcuts {
    /// The project list Siri last had donated to it, so the ~7s live poll
    /// doesn't re-donate an unchanged list every cycle.
    @MainActor private static var donatedProjects: [String]?

    /// Re-donates project names when the set actually changes, so a project
    /// created on another machine becomes speakable ("…to alpha lens in
    /// phren") as soon as it syncs down. Called from `AppModel.refresh()`,
    /// alongside the widget snapshot, for the same reason: that is where each
    /// sync generation's parsed state settles.
    @MainActor
    static func donateProjects(from model: AppModel) {
        // Deliberately not `model.writableProjects`, which honours the UI's
        // store filter: what Siri can hear must not narrow because the user
        // filtered a list on screen.
        let projects = model.storeContexts
            .filter(\.descriptor.canPush)
            .flatMap { context in
                context.snapshot.projects
                    .filter { !LocalStore.isReadOnlyProject($0.name) }
                    .map { "\(context.id)|\($0.name)" }
            }
            .sorted()
        guard projects != donatedProjects else { return }
        donatedProjects = projects
        updateAppShortcutParameters()
    }
}
