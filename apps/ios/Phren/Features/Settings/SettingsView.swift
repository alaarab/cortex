import SwiftUI
import PhrenKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var failedOps: [FailedOpEntry] = []
    @State private var confirmSignOut = false
    @State private var showAddStore = false
    @State private var removingStore: StoreDescriptor?

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
                                        TagChip(text: failed.storeName, color: .indigo)
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
            .navigationTitle("Settings")
            .task { failedOps = await model.failedOps() }
            .refreshable {
                await model.pullToRefresh()
                failedOps = await model.failedOps()
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
                Text(context.descriptor.id)
                    .font(.callout)
                if !context.descriptor.canPush {
                    TagChip(text: "read-only", color: .orange)
                }
            }
            HStack(spacing: 8) {
                if let last = context.status.lastSyncedAt {
                    Text("synced \(last.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("not synced yet")
                }
                if context.status.pendingCount > 0 {
                    Text("\(context.status.pendingCount) pending")
                        .foregroundStyle(.orange)
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
