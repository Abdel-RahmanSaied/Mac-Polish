import Darwin
import Foundation

@main
enum EngineEvaluationCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-engine-" + UUID().uuidString)
        let locked = root.appending(path: "tree/locked")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        let bytes = Data(repeating: 11, count: 8192)
        let hidden = try write("Library/Caches/.hidden-cache/payload", bytes)
        let scanner = DiskScanner(home: root, applicationsRoot: root.appending(path: "Applications"))
        let caches = scanner.report(section: .caches)
        precondition(caches.items.contains { $0.url == hidden.deletingLastPathComponent() }, "Hidden cache directories must not disappear from cleanup")
        let trash = try write(".Trash/.hidden-file", bytes)
        precondition(scanner.report(section: .trash).items.contains { $0.url == trash }, "Hidden Trash items must be counted")

        let original = try write("duplicates/nested/a.bin", bytes)
        let duplicateRoot = root.appending(path: "duplicates")
        var matches = DuplicateScanner().scan(minimumSize: 1, roots: [duplicateRoot, original.deletingLastPathComponent(), duplicateRoot])
        precondition(matches.isEmpty, "Overlapping roots must not invent copies of the same file")
        try fm.linkItem(at: original, to: duplicateRoot.appending(path: "linked.bin"))
        matches = DuplicateScanner().scan(minimumSize: 1, roots: [duplicateRoot])
        precondition(matches.isEmpty, "Hard links are the same file, not reclaimable duplicates")
        let actualCopy = try write("duplicates/real-copy.bin", bytes)
        matches = DuplicateScanner().scan(minimumSize: 1, roots: [duplicateRoot])
        precondition(matches.count == 2 && matches.contains { $0.url == actualCopy }, "A real independent copy must still be found")

        _ = try write("tree/locked/hidden", bytes)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        // Installer bundles also need partial measurement and denied-path reporting.
        let installer = root.appending(path: "Applications/Install macOS Fixture.app")
        _ = try write("Applications/Install macOS Fixture.app/visible", bytes)
        let closedContent = installer.appending(path: "Contents")
        _ = try write("Applications/Install macOS Fixture.app/Contents/secret", bytes)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closedContent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closedContent.path) }
        let installers = scanner.report(section: .oldFiles)
        precondition(installers.deniedPaths.contains(closedContent.path)
                     && installers.items.contains { $0.url.standardizedFileURL.path == installer.standardizedFileURL.path && !$0.isMeasurementComplete && !$0.isSelected },
                     "Partly unreadable installers must not appear fully measured")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closedContent.path)

        let folded = DiskTreeScanner.scan(root.appending(path: "tree").path,
                                          options: DiskTreeOptions(maximumChildren: 0)).root
        precondition(folded.unreadable == 1 && folded.children.contains { $0.unreadable == 1 },
                     "Folding zero-byte denied entries must preserve their visible warning")
        // Same-sized but different files should not need full hashing.
        let length = 2 * 1024 * 1024
        for index in 0..<24 {
            _ = try write("prefilter/file-\(index)", Data(repeating: UInt8(index), count: length))
        }
        var hashCalls = 0
        let started = Date()
        let filtered = DuplicateScanner().report(minimumSize: 1, roots: [root.appending(path: "prefilter")]) { url in
            hashCalls += 1
            return try FileFingerprint.sha256(url)
        }
        precondition(filtered.items.isEmpty && hashCalls == 0, "Different samples must avoid full-file hashing")
        print("PERF: 24 equal-sized files (48 MiB): 0 full hashes, <=4.5 MiB sampled, \(String(format: "%.3f", Date().timeIntervalSince(started))) s")

        // Equal samples are never proof of equal content: mutate outside the sampled ranges.
        var altered = Data(repeating: 55, count: length)
        let first = try write("collision/a", altered)
        altered[256 * 1024] = 9
        let second = try write("collision/b", altered)
        let firstSample = try FileFingerprint.sample(first, length: Int64(length))
        let secondSample = try FileFingerprint.sample(second, length: Int64(length))
        precondition(firstSample == secondSample)
        hashCalls = 0
        let collision = DuplicateScanner().report(minimumSize: 1, roots: [root.appending(path: "collision")]) { url in
            hashCalls += 1
            return try FileFingerprint.sha256(url)
        }
        precondition(collision.items.isEmpty && hashCalls == 2, "Equal samples must be checked with full SHA-256")

        for name in ["a", "b", "c"] { _ = try write("budget/\(name)", bytes) }
        hashCalls = 0
        let partial = DuplicateScanner().report(minimumSize: 1, roots: [root.appending(path: "budget")]) { url in
            hashCalls += 1
            if hashCalls == 3 { throw FileFingerprint.DeadlineReached() }
            return try FileFingerprint.sha256(url)
        }
        precondition(partial.incomplete && partial.items.count == 2 && partial.warning(purpose: "checked") != nil,
                     "Timeout must preserve already verified duplicates and show an incomplete warning")
        let expired = DuplicateScanner().report(roots: [root], deadline: .distantPast)
        precondition(expired.incomplete && expired.items.isEmpty)
        do {
            _ = try FileFingerprint.sha256(first, deadline: .distantPast)
            preconditionFailure("Hashing must obey its deadline")
        } catch is FileFingerprint.DeadlineReached {}
        let sparseA = root.appending(path: "sparse/a")
        try fm.createDirectory(at: sparseA.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in ["a", "b"] {
            let url = sparseA.deletingLastPathComponent().appending(path: name)
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 4 * 1024 * 1024)
            try handle.close()
        }
        let sparse = DuplicateScanner().scan(minimumSize: 1, roots: [sparseA.deletingLastPathComponent()])
        precondition(sparse.count == 2 && sparse.allSatisfy { $0.size == 4 * 1024 * 1024 && $0.estimatedDiskBytes < $0.size },
                     "Sparse content length must not inflate the on-disk estimate")
        let roundTrip = try JSONDecoder().decode(ScanReport<DuplicateFile>.self, from: JSONEncoder().encode(partial))
        precondition(roundTrip.incomplete && roundTrip.items.count == 2)
        print("PASS: hidden cache/Trash, overlapping roots, hard links, folded warnings, sampled rejection, full-hash collision check, partial results and deadlines")
    }
}
