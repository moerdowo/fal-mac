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

        // Show the rainbow F in the Dock. The asset catalog handles the
        // Finder / Get-Info icon for Xcode builds; this covers `swift run`
        // where Assets.car may not be compiled into the executable.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        } else if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }

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
                    if !state.apiKey.isEmpty {
                        if state.allModels.isEmpty { await state.loadModels() }
                        await state.refreshBalance()
                    }
                }
        }
        .windowToolbarStyle(.unified)

        // Separate Gallery window — opened via the toolbar button in the
        // main window. macOS allows reopening from Window menu after close.
        WindowGroup("Gallery", id: "gallery") {
            GalleryView()
                .environmentObject(state)
        }
        .defaultSize(width: 900, height: 620)

        // ⌘, is wired automatically when a Settings scene exists.
        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 540, height: 360)
        }
    }
}
