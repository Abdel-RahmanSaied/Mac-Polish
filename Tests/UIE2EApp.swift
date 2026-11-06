import AppKit
import SwiftUI

@MainActor
private func makeUIModel() -> AppModel {
    let model = AppModel()
    model.access.presented = false
    model.destination = .duplicates
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-UIE2E-" + UUID().uuidString)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Cleanup History of this test app stays with its fixtures, never in the real app's history file.
        model.cleanupHistory = CleanupHistoryModel(store: CleanupHistoryStore(url: root.appending(path: "cleanup-history.json")))
        let payload = Data(repeating: 37, count: 2 * 1024 * 1024)
        try payload.write(to: root.appending(path: "a-original.bin"))
        try payload.write(to: root.appending(path: "b-duplicate.bin"))
        try root.path.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "ui-e2e-root.txt"), atomically: true, encoding: .utf8)
        model.duplicateFiles = DuplicateScanner().scan(roots: [root])
        model.duplicateState = .ready
    } catch { fatalError("Cannot prepare isolated UI fixtures: \(error)") }
    return model
}

@main
struct UIE2EApp: App {
    @StateObject private var model = makeUIModel()
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView().environmentObject(model).frame(minWidth: 1050, minHeight: 680)
                .safeAreaInset(edge: .bottom) { Text("E2E fixture data · confirmation and cancellation tests").font(.caption).padding(5) }
                .task { model.memory.start() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("E2E") {
                Button("Simulate Permission Error") {
                    let url = model.duplicateFiles.last!.url
                    model.showCleanupOutcome(removedCount: 0, bytes: 0, issues: [CleanupIssue(url: url, kind: .permission, detail: "Simulated access denial for an isolated test fixture.")])
                }
                Button("Simulate Locked File") {
                    let url = model.duplicateFiles.last!.url
                    model.showCleanupOutcome(removedCount: 0, bytes: 0, issues: [CleanupIssue(url: url, kind: .locked, detail: "Simulated locked test fixture.")])
                }
            }
        }
        Settings { SettingsView().environmentObject(model).frame(width: 520, height: 460) }
    }
}
