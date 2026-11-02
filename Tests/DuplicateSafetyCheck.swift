import Foundation

@main
enum DuplicateSafetyCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-duplicate-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 8192)
        func make(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: url)
            return url
        }
        let a = try make("a.bin"), b = try make("b.bin"), c = try make("c.bin")
        _ = try make("gomodcache/example/a.bin")
        _ = try make("node_modules/example/b.bin")
        let scanned = DuplicateScanner().scan(minimumSize: 1, roots: [root])
        precondition(scanned.count == 3)
        let selected = scanned.map { file -> DuplicateFile in var f = file; f.isSelected = true; return f }
        let successful = DuplicateCleaner().clean(selected, trashItem: { _ in })
        precondition(successful.removedCount == 2 && successful.issues.isEmpty)
        let keeper = selected.sorted { $0.url.path < $1.url.path }[0]
        precondition(!successful.removedItemIDs.contains(keeper.id))
        try Data("changed".utf8).write(to: c)
        let changedSource = DuplicateCleaner().clean(selected, trashItem: { _ in })
        precondition(changedSource.removedCount == 1 && changedSource.issues.contains { $0.kind == .changed })
        try Data("changed keeper".utf8).write(to: a)
        let changedKeeper = DuplicateCleaner().clean(selected, trashItem: { _ in })
        precondition(changedKeeper.removedCount == 0 && changedKeeper.issues.contains { $0.kind == .changed })
        try fm.removeItem(at: a)
        let missingKeeper = DuplicateCleaner().clean(selected, trashItem: { _ in })
        precondition(missingKeeper.removedCount == 0 && missingKeeper.issues.contains { $0.kind == .missing })
        let link = root.appending(path: "redirect")
        try fm.createSymbolicLink(at: link, withDestinationURL: fm.temporaryDirectory)
        precondition(!SafeCleaner().isAllowed(link.appending(path: "anything")))
        precondition(TrashValidation.preflight(link)?.kind == .unsafe)
        let symlink = root.appending(path: "linked.bin")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: b)
        precondition((try? FileFingerprint.sha256(symlink)) == nil)
        print("PASS: managed-cache exclusion, keeper preservation, changed/missing copies, and symbolic-link containment")
    }
}
