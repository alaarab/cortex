import SwiftUI
import PhrenKit

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .signedOut:
                WelcomeView()
            case .pickingRepo:
                RepoPickerView()
            case .initialSync:
                InitialSyncView()
            default:
                ProgressView()
            }
        }
    }
}

// MARK: - Welcome + sign-in

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPATSheet = false
    @State private var deviceCode: DeviceCodeResponse?
    @State private var authError: String?
    @State private var polling = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("phren")
                .font(.largeTitle.bold())
            Text("Your agent's memory, in your pocket.\nSign in with GitHub to open your phren store.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            if let code = deviceCode {
                DeviceCodeView(code: code, polling: polling)
            }
            if let authError {
                Text(authError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await startDeviceFlow() }
            } label: {
                Label("Sign in with GitHub", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(polling)

            Button("Use a personal access token instead") {
                showPATSheet = true
            }
            .font(.footnote)
            .padding(.bottom)
        }
        .padding()
        .sheet(isPresented: $showPATSheet) {
            PATSignInSheet()
        }
    }

    private func startDeviceFlow() async {
        authError = nil
        let auth = DeviceFlowAuth()
        do {
            let code = try await auth.requestCode()
            deviceCode = code
            polling = true
            defer { polling = false }
            #if canImport(UIKit)
            if let url = URL(string: code.verificationUri) {
                await UIApplication.shared.open(url)
            }
            #endif
            switch try await auth.waitForAuthorization(code) {
            case .authorized(let token):
                try await model.signIn(token: token, kind: .oauth)
            case .expired:
                authError = "The code expired — try again."
            case .denied:
                authError = "Authorization was denied."
            default:
                break
            }
        } catch {
            authError = "Couldn't reach GitHub: \(error.localizedDescription)"
        }
        deviceCode = nil
    }
}

struct DeviceCodeView: View {
    let code: DeviceCodeResponse
    let polling: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("Enter this code on GitHub:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(.title, design: .monospaced).bold())
                .textSelection(.enabled)
            if polling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PATSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var validating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("github_pat_… or ghp_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Personal access token")
                } footer: {
                    Text("Create a fine-grained token with **Contents: Read and write** and **Metadata: Read** on your phren store repository. The token is stored only in this device's Keychain.")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Token sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        Task { await submit() }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || validating)
                }
            }
        }
    }

    private func submit() async {
        validating = true
        defer { validating = false }
        do {
            try await model.signIn(token: token, kind: .pat)
            dismiss()
        } catch {
            self.error = "Token rejected: \(error.localizedDescription)"
        }
    }
}

// MARK: - Repo picker

struct RepoPickerView: View {
    @Environment(AppModel.self) private var model
    @State private var repos: [GitHubRepo] = []
    @State private var phrenStoreNames: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var manualEntry = ""

    private var likelyStores: [GitHubRepo] {
        repos.filter { phrenStoreNames.contains($0.fullName) }
    }

    private var otherRepos: [GitHubRepo] {
        repos.filter { !phrenStoreNames.contains($0.fullName) }
    }

    var body: some View {
        List {
            if !likelyStores.isEmpty {
                Section("Phren stores") {
                    ForEach(likelyStores) { repo in
                        repoRow(repo, isStore: true)
                    }
                }
            }
            Section(likelyStores.isEmpty ? "Your repositories" : "Other repositories") {
                if loading {
                    HStack { ProgressView(); Text("Loading repositories…") }
                }
                ForEach(otherRepos) { repo in
                    repoRow(repo, isStore: false)
                }
            }
            Section {
                TextField("owner/repo", text: $manualEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") {
                    Task { await openManual() }
                }
                .disabled(!manualEntry.contains("/"))
            } header: {
                Text("Or enter a repository directly")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Pick the GitHub repository that holds your phren store (it contains phren.root.yaml). Set one up on your computer with `phren team init` or `phren store add`.")
                }
            }
        }
        .navigationTitle("Choose your store")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Sign out") {
                    Task { await model.signOut() }
                }
            }
        }
        .task { await load() }
    }

    private func repoRow(_ repo: GitHubRepo, isStore: Bool) -> some View {
        Button {
            Task { await model.selectRepo(owner: repo.owner.login, name: repo.name, branch: repo.defaultBranch) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.fullName).font(.body)
                    HStack(spacing: 6) {
                        if repo.isPrivate {
                            Label("Private", systemImage: "lock").font(.caption2)
                        }
                        if repo.permissions?.push == false {
                            Label("Read-only", systemImage: "eye").font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isStore {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            repos = try await model.client.listRepos()
            // Probe the most recently pushed repos for phren.root.yaml —
            // repo search is heavily rate-limited, direct probes are not.
            for repo in repos.prefix(10) {
                if await model.client.isPhrenStore(owner: repo.owner.login, name: repo.name) {
                    phrenStoreNames.insert(repo.fullName)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openManual() async {
        let parts = manualEntry.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2 else { return }
        do {
            let repo = try await model.client.repo(owner: String(parts[0]), name: String(parts[1]))
            await model.selectRepo(owner: repo.owner.login, name: repo.name, branch: repo.defaultBranch)
        } catch {
            self.error = "Couldn't open \(manualEntry): \(error.localizedDescription)"
        }
    }
}

struct InitialSyncView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Syncing your store…")
                .font(.headline)
            if let repo = model.selectedRepo {
                Text("\(repo.owner)/\(repo.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
