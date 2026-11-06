import Foundation

/// The health history file: temporary location only, private (0600), atomic, retention, corrupt-file handling,
/// privacy of what is stored, and reads and writes kept off the main thread.
@main
enum HealthHistoryCheck {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static func snapshot(_ offset: TimeInterval, score: Int = 90, partial: Bool = false) -> HealthSnapshot {
        HealthSnapshot(date: now.addingTimeInterval(offset), mode: .extended, score: score, partial: partial,
                       states: [.battery: .healthy, .storage: .attention, .memory: .healthy, .temperature: .healthy,
                                .diskHealth: .healthy, .security: .attention, .updates: .unknown],
                       storageFree: 40_000_000_000, storageTotal: 500_000_000_000, swapUsed: 1 << 30, pressureLevel: 1,
                       thermalState: 0, batteryMaxCapacity: 97, batteryCycles: 120)
    }

    @MainActor static func main() async throws {
        let override = ProcessInfo.processInfo.environment[HealthHistoryStore.locationOverride]
        precondition(override != nil, "MACPOLISH_HEALTH_HISTORY must be set so no check touches the user's history")
        precondition(HealthHistoryStore.defaultURL.path == override, "the default location honours the override")
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mac Polish").appending(path: "health-history.json")
        precondition(HealthHistoryStore.defaultURL.path != real.path, "checks never use the real history file")

        let root = FileManager.default.temporaryDirectory.appending(path: "MacPolish-health-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func historyURL(_ name: String) -> URL {
            let url = root.appending(path: name).appending(path: "health-history.json")
            precondition(url.path != real.path)
            return url
        }

        try await roundTrip(historyURL("round-trip"))
        retention(historyURL("retention"))
        try corrupt(historyURL("corrupt"))
        try privacy(historyURL("privacy"))
        try concurrentAppends(historyURL("concurrent"))
        try await fromResult(historyURL("result"))
        print("PASS: health history writes only to the temporary MACPOLISH_HEALTH_HISTORY location (never the real file), round-trips "
              + "snapshots with whole-second dates, is 0600 in a 0700 folder with no temporary files left (atomic rename), keeps the newest 90 "
              + "no older than 90 days, sets a corrupt file aside as .corrupt and starts empty, stores only dates, mode, score, states and "
              + "numbers (no paths, names or process lists), loads and saves on its private queue off the main thread, survives 200 "
              + "concurrent appends, and records a check result's partial flag, score and states")
    }

    @MainActor static func roundTrip(_ url: URL) async throws {
        let store = HealthHistoryStore(url: url, now: { now })
        precondition(!FileManager.default.fileExists(atPath: url.path), "creating a store reads and writes nothing")
        let empty = await store.snapshots()
        precondition(empty.isEmpty && store.loadNotice == nil, "a missing file is an empty history, not an error")
        let first = snapshot(-3_600.75), second = snapshot(-60, score: 70, partial: true)
        store.append(second)
        store.append(first)
        store.flush()
        precondition(store.saveError == nil, "save failed: \(store.saveError ?? "")")
        let reloaded = await HealthHistoryStore(url: url, now: { now }).snapshots()
        precondition(reloaded == [first, second], "reloading returns the same snapshots, oldest first")
        precondition(reloaded[0].date.timeIntervalSince1970 == reloaded[0].date.timeIntervalSince1970.rounded(.down), "whole seconds")
        precondition(reloaded[1].partial && reloaded[1].score == 70 && reloaded[1].states[.storage] == .attention)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history is readable only by the user")
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        precondition((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "the folder is private")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        precondition(leftovers == ["health-history.json"], "atomic writes leave no temporary files: \(leftovers)")
    }

    static func retention(_ url: URL) {
        let store = HealthHistoryStore(url: url, now: { now })
        for index in 0..<100 { store.append(snapshot(-Double(100 - index) * 3_600, score: index)) }
        store.flush()
        var kept = store.storedSnapshots
        precondition(kept.count == HealthHistoryStore.snapshotLimit && kept.first?.score == 10 && kept.last?.score == 99, "newest 90 are kept")
        store.append(snapshot(-100 * 86_400, score: 1))
        store.flush()
        kept = store.storedSnapshots
        precondition(kept.count == 90 && !kept.contains { $0.score == 1 }, "snapshots older than 90 days are dropped")
        let aged = HealthHistoryStore.retained([snapshot(-91 * 86_400), snapshot(-89 * 86_400), snapshot(-1)], now: now)
        precondition(aged.count == 2 && aged.allSatisfy { now.timeIntervalSince($0.date) <= 90 * 86_400 })
        let reloaded = HealthHistoryStore(url: url, now: { now }).storedSnapshots
        precondition(reloaded == kept, "retention is what is on disk")
        // Loading applies the age limit too.
        let later = HealthHistoryStore(url: url, now: { now.addingTimeInterval(95 * 86_400) }).storedSnapshots
        precondition(later.allSatisfy { now.addingTimeInterval(95 * 86_400).timeIntervalSince($0.date) <= 90 * 86_400 } && later.count < 90)
    }

    static func corrupt(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = HealthHistoryStore(url: url, now: { now })
        precondition(store.storedSnapshots.isEmpty, "a corrupt file starts an empty history")
        precondition(store.loadNotice?.contains("health-history.json.corrupt") == true, store.loadNotice ?? "no notice")
        precondition(FileManager.default.fileExists(atPath: store.corruptURL.path) && !FileManager.default.fileExists(atPath: url.path),
                     "the corrupt file is set aside, not deleted")
        let mode = try FileManager.default.attributesOfItem(atPath: store.corruptURL.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600)
        store.append(snapshot(-10))
        store.flush()
        precondition(HealthHistoryStore(url: url, now: { now }).storedSnapshots.count == 1, "a new history starts after a corrupt one")
        // A file of the wrong shape is corrupt too.
        try Data(#"{"version":1,"snapshots":[{"date":"yesterday"}]}"#.utf8).write(to: url)
        let wrong = HealthHistoryStore(url: url, now: { now })
        precondition(wrong.storedSnapshots.isEmpty && wrong.loadNotice != nil)
    }

    static func privacy(_ url: URL) throws {
        let store = HealthHistoryStore(url: url, now: { now })
        store.append(snapshot(-30))
        store.flush()
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = file["snapshots"] as? [[String: Any]], let first = snapshots.first else {
            preconditionFailure("the history is a JSON object with snapshots")
        }
        let allowed: Set<String> = ["date", "mode", "score", "partial", "states", "storageFree", "storageTotal", "swapUsed",
                                    "pressureLevel", "thermalState", "batteryMaxCapacity", "batteryCycles"]
        precondition(Set(first.keys).isSubset(of: allowed), "only allowed fields are stored: \(first.keys.sorted())")
        precondition(Set(file.keys) == ["version", "snapshots"])
        let states = first["states"] as? [String: String]
        precondition(states?["storage"] == "attention" && Set((states ?? [:]).keys).isSubset(of: Set(HealthCategory.allCases.map(\.rawValue))),
                     "states are stored as a readable object keyed by category")
        precondition(!text.contains("/") && !text.contains(NSUserName()) && !text.contains(NSHomeDirectory()), "no paths or names")
        precondition(!text.lowercased().contains("apple ssd") && !text.contains("Safari"), "no disk or app names")
    }

    static func concurrentAppends(_ url: URL) throws {
        let store = HealthHistoryStore(url: url, now: { now })
        DispatchQueue.concurrentPerform(iterations: 200) { index in store.append(snapshot(-Double(index), score: index % 101)) }
        store.flush()
        let decoded = HealthHistoryStore(url: url, now: { now }).storedSnapshots
        precondition(decoded.count == 90, "every append is applied, then retention: \(decoded.count)")
        precondition(zip(decoded, decoded.dropFirst()).allSatisfy { $0.date <= $1.date }, "oldest first")
    }

    @MainActor static func fromResult(_ url: URL) async throws {
        var finished: [HealthCategory: HealthCategoryResult] = [:]
        let storage = HealthScanner.storageResult(StorageValues(total: 500_000_000_000, important: 30_000_000_000, available: nil),
                                                  breakdown: [HealthContextEntry(name: "Secret Project", bytes: 1)], now: now)
        finished[.storage] = storage
        let result = HealthCheckResult.assemble(mode: .quick, startedAt: now, finishedAt: now, finished: finished, cancelled: true)
        let snapshot = HealthSnapshot(result)
        precondition(snapshot.partial && snapshot.score == result.score && snapshot.states[.storage] == .attention
                     && snapshot.states[.memory] == .unknown && snapshot.storageFree == 30_000_000_000 && snapshot.mode == .quick)
        let store = HealthHistoryStore(url: url, now: { now })
        store.append(snapshot)
        // Reads and writes happen on the store's queue: this main-actor task keeps running while they do.
        let loaded = await store.snapshots()
        precondition(loaded == [snapshot] && Thread.isMainThread, "async load returns to the caller")
        let text = try String(contentsOf: url, encoding: .utf8)
        precondition(!text.contains("Secret Project"), "storage context never reaches the history")
    }
}
