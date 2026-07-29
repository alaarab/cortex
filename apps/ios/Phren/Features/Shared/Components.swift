import SwiftUI
import PhrenKit

/// "live · updated 3s ago" freshness indicator shown on every list screen —
/// the visible promise that what you see is what's on GitHub right now.
struct LiveStatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .shadow(color: indicatorColor.opacity(0.7), radius: model.syncStatus.isLive ? 3 : 0)
            Text(statusText)
                .font(.caption.monospaced())
                .foregroundStyle(PhrenTheme.textMuted)
            Spacer()
            if model.syncStatus.pendingCount > 0 {
                Label("\(model.syncStatus.pendingCount)", systemImage: "arrow.up.circle")
                    .font(.caption.monospaced())
                    .foregroundStyle(PhrenTheme.amber)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(PhrenTheme.bg)
        .onReceive(ticker) { now = $0 }
        // Live/paused/error is carried by the dot's hue alone, which VoiceOver
        // cannot convey; combine the row and state it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Spoken form of what the coloured dot means, plus the freshness text and
    /// any pending count — all of which are otherwise visual-only.
    private var accessibilityDescription: String {
        var parts: [String] = []
        if model.syncStatus.lastError != nil {
            parts.append("Sync error")
        } else if model.syncStatus.isLive {
            parts.append("Live")
        } else {
            parts.append("Paused")
        }
        parts.append(statusText)
        if model.syncStatus.pendingCount > 0 {
            parts.append("\(model.syncStatus.pendingCount) change\(model.syncStatus.pendingCount == 1 ? "" : "s") waiting to upload")
        }
        return parts.joined(separator: ", ")
    }

    private var indicatorColor: Color {
        if model.allStoresLocal { return PhrenTheme.lavender }
        if model.syncStatus.lastError != nil { return PhrenTheme.red }
        return model.syncStatus.isLive ? PhrenTheme.cyan : PhrenTheme.textDim
    }

    private var statusText: String {
        if model.allStoresLocal {
            return "local · saved on this device"
        }
        if let error = model.syncStatus.lastError {
            return "sync error — \(error)"
        }
        guard let last = model.syncStatus.lastSyncedAt else {
            return model.syncStatus.isLive ? "live · syncing…" : "not synced yet"
        }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        let ago = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
        return model.syncStatus.isLive ? "live · updated \(ago)" : "updated \(ago)"
    }
}

struct ActionErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.lastActionError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).font(.footnote)
                Spacer()
                Button {
                    model.lastActionError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .accessibilityLabel("Dismiss error")
                }
            }
            .padding(10)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayText)
                .font(.callout)
            HStack(spacing: 6) {
                if let tag = finding.typeTag {
                    TagChip(text: tag, role: .type)
                }
                if finding.status != .active {
                    TagChip(text: finding.status.rawValue, role: .status)
                }
                if let scope = finding.scope {
                    TagChip(text: scope, role: .scope)
                }
                if let actor = finding.actor {
                    Text("@\(actor)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(finding.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = ["Finding"]
        if let tag = finding.typeTag { parts.append(tag) }
        if finding.status != .active { parts.append(finding.status.rawValue) }
        if finding.archived { parts.append("archived") }
        parts.append(displayText)
        parts.append(finding.date)
        return parts.joined(separator: ", ")
    }

    private var displayText: String { Self.displayText(finding) }

    /// Text without the leading `[tag]` — the chip carries it. Shared with the
    /// detail view so list and detail render the same string.
    static func displayText(_ finding: Finding) -> String {
        guard let tag = finding.typeTag else { return finding.text }
        let prefix = "[\(tag)] "
        return finding.text.lowercased().hasPrefix(prefix.lowercased())
            ? String(finding.text.dropFirst(prefix.count))
            : finding.text
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text).font(.callout)
            HStack {
                Text(note.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if note.promoted {
                    TagChip(text: "promoted", role: .good)
                }
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = note.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note at \(note.time)\(note.promoted ? ", promoted" : ""): \(note.text)")
    }
}

struct TagChip: View {
    let text: String
    let color: Color

    init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    init(text: String, role: PhrenTheme.ChipRole) {
        self.init(text: text, color: PhrenTheme.chipColor(role))
    }

    var body: some View {
        // The site's chips are monospace, squared-off, and bordered rather
        // than pill-shaped (docs/index.html .mini-tag / card styling).
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// Sheet for entering or editing a piece of text, with an optional finding
/// type picker (used for add finding, edit finding, promote note).
struct TextEntrySheet: View {
    let title: String
    let showsTypePicker: Bool
    let confirmLabel: String
    let onConfirm: (String, FindingType?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State var text: String
    @State var selectedType: FindingType?

    init(title: String, initialText: String = "", initialType: FindingType? = nil,
         showsTypePicker: Bool = false, confirmLabel: String = "Save",
         onConfirm: @escaping (String, FindingType?) async -> Void) {
        self.title = title
        self.showsTypePicker = showsTypePicker
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        _text = State(initialValue: initialText)
        _selectedType = State(initialValue: initialType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                }
                if showsTypePicker {
                    Picker("Type", selection: $selectedType) {
                        Text("none").tag(FindingType?.none)
                        ForEach(FindingType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(FindingType?.some(type))
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        let value = text
                        let type = selectedType
                        Task {
                            await onConfirm(value, type)
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
