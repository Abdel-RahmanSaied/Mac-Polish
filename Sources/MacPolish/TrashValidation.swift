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
        } catch {
            return issue(for: error as NSError, url: url)
        }
        return nil
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
        } else if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && ($0.code == NSFileReadNoPermissionError || $0.code == NSFileWriteNoPermissionError)) ||
            ($0.domain == NSPOSIXErrorDomain && ($0.code == Int(EACCES) || $0.code == Int(EPERM)))
        }) {
            kind = .permission
        } else {
            kind = .other
        }
        return CleanupIssue(url: url, kind: kind, detail: error.localizedDescription)
    }

    private static func chain(_ error: NSError, depth: Int = 0) -> [NSError] {
        guard depth < 8 else { return [] }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return [error] + (underlying.map { chain($0, depth: depth + 1) } ?? [])
    }
}
