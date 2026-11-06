import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()

        // ContentView registers its own window (MainWindowRegistration); bring it forward once it exists.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.showExisting()
        }
    }

    private func applyDockIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        // Set the running Dock tile directly, including when Launch Services has cached a generic icon.
        NSApp.applicationIconImage = icon
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        applyDockIcon()
        if !flag { MainWindow.showExisting() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting ends any scan worker still running instead of leaving it to finish its time limit.
    func applicationWillTerminate(_ notification: Notification) {
        WorkerProcesses.shared.terminateAll()
    }
}

struct MacPolishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_050, minHeight: 680)
                .task { model.memory.start() }
                .task { model.updates.start() }
                // Notices a Full Disk Access grant lost since the last launch, for example after an update.
                .task { await model.access.verifyOnLaunch() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)
        .commands {
            // Mac Polish has one main window; File › New Window would create unmanaged duplicates.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updates.check() }
                    openSettings()
                }
            }
        }

        MenuBarExtra {
            MemoryMenu(model: model, monitor: model.memory)
        } label: {
            Label("Mac Polish", systemImage: "memorychip")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 640)
        }
    }
}
