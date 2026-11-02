import CryptoKit
import Foundation

struct ApplicationScanner: Sendable {
    private var fileManager: FileManager { .default }

    func scan() -> [ApplicationItem] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
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
                let leftovers = findLeftovers(appName: name, bundleIdentifier: bundleID)

                results.append(ApplicationItem(
                    id: UUID(),
                    name: name,
                    url: url,
                    bundleIdentifier: bundleID,
                    version: version,
                    size: allocatedSize(of: url),
                    leftoverURLs: leftovers,
                    leftoverSize: leftovers.reduce(0) { $0 + allocatedSize(of: $1) },
                    canRemove: !path.hasPrefix("/System/Applications/"),
                    isSelected: false
                ))
            }
        }

        return results.sorted { $0.totalSize > $1.totalSize }
    }

    private func findLeftovers(appName: String, bundleIdentifier: String?) -> [URL] {
        let library = fileManager.homeDirectoryForCurrentUser.appending(path: "Library")
        var candidates: [URL] = []

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            candidates += [
                library.appending(path: "Caches/\(bundleIdentifier)"),
                library.appending(path: "Preferences/\(bundleIdentifier).plist"),
                library.appending(path: "Application Support/\(bundleIdentifier)"),
                library.appending(path: "Saved Application State/\(bundleIdentifier).savedState"),
                library.appending(path: "Containers/\(bundleIdentifier)")
            ]
        }

        candidates += [
            library.appending(path: "Application Support/\(appName)"),
            library.appending(path: "Caches/\(appName)")
        ]

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

    func scan(minimumSize: Int64 = 1_024 * 1_024) -> [DuplicateFile] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = ["Downloads", "Documents", "Desktop", "Pictures"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey
        ]
        var bySize: [Int64: [URL]] = [:]

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                guard size >= minimumSize else { continue }
                bySize[size, default: []].append(url)
            }
        }

        var results: [DuplicateFile] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                guard let digest = fingerprint(of: url) else { continue }
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

        return results.sorted {
            if $0.fingerprint == $1.fingerprint { return $0.url.path < $1.url.path }
            if $0.size == $1.size { return $0.fingerprint < $1.fingerprint }
            return $0.size > $1.size
        }
    }

    private func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
}

struct StorageScanner: Sendable {
    private var fileManager: FileManager { .default }

    func scan() -> [StorageEntry] {
        let home = fileManager.homeDirectoryForCurrentUser
        let names = ["Library", "Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"]

        return names.compactMap { name in
            let url = home.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return StorageEntry(id: UUID(), name: name, url: url, size: FileSizeCalculator.allocatedSize(of: url))
        }
        .sorted { $0.size > $1.size }
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

    func remove(_ applications: [ApplicationItem]) -> ApplicationRemovalResult {
        var removedIDs: Set<UUID> = []
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []

        for application in applications where application.isSelected {
            guard application.canRemove, isAllowedApplication(application.url) else {
                failures.append("Protected application: \(application.name)")
                continue
            }

            do {
                _ = try fileManager.trashItem(at: application.url, resultingItemURL: nil)
                reclaimedBytes += application.size

                for leftover in application.leftoverURLs where isAllowedLeftover(leftover) {
                    do {
                        let leftoverSize = FileSizeCalculator.allocatedSize(of: leftover)
                        _ = try fileManager.trashItem(at: leftover, resultingItemURL: nil)
                        reclaimedBytes += leftoverSize
                    } catch {
                        failures.append("\(leftover.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                removedIDs.insert(application.id)
            } catch {
                failures.append("\(application.name): \(error.localizedDescription)")
            }
        }

        return ApplicationRemovalResult(removedIDs: removedIDs, reclaimedBytes: reclaimedBytes, failures: failures)
    }

    private func isAllowedApplication(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homeApplications = fileManager.homeDirectoryForCurrentUser.appending(path: "Applications").standardizedFileURL.path
        return url.pathExtension.lowercased() == "app"
            && (path.hasPrefix("/Applications/") || path.hasPrefix(homeApplications + "/"))
            && !path.hasPrefix("/System/")
    }

    private func isAllowedLeftover(_ url: URL) -> Bool {
        let library = fileManager.homeDirectoryForCurrentUser.appending(path: "Library").standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(library + "/")
    }
}

enum FileSizeCalculator {
    static func allocatedSize(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isRegularFile == true,
                  childValues.isSymbolicLink != true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }
}
