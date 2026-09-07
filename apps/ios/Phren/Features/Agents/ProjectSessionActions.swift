import SwiftUI
import PhrenKit

/// Shared by project toolbars and graph details. Moshi is entirely optional;
/// links stay in this phone's preferences and never enter the store or queue.
struct ProjectSessionActions: View {
    enum Presentation { case menu, section }
    let storeId: String
    let project: String
    var presentation: Presentation = .menu

    @Environment(\.openURL) private var openURL
    @AppStorage("sessions.moshi.links.v1") private var savedData = Data()
    @State private var editing = false
    @State private var error: String?

    private var link: MoshiSessionLink? {
        (try? ProjectSessionLinks.read(savedData))?.link(storeID: storeId, project: project)
    }

    var body: some View {
        Group {
            switch presentation {
            case .menu:
                Menu { actions } label: { Label("Project session", systemImage: "terminal") }
                    .accessibilityLabel("Project session")
                    .sheet(isPresented: $editing) {
                        NavigationStack { ProjectSessionEditor(storeId: storeId, project: project) }
                    }
                    .modifier(MoshiLaunchAlert(error: $error))
            case .section:
                Section("Session") {
                    if let link { Text(link.summary).font(.caption).foregroundStyle(.secondary) }
                    actions
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let link {
            let openButton = Button("Open in Moshi", systemImage: "arrow.up.forward.app") {
                do {
                    let url = try link.url()
                    openURL(url) { accepted in
                        if !accepted {
                            error = "Moshi couldn't be opened on this iPhone. Check that it's installed and open your session there first. Your saved link is still available to edit."
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
            switch presentation {
            case .menu: openButton
            case .section: openButton.modifier(MoshiLaunchAlert(error: $error))
            }
            editAction("Edit Moshi link", icon: "pencil")
        } else {
            editAction("Add Moshi link", icon: "link")
        }
    }

    @ViewBuilder private func editAction(_ title: String, icon: String) -> some View {
        switch presentation {
        case .menu:
            Button(title, systemImage: icon) { editing = true }
        case .section:
            // Graph details already own a sheet and navigation stack.
            NavigationLink { ProjectSessionEditor(storeId: storeId, project: project, showsCancel: false) } label: {
                Label(title, systemImage: icon)
            }
        }
    }
}

/// Present from one concrete button/menu, not a Section's multiple children.
private struct MoshiLaunchAlert: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert("Couldn't open Moshi", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ProjectSessionEditor: View {
    let storeId: String
    let project: String
    var showsCancel = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.moshi.links.v1") private var savedData = Data()
    @State private var multiplexer: MoshiSessionLink.Multiplexer = .tmux
    @State private var session = ""
    @State private var workspace = ""
    @State private var window = ""
    @State private var tab = ""
    @State private var pane = ""
    @State private var loaded = false
    @State private var hasSavedLink = false
    @State private var loadError: String?
    @State private var error: String?

    private var destination: Result<MoshiSessionLink, Error> {
        Result {
            try MoshiSessionLink(multiplexer: multiplexer, session: session,
                                 workspace: multiplexer == .herdr ? workspace : "",
                                 window: multiplexer == .tmux ? window : "",
                                 tab: multiplexer == .herdr ? tab : "", pane: pane)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Project", value: project)
                LabeledContent("Store", value: storeId)
            } footer: {
                Text("An optional shortcut to Moshi on this iPhone. The link stays on this device.")
            }
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else {
                Section {
                    Picker("Session type", selection: Binding(get: { multiplexer }, set: { multiplexer = $0; pane = "" })) {
                        ForEach(MoshiSessionLink.Multiplexer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(multiplexer == .tmux ? "Session name" : "Server session (default)", text: $session)
                        .accessibilityIdentifier("moshi.session")
                    if multiplexer == .herdr {
                        TextField("Workspace ID (optional)", text: $workspace)
                    }
                } header: { Text("Moshi destination") } footer: {
                    Text(multiplexer == .tmux
                         ? "Use the tmux session name shown in Moshi. Open that session in Moshi before using the shortcut."
                         : "Use the Herdr server session name, not its workspace label. Leave the session empty for default. A workspace ID selects a workspace within it.")
                }
                Section {
                    DisclosureGroup("Specific window or pane") {
                        if multiplexer == .tmux {
                            TextField("Window number 0–9 (optional)", text: $window).keyboardType(.numberPad)
                            TextField("Pane ID, e.g. %5 (optional)", text: $pane)
                        } else {
                            TextField("Tab ID (optional)", text: $tab)
                            TextField("Pane ID (optional)", text: $pane)
                        }
                        Text("Exact pane selection needs a recent Moshi app and companion on the computer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    switch destination {
                    case .success(let link):
                        Text(link.summary).font(.callout)
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.secondary)
                    }
                } header: { Text("Opening the session") } footer: {
                    Text("Moshi resumes an open or minimized session and reports if it is unavailable. Phren cannot check its live status. Use distinct session names across computers to avoid opening a different match.")
                }
                if hasSavedLink {
                    Section {
                        Button("Remove link", role: .destructive) { save(nil) }
                    } footer: { Text("Removes this shortcut from Phren. Your Moshi session keeps running.") }
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Moshi session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save link") {
                    if case .success(let link) = destination { save(link) }
                }
                .disabled(loadError != nil || (try? destination.get()) == nil)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            do {
                if let link = try ProjectSessionLinks.read(savedData).link(storeID: storeId, project: project) {
                    multiplexer = link.multiplexer
                    session = link.session
                    workspace = link.workspace
                    window = link.window
                    tab = link.tab
                    pane = link.pane
                    hasSavedLink = true
                }
            } catch { loadError = "Saved links couldn't be read: \(error.localizedDescription)" }
        }
        .alert("Couldn't save link", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save(_ link: MoshiSessionLink?) {
        do {
            savedData = try ProjectSessionLinks.setting(link, storeID: storeId, project: project, in: savedData)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
