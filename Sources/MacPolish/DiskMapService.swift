import Foundation

/// The whole startup data volume as one tree, compared with what macOS reports as used.
struct DiskMapReport: Sendable {
    var tree: DiskTreeResult
    var volumes: VolumeUsage?
    var reconciliation: StorageReconciliation?
    var date: Date
    /// The sealed, read-only macOS system volume, read separately so no data-volume file is counted twice.
    var systemTree: DiskTreeResult? = nil
    var duration: TimeInterval = 0

    /// Every regular file counted on the internal disk: the data volume plus the system volume.
    var filesCounted: Int { tree.root.files + (systemTree?.root.files ?? 0) }
}

enum DiskMapService {
    /// Reads one folder tree. The worker reader runs in the read-only child process; tests use the in-process one.
    typealias TreeReader = @Sendable (_ root: String, _ options: DiskTreeOptions, _ timeout: TimeInterval) -> Result<DiskTreeResult, DiskScanFailure>

    static let dataRoot = "/System/Volumes/Data"
    /// Largest files kept for the whole disk; folder rows are folded independently of this list.
    static let largestFileCount = 250
    static let insightOptions = DiskInsightOptions(largestFiles: largestFileCount)
    /// Folders that can wait on a macOS access request get their own worker and time limit.
    static let protectedTimeout: TimeInterval = 180

    static let inProcessReader: TreeReader = { root, options, timeout in
        var options = options
        options.deadline = options.deadline ?? Date().addingTimeInterval(timeout)
        return .success(DiskTreeScanner.scan(root, options: options))
    }

    static let workerReader: TreeReader = workerReader(cancellation: nil)

    /// The worker reader, ending its worker process when `cancellation` is cancelled.
    static func workerReader(cancellation: ScanCancellation?) -> TreeReader {
        { root, options, timeout in
            var options = options
            // Stop reading before the process deadline so the partial tree still comes back.
            options.deadline = Date().addingTimeInterval(max(1, timeout * 0.9 - 5))
            guard let arguments = try? workerArguments(root: root, options: options) else {
                return .failure(DiskScanFailure(message: "The scan request could not be prepared."))
            }
            return DiskScanService.readValue(DiskTreeResult.self, mode: "tree", arguments: arguments, timeout: timeout,
                                             cancellation: cancellation)
        }
    }

    static func workerArguments(root: String, options: DiskTreeOptions) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return ["--root", root, "--options", String(decoding: try encoder.encode(options), as: UTF8.self)]
    }

    /// Folders macOS protects or a cloud provider serves. Desktop, Documents and Downloads can wait on a prompt;
    /// since macOS 27, other apps' containers are refused without one unless Full Disk Access is on.
    static func protectedFolders(home: URL) -> [URL] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
         "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers", "Library/Group Containers"]
            .map { home.appending(path: $0) }
    }

    /// The path of `url` on the data volume (`/Users/me` is `/System/Volumes/Data/Users/me`).
    static func dataPath(for url: URL, dataRoot: String = dataRoot) -> String {
        let path = url.standardizedFileURL.path
        return path == dataRoot || path.hasPrefix(dataRoot + "/") ? path : dataRoot + path
    }

    /// Folders on the system volume that are really the data volume (`/usr/share/firmlinks`), plus the
    /// mount points of the other volumes. The system volume and data volume share one device number in
    /// an APFS volume group, so without these exclusions a walk from `/` would count the data volume again.
    static func systemVolumeExclusions(firmlinks: String? = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) -> [String] {
        let listed = (firmlinks ?? "").split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let path = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            return path.hasPrefix("/") ? path : nil
        }
        let fallback = ["/Applications", "/Library", "/Users", "/Volumes", "/cores", "/opt", "/private", "/usr/local",
                        "/System/Library/Caches", "/System/Library/Assets", "/System/Library/Speech", "/AppleInternal"]
        return Array(Set((listed.isEmpty ? fallback : listed) + ["/System/Volumes", "/dev"])).sorted()
    }

    /// A data-volume path as users know it (`/System/Volumes/Data/Users/me` → `/Users/me`).
    static func familiarPath(_ path: String, dataRoot: String = dataRoot) -> String {
        path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
    }

    /// The familiar path for a row, as Finder and Terminal show it.
    static func displayPath(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    /// A URL Finder can reveal: the firmlinked path when it exists, otherwise the data volume path.
    static func revealURL(_ components: [String], dataRoot: String = dataRoot) -> URL {
        let familiar = displayPath(components)
        if FileManager.default.fileExists(atPath: familiar) { return URL(fileURLWithPath: familiar) }
        return URL(fileURLWithPath: dataRoot + (components.isEmpty ? "" : familiar))
    }

    /// Reads the data volume in one worker and each protected folder in its own, then joins them.
    /// Fails only when the data volume itself could not be read.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     dataRoot: String = dataRoot,
                     timeout: TimeInterval = 900,
                     reader: @escaping TreeReader = workerReader,
                     includeSystemVolume: Bool? = nil,
                     volumes: @escaping @Sendable () -> VolumeUsage? = { try? VolumeUsage.read().get() }) -> Result<DiskMapReport, DiskScanFailure> {
        let started = Date()
        // Only the real startup data volume has a matching system volume at `/`; fixtures never do.
        let systemRoot: String? = includeSystemVolume ?? (dataRoot == Self.dataRoot) ? "/" : nil
        let protected = protectedFolders(home: home)
            .map { dataPath(for: $0, dataRoot: dataRoot) }
            .filter { FileAttributes.read(path: $0)?.kind == .folder }
        let mainOptions = DiskTreeOptions(excluded: protected, insights: insightOptions)
        var jobs: [(String, DiskTreeOptions, TimeInterval)] = [(dataRoot, mainOptions, timeout)]
            + protected.map { ($0, DiskTreeOptions(insights: insightOptions), min(timeout, protectedTimeout)) }
        if let systemRoot {
            // Rows a few levels deep are enough to explain the sealed volume; every file is still counted.
            jobs.append((systemRoot, DiskTreeOptions(minimumListedBytes: 16 << 20, maximumChildren: 50, keepDepth: 4,
                                                     excluded: systemVolumeExclusions(), insights: insightOptions),
                         min(timeout, protectedTimeout)))
        }
        let layout = LockedResults<VolumeUsage?>(count: 1)
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { layout.set(0, volumes()) }
        let results = DiskScanService.concurrentMap(jobs) { reader($0.0, $0.1, $0.2) }
        group.wait()
        let protectedResults = Array(results.dropFirst().prefix(protected.count))
        let systemTree: DiskTreeResult? = systemRoot == nil ? nil : {
            if case .success(var found) = results.last { found.root.name = "macOS system volume"; return found }
            return nil
        }()

        if results.contains(where: { if case .failure(let failure) = $0 { failure.cancelled } else { false } }) {
            return .failure(.cancelledByUser)
        }
        guard case .success(var combined) = results[0] else {
            if case .failure(let failure) = results[0] { return .failure(failure) }
            return .failure(DiskScanFailure(message: "The startup disk could not be read."))
        }
        var insightParts: [DiskInsights?] = [combined.insights]
        for (path, result) in zip(protected, protectedResults) {
            let components = path.dropFirst(dataRoot.count).split(separator: "/").map(String.init)
            switch result {
            case .success(let found):
                insightParts.append(found.insights)
                combined.root = combined.root.grafting(found.root, at: components)
                combined.incomplete = combined.incomplete || found.incomplete
                combined.unreadablePaths = Array((combined.unreadablePaths + found.unreadablePaths).sorted().prefix(50))
            case .failure(let failure):
                let note = failure.timedOut
                    ? "No answer in time. macOS may be waiting for you to allow access; review scan permissions and analyze again."
                    : "Could not be read. Review scan permissions and analyze again."
                combined.root = combined.root.grafting(DiskNode(name: "", kind: .notScanned, notScanned: 1, note: note), at: components)
                combined.incomplete = true
            }
        }
        combined.root.name = volumeName(dataRoot)
        combined.insights = DiskInsights.merged(insightParts, keepingLargest: largestFileCount)

        let usage = layout.values[0]
        let tree = combined.root
        let reconciliation = usage?.dataBytes.map {
            StorageReconciliation(dataUsed: $0, found: tree.bytes, uncertain: tree.uncertainBytes,
                                  unreadable: tree.unreadable, notScanned: tree.notScanned)
        }
        return .success(DiskMapReport(tree: combined, volumes: usage, reconciliation: reconciliation, date: Date(),
                                      systemTree: systemTree, duration: Date().timeIntervalSince(started)))
    }

    private static func volumeName(_ dataRoot: String) -> String {
        guard dataRoot == Self.dataRoot else { return (dataRoot as NSString).lastPathComponent }
        return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }
}
