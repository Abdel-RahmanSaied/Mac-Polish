import Foundation

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(values) }
}

/// One stalled folder (a cloud provider, or a macOS access prompt waiting for the user)
/// must not discard results from every other location.
@main
enum PartialScanCheck {
    static func main() {
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        let fixture = URL(fileURLWithPath: "/fixture")
        func item(_ name: String, _ category: ScanCategory, _ size: Int64) -> ScanItem {
            ScanItem(url: fixture.appending(path: name), size: size, category: category, modifiedAt: nil)
        }
        let stalled = DiskScanFailure(message: "stalled", timedOut: true)
        let cacheItems = [item("small-cache", .cache, 10), item("big-cache", .cache, 90)]
        let documentItems = [item("movie.mov", .largeFile, 500)]

        // Break caught: a single timed-out section turning the whole scan into a failure.
        let calls = Calls()
        let partial = DiskScanService.scan(includeLargeFiles: true) { section in
            calls.add(section.rawValue)
            switch section {
            case .downloads: return .failure(stalled)
            case .caches: return .success(ScanReport(items: cacheItems, deniedPaths: []))
            case .documents: return .success(ScanReport(items: documentItems, deniedPaths: []))
            default: return .success(ScanReport(items: [], deniedPaths: []))
            }
        }
        guard case .success(let outcome) = partial else { preconditionFailure("Readable sections must still produce results") }
        precondition(outcome.incomplete == [.downloads], "Only the stalled section is incomplete")
        precondition(outcome.items.map(\.url.lastPathComponent) == ["big-cache", "small-cache", "movie.mov"],
                     "Results from readable sections are merged in the usual order, got \(outcome.items.map(\.url.lastPathComponent))")
        precondition(outcome.warning?.contains("Downloads") == true, "The warning names the location that did not finish")
        precondition(calls.all == Set(DiskScanner.Section.allCases.map(\.rawValue)), "Every section is read")

        // Break caught: reading personal folders for large files when the setting is off.
        let withoutLarge = Calls()
        _ = DiskScanService.scan(includeLargeFiles: false) { withoutLarge.add($0.rawValue); return .success(ScanReport(items: [], deniedPaths: [])) }
        precondition(withoutLarge.all.isDisjoint(with: ["downloads", "documents", "desktop"]), "Large-file folders are skipped when disabled")

        // Break caught: reporting success when nothing could be read.
        guard case .failure(let failure) = DiskScanService.scan(includeLargeFiles: true, reader: { _ in .failure(stalled) }) else {
            preconditionFailure("A scan with no readable section is a failure")
        }
        precondition(failure.timedOut, "A scan where every section stalled reports the time limit")

        // Folder access: one prompt waiting for the user must not hide the other folders' answers.
        let access = FolderAccessCheck.checkAll { name, url in
            name == "Downloads" ? .failure(stalled) : .success([FolderAccessResult(name: name, url: url, status: .readable)])
        }
        precondition(access.results.count == FolderAccessCheck.locations().count, "Every folder is reported")
        precondition(access.results.first { $0.name == "Downloads" }?.status == .timedOut, "The stalled folder is marked as not answered")
        precondition(access.results.filter { $0.name != "Downloads" }.allSatisfy { $0.status == .readable }, "Other folders keep their answers")
        precondition(access.warning != nil, "The user is told that a folder did not answer in time")
        precondition(FolderAccessCheck.checkAll { name, url in .success([FolderAccessResult(name: name, url: url, status: .readable)]) }.warning == nil)

        // The real worker honours the per-section and per-folder arguments (locations without macOS prompts).
        guard case .success = DiskScanService.readValue(ScanReport<ScanItem>.self, mode: "basic", arguments: ["--section", "logs"], timeout: 60) else {
            preconditionFailure("The worker scans a single requested section")
        }
        guard case .success(let developer) = DiskScanService.read(FolderAccessResult.self, mode: "access", arguments: ["--location", "Xcode user data"], timeout: 30),
              developer.map(\.name) == ["Xcode user data"] else {
            preconditionFailure("The worker checks only the requested folder")
        }
        print("PASS: partial scans keep readable sections, name stalled locations, and check folders independently")
    }
}
