import Foundation

/// Cleanup history (file-backed, private, capped, corruption-tolerant) and the shared cleanup confirmation builders.
/// Uses only new temporary folders: never the real Trash and never the real history file.
@main
@MainActor
enum CleanupHistoryCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacPolish-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultPath = CleanupHistoryStore.defaultURL.path
        func historyURL(_ name: String) -> URL {
            let url = root.appending(path: name).appending(path: "cleanup-history.json")
            precondition(url.path != defaultPath, "Checks must never use the real history file")
            return url
        }

        try roundTrip(historyURL("round-trip"))
        try corruptFile(historyURL("corrupt"))
        cap(historyURL("cap"))
        mapping()
        try privacy(historyURL("privacy"), root: root)
        try model(historyURL("model"))
        confirmations()
        gate()
        print("PASS: cleanup history round-trips from disk with 0600 permissions, sets a corrupt file aside as .corrupt and starts empty, keeps the newest 500, maps moved/skipped entries with sizes and reasons, never stores file contents, and clears without touching files; confirmations sum counts and bytes, pass hidden-by-search through, explain every group (warnings for large files, device backups, Python venvs and leftover app data), truncate names with \"and N more\", and finish once")
    }

    // MARK: History

    static func roundTrip(_ url: URL) throws {
        let store = CleanupHistoryStore(url: url)
        precondition(store.records.isEmpty && store.loadNotice == nil, "A missing file is an empty history, not an error")
        let moved = [CleanupRecord.Entry(path: "/tmp/a cache", bytes: 1_000), CleanupRecord.Entry(path: "/tmp/b", bytes: nil)]
        let skipped = [CleanupRecord.Entry(path: "/tmp/c", bytes: 30, reason: "The item changed after scanning.")]
        let first = store.record(source: "Cleanup", moved: moved, skipped: skipped, date: Date(timeIntervalSince1970: 1_700_000_000.75))
        let second = store.record(source: "Optimize", moved: [.dockerBuildCache(bytes: 5)], skipped: [], permanent: true,
                                  date: Date(timeIntervalSince1970: 1_700_000_100))
        precondition(store.record(source: "Cleanup", moved: [], skipped: []) == nil, "An empty cleanup is not recorded")
        precondition(store.saveError == nil, "Save failed: \(store.saveError ?? "")")

        let reloaded = CleanupHistoryStore(url: url)
        precondition(reloaded.records == [second!, first!], "Reloading from disk must return the same records, newest first")
        let record = reloaded.records[1]
        precondition(record.source == "Cleanup" && record.moved == moved && record.skipped == skipped && !record.permanent)
        precondition(record.movedBytes == 1_000, "Unknown sizes are not counted")
        precondition(reloaded.records[0].permanent, "Permanent removal must survive a reload")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600, "History must be readable only by the user, got \(String(mode?.intValue ?? -1, radix: 8))")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        precondition(leftovers == ["cleanup-history.json"], "Atomic writes must not leave temporary files: \(leftovers)")

        // A record written by an older build without `permanent` still loads.
        let legacy = #"{"version":1,"records":[{"id":"\#(UUID().uuidString)","date":"2024-01-01T00:00:00Z","source":"Cleanup","moved":[{"path":"/x","bytes":1}],"skipped":[]}]}"#
        try Data(legacy.utf8).write(to: url)
        let legacyStore = CleanupHistoryStore(url: url)
        precondition(legacyStore.records.count == 1 && !legacyStore.records[0].permanent && legacyStore.loadNotice == nil)

        // Clearing forgets the history only.
        let survivor = url.deletingLastPathComponent().appending(path: "user-file.txt")
        try Data("keep".utf8).write(to: survivor)
        legacyStore.clear()
        precondition(legacyStore.records.isEmpty && CleanupHistoryStore(url: url).records.isEmpty, "Clear must persist")
        precondition(FileManager.default.fileExists(atPath: survivor.path), "Clearing history must not touch other files")
    }

    static func corruptFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{\"version\":1,\"records\":[{\"id\":".utf8)
        try garbage.write(to: url)
        let store = CleanupHistoryStore(url: url)
        precondition(store.records.isEmpty, "A corrupt file starts an empty history")
        precondition(store.loadNotice?.contains(".corrupt") == true, "The user is told the old file was kept")
        precondition(FileManager.default.contents(atPath: store.corruptURL.path) == garbage,
                     "The corrupt file is kept aside unchanged as .corrupt")
        precondition(store.corruptURL.lastPathComponent == "cleanup-history.json.corrupt")
        precondition(!FileManager.default.fileExists(atPath: url.path), "The corrupt file was moved, not copied")

        store.record(source: "Duplicates", moved: [.init(path: "/tmp/d", bytes: 1)], skipped: [])
        precondition(CleanupHistoryStore(url: url).records.count == 1, "Recording works again after a corrupt file")
        precondition(FileManager.default.fileExists(atPath: store.corruptURL.path), "Recording keeps the .corrupt file")
        store.clear()
        precondition(!FileManager.default.fileExists(atPath: store.corruptURL.path), "Clear History also forgets the set-aside file")

        // Valid JSON of the wrong shape is corrupt too, and never crashes.
        try Data("[1,2,3]".utf8).write(to: url)
        precondition(CleanupHistoryStore(url: url).records.isEmpty)
    }

    static func cap(_ url: URL) {
        let store = CleanupHistoryStore(url: url)
        precondition(store.limit == 500 && CleanupHistoryStore.recordLimit == 500)
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        for index in 0..<510 {
            store.record(source: "Cleanup \(index)", moved: [.init(path: "/tmp/\(index)", bytes: Int64(index))], skipped: [],
                         date: start.addingTimeInterval(TimeInterval(index)))
        }
        for records in [store.records, CleanupHistoryStore(url: url).records] {
            precondition(records.count == 500, "Keep 500 records, got \(records.count)")
            precondition(records.first?.source == "Cleanup 509" && records.last?.source == "Cleanup 10",
                         "Keep the newest 500, newest first")
        }
    }

    static func mapping() {
        let a = (id: UUID(), url: URL(fileURLWithPath: "/tmp/history/a"), bytes: Int64(100))
        let b = (id: UUID(), url: URL(fileURLWithPath: "/tmp/history/b"), bytes: Int64(50))
        let c = (id: UUID(), url: URL(fileURLWithPath: "/tmp/history/c"), bytes: Int64(25))
        let d = (id: UUID(), url: URL(fileURLWithPath: "/tmp/history/d"), bytes: Int64(5))
        let other = URL(fileURLWithPath: "/tmp/history/leftover")
        let result = CleanupResult(
            removedCount: 1, reclaimedBytes: 100, failures: [], removedItemIDs: [a.id],
            issues: [CleanupIssue(url: b.url, kind: .changed, detail: "The item changed after scanning. Scan again before cleaning it."),
                     CleanupIssue(url: other, kind: .permission, detail: "macOS denied access.")])
        let entries = CleanupHistoryStore.entries(from: result, candidates: [a, b, c, d].filter { $0.id != d.id } )
        precondition(entries.moved == [.init(path: a.url.path, bytes: 100)], "Moved are the removed candidates with their sizes")
        precondition(entries.skipped.count == 3, "Every issue and every unreported candidate is skipped: \(entries.skipped)")
        precondition(entries.skipped[0] == .init(path: b.url.path, bytes: 50, reason: "The item changed after scanning. Scan again before cleaning it."),
                     "A skipped candidate keeps its size and the issue detail")
        precondition(entries.skipped[1] == .init(path: other.path, bytes: nil, reason: "macOS denied access."),
                     "An issue outside the candidates has no known size")
        precondition(entries.skipped[2].path == c.url.path && entries.skipped[2].bytes == 25 && entries.skipped[2].reason != nil,
                     "A candidate that neither moved nor reported is not silently dropped")
        precondition(!entries.skipped.contains { $0.path == d.url.path }, "Only candidates are recorded")

        let apps = ApplicationRemovalResult(removedIDs: [a.id], reclaimedBytes: 100, failures: [], issues: [])
        let appEntries = CleanupHistoryStore.entries(from: apps, candidates: [a])
        precondition(appEntries.moved.count == 1 && appEntries.skipped.isEmpty)
    }

    static func privacy(_ url: URL, root: URL) throws {
        let secret = "SECRET-\(UUID().uuidString)-do-not-store"
        let file = root.appending(path: "private notes.txt")
        try Data(secret.utf8).write(to: file)
        let item = ScanItem(url: file, size: Int64(secret.utf8.count), category: .largeFile, modifiedAt: nil)
        let result = CleanupResult(removedCount: 1, reclaimedBytes: item.size, failures: [], removedItemIDs: [item.id])
        let entries = CleanupHistoryStore.entries(from: result, candidates: [(id: item.id, url: item.url, bytes: item.size)])
        let store = CleanupHistoryStore(url: url)
        store.record(source: "Large Files", moved: entries.moved, skipped: entries.skipped)
        let json = try String(contentsOf: url, encoding: .utf8)
        precondition(json.contains(file.path), "The path is stored so the user can find the item again")
        precondition(!json.contains(secret) && !json.contains("SECRET-"), "History must never store file contents")
        let keys = ["bytes", "date", "id", "moved", "path", "permanent", "reason", "records", "skipped", "source", "version"]
        let found = Set(json.matches(of: #/"([a-zA-Z]+)":/#).map { String($0.output.1) })
        precondition(found.isSubset(of: Set(keys)), "Only paths, sizes, dates, sources and reasons are stored: \(found)")
    }

    static func model(_ url: URL) throws {
        let model = CleanupHistoryModel(store: CleanupHistoryStore(url: url))
        let item = (id: UUID(), url: URL(fileURLWithPath: "/tmp/history/model"), bytes: Int64(7))
        model.record(source: "Project Artifacts",
                     result: CleanupResult(removedCount: 1, reclaimedBytes: 7, failures: [], removedItemIDs: [item.id]),
                     candidates: [item])
        precondition(model.records.count == 1 && model.records[0].source == "Project Artifacts" && model.notice == nil)
        model.clear()
        precondition(model.records.isEmpty && CleanupHistoryStore(url: url).records.isEmpty)
    }

    // MARK: Confirmation

    static func confirmations() {
        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        let base = URL(fileURLWithPath: "/tmp/MacPolish-confirmation")
        let cache1 = ScanItem(url: base.appending(path: "c1"), size: 100, category: .cache, modifiedAt: old, newestContentModifiedAt: old)
        let cache2 = ScanItem(url: base.appending(path: "c2"), size: 200, category: .cache, modifiedAt: old, newestContentModifiedAt: old)
        let large = ScanItem(url: base.appending(path: "movie.mov"), size: 5_000, category: .largeFile, modifiedAt: old)
        let backup = ScanItem(url: base.appending(path: "backup"), size: 700, category: .deviceBackup, modifiedAt: old)
        let logs = ScanItem(url: base.appending(path: "recent.log"), size: 3, category: .logs, modifiedAt: now, newestContentModifiedAt: now)
        let items = [cache1, cache2, large, backup, logs]

        guard let confirmation = CleanupConfirmation.forScanItems(items, source: "Cleanup", hiddenBySearch: 2, now: now) else {
            preconditionFailure("Selected items need a confirmation")
        }
        precondition(confirmation.count == 5 && confirmation.bytes == 6_003, "Count and bytes are the sums of the items")
        precondition(confirmation.hiddenBySearch == 2 && confirmation.source == "Cleanup")
        precondition(confirmation.title == "Move 5 items to Trash?" && confirmation.actionTitle == "Move to Trash")
        precondition(confirmation.itemIDs == Set(items.map(\.id)), "Confirm runs exactly the described items")
        precondition(confirmation.names.first == "movie.mov", "Largest items are listed first")
        precondition(CleanupConfirmation.hiddenBySearchText(2) == "2 selected items are hidden by your search and will be included. Clear the search to review them first.")
        precondition(CleanupConfirmation.hiddenBySearchText(0) == nil)
        precondition(CleanupConfirmation.forScanItems([], source: "Cleanup") == nil, "Nothing selected means no confirmation")

        let groups = confirmation.groups
        precondition(groups.map(\.title) == [ScanCategory.cache, .logs, .largeFile, .deviceBackup].map(\.rawValue),
                     "One group per category, in category order: \(groups.map(\.title))")
        precondition(groups.allSatisfy { !$0.reason.isEmpty }, "Every group explains why")
        precondition(groups.reduce(0) { $0 + $1.count } == 5 && groups.reduce(Int64(0)) { $0 + $1.bytes } == 6_003)
        let cacheGroup = groups[0]
        precondition(cacheGroup.count == 2 && cacheGroup.bytes == 300)
        precondition(cacheGroup.reason == "Regenerated by apps; nothing inside changed for 7+ days.", cacheGroup.reason)
        precondition(cacheGroup.warning?.contains("rebuild") == true)
        precondition(!groups[1].reason.contains("nothing inside changed"), "Never claim old age for recently changed items")
        precondition(groups[2].reason.contains("not regenerable") && groups[2].warning?.isEmpty == false, "Large files warn")
        precondition(groups[3].warning?.contains("only backup") == true, "Device backups warn they may be the only backup")
        for category in ScanCategory.allCases {
            precondition(!CleanupConfirmation.explanation(for: category).reason.isEmpty, "\(category) needs a reason")
        }
        precondition(CleanupConfirmation.explanation(for: .oldInstaller).reason.contains("downloaded again from Apple"))

        // Optimize with Docker: permanent removal is explicit.
        let optimize = CleanupConfirmation.forOptimize([cache1], dockerBuildCacheBytes: 1_000, now: now)!
        precondition(optimize.bytes == 1_100 && optimize.permanentRemoval?.contains("permanently") == true
                     && optimize.groups.last?.warning?.contains("permanently") == true)
        precondition(CleanupConfirmation.forOptimize([], dockerBuildCacheBytes: 10)?.title == "Remove Docker build cache?")
        precondition(CleanupConfirmation.forOptimize([], dockerBuildCacheBytes: nil) == nil)

        // Duplicates: plan sizes on disk, one group, one copy kept.
        let dupes = [DuplicateFile(id: UUID(), url: URL(fileURLWithPath: "/tmp/x/a.jpg"), size: 10, fingerprint: "f", isSelected: true, diskBytes: 4),
                     DuplicateFile(id: UUID(), url: URL(fileURLWithPath: "/tmp/y/a.jpg"), size: 10, fingerprint: "f", isSelected: true)]
        let duplicates = CleanupConfirmation.forDuplicates(dupes, hiddenBySearch: 1)!
        precondition(duplicates.count == 2 && duplicates.bytes == 14 && duplicates.hiddenBySearch == 1)
        precondition(duplicates.groups.count == 1 && duplicates.groups[0].reason.contains("SHA-256") && duplicates.groups[0].reason.contains("one copy"))
        precondition(duplicates.notes.contains("At least one copy of each duplicate is kept."))
        precondition(duplicates.title == "Move 2 duplicate copies to Trash?")

        // Applications: app plus its own library data.
        let app = ApplicationItem(id: UUID(), name: "Editor", url: URL(fileURLWithPath: "/Applications/Editor.app"), bundleIdentifier: "com.example.editor",
                                  version: "1", size: 1_000, leftoverURLs: [URL(fileURLWithPath: "/tmp/lib")], leftoverSize: 24,
                                  canRemove: false, isSelected: true)
        let apps = CleanupConfirmation.forApplications([app])!
        precondition(apps.bytes == 1_024 && apps.groups[0].reason.contains("library data") && apps.title == "Move 1 app to Trash?")
        precondition(apps.notes.contains { $0.contains("administrator") }, "Apps that will be skipped are announced")

        // Project artifacts: per kind, the regenerate hint, and a strong warning for virtual environments.
        func artifact(_ kind: ProjectArtifactKind, _ size: Int64) -> ProjectArtifact {
            ProjectArtifact(url: base.appending(path: "proj/\(kind.folderNames[0])"), projectURL: base.appending(path: "proj"), kind: kind,
                            size: size, modifiedAt: nil, newestContentModifiedAt: nil, projectLastActivity: nil, isMeasurementComplete: true)
        }
        let artifacts = CleanupConfirmation.forProjectArtifacts([artifact(.nodeModules, 10), artifact(.pythonVenv, 20), artifact(.nodeModules, 5)], hiddenBySearch: 3)!
        precondition(artifacts.count == 3 && artifacts.bytes == 35 && artifacts.hiddenBySearch == 3)
        precondition(artifacts.groups.map(\.title) == [ProjectArtifactKind.nodeModules.displayName, ProjectArtifactKind.pythonVenv.displayName])
        precondition(artifacts.groups[0].count == 2 && artifacts.groups[0].reason.contains(ProjectArtifactKind.nodeModules.regenerateHint))
        precondition(artifacts.groups[1].warning?.contains("installed by hand") == true, "Virtual environments warn strongly")
        precondition(ProjectArtifactKind.allCases.allSatisfy { !CleanupConfirmation.explanation(for: $0).reason.isEmpty })
        precondition(artifacts.names.first == ".venv in proj")

        // Leftover app data: the bundle-identifier match can be wrong.
        let orphan = OrphanedDataItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/lib/com.gone.app"), bundleIdentifier: "com.gone.app",
                                      location: "Application Support", size: 64, newestContentModifiedAt: nil, modifiedAt: nil,
                                      isMeasurementComplete: true, isSelected: true)
        var shared = orphan
        shared.sameVendorApp = "com.gone.other"
        let orphaned = CleanupConfirmation.forOrphanedData([orphan, shared])!
        precondition(orphaned.bytes == 128 && orphaned.groups.count == 2)
        precondition(orphaned.groups.allSatisfy { $0.reason.contains("bundle identifier") && $0.reason.contains("other disks") && $0.warning?.isEmpty == false },
                     "Leftover app data explains the match and warns")

        // Names: the first 8, then "and N more".
        let names = (1...12).map { "item \($0)" }
        let truncated = CleanupConfirmation.truncatedNames(names)
        precondition(truncated.shown == Array(names.prefix(8)) && truncated.more == "and 4 more")
        precondition(CleanupConfirmation.truncatedNames(Array(names.prefix(8))).more == nil, "No suffix when all fit")
        precondition(CleanupConfirmation.truncatedNames(names, limit: 3).more == "and 9 more")
        precondition(CleanupConfirmation.trashExplanation == "Items go to Trash. Space is released when Trash is emptied; you can put items back from Trash until then.")
    }

    static func gate() {
        // Cancel then the sheet disappearing must report one cancel; a double click one confirm.
        let gate = CleanupConfirmationGate()
        let id = UUID()
        precondition(gate.claim(id) && !gate.claim(id) && !gate.claim(id), "A confirmation finishes exactly once")
        precondition(gate.claim(UUID()), "Each new confirmation can finish")
    }
}
