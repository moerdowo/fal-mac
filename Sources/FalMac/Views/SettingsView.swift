import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var gallery: GalleryStore = .shared

    @State private var draftKey: String = ""
    @State private var draftProfile: String = ""
    @State private var showSaved = false

    var body: some View {
        Form {
            Section("Profiles") {
                if !state.apiProfiles.isEmpty {
                    Picker("Active profile", selection: Binding(
                        get: { state.activeProfile },
                        set: { state.activeProfile = $0 }
                    )) {
                        ForEach(state.apiProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                    .pickerStyle(.menu)

                    if state.apiProfiles.count > 1 {
                        Button(role: .destructive) {
                            state.deleteProfile(state.activeProfile)
                        } label: {
                            Label("Delete \"\(state.activeProfile)\"", systemImage: "minus.circle")
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("fal.ai API Key") {
                if !state.apiProfiles.isEmpty {
                    Text("Editing key for: **\(state.activeProfile)**")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField("FAL_KEY", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        state.saveAPIKey(draftKey)
                        showSaved = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { showSaved = false }
                            await state.loadModels()
                            await state.refreshBalance()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draftKey.isEmpty)

                    Button("Clear") {
                        draftKey = ""
                        state.saveAPIKey("")
                    }
                    .disabled(state.apiKey.isEmpty && draftKey.isEmpty)

                    if showSaved { Text("Saved").foregroundStyle(.secondary) }
                    Spacer()
                    Link("Get a key →", destination: URL(string: "https://fal.ai/dashboard/keys")!)
                }
                Text("Stored in your macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Add another profile") {
                HStack {
                    TextField("Profile name (e.g. Team, Work)", text: $draftProfile)
                        .textFieldStyle(.roundedBorder)
                    Button("Switch / create") {
                        let name = draftProfile.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        if state.apiProfiles.contains(name) {
                            state.activeProfile = name
                        } else {
                            state.setKey("", for: name)
                        }
                        draftProfile = ""
                        draftKey = ""
                    }
                    .disabled(draftProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Each profile has its own key, balance, and run history view.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Gallery") {
                Toggle(isOn: Binding(
                    get: { gallery.autoDownload },
                    set: { gallery.autoDownload = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-save generated media")
                        Text("Every completed run's outputs are downloaded to the Gallery folder and indexed in the Gallery window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gallery folder").font(.callout)
                        Text(gallery.folder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            gallery.setFolder(url)
                            state.saveDownloadFolder(url)
                        }
                    }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([gallery.folder])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { draftKey = state.apiKey }
    }
}
