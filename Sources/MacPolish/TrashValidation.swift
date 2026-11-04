import Foundation

/// Validate known filesystem restrictions; never alter permissions or retry deletion automatically.
enum TrashValidation {
    static func isUnredirected(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized == url.resolvingSymlinksInPath().standardizedFileURL else { return false }
        // Foundation may leave an unresolved path unchanged when its final component is missing.
        // Inspect ancestors too, so a redirect is rejected even before that final file exists.
        var current = standardized
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { return false }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return true
    }

    static func isGoModuleCache(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return parts.contains("gomodcache") || zip(parts, parts.dropFirst()).contains { $0 == "pkg" && $1 == "mod" }
    }

    static func isManagedDependency(_ url: URL) -> Bool {
        isGoModuleCache(url) || url.standardizedFileURL.pathComponents.contains("node_modules")
    }

    static func preflight(_ url: URL) -> CleanupIssue? {
        guard isUnredirected(url) else {
            return CleanupIssue(url: url, kind: .unsafe, detail: "A symbolic link or redirected folder changed the path. The item was skipped.")
        }
        if isManagedDependency(url) {
            return CleanupIssue(url: url, kind: .managedCache,
                                detail: "Managed dependency folder: use its package manager instead of removing individual duplicate files.")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.immutable] as? Bool == true {
                return CleanupIssue(url: url, kind: .locked, detail: "This item is locked. Review it in Finder before trying again.")
            }
            // Removing a file requires writing its parent directory, even if the file can be read.
            let parent = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            if parent[.immutable] as? Bool == true {
                return CleanupIssue(url: url, kind: .locked, detail: "The containing folder is locked. Review it in Finder before trying again.")
            }
            if let mode = parent[.posixPermissions] as? NSNumber, mode.intValue & 0o222 == 0 {
                return CleanupIssue(url: url, kind: .readOnly,
                                    detail: "The containing folder is read-only. Full Disk Access does not change filesystem permissions.")
            }
            // Moving a folder to another folder rewrites its link to the parent, so macOS needs
            // write permission on the folder itself, not only on the folder that contains it.
            if attributes[.type] as? FileAttributeType == .typeDirectory, refusesWrite(url) {
                return accessIssue(url: url)
            }
        } catch {
            return issue(for: error as NSError, url: url)
        }
        return nil
    }

    /// An item this account may not change: owned by another account (an administrator must move it) or read-only.
    static func accessIssue(url: URL) -> CleanupIssue {
        if ownedByAnotherAccount(url) || ownedByAnotherAccount(url.deletingLastPathComponent()) {
            return CleanupIssue(url: url, kind: .ownership,
                                detail: "This item belongs to another account, often because an installer added it. "
                                    + "An administrator must remove it: use Show in Finder, then Move to Trash, and enter an administrator password. "
                                    + "Full Disk Access does not change ownership.")
        }
        return CleanupIssue(url: url, kind: .readOnly,
                            detail: "This folder is read-only, so it cannot be moved to Trash. "
                                + "Review its permissions in Finder (Get Info → Sharing & Permissions). Full Disk Access does not change them.")
    }

    /// `afpAccessDenied`: the status Trash moves report when the file system refuses.
    private static let afpAccessDeniedStatus = -5000

    /// True when the file's own permissions (EACCES), not a macOS protection (EPERM), refuse writing `url`.
    private static func refusesWrite(_ url: URL) -> Bool {
        access(url.path, W_OK) != 0 && errno == EACCES
    }

    /// Moving needs write permission on the containing folder, and on the item itself when it is a folder.
    private static func permissionsRefuse(_ url: URL) -> Bool {
        let isFolder = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
        return (isFolder && refusesWrite(url)) || refusesWrite(url.deletingLastPathComponent())
    }

    private static func ownedByAnotherAccount(_ url: URL) -> Bool {
        guard let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value != getuid()
    }

    static func issue(for error: NSError, url: URL) -> CleanupIssue {
        let errors = chain(error)
        let kind: CleanupIssue.Kind
        if errors.contains(where: { ($0.domain == NSPOSIXErrorDomain && $0.code == Int(EROFS)) || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteVolumeReadOnlyError) }) {
            kind = .readOnly
        } else if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoSuchFileError) ||
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileNoSuchFileError) ||
            ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT))
        }) {
            kind = .missing
        } else if errors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPERM) }) {
            // EPERM: a macOS protection refused, not the file's own permissions.
            return privacyIssue(url: url, error: error)
        } else if errors.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EACCES) }) {
            // EACCES: the file's owner and permissions refused; Full Disk Access cannot change that.
            return accessIssue(url: url)
        } else if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && ($0.code == NSFileReadNoPermissionError || $0.code == NSFileWriteNoPermissionError))
                || ($0.domain == NSOSStatusErrorDomain && $0.code == afpAccessDeniedStatus)
        }) {
            // Trash reports a refused move without a POSIX code (Cocoa 513 over OSStatus -5000),
            // so look at the item: its own permissions, or a macOS protection.
            return permissionsRefuse(url) ? accessIssue(url: url) : privacyIssue(url: url, error: error)
        } else {
            kind = .other
        }
        return CleanupIssue(url: url, kind: kind, detail: error.localizedDescription)
    }

    private static func privacyIssue(url: URL, error: NSError) -> CleanupIssue {
        let path = url.standardizedFileURL.path
        // Containers first: they are named after bundle identifiers, which can end in ".app".
        if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
            return CleanupIssue(url: url, kind: .permission,
                                detail: "macOS protects other apps' data. Since macOS 27 it refuses without asking. "
                                    + "Turn on Full Disk Access for Mac Polish, then try again.")
        }
        if url.pathExtension.lowercased() == "app" && !path.contains("/Library/") {
            return CleanupIssue(url: url, kind: .appManagement,
                                detail: "macOS App Management blocked removing this app. Allow Mac Polish in "
                                    + "System Settings → Privacy & Security → App Management, then try again.")
        }
        return CleanupIssue(url: url, kind: .permission, detail: error.localizedDescription)
    }

    private static func chain(_ error: NSError, depth: Int = 0) -> [NSError] {
        guard depth < 8 else { return [] }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return [error] + (underlying.map { chain($0, depth: depth + 1) } ?? [])
    }
}
