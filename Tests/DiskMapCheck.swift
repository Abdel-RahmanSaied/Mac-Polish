import Foundation

@main
enum DiskMapCheck {
    static func main() throws {
        let fm = FileManager.default
        let dataRoot = fm.temporaryDirectory.appending(path: "MacPolish-map-test-" + UUID().uuidString).path
        defer { try? fm.removeItem(atPath: dataRoot) }
        func write(_ relative: String, bytes: Int) throws {
            let url = URL(fileURLWithPath: dataRoot + "/" + relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        }
        let mib = 1 << 20
        try write("Applications/Tool.app/Contents/binary", bytes: 2 * mib)
        try write("Users/me/.cache/model.bin", bytes: 3 * mib)
        try write("Users/me/Desktop/photo.raw", bytes: 2 * mib)
        try write("Users/me/Documents/report.pdf", bytes: 2 * mib)
        try write("Users/me/Library/Containers/app/data.db", bytes: 2 * mib)
        let home = URL(fileURLWithPath: dataRoot + "/Users/me")
        let expected = FileSizeCalculator.allocatedSize(of: URL(fileURLWithPath: dataRoot))

        // Protected folders are read by their own reader calls and grafted back at their place.
        let calls = LockedList()
        let recording: DiskMapService.TreeReader = { root, options, timeout in
            calls.append(root, options.excluded)
            return DiskMapService.inProcessReader(root, options, timeout)
        }
        let usage = VolumeUsage(capacity: 100 * Int64(mib), free: 50 * Int64(mib),
                                volumes: [.init(name: "Data", role: "Data", bytes: expected)])
        let report = try DiskMapService.scan(home: home, dataRoot: dataRoot, reader: recording, volumes: { usage }).get()
        let tree = report.tree.root
        precondition(tree.bytes == expected, "map total \(tree.bytes) vs \(expected)")
        let mainCall = calls.items.first { $0.root == dataRoot }!
        precondition(mainCall.excluded.contains(home.path + "/Desktop") && mainCall.excluded.contains(home.path + "/Library/Containers"))
        precondition(calls.items.contains { $0.root == home.path + "/Documents" && $0.excluded.isEmpty })
        precondition(!calls.items.contains { $0.root == home.path + "/Movies" }, "missing folders are not read")
        func node(_ path: [String]) -> DiskNode? {
            path.reduce(Optional(tree)) { node, name in node?.children.first { $0.name == name } }
        }
        precondition(node(["Users", "me", "Desktop", "photo.raw"])?.kind == .file)
        precondition(node(["Users", "me", "Library", "Containers"])?.bytes ?? 0 >= Int64(2 * mib))
        precondition(report.reconciliation?.coverage == 1 && report.reconciliation?.meetsTarget == true)

        // A protected folder that never answers is shown as not scanned; everything else remains.
        let stalled: DiskMapService.TreeReader = { root, options, timeout in
            root.hasSuffix("/Desktop") ? .failure(DiskScanFailure(message: "late", timedOut: true))
                : DiskMapService.inProcessReader(root, options, timeout)
        }
        let partial = try DiskMapService.scan(home: home, dataRoot: dataRoot, reader: stalled, volumes: { nil }).get()
        let desktop = partial.report(["Users", "me", "Desktop"])
        precondition(desktop?.kind == .notScanned && desktop?.note?.contains("No answer in time") == true)
        precondition(partial.tree.root.notScanned == 1 && partial.tree.incomplete && partial.reconciliation == nil)
        precondition(partial.tree.root.bytes == expected - FileSizeCalculator.allocatedSize(of: home.appending(path: "Desktop")))

        // Without the main volume there is no map.
        let broken: DiskMapService.TreeReader = { root, options, timeout in
            root == dataRoot ? .failure(DiskScanFailure(message: "boom")) : DiskMapService.inProcessReader(root, options, timeout)
        }
        if case .success = DiskMapService.scan(home: home, dataRoot: dataRoot, reader: broken, volumes: { nil }) {
            preconditionFailure("main volume failure must fail the map")
        }

        // Paths shown to people use the familiar firmlinked form.
        precondition(DiskMapService.displayPath(["Users", "me"]) == "/Users/me")
        precondition(DiskMapService.displayPath([]) == "/")
        precondition(DiskMapService.dataPath(for: URL(fileURLWithPath: "/Users/me")) == "/System/Volumes/Data/Users/me")

        // The worker request round-trips its options.
        var options = DiskTreeOptions(keepDepth: 1, excluded: ["/a b"], threads: 4)
        options.deadline = Date(timeIntervalSince1970: 1_000)
        let arguments = try ["--scan-worker", "tree"] + DiskMapService.workerArguments(root: "/x y", options: options)
        let request = ScanWorker.treeRequest(arguments)
        precondition(request?.root == "/x y" && request?.options == options)
        precondition(ScanWorker.treeRequest(["--scan-worker", "tree", "--root", "/x"]) == nil)

        print("PASS: whole-volume map with protected folders grafted, stalled folder reported, main failure, display paths, worker request")
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(root: String, excluded: [String])] = []
    func append(_ root: String, _ excluded: [String]) { lock.lock(); items.append((root, excluded)); lock.unlock() }
}

extension DiskMapReport {
    func report(_ path: [String]) -> DiskNode? {
        path.reduce(Optional(tree.root)) { node, name in node?.children.first { $0.name == name } }
    }
}
