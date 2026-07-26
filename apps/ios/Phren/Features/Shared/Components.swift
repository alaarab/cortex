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
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.syncStatus.pendingCount > 0 {
                Label("\(model.syncStatus.pendingCount)", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onReceive(ticker) { now = $0 }
    }

    private var indicatorColor: Color {
        if model.syncStatus.lastError != nil { return .red }
        return model.syncStatus.isLive ? .green : .gray
    }

    private var statusText: String {
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
                    TagChip(text: tag, color: .blue)
                }
                if finding.status != .active {
                    TagChip(text: finding.status.rawValue, color: .orange)
                }
                if let scope = finding.scope {
                    TagChip(text: scope, color: .purple)
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
    }

    private var displayText: String {
        // Show the text without the leading [tag] — the chip carries it.
        guard let tag = finding.typeTag else { return finding.text }
        let prefix = "[\(tag)] "
        return finding.text.lowercased().hasPrefix(prefix.lowercased())
            ? String(finding.text.dropFirst(prefix.count))
            : finding.text
    }
}

struct TagChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
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
