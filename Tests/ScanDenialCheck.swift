import Foundation

/// A folder macOS refuses to open must be reported as denied, never shown as an empty result.
@main
enum ScanDenialCheck {
    static func main() throws {
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        let fm = FileManager.default
        // Not the temporary folder: /var is a symbolic link, and fingerprinting refuses redirected paths.
        let home = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-denial-" + UUID().uuidString)
        var locked: [URL] = []
        defer {
            for url in locked.reversed() { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            try? fm.removeItem(at: home)
        }
        func folder(_ path: String) throws -> URL {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ path: String, bytes: Int = 8_192) throws -> URL {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        // chmod 000 gives EACCES; macOS privacy denials give EPERM. Both classify as restricted.
        func lock(_ url: URL) throws {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            locked.append(url)
        }
        let scanner = DiskScanner(home: home, applicationsRoot: home.appending(path: "Applications"), largeFileMinimum: 4_096)

        // Readable folder: its large file is found and nothing is reported as denied.
        let desktop = try folder("Desktop")
        _ = try file("Desktop/big.bin")
        let readable = scanner.report(section: .desktop)
        precondition(readable.items.count == 1 && readable.deniedPaths.isEmpty, "A readable Desktop reports its file and no denial")

        // Break caught: a denied Desktop looking like a Desktop without large files.
        try lock(desktop)
        let denied = scanner.report(section: .desktop)
        precondition(denied.items.isEmpty, "Nothing inside a denied folder can be listed")
        precondition(denied.deniedPaths == [desktop.path], "The denied Desktop is reported, got \(denied.deniedPaths)")

        // A folder that does not exist is normal, not a denial.
        precondition(scanner.report(section: .documents).deniedPaths.isEmpty, "A missing Documents folder is not a denial")

        // A denied sub-folder keeps the rest of the folder's results and is reported on its own.
        _ = try file("Downloads/installer.dmg")
        let privateFolder = try folder("Downloads/private")
        _ = try file("Downloads/private/hidden-from-scan.bin")
        try lock(privateFolder)
        let downloads = scanner.report(section: .downloads)
        precondition(downloads.items.map(\.url.lastPathComponent) == ["installer.dmg"], "Readable Downloads items are kept")
        precondition(downloads.deniedPaths == [privateFolder.path], "The denied sub-folder is reported, got \(downloads.deniedPaths)")

        // A readable cache root can still contain inaccessible content. Keep its partial
        // measurement, report the exact denied child, and never preselect it for cleanup.
        _ = try file("Library/Caches/example/visible.bin")
        let nestedCache = try folder("Library/Caches/example/locked")
        _ = try file("Library/Caches/example/locked/secret.bin")
        try lock(nestedCache)
        let partialCache = scanner.report(section: .caches)
        precondition(partialCache.deniedPaths == [nestedCache.path])
        precondition(partialCache.items.count == 1 && !partialCache.items[0].isMeasurementComplete
                     && !partialCache.items[0].isSelected)
        let entirelyClosed = try folder("Library/Caches/entirely-closed")
        _ = try file("Library/Caches/entirely-closed/hidden.bin")
        try lock(entirelyClosed)
        precondition(scanner.report(section: .caches).deniedPaths.contains(entirelyClosed.path),
                     "A zero-byte partial measurement must still report its denial")

        // Trash, caches and developer folders: the same rule for the child listings.
        let trash = try folder(".Trash")
        _ = try file(".Trash/old.zip")
        try lock(trash)
        precondition(scanner.report(section: .trash).deniedPaths == [trash.path], "A denied Trash is reported, not shown as empty")
        let caches = try folder("Library/Caches")
        try lock(caches)
        precondition(scanner.report(section: .caches).deniedPaths == [caches.path], "Denied caches are reported")
        let derived = try folder("Library/Developer/Xcode/DerivedData")
        try lock(derived)
        precondition(scanner.report(section: .developer).deniedPaths.contains(derived.path), "A denied DerivedData folder is reported")

        // The scan outcome keeps denials apart from locations that did not answer in time.
        let stalled = DiskScanFailure(message: "stalled", timedOut: true)
        let deniedDesktop = ScanReport<ScanItem>(items: [], deniedPaths: [desktop.path])
        let cache = ScanItem(url: home.appending(path: "Library/Caches/app"), size: 10, category: .cache, modifiedAt: nil)
        let outcomeResult = DiskScanService.scan(includeLargeFiles: true) { section in
            switch section {
            case .desktop: return .success(deniedDesktop)
            case .downloads: return .failure(stalled)
            case .caches: return .success(ScanReport(items: [cache], deniedPaths: []))
            default: return .success(ScanReport(items: [], deniedPaths: []))
            }
        }
        guard case .success(let outcome) = outcomeResult else { preconditionFailure("Answered sections still produce results") }
        precondition(outcome.denied == [.desktop], "Denied sections are listed, got \(outcome.denied)")
        precondition(outcome.incomplete == [.downloads], "Only the stalled section is incomplete, got \(outcome.incomplete)")
        precondition(outcome.items.map(\.url.lastPathComponent) == ["app"], "Readable results are kept")
        guard let warning = outcome.warning else { preconditionFailure("Denied folders produce a warning") }
        precondition(warning.contains("Desktop") && warning.contains("Downloads"), "The warning names both locations: \(warning)")
        precondition(warning.contains("Full Disk Access") && warning.contains("Files & Folders"),
                     "The warning says how to allow access: \(warning)")
        let clean = DiskScanService.scan(includeLargeFiles: false) { _ in .success(ScanReport(items: [], deniedPaths: [])) }
        guard case .success(let quiet) = clean else { preconditionFailure("An empty readable scan succeeds") }
        precondition(quiet.warning == nil && quiet.denied.isEmpty, "A fully readable scan has no warning")

        // Duplicates: a denied personal folder is reported while readable folders are still compared.
        let shared = try folder("Pictures")
        let twin = Data(repeating: 3, count: 2 * 1_024 * 1_024)
        try twin.write(to: shared.appending(path: "a.jpg"))
        try twin.write(to: shared.appending(path: "b.jpg"))
        let closed = try folder("Movies-denied")
        try lock(closed)
        let duplicates = DuplicateScanner().report(minimumSize: 1_024 * 1_024, roots: [shared, closed])
        precondition(duplicates.items.count == 2, "Readable duplicates are still found, got \(duplicates.items.map(\.url.path)) denied \(duplicates.deniedPaths)")
        precondition(duplicates.deniedPaths == [closed.path], "The denied folder is reported, got \(duplicates.deniedPaths)")
        let duplicateWarning = AccessWarning.denied(duplicates.deniedPaths, purpose: "checked for duplicates")
        precondition(duplicateWarning?.contains("Movies-denied") == true && duplicateWarning?.contains("checked for duplicates") == true,
                     "The duplicate warning names the folder: \(duplicateWarning ?? "nil")")
        precondition(AccessWarning.denied([], purpose: "checked for duplicates") == nil, "No denial, no warning")

        // Listing/metadata can succeed while reading a candidate's contents fails.
        let unreadableFile = shared.appending(path: "b.jpg")
        try lock(unreadableFile)
        let hashDenied = DuplicateScanner().report(minimumSize: 1_024 * 1_024, roots: [shared])
        precondition(hashDenied.items.isEmpty && hashDenied.deniedPaths == [unreadableFile.path],
                     "A fingerprint read denial must warn rather than claim a complete empty result")
        let serialized = try JSONEncoder().encode(hashDenied)
        let decoded = try JSONDecoder().decode(ScanReport<DuplicateFile>.self, from: serialized)
        precondition(decoded.deniedPaths == [unreadableFile.path])

        // The real worker returns the section report, including the denial list.
        guard case .success(let logs) = DiskScanService.readValue(ScanReport<ScanItem>.self, mode: "basic",
                                                                   arguments: ["--section", "logs"], timeout: 60) else {
            preconditionFailure("The worker returns a section report")
        }
        _ = logs.deniedPaths
        print("PASS: denied folders and sub-folders are reported (not shown as empty), kept apart from timeouts, in scans and duplicates")
    }
}
