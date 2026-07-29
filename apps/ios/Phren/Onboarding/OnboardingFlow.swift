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
            // The bobbing pixel-art mascot + the site's typewriter finding card.
            PhrenMascotView(size: 130)
            Text("phren")
                .font(.system(.largeTitle, design: .monospaced).bold())
                .foregroundStyle(PhrenTheme.text)
            Text("memory that travels with your agents")
                .font(.callout.monospaced())
                .foregroundStyle(PhrenTheme.lavender)
                .multilineTextAlignment(.center)
            TypewriterFindingCard()
                .padding(.top, 4)
            Text("Sign in with GitHub to open your phren store.")
                .font(.footnote)
                .foregroundStyle(PhrenTheme.textMuted)
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

            if DeviceFlowAuth.isConfigured {
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
            } else {
                // No OAuth App registered yet — the PAT flow is the sign-in.
                Button {
                    showPATSheet = true
                } label: {
                    Label("Sign in with a GitHub token", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Explore the demo") {
                Task { await model.enterDemoMode() }
            }
            .font(.footnote)
            .foregroundStyle(PhrenTheme.textMuted)
            .padding(.bottom)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhrenTheme.bg)
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
                .font(.footnote.monospaced())
                .foregroundStyle(PhrenTheme.textMuted)
            Text(code.userCode)
                .font(.system(.title, design: .monospaced).bold())
                .foregroundStyle(PhrenTheme.cyan)
                .textSelection(.enabled)
            if polling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…")
                        .font(.footnote.monospaced())
                        .foregroundStyle(PhrenTheme.textMuted)
                }
            }
        }
        .padding()
        .background(PhrenTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PhrenTheme.border, lineWidth: 1))
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

/// First-run store selection: picking a repo adds it as the first store.
struct RepoPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        RepoPickerList(
            existingStoreIds: [],
            footer: "Pick the GitHub repository that holds your phren store (it contains phren.root.yaml). Set one up on your computer with `phren team init` or `phren store add`."
        ) { repo in
            Task { await model.addStore(repo: repo) }
        }
        .navigationTitle("Choose your store")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Sign out") {
                    Task { await model.signOut() }
                }
            }
        }
    }
}

/// Reusable repo list with phren-store detection: used by first-run onboarding
/// and by Settings → Stores → Add store.
struct RepoPickerList: View {
    let existingStoreIds: Set<String>
    let footer: String
    let onSelect: (GitHubRepo) -> Void

    @Environment(AppModel.self) private var model
    @State private var repos: [GitHubRepo] = []
    @State private var phrenStoreNames: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var manualEntry = ""

    init(existingStoreIds: Set<String>,
         footer: String = "Add any repository that holds a phren store (it contains phren.root.yaml).",
         onSelect: @escaping (GitHubRepo) -> Void) {
        self.existingStoreIds = existingStoreIds
        self.footer = footer
        self.onSelect = onSelect
    }

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
                    Text(footer)
                }
            }
        }
        .phrenScreen()
        .task { await load() }
    }

    private func repoRow(_ repo: GitHubRepo, isStore: Bool) -> some View {
        let alreadyAdded = existingStoreIds.contains(repo.fullName)
        return Button {
            onSelect(repo)
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
                if alreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isStore {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
        .disabled(alreadyAdded)
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
            onSelect(repo)
        } catch {
            self.error = "Couldn't open \(manualEntry): \(error.localizedDescription)"
        }
    }
}

struct InitialSyncView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            PhrenMascotView(size: 90)
            ProgressView()
                .tint(PhrenTheme.cyan)
            Text("Syncing your store…")
                .font(.headline.monospaced())
                .foregroundStyle(PhrenTheme.text)
            if let store = model.storeDescriptors.last {
                Text(store.id)
                    .font(.footnote.monospaced())
                    .foregroundStyle(PhrenTheme.lavender)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhrenTheme.bg)
    }
}
