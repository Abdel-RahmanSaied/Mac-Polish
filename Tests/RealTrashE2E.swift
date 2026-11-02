import Foundation

private final class TrashRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(URL, URL)] = []
    func add(_ original: URL, _ trashed: URL) { lock.lock(); defer { lock.unlock() }; entries.append((original, trashed)) }
    var all: [(URL, URL)] { lock.lock(); defer { lock.unlock() }; return entries }
}

@main
enum RealTrashE2E {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-E2E-" + UUID().uuidString)
        let records = TrashRecords()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for (original, trashed) in records.all where fm.fileExists(atPath: trashed.path) {
                try? fm.moveItem(at: trashed, to: original)
            }
            try? fm.removeItem(at: root)
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "MacPolishE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let first = Data(repeating: 17, count: 2 * 1024 * 1024)
        let second = Data(repeating: 29, count: 2 * 1024 * 1024)
        for (name, data) in [("a-original.bin", first), ("b-copy.bin", first), ("c-copy.bin", first),
                             ("d-original.bin", second), ("e-changed.bin", second),
                             ("gomodcache/module/cache.bin", first), ("node_modules/package/cache.bin", first)] {
            let url = root.appending(path: name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        var scanned = DuplicateScanner().scan(roots: [root])
        try check(scanned.count == 5, "Scan must exclude managed dependencies and find the five fixture files")
        let extras = DuplicateSelection.extras(in: scanned)
        for index in scanned.indices { scanned[index].isSelected = extras.contains(scanned[index].id) }
        try Data("changed after scanning".utf8).write(to: root.appending(path: "e-changed.bin"))
        let outcome = DuplicateCleaner().clean(scanned) { url in
            guard url.path.hasPrefix(root.path + "/") else { throw NSError(domain: "MacPolishE2E", code: 2) }
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            guard let destination else { throw NSError(domain: "MacPolishE2E", code: 3) }
            records.add(url, destination as URL)
        }
        try check(outcome.removedCount == 2 && records.all.count == 2, "Exactly two unchanged fixture duplicates must reach Trash")
        try check(outcome.issues.count == 1 && outcome.issues[0].kind == .changed, "Changed fixture must be skipped")
        try check(fm.fileExists(atPath: root.appending(path: "a-original.bin").path), "First keeper must remain")
        try check(fm.fileExists(atPath: root.appending(path: "d-original.bin").path), "Second keeper must remain")
        try check(fm.fileExists(atPath: root.appending(path: "e-changed.bin").path), "Changed file must remain")
        for (original, trashed) in records.all {
            try check(!fm.fileExists(atPath: original.path) && fm.fileExists(atPath: trashed.path), "Fixture must actually move to macOS Trash")
            try fm.moveItem(at: trashed, to: original)
            try check(try Data(contentsOf: original) == first, "Restored fixture must retain its exact bytes")
        }
        print("PASS E2E: real scan → select extras → revalidate → macOS Trash → restore; two moves, one changed-file skip, both keepers intact")
    }
}
