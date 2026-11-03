import Foundation

/// "Move Selected to Trash" on result pages must ask first, summarise exactly what will move,
/// and do nothing until confirmed.
@main
enum CleanupConfirmationCheck {
    @MainActor
    static func main() async {
        let model = AppModel()
        model.access.presented = false
        // Paths outside every cleanup root: even a confirmed run cannot move anything.
        let root = FileManager.default.temporaryDirectory.appending(path: "MacPolish-confirm-" + UUID().uuidString)
        let a = ScanItem(url: root.appending(path: "a"), size: 100, category: .cache, modifiedAt: nil, isSelected: true)
        let b = ScanItem(url: root.appending(path: "b"), size: 50, category: .cache, modifiedAt: nil, isSelected: true)
        let c = ScanItem(url: root.appending(path: "c"), size: 25, category: .cache, modifiedAt: nil, isSelected: false)
        model.items = [a, b, c]
        model.state = .finished

        // Break caught: cleaning starts on the first click.
        model.requestCleanup(itemIDs: [a.id, b.id, c.id])
        precondition(model.state == .finished, "Requesting cleanup must not start it")
        precondition(model.pendingCleanup?.count == 2 && model.pendingCleanup?.bytes == 150,
                     "The confirmation must describe only the selected items in scope")

        model.cancelCleanup()
        precondition(model.pendingCleanup == nil && model.state == .finished, "Cancel must leave everything untouched")

        // Break caught: confirming more than the visible scope the user reviewed.
        model.requestCleanup(itemIDs: [b.id])
        precondition(model.pendingCleanup?.count == 1 && model.pendingCleanup?.bytes == 50)
        model.confirmCleanup()
        precondition(model.pendingCleanup == nil && model.state == .cleaning, "Confirming starts the cleanup")
        for _ in 0..<200 where model.state == .cleaning { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(model.state == .finished && model.lastCleanup?.issues.map(\.url) == [b.url],
                     "Only the confirmed item is processed")

        // Break caught: an empty confirmation dialog.
        model.requestCleanup(itemIDs: [c.id])
        precondition(model.pendingCleanup == nil, "Nothing selected means no confirmation")
        print("PASS: cleanup asks first, summarises the selected scope, cancels cleanly and runs only what was confirmed")
    }
}
