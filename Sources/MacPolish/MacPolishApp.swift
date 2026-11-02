import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow = NSApp.windows.first(where: { $0.canBecomeMain })
            self.mainWindow?.isReleasedWhenClosed = false
            self.mainWindow?.makeKeyAndOrderFront(nil)
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
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)
        .commands {
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
