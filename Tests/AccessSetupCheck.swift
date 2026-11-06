import Foundation

@main
enum AccessSetupCheck {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-access-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        precondition(FolderAccessCheck.check(name: "Empty", url: root).status == .readable)
        precondition(FolderAccessCheck.check(name: "Missing", url: root.appending(path: "missing")).status == .missing)
        precondition(FolderAccessCheck.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == .restricted)
        precondition(FolderAccessCheck.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .restricted)
        precondition(FolderAccessCheck.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .restricted)
        precondition(FolderAccessCheck.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) == .unavailable)
        let nested = NSError(domain: "Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        precondition(FolderAccessCheck.classify(nested) == .missing)
        let locations = FolderAccessCheck.locations(home: root)
        precondition(locations.count > 16 && Set(locations.map { $0.1.path }).count == locations.count)
        precondition(locations.contains { $0.1.path == root.appending(path: "Documents").path })
        precondition(locations.contains { $0.1.path == DiskMapService.dataRoot })
        let suite = "MacPolish-access-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = AccessSetupModel(defaults: defaults)
        precondition(access.presented && access.results.isEmpty && !access.checking)
        precondition(access.step == .welcome && access.hasIncompleteAccess)
        access.step = .folders
        let resumed = AccessSetupModel(defaults: defaults)
        precondition(resumed.presented && resumed.step == .folders, "Resume setup after macOS requests a restart")
        access.fullDiskAccess = .accessible
        access.results = [FolderAccessResult(name: "fixture", url: root, status: .timedOut)]
        precondition(access.hasIncompleteAccess, "Timeouts are not ready access")
        access.results = [FolderAccessResult(name: "fixture", url: root, status: .readable)]
        precondition(!access.hasIncompleteAccess)
        access.settingsPresented = true
        access.results = FolderAccessCheck.locations().map { FolderAccessResult(name: $0.0, url: $0.1, status: .readable) }
        access.checkedAt = Date()
        if access.fullDiskAccess == nil { access.fullDiskAccess = .unknown }
        access.finish()
        precondition(!access.presented && !access.settingsPresented)
        let returning = AccessSetupModel(defaults: defaults)
        precondition(!returning.presented && returning.step == .welcome && returning.results.isEmpty && returning.checkedAt == nil)
        print("PASS: readable/missing/restricted/unknown access, isolated paths, first-run and skipped setup persistence")
    }
}
