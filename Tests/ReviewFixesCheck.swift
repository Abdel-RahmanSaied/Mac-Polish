import Foundation

/// Regression checks for the defects found in the deep review: what confirmations count, what cancelling restores,
/// when pages rescan, what happens to scans refused by the access gate, and duplicate cleanup bounds.
@main
enum ReviewFixesCheck {
    @MainActor static func main() throws {
        let suite = "MacPolish-review-fixes-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = AccessSetupModel(defaults: defaults, probe: { .unknown }, copies: { [] })
        let app = AppModel(access: access)

        // Duplicate plan: a group where every copy is ticked still keeps one, and the totals say so.
        func file(_ path: String, _ print: String, selected: Bool) -> DuplicateFile {
            DuplicateFile(id: UUID(), url: URL(fileURLWithPath: path), size: 1_000, fingerprint: print, isSelected: selected, diskBytes: 1_000)
        }
        app.duplicateFiles = [file("/x/b", "A", selected: true), file("/x/a", "A", selected: true), file("/x/c", "A", selected: true),
                              file("/y/a", "B", selected: false), file("/y/b", "B", selected: true)]
        precondition(app.duplicateGroups.count == 2 && app.duplicateGroups.allSatisfy { $0.files.map(\.url.path) == $0.files.map(\.url.path).sorted() },
                     "groups are cached and sorted by path")
        let plan = app.duplicateRemovalPlan.map(\.url.path).sorted()
        precondition(plan == ["/x/b", "/x/c", "/y/b"], "the first path of a fully selected group is kept: \(plan)")
        precondition(app.selectedDuplicateSize == 3_000, "the confirmed size never includes the kept copy")

        // Remove All replaces the selection for review; cancelling restores the hand-made one.
        let manual = Dictionary(uniqueKeysWithValues: app.duplicateFiles.map { ($0.url.path, $0.isSelected) })
        app.duplicateState = .ready
        app.prepareAllDuplicateRemoval()
        precondition(app.confirmsDuplicateRemoval && app.duplicateFiles.first { $0.url.path == "/y/a" }?.isSelected == false)
        app.cancelDuplicateRemoval()
        precondition(Dictionary(uniqueKeysWithValues: app.duplicateFiles.map { ($0.url.path, $0.isSelected) }) == manual,
                     "cancelling Remove All restores the previous selection")

        // A finished scan with no duplicates is a result, not a reason to hash everything again on every visit.
        defaults.set(true, forKey: AccessSetupModel.reviewedKey)
        app.duplicateFiles = []
        app.duplicateState = .ready
        app.findDuplicates()
        precondition(app.duplicateState == .ready, "an empty result must not rescan on revisit")
        app.startupState = .ready
        app.loadStartupItems()
        precondition(app.startupState == .ready)

        // Scans refused by the gate are remembered and start when the review is finished, instead of staying idle.
        let gated = AccessSetupModel(defaults: UserDefaults(suiteName: suite + "-gated")!, probe: { .unknown }, copies: { [] })
        defer { UserDefaults().removePersistentDomain(forName: suite + "-gated") }
        let waiting = AppModel(access: gated)
        waiting.findDuplicates()
        waiting.loadStartupItems()
        precondition(waiting.duplicateState == .idle && waiting.startupState == .idle && gated.presented)
        gated.results = FolderAccessCheck.locations().map { FolderAccessResult(name: $0.0, url: $0.1, status: .readable) }
        gated.checkedAt = Date()
        gated.fullDiskAccess = .unknown
        gated.finish()
        precondition(waiting.duplicateState == .loading && waiting.startupState == .loading,
                     "refused scans start once the review completes")

        // Every new scan entry point is behind the same gate: nothing reads files before the review.
        let freshSuite = suite + "-fresh"
        defer { UserDefaults().removePersistentDomain(forName: freshSuite) }
        let fresh = AppModel(access: AccessSetupModel(defaults: UserDefaults(suiteName: freshSuite)!, probe: { .unknown }, copies: { [] }))
        fresh.artifacts.scan()
        fresh.startupAudit.scan()
        fresh.orphans.scan()
        fresh.deepScan.start()
        precondition(fresh.artifacts.state == .idle && fresh.startupAudit.state == .idle && fresh.orphans.state == .idle
                     && !fresh.deepScan.running && fresh.deepScan.steps.isEmpty && fresh.access.presented,
                     "artifacts, startup audit, orphans and deep scan must refuse before access review")

        // Optimize moves items on its own scan; the Cleanup page must not keep offering those paths.
        let moved = URL(fileURLWithPath: "/tmp/moved-cache")
        app.items = [ScanItem(url: moved, size: 10, category: .cache, modifiedAt: nil),
                     ScanItem(url: URL(fileURLWithPath: "/tmp/kept-cache"), size: 10, category: .cache, modifiedAt: nil)]
        app.optimizer.onOutcome?(CleanupOutcome(date: Date(), movedCount: 1, movedBytes: 10, issues: [], movedURLs: [moved.standardizedFileURL]))
        precondition(app.items.map(\.url.lastPathComponent) == ["kept-cache"], "Optimize removals prune Cleanup items")

        // A disk map shared by Optimize does not end a Storage Map analysis that is still running.
        app.storageState = .loading
        let tree = DiskTreeResult(root: DiskNode(name: "Data", kind: .folder))
        app.optimizer.onDiskMap?(DiskMapReport(tree: tree, volumes: nil, reconciliation: nil, date: Date()))
        precondition(app.storageState == .loading && app.diskMap != nil)

        // Permission review after a failed cleanup opens on a step that shows the cleanup explanation.
        access.step = .welcome
        app.operationIssues = [CleanupIssue(url: moved, kind: .appManagement, detail: "blocked")]
        app.reviewCleanupPermissions()
        precondition(access.step == .review || access.step == .diskAccess)

        // Duplicate cleanup: a past deadline moves nothing and says why; a valid group keeps exactly one copy.
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-review-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let paths = ["a.bin", "b.bin", "c.bin"].map { root.appending(path: $0) }
        for path in paths { try content.write(to: path) }
        let digest = try FileFingerprint.sha256(paths[0])
        let copies = paths.enumerated().map { DuplicateFile(id: UUID(), url: $1, size: Int64(content.count), fingerprint: digest, isSelected: $0 > 0) }
        let late = DuplicateCleaner().clean(copies, deadline: Date().addingTimeInterval(-1), trashItem: { _ in preconditionFailure("must not move after the deadline") })
        precondition(late.removedCount == 0 && late.issues.contains { $0.detail.contains("time limit") })
        final class Recorder: @unchecked Sendable { var urls: [URL] = []; let lock = NSLock()
            func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() } }
        let recorder = Recorder()
        let done = DuplicateCleaner().clean(copies, trashItem: { recorder.add($0) })
        precondition(done.removedCount == 2 && Set(recorder.urls) == Set(paths.dropFirst()), "two extra copies move, the first is kept")

        // A keeper edited after it was verified stops the rest of its group.
        let edited = recorder
        edited.urls = []
        let changing = DuplicateCleaner().clean(copies, trashItem: { url in
            edited.add(url)
            // Simulate another app writing to the kept copy after the first move.
            try? Data([1, 2, 3]).write(to: paths[0])
        })
        precondition(changing.removedCount == 1 && changing.issues.contains { $0.url == paths[0] && $0.kind == .changed },
                     "a keeper that changes mid-group stops further moves")

        print("PASS: duplicate plans keep one copy and confirm only what moves, Remove All cancel restores selection, empty results don't rescan, gated scans resume after review, new entry points are gated, Optimize prunes Cleanup, shared maps keep loading state, permission review opens on the cleanup step, duplicate cleanup honours deadlines and keeper changes")
    }
}
