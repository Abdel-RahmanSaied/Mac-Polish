import Foundation

/// The whole startup data volume as one tree, compared with what macOS reports as used.
struct DiskMapReport: Sendable {
    var tree: DiskTreeResult
    var volumes: VolumeUsage?
    var reconciliation: StorageReconciliation?
    var date: Date
}

enum DiskMapService {
    /// Reads one folder tree. The worker reader runs in the read-only child process; tests use the in-process one.
    typealias TreeReader = @Sendable (_ root: String, _ options: DiskTreeOptions, _ timeout: TimeInterval) -> Result<DiskTreeResult, DiskScanFailure>

    static let dataRoot = "/System/Volumes/Data"
    /// Folders that can wait on a macOS access request get their own worker and time limit.
    static let protectedTimeout: TimeInterval = 180

    static let inProcessReader: TreeReader = { root, options, timeout in
        var options = options
        options.deadline = options.deadline ?? Date().addingTimeInterval(timeout)
        return .success(DiskTreeScanner.scan(root, options: options))
    }

    static let workerReader: TreeReader = { root, options, timeout in
        var options = options
        // Stop reading before the process deadline so the partial tree still comes back.
        options.deadline = Date().addingTimeInterval(max(1, timeout * 0.9 - 5))
        guard let arguments = try? workerArguments(root: root, options: options) else {
            return .failure(DiskScanFailure(message: "The scan request could not be prepared."))
        }
        return DiskScanService.readValue(DiskTreeResult.self, mode: "tree", arguments: arguments, timeout: timeout)
    }

    static func workerArguments(root: String, options: DiskTreeOptions) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return ["--root", root, "--options", String(decoding: try encoder.encode(options), as: UTF8.self)]
    }

    /// Folders where reading can trigger a macOS privacy prompt (or a cloud provider) and stall.
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
                     volumes: @escaping @Sendable () -> VolumeUsage? = { try? VolumeUsage.read().get() }) -> Result<DiskMapReport, DiskScanFailure> {
        let protected = protectedFolders(home: home)
            .map { dataPath(for: $0, dataRoot: dataRoot) }
            .filter { FileAttributes.read(path: $0)?.kind == .folder }
        let mainOptions = DiskTreeOptions(excluded: protected)
        let jobs: [(String, DiskTreeOptions, TimeInterval)] = [(dataRoot, mainOptions, timeout)]
            + protected.map { ($0, DiskTreeOptions(), min(timeout, protectedTimeout)) }
        let layout = LockedResults<VolumeUsage?>(count: 1)
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { layout.set(0, volumes()) }
        let results = DiskScanService.concurrentMap(jobs) { reader($0.0, $0.1, $0.2) }
        group.wait()

        guard case .success(var combined) = results[0] else {
            if case .failure(let failure) = results[0] { return .failure(failure) }
            return .failure(DiskScanFailure(message: "The startup disk could not be read."))
        }
        for (path, result) in zip(protected, results.dropFirst()) {
            let components = path.dropFirst(dataRoot.count).split(separator: "/").map(String.init)
            switch result {
            case .success(let found):
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

        let usage = layout.values[0]
        let tree = combined.root
        let reconciliation = usage?.dataBytes.map {
            StorageReconciliation(dataUsed: $0, found: tree.bytes, uncertain: tree.uncertainBytes,
                                  unreadable: tree.unreadable, notScanned: tree.notScanned)
        }
        return .success(DiskMapReport(tree: combined, volumes: usage, reconciliation: reconciliation, date: Date()))
    }

    private static func volumeName(_ dataRoot: String) -> String {
        guard dataRoot == Self.dataRoot else { return (dataRoot as NSString).lastPathComponent }
        return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }
}
