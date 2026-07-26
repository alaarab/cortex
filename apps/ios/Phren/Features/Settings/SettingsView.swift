import SwiftUI
import PhrenKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var failedOps: [QueuedOp] = []
    @State private var confirmSignOut = false

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

                Section("Store") {
                    if let repo = model.selectedRepo {
                        LabeledContent("Repository", value: "\(repo.owner)/\(repo.name)")
                        LabeledContent("Branch", value: repo.branch)
                    }
                    Button("Sync now") {
                        Task { await model.pullToRefresh() }
                    }
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
                }

                if !failedOps.isEmpty {
                    Section {
                        ForEach(failedOps) { op in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(op.op.label).font(.callout)
                                if let error = op.lastError {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        await model.discardFailedOp(id: op.id)
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
            .confirmationDialog(
                "Sign out and remove the local copy of your store from this device?",
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
