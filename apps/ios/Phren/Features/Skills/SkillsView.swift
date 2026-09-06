import PhrenKit
import SwiftUI

/// Browse and edit skills. Global skills and each project's skills are listed
/// together because that is how they resolve at read time — a project sees
/// global skills plus its own (`buildSkillManifest`, skill/registry.ts:293).
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    /// nil lists every scope; a value narrows to one project's own skills.
    var project: String?

    @State private var creating = false

    private var skills: [StoreSkill] {
        guard let project else { return model.mergedSkills }
        return model.mergedSkills.filter {
            if case .project(let name) = $0.skill.scope { return name == project }
            return false
        }
    }

    private var grouped: [(title: String, skills: [StoreSkill])] {
        Dictionary(grouping: skills) { $0.skill.scope.source }
            .map { (title: $0.key, skills: $0.value.sorted { $0.skill.name < $1.skill.name }) }
            // "global" first, then projects alphabetically — matching the
            // snapshot's own ordering.
            .sorted { left, right in
                if left.title == "global" { return true }
                if right.title == "global" { return false }
                return left.title < right.title
            }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.title) { group in
                Section(group.title == "global" ? "Global" : group.title) {
                    ForEach(group.skills) { entry in
                        NavigationLink {
                            SkillEditorView(entry: entry)
                        } label: {
                            SkillRow(skill: entry.skill)
                        }
                    }
                }
            }

            if skills.isEmpty {
                PhrenEmptyState(
                    title: "No skills yet",
                    message: project == nil
                        ? "Skills live in global/skills/ and <project>/skills/. Create one to get started."
                        : "This project has no skills of its own. Global skills still apply to it."
                )
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    creating = true
                } label: {
                    Label("New skill", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NewSkillSheet(defaultProject: project)
        }
    }
}

private struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.title ?? skill.name)
                    .font(.body.weight(.medium))
                if skill.format == .folder {
                    // A folder skill may carry files the app does not sync;
                    // the badge explains why only SKILL.md is editable here.
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = skill.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(skill.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Full-file markdown editor. Skills are authored prose with no line grammar,
/// so the whole file round-trips verbatim.
struct SkillEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: StoreSkill

    @State private var text: String = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var warnings: [String] { SkillFile.frontmatterWarnings(for: text) }
    private var isDirty: Bool { loaded && text != entry.skill.content }

    var body: some View {
        VStack(spacing: 0) {
            if !warnings.isEmpty {
                // A warning, not a block: `phren link` validates frontmatter,
                // but refusing to save a half-written skill would be worse
                // than letting it sync.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.yellow.opacity(0.15))
            }

            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
        }
        .navigationTitle(entry.skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!isDirty || saving)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete skill", systemImage: "trash")
                }
            }
        }
        .task {
            guard !loaded else { return }
            text = entry.skill.content
            loaded = true
        }
        .confirmationDialog("Delete \(entry.skill.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This removes \(entry.skill.path) from the store on the next sync.")
        }
        .alert("Couldn't save", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.saveSkill(path: entry.skill.path, content: text, in: entry.storeId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        do {
            try await model.deleteSkill(path: entry.skill.path, in: entry.storeId)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let defaultProject: String?

    @State private var name = ""
    @State private var scopeIsGlobal = false
    @State private var project = ""
    @State private var storeId = ""
    @State private var error: String?

    private var projects: [String] {
        Array(Set(model.mergedProjects.map(\.project.name))).sorted()
    }

    private var scope: Skill.Scope {
        scopeIsGlobal ? .global : .project(project)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && LocalStore.isSkillPath(AppModel.newSkillPath(scope: scope, name: trimmedName))
            && !storeId.isEmpty
            && (scopeIsGlobal || !project.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("skill-name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !trimmedName.isEmpty && !isValid {
                        Text("Letters, numbers, dots, dashes and underscores only.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Scope") {
                    Toggle("Global skill", isOn: $scopeIsGlobal)
                    if !scopeIsGlobal {
                        Picker("Project", selection: $project) {
                            ForEach(projects, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                if model.hasMultipleStores {
                    Section("Store") {
                        Picker("Store", selection: $storeId) {
                            ForEach(model.storeDescriptors, id: \.id) { descriptor in
                                Text(descriptor.displayName).tag(descriptor.id)
                            }
                        }
                    }
                }

                if isValid {
                    Section("Path") {
                        Text(AppModel.newSkillPath(scope: scope, name: trimmedName))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!isValid)
                }
            }
            .task {
                project = defaultProject ?? projects.first ?? ""
                scopeIsGlobal = defaultProject == nil
                storeId = model.storeDescriptors.first?.id ?? ""
            }
            .alert("Couldn't create that skill", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func create() async {
        do {
            let path = AppModel.newSkillPath(scope: scope, name: trimmedName)
            try await model.saveSkill(path: path, content: SkillFile.template(name: trimmedName), in: storeId)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
