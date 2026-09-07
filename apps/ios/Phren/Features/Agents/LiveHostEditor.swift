import PhrenKit
import PhrenLive
import SwiftUI

struct LiveHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    var existing: LiveHost?
    @State private var id = UUID()
    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var key = ""
    @State private var error: String?
    @State private var saved = false
    @State private var removing = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("SSH computer") {
                TextField("Name", text: $name).accessibilityIdentifier("live-host-name")
                TextField("Tailscale hostname or IP", text: $address).accessibilityIdentifier("live-host-address")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(existing != nil)
                TextField("SSH port", text: $port).keyboardType(.numberPad).disabled(existing != nil)
                TextField("SSH username", text: $username).accessibilityIdentifier("live-host-username")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(existing != nil)
                if existing != nil {
                    Text("To change the SSH destination or user, add another computer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Authorize this iPhone") {
                Text("Create a device key, then add the copied line to ~/.ssh/authorized_keys for this user on the computer. SSH must allow forwarding to 127.0.0.1:24543, where moshi-hook listens.")
                    .font(.callout).foregroundStyle(.secondary)
                if key.isEmpty {
                    Button("Create device key") { createKey() }
                } else {
                    Button(copied ? "Copied SSH authorization line" : "Copy SSH authorization line", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = key
                        copied = true
                    }
                    ShareLink("Share SSH authorization line", item: key)
                }
                if let fingerprint = existing?.fingerprint {
                    Text("Trusted host: \(fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("The private key stays on this iPhone. Phren reads the hook's default Herdr server; it does not start sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            if existing != nil {
                Section {
                    Button("Forget computer", role: .destructive) { removing = true }
                    Text("Also remove this iPhone's public key from authorized_keys on the computer to revoke its access there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add computer" : "Connection settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(key.isEmpty)
            }
        }
        .phrenScreen()
        .onAppear {
            if let existing {
                id = existing.id; name = existing.name; address = existing.address
                port = String(existing.port); username = existing.username
                createKey()
            }
        }
        .onDisappear {
            if existing == nil && !saved { try? DeviceSSHKey.delete(id) }
        }
        .confirmationDialog("Forget this computer and delete its SSH key from this iPhone?", isPresented: $removing, titleVisibility: .visible) {
            Button("Forget computer", role: .destructive) {
                do {
                    let next = try LiveSessionPreferences.removing(id, from: data)
                    try DeviceSSHKey.delete(id)
                    data = next
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func createKey() {
        do { key = try DeviceSSHKey.publicKey(id) }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            let host = try LiveHost(id: id, name: name, address: address, port: Int(port) ?? 0,
                                   username: username, fingerprint: existing?.fingerprint)
            data = try LiveSessionPreferences.saving(host, in: data)
            saved = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
