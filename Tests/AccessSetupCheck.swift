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
        precondition(locations.count == 6 && Set(locations.map { $0.1.path }).count == 6)
        precondition(locations.allSatisfy { $0.1.path.hasPrefix(root.path + "/") })
        let suite = "MacPolish-access-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = AccessSetupModel(defaults: defaults)
        precondition(access.presented && access.results.isEmpty && !access.checking)
        access.settingsPresented = true
        access.finish()
        precondition(!access.presented && !access.settingsPresented)
        let returning = AccessSetupModel(defaults: defaults)
        precondition(!returning.presented && returning.results.isEmpty && returning.checkedAt == nil)
        print("PASS: readable/missing/restricted/unknown access, isolated paths, first-run and skipped setup persistence")
    }
}
