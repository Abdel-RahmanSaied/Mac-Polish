import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
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
                .frame(width: 520, height: 460)
        }
    }
}
