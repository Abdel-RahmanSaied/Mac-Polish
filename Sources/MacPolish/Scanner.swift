import Foundation

struct DiskScanner: Sendable {
    private var fileManager: FileManager { .default }

    func scan(includeLargeFiles: Bool = true) -> [ScanItem] {
        var items: [ScanItem] = []
        let home = fileManager.homeDirectoryForCurrentUser

        items += scanChildren(of: home.appending(path: "Library/Caches"), category: .cache).filter {
            !["com.apple.dt.Xcode", "org.swift.swiftpm"].contains($0.url.lastPathComponent)
        }
        items += scanChildren(of: home.appending(path: "Library/Logs"), category: .logs).filter {
            $0.url.lastPathComponent != "DiagnosticReports"
        }
        items += scanChildren(of: home.appending(path: ".Trash"), category: .trash)
        items += scanDeveloperFiles(in: home)
        items += scanOldFiles(in: home)

        if includeLargeFiles {
            let roots = ["Downloads", "Documents", "Desktop"].map { home.appending(path: $0) }
            items += roots.flatMap { scanLargeFiles(in: $0, minimumSize: 100 * 1_024 * 1_024) }
        }

        return items.sorted { lhs, rhs in
            if lhs.category == rhs.category { return lhs.size > rhs.size }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }

    private func scanChildren(of root: URL, category: ScanCategory, isSelected: Bool? = nil) -> [ScanItem] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { url -> ScanItem? in
            guard !isSymbolicLink(url) else { return nil }
            let size = allocatedSize(of: url)
            guard size > 0 else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return ScanItem(
                url: url,
                size: size,
                category: category,
                modifiedAt: values?.contentModificationDate,
                isSelected: isSelected ?? (category != .largeFile)
            )
        }
    }

    private func scanDeveloperFiles(in home: URL) -> [ScanItem] {
        let developer = home.appending(path: "Library/Developer")
        var items: [ScanItem] = []

        items += scanAgedChildren(
            of: developer.appending(path: "Xcode/DerivedData"),
            category: .derivedData,
            olderThanDays: 30,
            isSelected: true
        )
        items += scanAgedChildren(
            of: developer.appending(path: "Xcode/Archives"),
            category: .xcodeArchive,
            olderThanDays: 180,
            isSelected: false
        )

        for platform in ["iOS", "watchOS", "tvOS"] {
            items += scanAgedChildren(
                of: developer.appending(path: "Xcode/\(platform) DeviceSupport"),
                category: .deviceSupport,
                olderThanDays: 180,
                isSelected: false
            )
        }

        items += scanChildren(
            of: developer.appending(path: "CoreSimulator/Caches"),
            category: .simulatorCache,
            isSelected: true
        )
        items += scanChildren(
            of: home.appending(path: "Library/Caches/com.apple.dt.Xcode"),
            category: .xcodeCache,
            isSelected: true
        )
        items += scanChildren(
            of: home.appending(path: "Library/Caches/org.swift.swiftpm"),
            category: .xcodeCache,
            isSelected: true
        )
        items += scanOldXcodeCopies()
        items += scanOldXcodeDownloads(in: home.appending(path: "Downloads"))

        return items
    }

    private func scanOldXcodeCopies() -> [ScanItem] {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let copies: [(url: URL, version: String)] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "app",
                  url.deletingPathExtension().lastPathComponent.lowercased().hasPrefix("xcode") else { return nil }
            let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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
        guard let urls = try? fileManager.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
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
            olderThanDays: 30,
            isSelected: true
        )
        items += scanAgedChildren(
            of: home.appending(path: "Library/Application Support/MobileSync/Backup"),
            category: .deviceBackup,
            olderThanDays: 180,
            isSelected: false
        )

        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
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
        olderThanDays: Int,
        isSelected: Bool
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
            let size = allocatedSize(of: url)
            guard size > 0 else { return nil }
            return ScanItem(
                url: url,
                size: size,
                category: category,
                modifiedAt: modifiedAt,
                isSelected: isSelected
            )
        }
    }

    private func scanLargeFiles(in root: URL, minimumSize: Int64) -> [ScanItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var items: [ScanItem] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size >= minimumSize else { continue }
            items.append(ScanItem(
                url: url,
                size: size,
                category: .largeFile,
                modifiedAt: values.contentModificationDate,
                isSelected: false
            ))
        }
        return items
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
              ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isRegularFile == true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

struct SafeCleaner: Sendable {
    private var fileManager: FileManager { .default }

    func clean(_ items: [ScanItem]) -> CleanupResult {
        var removedCount = 0
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []
        var removedItemIDs: Set<UUID> = []

        for item in items where item.isSelected {
            guard isAllowed(item) else {
                failures.append("Blocked unsafe path: \(item.url.path)")
                continue
            }

            do {
                _ = try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                removedCount += 1
                reclaimedBytes += item.size
                removedItemIDs.insert(item.id)
            } catch {
                failures.append("\(item.displayName): \(error.localizedDescription)")
            }
        }

        return CleanupResult(
            removedCount: removedCount,
            reclaimedBytes: reclaimedBytes,
            failures: failures,
            removedItemIDs: removedItemIDs
        )
    }

    func isAllowed(_ url: URL) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let candidate = url.standardizedFileURL
        let roots = [
            home.appending(path: "Library/Caches"),
            home.appending(path: "Library/Logs"),
            home.appending(path: ".Trash"),
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
        if isAllowed(item.url) { return true }
        if item.category == .oldXcode {
            let path = item.url.standardizedFileURL.path
            return path.hasPrefix("/Applications/Xcode") && path.hasSuffix(".app")
        }
        guard item.category == .oldInstaller else { return false }
        let path = item.url.standardizedFileURL.path
        return path.hasPrefix("/Applications/Install macOS ") && path.hasSuffix(".app")
    }
}
