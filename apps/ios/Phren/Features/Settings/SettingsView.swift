import SwiftUI
import PhrenKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var failedOps: [FailedOpEntry] = []
    @State private var confirmSignOut = false
    @State private var showAddStore = false
    @State private var removingStore: StoreDescriptor?
    @State private var connectingStore: StoreDescriptor?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = model.user {
                        LabeledContent("GitHub", value: "@\(user.login)")
                        if let name = user.name {
                            LabeledContent("Name", value: name)
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        confirmSignOut = true
                    }
                }

                Section {
                    ForEach(model.storeContexts) { context in
                        StoreRow(context: context)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    removingStore = context.descriptor
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if context.descriptor.isLocal {
                                    Button {
                                        connectingStore = context.descriptor
                                    } label: {
                                        Label("Connect", systemImage: "icloud.and.arrow.up")
                                    }
                                    .tint(PhrenTheme.accentSolid)
                                }
                            }
                    }
                    Button {
                        showAddStore = true
                    } label: {
                        Label("Add store", systemImage: "plus")
                    }
                } header: {
                    Text("Stores")
                } footer: {
                    Text("Each store is a GitHub repository holding a phren store. Removing one only deletes this device's local copy.")
                }

                Section("Sync") {
                    LabeledContent("Live updates", value: model.syncStatus.isLive ? "On" : "Paused")
                    if let last = model.syncStatus.lastSyncedAt {
                        LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .standard))
                    }
                    LabeledContent("Pending changes", value: "\(model.syncStatus.pendingCount)")
                    if let error = model.syncStatus.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Sync now") {
                        Task {
                            await model.pullToRefresh()
                            failedOps = await model.failedOps()
                        }
                    }
                }

                if !failedOps.isEmpty {
                    Section {
                        ForEach(failedOps) { failed in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(failed.op.op.label).font(.callout)
                                HStack(spacing: 6) {
                                    if model.hasMultipleStores {
                                        TagChip(text: failed.storeName, role: .store)
                                    }
                                    if let error = failed.op.lastError {
                                        Text(error).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        await model.discardFailedOp(storeId: failed.storeId, id: failed.op.id)
                                        failedOps = await model.failedOps()
                                    }
                                } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                            }
                        }
                        Button("Retry all") {
                            Task {
                                await model.retryFailedOps()
                                failedOps = await model.failedOps()
                            }
                        }
                    } header: {
                        Text("Needs attention")
                    } footer: {
                        Text("These changes couldn't be applied — usually because the item changed on another machine. Retry or discard them.")
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "phren for iOS")
                    Link("phren on GitHub", destination: URL(string: "https://github.com/alaarab/phren")!)
                }
            }
            .phrenScreen()
            .navigationTitle("Settings")
            .task { failedOps = await model.failedOps() }
            .refreshable {
                await model.pullToRefresh()
                failedOps = await model.failedOps()
            }
            .sheet(item: $connectingStore) { descriptor in
                ConnectStoreSheet(descriptor: descriptor)
            }
            .sheet(isPresented: $showAddStore) {
                NavigationStack {
                    RepoPickerList(
                        existingStoreIds: Set(model.storeDescriptors.map(\.id))
                    ) { repo in
                        showAddStore = false
                        Task { await model.addStore(repo: repo) }
                    }
                    .navigationTitle("Add store")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddStore = false }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Remove \(removingStore?.id ?? "this store") from this device? The GitHub repository is not affected.",
                isPresented: Binding(
                    get: { removingStore != nil },
                    set: { if !$0 { removingStore = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove store", role: .destructive) {
                    if let store = removingStore {
                        Task { await model.removeStore(id: store.id) }
                    }
                    removingStore = nil
                }
            }
            .confirmationDialog(
                "Sign out and remove the local copies of all stores from this device?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
        }
    }
}

struct StoreRow: View {
    let context: StoreContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(context.descriptor.isLocal ? context.descriptor.name : context.descriptor.id)
                    .font(.callout)
                if context.descriptor.isLocal {
                    TagChip(text: "on this device", role: .scope)
                }
                if !context.descriptor.canPush {
                    TagChip(text: "read-only", role: .warn)
                }
            }
            HStack(spacing: 8) {
                if context.descriptor.isLocal {
                    Text("saved locally · not on GitHub")
                } else if let last = context.status.lastSyncedAt {
                    Text("synced \(last.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("not synced yet")
                }
                if context.status.pendingCount > 0 {
                    Text("\(context.status.pendingCount) pending")
                        .foregroundStyle(PhrenTheme.orange)
                }
                if let error = context.status.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}


/// Upgrades a local store to a GitHub-backed one. The user creates an empty
/// repo on github.com first; the app uploads every file and reopens the store
/// as a normal synced one.
struct ConnectStoreSheet: View {
    let descriptor: StoreDescriptor

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var owner = ""
    @State private var repo = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if model.user == nil {
                    Section {
                        Text("Sign in with GitHub first (remove the local-only setup by signing in from the welcome screen, or add a token in Settings), then come back here.")
                            .font(.footnote)
                    }
                } else {
                    Section {
                        TextField("Owner (user or org)", text: $owner)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Repository name", text: $repo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Create an empty private repository on github.com first. Everything in \(descriptor.name) uploads there, one commit per file, and the store becomes a normal synced one.")
                    }
                }
            }
            .navigationTitle("Connect to GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Uploading…" : "Connect") {
                        working = true
                        Task {
                            let ok = await model.connectLocalStore(
                                storeId: descriptor.id,
                                owner: owner.trimmingCharacters(in: .whitespaces),
                                repo: repo.trimmingCharacters(in: .whitespaces)
                            )
                            working = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(working || model.user == nil
                              || owner.trimmingCharacters(in: .whitespaces).isEmpty
                              || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
