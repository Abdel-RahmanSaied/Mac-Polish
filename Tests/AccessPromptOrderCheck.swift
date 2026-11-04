import Foundation

private final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peakPrompting = 0
    private(set) var promptOrder: [String] = []
    private(set) var otherStarts: [String: Date] = [:]
    private(set) var promptEnds: [String: Date] = [:]
    func begin(_ name: String, prompting: Bool) {
        lock.lock(); defer { lock.unlock() }
        if prompting { active += 1; peakPrompting = max(peakPrompting, active); promptOrder.append(name) }
        else { otherStarts[name] = Date() }
    }
    func end(_ name: String, prompting: Bool) {
        lock.lock(); defer { lock.unlock() }
        if prompting { active -= 1; promptEnds[name] = Date() }
    }
}

/// macOS shows one folder access prompt at a time. Folders that can prompt are checked one after another,
/// so each gets its own full time limit instead of sharing one window with the prompts queued before it.
@main
enum AccessPromptOrderCheck {
    static func main() {
        let prompting = FolderAccessCheck.promptingLocations
        precondition(prompting == ["Desktop", "Documents", "Downloads"], "The folders macOS asks about, got \(prompting)")

        let tracker = Tracker()
        let started = Date()
        let check = FolderAccessCheck.checkAll { name, url in
            let isPrompting = prompting.contains(name)
            tracker.begin(name, prompting: isPrompting)
            // A prompting folder waits as if the user is reading a macOS request.
            Thread.sleep(forTimeInterval: isPrompting ? 0.3 : 0.05)
            tracker.end(name, prompting: isPrompting)
            return .success([FolderAccessResult(name: name, url: url, status: .readable)])
        }
        let elapsed = Date().timeIntervalSince(started)

        // Break caught: all prompting folders started at once, sharing one deadline.
        precondition(tracker.peakPrompting == 1, "Prompting folders must not overlap, peak \(tracker.peakPrompting)")
        precondition(tracker.promptOrder == ["Desktop", "Documents", "Downloads"], "Order follows the setup list, got \(tracker.promptOrder)")
        precondition(elapsed >= 0.85, "Sequential prompting folders take their time one after another (\(elapsed)s)")
        // Folders that never prompt are not held back behind the prompts.
        if let firstPromptEnd = tracker.promptEnds["Desktop"] {
            precondition(tracker.otherStarts.values.allSatisfy { $0 < firstPromptEnd }, "Other folders start alongside the first prompt")
        } else { preconditionFailure("Desktop finished") }
        precondition(check.results.map(\.name) == FolderAccessCheck.locations().map(\.0), "Results keep the setup list order")
        precondition(check.results.allSatisfy { $0.status == .readable } && check.warning == nil)

        // A folder that does not answer still only affects itself.
        let stalled = FolderAccessCheck.checkAll { name, url in
            name == "Documents" ? .failure(DiskScanFailure(message: "waiting", timedOut: true))
                : .success([FolderAccessResult(name: name, url: url, status: .readable)])
        }
        precondition(stalled.results.first { $0.name == "Documents" }?.status == .timedOut)
        precondition(stalled.results.first { $0.name == "Downloads" }?.status == .readable, "Downloads is checked after Documents stalls")
        print("PASS: prompting folders are checked one at a time with their own time limit; other folders run alongside")
    }
}
