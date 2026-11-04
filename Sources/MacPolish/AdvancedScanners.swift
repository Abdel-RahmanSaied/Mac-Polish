import CryptoKit
import Foundation

struct ApplicationScanner: Sendable {
    private var fileManager: FileManager { .default }
    /// Folders to list; nil means /Applications, /System/Applications and ~/Applications.
    var roots: [URL]? = nil

    func scan() -> [ApplicationItem] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = self.roots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory)
        ]

        var seen: Set<String> = []
        var results: [ApplicationItem] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }

                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let bundleID = bundle?.bundleIdentifier
                let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                let leftovers = Self.leftovers(appName: name, bundleIdentifier: bundleID,
                                               library: fileManager.homeDirectoryForCurrentUser.appending(path: "Library"))
                let isProtected = path.hasPrefix("/System/Applications/") || bundleID == "com.asaied.macpolish"

                results.append(ApplicationItem(
                    id: UUID(),
                    name: name,
                    url: url,
                    bundleIdentifier: bundleID,
                    version: version,
                    size: allocatedSize(of: url),
                    leftoverURLs: leftovers,
                    leftoverSize: leftovers.reduce(0) { $0 + allocatedSize(of: $1) },
                    canRemove: !isProtected,
                    isSelected: false,
                    // Shown before selection: Finder can remove it with an administrator password; Mac Polish cannot.
                    removalNote: isProtected ? nil : TrashValidation.preflight(url).flatMap {
                        [.ownership, .readOnly, .locked].contains($0.kind) ? $0.detail : nil
                    }
                ))
            }
        }

        return results.sorted { $0.totalSize > $1.totalSize }
    }

    static func leftovers(appName: String, bundleIdentifier: String?, library: URL) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        // Names come from the app's own Info.plist; only a plain single folder name is trusted.
        func isPlainName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/")
        }

        if let bundleIdentifier, isPlainName(bundleIdentifier) {
            candidates += [
                library.appending(path: "Caches/\(bundleIdentifier)"),
                library.appending(path: "Preferences/\(bundleIdentifier).plist"),
                library.appending(path: "Application Support/\(bundleIdentifier)"),
                library.appending(path: "Saved Application State/\(bundleIdentifier).savedState"),
                library.appending(path: "Containers/\(bundleIdentifier)")
            ]
        }

        if isPlainName(appName) {
            candidates += [
                library.appending(path: "Application Support/\(appName)"),
                library.appending(path: "Caches/\(appName)")
            ]
        }

        var seen: Set<String> = []
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            return fileManager.fileExists(atPath: path) && seen.insert(path).inserted
        }
    }

    private func allocatedSize(of url: URL) -> Int64 {
        FileSizeCalculator.allocatedSize(of: url)
    }
}

struct DuplicateScanner: Sendable {
    private var fileManager: FileManager { .default }

    func scan(minimumSize: Int64 = 1_024 * 1_024, roots customRoots: [URL]? = nil) -> [DuplicateFile] {
        report(minimumSize: minimumSize, roots: customRoots).items
    }

    /// Duplicates in the readable folders, and the folders macOS would not let the scan open.
    func report(minimumSize: Int64 = 1_024 * 1_024, roots customRoots: [URL]? = nil) -> ScanReport<DuplicateFile> {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = customRoots ?? ["Downloads", "Documents", "Desktop", "Pictures"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let denied = DeniedFolders()
        var bySize: [Int64: [URL]] = [:]

        for root in roots {
            guard let enumerator = denied.enumerator(at: root, keys: Array(keys),
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for case let url as URL in enumerator {
                if TrashValidation.isManagedDependency(url) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                // Identical content always has identical length; allocated blocks vary with
                // sparse files and compression, and would split or blur the size groups.
                guard let length = values.fileSize else { continue }
                let size = Int64(length)
                guard size >= minimumSize else { continue }
                bySize[size, default: []].append(url)
            }
        }

        var results: [DuplicateFile] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                let digest: String
                do { digest = try FileFingerprint.sha256(url) }
                catch { denied.note(url, error); continue }
                byHash[digest, default: []].append(url)
            }
            for (digest, matches) in byHash where matches.count > 1 {
                results += matches.map {
                    DuplicateFile(
                        id: UUID(),
                        url: $0,
                        size: size,
                        fingerprint: digest,
                        isSelected: false
                    )
                }
            }
        }

        let sorted = results.sorted {
            if $0.fingerprint == $1.fingerprint { return $0.url.path < $1.url.path }
            if $0.size == $1.size { return $0.fingerprint < $1.fingerprint }
            return $0.size > $1.size
        }
        return ScanReport(items: sorted, deniedPaths: denied.paths)
    }


}

struct StartupScanner: Sendable {
    private var fileManager: FileManager { .default }

    func scan() -> [StartupEntry] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots: [(URL, Bool)] = [
            (home.appending(path: "Library/LaunchAgents"), false),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), true),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), true)
        ]
        var results: [StartupEntry] = []

        for (root, requiresAdministrator) in roots {
            guard let files = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in files where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                results.append(StartupEntry(
                    id: UUID(),
                    label: dictionary["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                    url: url,
                    program: dictionary["Program"] as? String ?? (dictionary["ProgramArguments"] as? [String])?.first,
                    runsAtLoad: dictionary["RunAtLoad"] as? Bool ?? false,
                    requiresAdministrator: requiresAdministrator
                ))
            }
        }

        return results.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

struct ApplicationUninstaller: Sendable {
    private var fileManager: FileManager { .default }
    /// Folders apps may be removed from; nil means /Applications and ~/Applications.
    var applicationRoots: [URL]? = nil

    func remove(_ applications: [ApplicationItem]) -> ApplicationRemovalResult {
        var removedIDs: Set<UUID> = []
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []
        var issues: [CleanupIssue] = []

        for application in applications where application.isSelected {
            guard application.canRemove, application.bundleIdentifier != "com.asaied.macpolish", isAllowedApplication(application.url) else {
                let issue = CleanupIssue(url: application.url, kind: .unsafe, detail: "Protected application.")
                failures.append(issue.message)
                issues.append(issue)
                continue
            }

            if let issue = TrashValidation.preflight(application.url) {
                failures.append(issue.message)
                issues.append(issue)
                continue
            }
            do {
                _ = try fileManager.trashItem(at: application.url, resultingItemURL: nil)
                reclaimedBytes += application.size

                for leftover in application.leftoverURLs where isAllowedLeftover(leftover) {
                    if let issue = TrashValidation.preflight(leftover) {
                        failures.append(issue.message)
                        issues.append(issue)
                        continue
                    }
                    do {
                        let leftoverSize = FileSizeCalculator.allocatedSize(of: leftover)
                        _ = try fileManager.trashItem(at: leftover, resultingItemURL: nil)
                        reclaimedBytes += leftoverSize
                    } catch {
                        let issue = TrashValidation.issue(for: error as NSError, url: leftover)
                        failures.append(issue.message)
                        issues.append(issue)
                    }
                }
                removedIDs.insert(application.id)
            } catch {
                let issue = TrashValidation.issue(for: error as NSError, url: application.url)
                failures.append(issue.message)
                issues.append(issue)
            }
        }

        return ApplicationRemovalResult(removedIDs: removedIDs, reclaimedBytes: reclaimedBytes, failures: failures, issues: issues)
    }

    private func isAllowedApplication(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = (applicationRoots ?? [URL(fileURLWithPath: "/Applications"),
                                          fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")])
            .map { $0.standardizedFileURL.path }
        return TrashValidation.isUnredirected(url)
            && url.pathExtension.lowercased() == "app"
            && roots.contains { path.hasPrefix($0 + "/") }
            && !path.hasPrefix("/System/")
    }

    private func isAllowedLeftover(_ url: URL) -> Bool {
        let library = fileManager.homeDirectoryForCurrentUser.appending(path: "Library").standardizedFileURL.path
        return TrashValidation.isUnredirected(url)
            && url.standardizedFileURL.path.hasPrefix(library + "/")
    }
}

struct SizeMeasurement: Sendable {
    /// Real disk space: clones and hard links count once across all their paths (see FileAttributes).
    let bytes: Int64
    /// Newest modification date of the item, its files and its sub-folders.
    let newestModification: Date?
    /// Folders inside that macOS would not let this process read; their contents are not in `bytes`.
    var unreadableFolders = 0
}

enum FileSizeCalculator {
    static func allocatedSize(of url: URL) -> Int64 {
        measure(url).bytes
    }

    /// Walks the item on its own volume without following symbolic links or entering mount points.
    static func measure(_ url: URL, onReadError: ((URL, Int32) -> Void)? = nil) -> SizeMeasurement {
        guard let item = FileAttributes.read(path: url.path) else {
            let error = errno
            onReadError?(url, error)
            return SizeMeasurement(bytes: 0, newestModification: nil, unreadableFolders: 1)
        }
        switch item.kind {
        case .file: return SizeMeasurement(bytes: item.attributedBytes, newestModification: item.modified)
        case .folder: break
        case .symlink, .other: return SizeMeasurement(bytes: 0, newestModification: nil)
        }

        var total: Int64 = 0
        var newest = item.modified
        var unreadable = 0
        var pending = [url.path]
        while let folder = pending.popLast() {
            let listing = BulkDirectoryReader.entries(of: folder)
            if let error = listing.error {
                unreadable += 1
                onReadError?(URL(fileURLWithPath: folder), error)
            }
            for entry in listing.entries {
                guard entry.error == 0 else {
                    unreadable += 1
                    onReadError?(URL(fileURLWithPath: folder).appendingPathComponent(entry.name), entry.error)
                    continue
                }
                // Sub-folder dates record files added or removed inside them.
                if entry.kind == .file || entry.kind == .folder, let modified = entry.modified,
                   modified > (newest ?? .distantPast) {
                    newest = modified
                }
                switch entry.kind {
                case .file: total += entry.attributedBytes
                case .folder where entry.device == item.device && !entry.isMountPoint:
                    pending.append(folder + "/" + entry.name)
                default: break
                }
            }
        }
        return SizeMeasurement(bytes: total, newestModification: newest, unreadableFolders: unreadable)
    }
}
