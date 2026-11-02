import Foundation

@main
enum TrashValidationCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-cleanup-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let good = try file("good")
        let denied = try file("denied")
        let managed = try file("gomodcache/example.org/module/file.go")
        let locked = try file("locked")
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        precondition(TrashValidation.preflight(locked)?.kind == .locked)
        let readOnly = try file("read-only/fixture")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.deletingLastPathComponent().path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.deletingLastPathComponent().path) }
        precondition(TrashValidation.preflight(good) == nil)
        precondition(TrashValidation.preflight(managed)?.kind == .managedCache)
        precondition(TrashValidation.preflight(readOnly)?.kind == .readOnly)
        precondition(TrashValidation.preflight(root.appending(path: "missing"))?.kind == .missing)
        precondition(TrashValidation.isGoModuleCache(URL(fileURLWithPath: "/tmp/pkg/mod/example.org/a.go")))
        precondition(!TrashValidation.isGoModuleCache(URL(fileURLWithPath: "/tmp/gomodcache-notes/a.go")))
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))] {
            precondition(TrashValidation.issue(for: error, url: denied).needsAccess)
        }
        let nested = NSError(domain: "Fixture", code: 9, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        precondition(TrashValidation.issue(for: nested, url: denied).needsAccess)
        let readOnlyError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
        precondition(TrashValidation.issue(for: readOnlyError, url: denied).kind == .readOnly)
        precondition(!TrashValidation.issue(for: NSError(domain: "Fixture", code: 13), url: denied).needsAccess)
        func item(_ url: URL) -> ScanItem { ScanItem(url: url, size: 7, category: .cache, modifiedAt: nil) }
        let items = [item(good), item(denied), item(managed), item(readOnly)]
        let result = SafeCleaner().clean(items) { url in
            // Deliberately no filesystem mutation: simulate one success and a permission denial.
            if url.lastPathComponent == "denied" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSLocalizedDescriptionKey: "Localized fixture without English permission text"])
            }
        }
        precondition(result.removedCount == 1 && result.removedItemIDs == [items[0].id] && result.reclaimedBytes == 7)
        precondition(result.issues.count == 3 && result.failures.count == 3)
        precondition(result.issues.filter(\.needsAccess).count == 1)
        precondition(fm.fileExists(atPath: denied.path) && fm.fileExists(atPath: good.path))
        let model = AppModel()
        model.access.presented = false
        model.duplicateFiles = items.map { DuplicateFile(id: $0.id, url: $0.url, size: $0.size, fingerprint: "fixture", isSelected: true) }
        model.finishDuplicateCleanup(result)
        precondition(model.duplicateFiles.count == 3 && model.duplicateFiles.allSatisfy(\.isSelected))
        precondition(model.operationIssues.contains(where: \.needsAccess))
        model.reviewCleanupPermissions()
        precondition(model.operationMessage == nil && model.access.cleanupContext.count == 1)
        for _ in 0..<20 {
            if model.access.presented { break }
            await Task.yield()
        }
        precondition(model.access.presented)
        precondition(model.duplicateState == .ready && model.duplicateFiles.count == 3)
        print("PASS: typed permission errors, managed/read-only preflight, partial success, failed selection retention, access setup without automatic retry")
    }
}
