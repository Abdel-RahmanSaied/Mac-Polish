import Darwin
import Foundation

/// Moving a folder to Trash needs write permission on the folder itself. Items owned by another account
/// need an administrator (Finder asks for the password); Full Disk Access cannot help, so it must not be offered.
@main
enum RemovalRightsCheck {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-rights-" + UUID().uuidString)
        let applications = root.appending(path: "Applications")
        let locked = applications.appending(path: "Locked.app")
        let normal = applications.appending(path: "Normal.app")
        for app in [locked, normal] { try fm.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true) }
        try Data("fixture".utf8).write(to: locked.appending(path: "Contents/Info.plist"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        // Break caught: a read-only folder passing preflight because only its parent was checked.
        guard let readOnly = TrashValidation.preflight(locked) else { preconditionFailure("A folder without write permission is blocked") }
        precondition(readOnly.kind == .readOnly && !readOnly.needsAccess, "Your own read-only folder is read-only, got \(readOnly.kind)")
        precondition(TrashValidation.preflight(normal) == nil, "A writable folder is not blocked")

        // The real error macOS returns for that move is a permission error, classified the same way.
        do {
            _ = try fm.trashItem(at: locked, resultingItemURL: nil)
            preconditionFailure("macOS moved a folder without write permission; the fixture is in Trash")
        } catch {
            let issue = TrashValidation.issue(for: error as NSError, url: locked)
            precondition(issue.kind == .readOnly && !issue.needsAccess, "The real move error is not a Full Disk Access problem, got \(issue.kind)")
        }
        precondition(fm.fileExists(atPath: locked.path))

        // Error classification: privacy (EPERM) and ownership (EACCES) need different fixes.
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: eperm])
        let someApp = URL(fileURLWithPath: "/Applications/Example.app")
        precondition(TrashValidation.issue(for: eperm, url: someApp).kind == .appManagement, "macOS blocking an app removal is App Management")
        precondition(TrashValidation.issue(for: wrapped, url: someApp).needsAccess, "App Management is a privacy setting")
        let container = fm.homeDirectoryForCurrentUser.appending(path: "Library/Containers/com.example.app")
        let containerIssue = TrashValidation.issue(for: eperm, url: container)
        precondition(containerIssue.kind == .permission && containerIssue.detail.contains("other apps"), "Other apps' data: \(containerIssue.detail)")
        precondition(TrashValidation.issue(for: eperm, url: normal).kind == .permission)
        precondition(TrashValidation.issue(for: eacces, url: locked).kind == .readOnly, "EACCES on your own item is read-only")

        // A real app owned by another account (installer packages install as root) needs an administrator.
        let currentUser = getuid()
        let rootOwned = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil))?
            .first { url in
                guard url.pathExtension == "app", let owner = try? fm.attributesOfItem(atPath: url.path)[.ownerAccountID] as? NSNumber
                else { return false }
                return owner.uint32Value != currentUser && access(url.path, W_OK) != 0
            }
        if let rootOwned {
            // Read-only checks: nothing is moved.
            guard let ownership = TrashValidation.preflight(rootOwned) else { preconditionFailure("\(rootOwned.lastPathComponent) must be blocked") }
            precondition(ownership.kind == .ownership && !ownership.needsAccess, "Another account's app needs an administrator, got \(ownership.kind)")
            precondition(ownership.detail.contains("administrator") && ownership.detail.contains("Finder"), ownership.detail)
            precondition(TrashValidation.issue(for: eacces, url: rootOwned).kind == .ownership)
            print("  real app owned by another account: \(rootOwned.lastPathComponent) → needs an administrator")
        } else {
            print("  note: no app owned by another account in /Applications; real ownership case not exercised")
        }
        let ownershipSummary = CleanupIssue.summary([CleanupIssue(url: someApp, kind: .ownership, detail: "fixture")])
        precondition(!ownershipSummary.contains("Full Disk Access") && ownershipSummary.contains("administrator"),
                     "Ownership advice must not point to Full Disk Access: \(ownershipSummary)")
        precondition(CleanupIssue.summary([CleanupIssue(url: someApp, kind: .appManagement, detail: "fixture")]).contains("App Management"))

        // The application list marks blocked apps before anything is selected.
        let scanned = ApplicationScanner(roots: [applications]).scan()
        guard let lockedItem = scanned.first(where: { $0.url.lastPathComponent == "Locked.app" }),
              let normalItem = scanned.first(where: { $0.url.lastPathComponent == "Normal.app" }) else {
            preconditionFailure("Both fixture apps are listed, got \(scanned.map(\.url.lastPathComponent))")
        }
        precondition(lockedItem.removalNote != nil && normalItem.removalNote == nil, "Only the blocked app carries a note")
        let model = AppModel()
        model.applications = scanned
        model.setApplicationSelection(true, id: lockedItem.id)
        model.setApplicationSelection(true, id: normalItem.id)
        precondition(model.applications.first { $0.id == lockedItem.id }?.isSelected == false, "A blocked app cannot be selected")
        precondition(model.applications.first { $0.id == normalItem.id }?.isSelected == true)

        // The uninstaller explains the block instead of calling it a protected app, and moves nothing.
        var selectedLocked = lockedItem
        selectedLocked.isSelected = true
        let removal = ApplicationUninstaller(applicationRoots: [applications]).remove([selectedLocked])
        precondition(removal.removedIDs.isEmpty && fm.fileExists(atPath: locked.path))
        precondition(removal.issues.map(\.kind) == [.readOnly], "The uninstaller reports the real reason, got \(removal.issues.map(\.kind))")

        // The setup sheet offers App Management when macOS blocked an app removal.
        model.access.cleanupContext = [CleanupIssue(url: someApp, kind: .appManagement, detail: "fixture")]
        precondition(model.access.needsAppManagement)
        precondition(PrivacyPane.appManagement.url.absoluteString.hasSuffix("?Privacy_AppBundles"))
        print("PASS: read-only and other-owner folders are blocked before moving, EACCES/EPERM/App Management are told apart, blocked apps are marked")
    }
}
