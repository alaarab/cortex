import AppIntents
import SwiftUI
import PhrenKit

/// "Hey Siri, add a task to phren" — dictate it, done. No app, no screen.
///
/// The intent runs in the app's process (`openAppWhenRun` stays false; the
/// system launches the process in the background if it isn't already up), and
/// `PhrenCapture` decides whether that process has a bootstrapped `AppModel`
/// to route through or has to queue the op offline itself.
struct AddPhrenTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"

    static var description = IntentDescription(
        "Adds a task to a phren project. Works from the Lock Screen without opening the app — the task queues locally and syncs on the next launch.",
        categoryName: "Capture",
        searchKeywords: ["task", "todo", "capture", "phren", "note"]
    )

    /// The entire point is that nothing opens.
    static var openAppWhenRun = false

    /// Capture has to work from a locked phone — that is where a thought
    /// arrives, hands full, walking. Requiring an unlock would make the
    /// feature pointless. The trade-off, accepted deliberately: whoever is
    /// holding the phone can dictate text into the queue. Nothing is read
    /// back, nothing is deleted, and no token is ever touched — the worst
    /// case is a junk task the owner deletes later.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var text: String

    /// Optional so a configured default (Settings → Quick capture) can skip
    /// the question entirely — but never guessed when it's absent: `perform`
    /// throws `needsValueError` instead, which makes Siri ask out loud and the
    /// Shortcuts app show its project picker mid-run, then re-runs `perform`
    /// with the answer. Nothing is written before the destination is known, so
    /// that second run is not a retry of a partial capture.
    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            // Dictation heard nothing usable — ask again rather than filing
            // an empty task.
            throw $text.needsValueError("What's the task?")
        }
        let target: PhrenCaptureTarget
        switch try await PhrenCapture.resolveTarget(project) {
        case .resolved(let resolved):
            target = resolved
        case .ask(let reason):
            throw $project.needsValueError(IntentDialog(reason.prompt))
        }
        try await PhrenCapture.capture(.addTask(project: target.project, text: value), to: target)
        return .result(
            dialog: "Added to \(target.spokenName).",
            view: CaptureSnippetView(kind: "Task", text: value, destination: target.displayName)
        )
    }
}
