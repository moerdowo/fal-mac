import SwiftUI

@main
struct FalMacApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("fal.ai") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    if !state.apiKey.isEmpty, state.allModels.isEmpty {
                        await state.loadModels()
                    }
                }
        }
        .windowToolbarStyle(.unified)

        // ⌘, is wired automatically when a Settings scene exists.
        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 520, height: 280)
        }
    }
}
