import SwiftUI
import AppKit

/// Apps launched via `swift run` have no `.app` bundle / Info.plist, so AppKit
/// defaults to `.accessory` activation. That leaves the window unable to
/// become key, which means text fields can't receive keystrokes. Forcing
/// `.regular` here makes the app behave like a real foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure the first window becomes key so keyboard input is routed.
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct FalMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
