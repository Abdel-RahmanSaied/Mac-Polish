import Foundation

/// What one read-only pass found, and the folders macOS would not let it open.
/// A denied folder is never the same as an empty one: callers must tell the user.
struct ScanReport<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var deniedPaths: [String]
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
    /// Tells the user which folders macOS refused and how to allow them; nil when nothing was denied.
    static func denied(_ locations: [String], purpose: String) -> String? {
        guard !locations.isEmpty else { return nil }
        let names = locations.map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : "")
        return "macOS denied access to \(shown), so \(names.count == 1 ? "it was" : "they were") not fully \(purpose). "
            + "Turn on Full Disk Access for Mac Polish, or allow the folder in Privacy & Security → Files & Folders, then try again."
    }
}
