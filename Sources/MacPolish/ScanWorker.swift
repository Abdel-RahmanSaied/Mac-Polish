import Darwin
import Foundation

/// Entry point for the read-only child process that DiskScanService launches with `--scan-worker <mode>`.
enum ScanWorker {
    /// Returns the exit status when the arguments request worker mode, or nil to start the app normally.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--scan-worker") else { return nil }
        // The worker reads with the app's macOS file permissions (including Full Disk Access).
        // Only the app binary itself may launch it; `open --args`, shells and scripts are refused.
        guard isLaunchedBySameExecutable() else { return 3 }
        guard arguments.indices.contains(index + 1) else { return 2 }
        func write<T: Encodable>(_ value: T) throws {
            FileHandle.standardOutput.write(try JSONEncoder().encode(value))
        }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        do {
            switch arguments[index + 1] {
            case "basic":
                if let name = value(after: "--section") {
                    guard let section = DiskScanner.Section(rawValue: name) else { return 2 }
                    try write(DiskScanner().report(section: section))
                } else {
                    try write(DiskScanner().scan(includeLargeFiles: arguments.contains("--include-large-files")))
                }
            case "duplicates": try write(DuplicateScanner().report())
            case "applications": try write(ApplicationScanner().scan())
            case "tree":
                guard let request = treeRequest(arguments) else { return 2 }
                try write(DiskTreeScanner.scan(request.root, options: request.options))
            case "startup": try write(StartupScanner().scan())
            case "access":
                let requested = value(after: "--location")
                let locations = FolderAccessCheck.locations().filter { requested == nil || $0.0 == requested }
                guard !locations.isEmpty else { return 2 }
                try write(locations.map { FolderAccessCheck.check(name: $0.0, url: $0.1) })
            case "full-disk-access": try write(FullDiskAccess.status())
            default: return 2
            }
            return 0
        } catch { return 2 }
    }

    /// `--root <path> --options <json>` for the tree mode; nil when either is missing or invalid.
    static func treeRequest(_ arguments: [String]) -> (root: String, options: DiskTreeOptions)? {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let root = value(after: "--root"), root.hasPrefix("/"), let json = value(after: "--options") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let options = try? decoder.decode(DiskTreeOptions.self, from: Data(json.utf8)) else { return nil }
        return (root, options)
    }

    /// True when the parent process runs the same executable file as this process.
    static func isLaunchedBySameExecutable() -> Bool {
        let parent = getppid()
        // A parent of launchd means the app was started by LaunchServices or the original parent exited.
        guard parent > 1, let own = executableIdentity(of: getpid()), let launcher = executableIdentity(of: parent) else { return false }
        return own == launcher
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func executableIdentity(of pid: pid_t) -> FileIdentity? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var info = stat()
        guard stat(buffer, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
