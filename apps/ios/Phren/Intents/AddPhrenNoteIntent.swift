import AppIntents
import PhrenKit

/// "Hey Siri, add a note to phren" — the hands-free twin of the voice capture
/// sheet's Note mode. Same op, same file, same offline-first queue; the only
/// thing missing is the screen.
struct AddPhrenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Note"

    static var description = IntentDescription(
        "Captures a note into a phren project. Works from the Lock Screen without opening the app — the note queues locally and syncs on the next launch.",
        categoryName: "Capture",
        searchKeywords: ["note", "capture", "thought", "phren", "journal"]
    )

    static var openAppWhenRun = false

    /// See `AddPhrenTaskIntent` — capture from a locked phone is the feature.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Note", requestValueDialog: "What should the note say?")
    var text: String

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw $text.needsValueError("What should the note say?")
        }
        let target = try await PhrenCapture.resolveTarget(project)
        // Same UTC day/time stamping the notes file expects from any writer.
        let stamp = AppModel.nowNoteTimestamp()
        try await PhrenCapture.capture(
            .addNote(project: target.project, date: stamp.date, time: stamp.time, text: value),
            to: target
        )
        return .result(dialog: "Added to \(target.spokenName).")
    }
}
