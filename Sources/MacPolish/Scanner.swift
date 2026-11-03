import Foundation

extension DiskScanner {
    /// Independently scanned parts of the basic scan. Each runs in its own worker with its own deadline.
    enum Section: String, CaseIterable, Sendable {
        case caches, logs, trash, developer, xcodeInstallers, oldFiles, downloads, documents, desktop

        var displayName: String {
            switch self {
            case .caches: "User caches"
            case .logs: "Logs"
            case .trash: "Trash"
            case .developer: "Developer files"
            case .xcodeInstallers: "Xcode installers in Downloads"
            case .oldFiles: "Old files"
            case .downloads: "Downloads"
            case .documents: "Documents"
            case .desktop: "Desktop"
            }
        }

        var isLargeFileFolder: Bool { [.downloads, .documents, .desktop].contains(self) }
    }
}

struct DiskScanner: Sendable {
    private var fileManager: FileManager { .default }
    private let home: URL
    private let applicationsRoot: URL
    private let largeFileMinimum: Int64
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applicationsRoot: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
         largeFileMinimum: Int64 = 100 * 1_024 * 1_024) {
        self.home = home
        self.applicationsRoot = applicationsRoot
        self.largeFileMinimum = largeFileMinimum
    }

    func scan(includeLargeFiles: Bool = true) -> [ScanItem] {
        let sections = Section.allCases.filter { includeLargeFiles || !$0.isLargeFileFolder }
        return Self.sorted(sections.flatMap { scan(section: $0) })
    }

    func scan(section: Section) -> [ScanItem] {
        switch section {
        // Xcode and SwiftPM caches are reported by the developer section.
        case .caches: scanChildren(of: home.appending(path: "Library/Caches"), category: .cache,
                                   excluding: ["com.apple.dt.Xcode", "org.swift.swiftpm"])
        case .logs: scanChildren(of: home.appending(path: "Library/Logs"), category: .logs, excluding: ["DiagnosticReports"])
        case .trash: scanChildren(of: home.appending(path: ".Trash"), category: .trash)
        case .developer: scanDeveloperFiles(in: home)
        // Separate from .developer: Downloads can wait on a macOS access prompt.
        case .xcodeInstallers: scanOldXcodeDownloads(in: home.appending(path: "Downloads"))
        case .oldFiles: scanOldFiles(in: home)
        case .downloads: scanLargeFiles(in: home.appending(path: "Downloads"), minimumSize: largeFileMinimum)
        case .documents: scanLargeFiles(in: home.appending(path: "Documents"), minimumSize: largeFileMinimum)
        case .desktop: scanLargeFiles(in: home.appending(path: "Desktop"), minimumSize: largeFileMinimum)
        }
    }

    static func sorted(_ items: [ScanItem]) -> [ScanItem] {
        items.sorted { lhs, rhs in
            if lhs.category == rhs.category { return lhs.size > rhs.size }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }

    private func scanChildren(of root: URL, category: ScanCategory, excluding excludedNames: Set<String> = []) -> [ScanItem] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { url -> ScanItem? in
            guard !excludedNames.contains(url.lastPathComponent), !isSymbolicLink(url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return item(url: url, category: category, modifiedAt: values?.contentModificationDate)
        }
    }

    /// Measures the item and lets the shared cleanup policy decide whether it starts selected.
    private func item(url: URL, category: ScanCategory, modifiedAt: Date?) -> ScanItem? {
        let measurement = FileSizeCalculator.measure(url)
        guard measurement.bytes > 0 else { return nil }
        var item = ScanItem(
            url: url,
            size: measurement.bytes,
            category: category,
            modifiedAt: modifiedAt,
            newestContentModifiedAt: measurement.newestModification,
            isMeasurementComplete: measurement.unreadableFolders == 0
        )
        item.isSelected = CleanupPolicy.shouldPreselect(item)
        return item
    }

    private func scanDeveloperFiles(in home: URL) -> [ScanItem] {
        let developer = home.appending(path: "Library/Developer")
        var items: [ScanItem] = []

        items += scanAgedChildren(
            of: developer.appending(path: "Xcode/DerivedData"),
            category: .derivedData,
            olderThanDays: 30
        )
        items += scanAgedChildren(
            of: developer.appending(path: "Xcode/Archives"),
            category: .xcodeArchive,
            olderThanDays: 180
        )

        for platform in ["iOS", "watchOS", "tvOS"] {
            items += scanAgedChildren(
                of: developer.appending(path: "Xcode/\(platform) DeviceSupport"),
                category: .deviceSupport,
                olderThanDays: 180
            )
        }

        items += scanChildren(
            of: developer.appending(path: "CoreSimulator/Caches"),
            category: .simulatorCache
        )
        items += scanChildren(
            of: home.appending(path: "Library/Caches/com.apple.dt.Xcode"),
            category: .xcodeCache
        )
        items += scanChildren(
            of: home.appending(path: "Library/Caches/org.swift.swiftpm"),
            category: .xcodeCache
        )
        items += scanOldXcodeCopies()

        return items
    }

    private func scanOldXcodeCopies() -> [ScanItem] {
        let applications = applicationsRoot
        guard let urls = try? fileManager.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let copies: [(url: URL, version: String)] = urls.compactMap { url in
            // Match bundle identity, not the name: tools such as Xcodes.app are not Xcode copies.
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.apple.dt.Xcode" else { return nil }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            return (url, version)
        }
        guard copies.count > 1 else { return [] }

        let sorted = copies.sorted { lhs, rhs in
            lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
        return sorted.dropFirst().compactMap { copy in
            let size = allocatedSize(of: copy.url)
            guard size > 0 else { return nil }
            let values = try? copy.url.resourceValues(forKeys: [.contentModificationDateKey])
            return ScanItem(
                url: copy.url,
                size: size,
                category: .oldXcode,
                modifiedAt: values?.contentModificationDate,
                isSelected: false
            )
        }
    }

    private func scanOldXcodeDownloads(in downloads: URL) -> [ScanItem] {
        // Filter names before requesting resource metadata. Prefetching allocated sizes for
        // every unrelated download can block in Foundation on special/provider-backed files.
        guard let names = try? fileManager.contentsOfDirectory(atPath: downloads.path) else { return [] }
        let urls = names.filter { !$0.hasPrefix(".") }.map { downloads.appending(path: $0) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

        return urls.compactMap { url in
            let lowerName = url.lastPathComponent.lowercased()
            guard lowerName.hasPrefix("xcode"), lowerName.hasSuffix(".xip") || lowerName.hasSuffix(".dmg"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { return nil }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size > 0 else { return nil }
            return ScanItem(
                url: url,
                size: size,
                category: .xcodeDownload,
                modifiedAt: modifiedAt,
                isSelected: false
            )
        }
    }

    private func scanOldFiles(in home: URL) -> [ScanItem] {
        var items = scanAgedChildren(
            of: home.appending(path: "Library/Logs/DiagnosticReports"),
            category: .diagnostics,
            olderThanDays: 30
        )
        items += scanAgedChildren(
            of: home.appending(path: "Library/Application Support/MobileSync/Backup"),
            category: .deviceBackup,
            olderThanDays: 180
        )

        let applications = applicationsRoot
        if let appURLs = try? fileManager.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            items += appURLs.compactMap { url in
                guard url.pathExtension.lowercased() == "app",
                      url.lastPathComponent.localizedCaseInsensitiveContains("Install macOS") else { return nil }
                let size = allocatedSize(of: url)
                guard size > 0 else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return ScanItem(
                    url: url,
                    size: size,
                    category: .oldInstaller,
                    modifiedAt: values?.contentModificationDate,
                    isSelected: false
                )
            }
        }
        return items
    }

    private func scanAgedChildren(
        of root: URL,
        category: ScanCategory,
        olderThanDays: Int
    ) -> [ScanItem] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? .distantPast
        return children.compactMap { url in
            guard !isSymbolicLink(url),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { return nil }
            return item(url: url, category: category, modifiedAt: modifiedAt)
        }
    }

    /// Files and packages (apps, libraries, bundles) at least `minimumSize`, hidden ones included.
    /// Hidden folders such as `.git` are not entered: their files belong to the folder and are not offered alone.
    private func scanLargeFiles(in root: URL, minimumSize: Int64) -> [ScanItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var items: [ScanItem] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if values.isPackage == true {
                    if let item = item(url: url, category: .largeFile, modifiedAt: values.contentModificationDate),
                       item.size >= minimumSize {
                        items.append(item)
                    }
                } else if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }
            // Regular files only: pipes, sockets and devices are never measured or offered.
            guard let attributes = FileAttributes.read(path: url.path), attributes.kind == .file,
                  attributes.attributedBytes >= minimumSize else { continue }
            items.append(ScanItem(
                url: url,
                size: attributes.attributedBytes,
                category: .largeFile,
                modifiedAt: values.contentModificationDate,
                isSelected: false
            ))
        }
        return items
    }

    private func allocatedSize(of url: URL) -> Int64 {
        FileSizeCalculator.allocatedSize(of: url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

struct SafeCleaner: Sendable {
    private var fileManager: FileManager { .default }
    private let applicationsRoot: URL
    init(applicationsRoot: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.applicationsRoot = applicationsRoot
    }

    func clean(_ items: [ScanItem], trashItem: @Sendable (URL) throws -> Void = { url in
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) -> CleanupResult {
        var removedCount = 0
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []
        var issues: [CleanupIssue] = []
        var removedItemIDs: Set<UUID> = []

        for item in items where item.isSelected {
            guard item.category != .trash else {
                let issue = CleanupIssue(url: item.url, kind: .alreadyInTrash,
                                         detail: "Already in Trash. Empty Trash in Finder to release this space.")
                failures.append(issue.message)
                issues.append(issue)
                continue
            }
            guard isAllowed(item) else {
                let issue = CleanupIssue(url: item.url, kind: .unsafe, detail: "Blocked unsafe path.")
                failures.append(issue.message)
                issues.append(issue)
                continue
            }

            if let issue = TrashValidation.preflight(item.url) {
                failures.append(issue.message)
                issues.append(issue)
                continue
            }
            if let expected = item.modifiedAt,
               let current = try? fileManager.attributesOfItem(atPath: item.url.path)[.modificationDate] as? Date,
               current != expected {
                let issue = CleanupIssue(url: item.url, kind: .changed, detail: "The item changed after scanning. Scan again before cleaning it.")
                failures.append(issue.message)
                issues.append(issue)
                continue
            }
            // Folder dates miss edits deep inside; compare the newest content date recorded by the scan.
            if item.newestContentModifiedAt != nil || !item.isMeasurementComplete {
                let measurement = FileSizeCalculator.measure(item.url)
                guard item.isMeasurementComplete, measurement.unreadableFolders == 0,
                      let currentNewest = measurement.newestModification else {
                    let issue = CleanupIssue(url: item.url, kind: .changed,
                                             detail: "Could not verify all content inside this item. Check folder access and scan again before cleaning it.")
                    failures.append(issue.message)
                    issues.append(issue)
                    continue
                }
                if let recordedNewest = item.newestContentModifiedAt, currentNewest > recordedNewest {
                    let issue = CleanupIssue(url: item.url, kind: .changed, detail: "Content inside this item changed after scanning. Scan again before cleaning it.")
                    failures.append(issue.message)
                    issues.append(issue)
                    continue
                }
            }
            do {
                try trashItem(item.url)
                removedCount += 1
                reclaimedBytes += item.size
                removedItemIDs.insert(item.id)
            } catch {
                let issue = TrashValidation.issue(for: error as NSError, url: item.url)
                failures.append(issue.message)
                issues.append(issue)
            }
        }

        return CleanupResult(
            removedCount: removedCount,
            reclaimedBytes: reclaimedBytes,
            failures: failures,
            removedItemIDs: removedItemIDs,
            issues: issues
        )
    }

    func isAllowed(_ url: URL) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard TrashValidation.isUnredirected(url) else { return false }
        let roots = [
            home.appending(path: "Library/Caches"),
            home.appending(path: "Library/Logs"),
            home.appending(path: "Downloads"),
            home.appending(path: "Documents"),
            home.appending(path: "Desktop"),
            home.appending(path: "Pictures"),
            home.appending(path: "Library/Developer/Xcode"),
            home.appending(path: "Library/Developer/CoreSimulator/Caches"),
            home.appending(path: "Library/Application Support/MobileSync/Backup")
        ].map(\.standardizedFileURL)

        return roots.contains { root in
            candidate != root && candidate.path.hasPrefix(root.path + "/")
        }
    }

    private func isAllowed(_ item: ScanItem) -> Bool {
        guard TrashValidation.isUnredirected(item.url) else { return false }
        if isAllowed(item.url) { return true }
        let applications = applicationsRoot.standardizedFileURL.path
        if item.category == .oldXcode {
            // Same identity rule as the scanner: a direct .app child of Applications that is really Xcode.
            let url = item.url.standardizedFileURL
            return url.deletingLastPathComponent().path == applications && url.pathExtension == "app"
                && Bundle(url: url)?.bundleIdentifier == "com.apple.dt.Xcode"
        }
        guard item.category == .oldInstaller else { return false }
        let path = item.url.standardizedFileURL.path
        return path.hasPrefix(applications + "/Install macOS ") && path.hasSuffix(".app")
    }
}
