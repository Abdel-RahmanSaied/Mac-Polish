import Foundation

/// End-to-end disk map test. Like the app's main.swift, this binary is also its own read-only scan worker,
/// so every reader below launches real `--scan-worker tree` child processes through the production path:
/// argument encoding, launcher guard, scan, JSON over stdout, time limits, grafting and reconciliation.
/// Part 1 uses an isolated fixture in ~/Library/Caches. Part 2 reads the real startup disk (read-only),
/// skipping the folders that can raise macOS privacy prompts.
@main
enum DiskMapE2E {
    static func main() throws {
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        try fixtureMap()
        try realStartupDisk()
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw NSError(domain: "DiskMapE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: message()]) }
    }

    static func allocated(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
    }

    // MARK: Part 1 — isolated fixture through real worker processes

    static func fixtureMap() throws {
        let fm = FileManager.default
        let dataRoot = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-DiskMapE2E-" + UUID().uuidString)
        let locked = dataRoot.appending(path: "private/locked")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: dataRoot)
        }
        let mib = 1 << 20
        var expected: Int64 = 0
        @discardableResult
        func write(_ relative: String, bytes: Int, counted: Bool = true) throws -> URL {
            let url = dataRoot.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
            if counted { expected += try allocated(url) }
            return url
        }
        try write("Applications/Tool.app/Contents/binary", bytes: 3 * mib)
        let model = try write("Users/me/.cache/model.bin", bytes: 4 * mib)
        try check(clonefile(model.path, dataRoot.appending(path: "Users/me/.cache/model-clone.bin").path, 0) == 0, "clonefile")
        try fm.linkItem(at: model, to: dataRoot.appending(path: "Users/me/.cache/model-link.bin"))
        try write("Users/me/.hidden-notes", bytes: 3 * mib / 2)
        try write("Users/me/Desktop/photo.raw", bytes: 2 * mib)
        try write("Users/me/Documents/report.pdf", bytes: 2 * mib)
        try write("Users/me/Library/Containers/app/data.db", bytes: 2 * mib)
        for index in 0..<300 { try write("Users/me/small/file\(index).txt", bytes: 4_096) }
        try write("private/locked/secret.bin", bytes: 2 * mib, counted: false)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let home = dataRoot.appending(path: "Users/me")
        let usage = VolumeUsage(capacity: 1_000 * Int64(mib), free: 500 * Int64(mib),
                                volumes: [.init(name: "Data", role: "Data", bytes: expected + Int64(mib / 2))])

        // Every folder read goes through a real worker process.
        let calls = CallLog()
        let counting: DiskMapService.TreeReader = { root, options, timeout in
            calls.add(root)
            return DiskMapService.workerReader(root, options, timeout)
        }
        let report = try DiskMapService.scan(home: home, dataRoot: dataRoot.path, timeout: 60, reader: counting,
                                             volumes: { usage }).get()
        let tree = report.tree.root
        try check(tree.bytes == expected, "worker map total \(tree.bytes) must equal the unique data written \(expected)")
        try check(calls.roots.count == 4 && calls.roots.contains(home.path + "/Desktop")
                  && calls.roots.contains(home.path + "/Library/Containers"),
                  "one worker for the volume and one per existing protected folder: \(calls.roots)")
        func node(_ path: [String], in root: DiskNode = tree) -> DiskNode? {
            path.reduce(Optional(root)) { node, name in node?.children.first { $0.name == name } }
        }
        try check(node(["Users", "me", "Desktop", "photo.raw"])?.kind == .file, "protected folder grafted back")
        try check(node(["Users", "me", ".hidden-notes"])?.kind == .file, "hidden files are mapped")
        try check(node(["Users", "me", ".cache"])?.bytes == (try allocated(model)), "clone and hard link count once")
        try check(node(["Users", "me", "small", DiskNode.smallerItemsName])?.files == 300, "small files fold into one row")
        try check(node(["private", "locked"])?.kind == .unreadable && tree.unreadable == 1
                  && report.tree.unreadablePaths == [locked.path], "unreadable folder is listed, not empty")
        try check(report.reconciliation?.unexplained == Int64(mib / 2) && report.reconciliation?.meetsTarget == true,
                  "reconciliation names the unexplained remainder: \(String(describing: report.reconciliation))")

        // Worker processes and in-process scanning produce the same map.
        let inProcess = try DiskMapService.scan(home: home, dataRoot: dataRoot.path, reader: DiskMapService.inProcessReader,
                                                volumes: { usage }).get()
        try check(inProcess.tree == report.tree, "worker and in-process maps must match")

        // A protected folder whose worker runs out of time is killed and reported; the rest of the map stays.
        let started = Date()
        // The Desktop worker is given the whole real data volume (read-only) and 0.3 s, so it is still
        // reading when its time runs out and the parent has to stop it, as with an unanswered access prompt.
        let stalled: DiskMapService.TreeReader = { root, options, timeout in
            root.hasSuffix("/Desktop") ? DiskMapService.workerReader(DiskMapService.dataRoot, DiskTreeOptions(), 0.3)
                : DiskMapService.workerReader(root, options, timeout)
        }
        let partial = try DiskMapService.scan(home: home, dataRoot: dataRoot.path, timeout: 60, reader: stalled,
                                              volumes: { usage }).get()
        let desktop = node(["Users", "me", "Desktop"], in: partial.tree.root)
        try check(desktop?.kind == .notScanned && desktop?.note?.contains("No answer in time") == true, "stalled folder reported")
        try check(partial.tree.root.bytes == expected - (try allocated(home.appending(path: "Desktop/photo.raw"))),
                  "other folders keep their sizes")
        try check(Date().timeIntervalSince(started) < 20, "a stalled worker must not hold the map")

        // System Data measures through the worker as well.
        let area = SystemDataScanner.measure(name: "Home", url: home, note: "")
        try check(area.bytes == expected - (try allocated(dataRoot.appending(path: "Applications/Tool.app/Contents/binary")))
                  && !area.partial && area.children.count <= 6, "System Data area via worker: \(String(describing: area.bytes))")

        // The worker refuses requests from any launcher except this executable.
        let executable = Bundle.main.executableURL!.path
        let shell = SystemDataScanner.run("/bin/sh", ["-c", "\"$0\" --scan-worker tree --root \"$1\" --options '{}'; echo \"status=$?\"",
                                                      executable, dataRoot.path], timeout: 10)
        try check(shell.output.trimmingCharacters(in: .whitespacesAndNewlines) == "status=3",
                  "worker launched by a shell must refuse with status 3: \(shell.output)")

        print("PASS (fixture): worker processes per protected folder, grafting, clones and hard links once, hidden files, folding, unreadable folder, reconciliation, worker = in-process, stalled worker killed, System Data via worker, launcher guard")
    }

    // MARK: Part 2 — the real startup disk, read-only

    static func realStartupDisk() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protected = DiskMapService.protectedFolders(home: home).map { DiskMapService.dataPath(for: $0) }
        let started = Date()
        let result = try DiskMapService.workerReader(DiskMapService.dataRoot, DiskTreeOptions(excluded: protected), 300).get()
        let seconds = Date().timeIntervalSince(started)
        let usage = try VolumeUsage.read().get()
        let root = result.root
        let gb = { (bytes: Int64) in String(format: "%.1f GB", Double(bytes) / 1e9) }
        guard let dataUsed = usage.dataBytes else { throw NSError(domain: "DiskMapE2E", code: 2) }
        try check(!result.incomplete, "the startup disk scan must finish within its time limit")
        try check(root.bytes > 0 && root.files > 0, "the startup disk scan must find files")
        try check(root.bytes <= dataUsed + root.uncertainBytes + dataUsed / 100,
                  "found \(gb(root.bytes)) cannot exceed the data volume \(gb(dataUsed)) beyond the shared-clone margin")
        try check(usage.used == usage.capacity - usage.free && usage.macOSBytes > 0, "container layout must be read")
        let topLevel = root.children.filter { $0.kind != .smallerItems }.prefix(5).map { "\($0.name) \(gb($0.bytes))" }
        print("PASS (startup disk): \(gb(root.bytes)) of \(gb(dataUsed)) found outside protected folders "
              + "(\(Int(Double(root.bytes) / Double(dataUsed) * 100))%), \(root.files) files, \(root.unreadable) unreadable, "
              + "\(String(format: "%.0f", seconds)) s. Largest: \(topLevel.joined(separator: ", ")). "
              + "Protected folders are measured by the app itself after macOS allows access.")
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ root: String) { lock.lock(); values.append(root); lock.unlock() }
    var roots: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
