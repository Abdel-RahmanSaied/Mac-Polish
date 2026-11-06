import Foundation

/// What one read-only pass found, and the folders macOS would not let it open.
/// A denied folder is never the same as an empty one: callers must tell the user.
struct ScanReport<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var deniedPaths: [String]
    /// A cooperative deadline preserves verified results instead of discarding the entire scan.
    var incomplete: Bool = false
    /// Locations whose worker gave no answer in time (for example, an unanswered macOS access prompt).
    var unansweredPaths: [String]? = nil

    func warning(purpose: String) -> String? {
        var parts: [String] = []
        if let access = AccessWarning.denied(deniedPaths, purpose: purpose) { parts.append(access) }
        if incomplete {
            parts.append("The scan reached its time limit. Verified results are shown, but some files have not been checked.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Collects folders a scan needed but could not open. Missing folders are normal and not recorded.
final class DeniedFolders {
    private(set) var paths: [String] = []

    func note(_ url: URL, _ error: Error) {
        guard FolderAccessCheck.classify(error as NSError) == .restricted else { return }
        let path = url.standardizedFileURL.path
        if !paths.contains(path) { paths.append(path) }
    }

    /// Lists `root`, recording a denial instead of returning an empty listing.
    func contents(of root: URL, keys: [URLResourceKey]? = nil,
                  options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: options)
        } catch {
            note(root, error)
            return nil
        }
    }

    /// Walks `root`, recording the root and every sub-folder that could not be opened.
    func enumerator(at root: URL, keys: [URLResourceKey],
                    options: FileManager.DirectoryEnumerationOptions) -> FileManager.DirectoryEnumerator? {
        // The enumerator does not reliably report its own root, so check it first.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            note(root, error)
            return nil
        }
        return FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) { [self] url, error in
            note(url, error)
            return true
        }
    }
}

enum AccessWarning {
    /// A read denial does not prove that a privacy grant is missing.
    static func denied(_ locations: [String], purpose: String) -> String? {
        guard !locations.isEmpty else { return nil }
        let names = Array(Set(locations)).sorted()
        let shown = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : "")
        return "Some content could not be \(purpose): \(shown). Readable results are still shown. "
            + "This does not mean Full Disk Access is off. Protected files, ownership or folder permissions can still block access. "
            + "If access has not been granted to this copy of Mac Polish, review Full Disk Access and Files & Folders in Privacy & Security."
    }
}
