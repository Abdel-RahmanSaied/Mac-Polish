import Foundation

@main
enum OptimizePolicyCheck {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-policy-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appending(path: "old-cache")
        try Data("fixture".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: file.path)
        func item(_ category: ScanCategory, _ url: URL) -> ScanItem {
            ScanItem(url: url, size: 7, category: category, modifiedAt: nil)
        }
        let candidate = OptimizePolicy.candidate(item(.cache, file))
        precondition(candidate != nil)
        precondition(OptimizePolicy.unchanged(candidate!))
        precondition(OptimizePolicy.candidate(item(.deviceBackup, file)) == nil)
        precondition(OptimizePolicy.candidate(item(.largeFile, file)) == nil)
        precondition(OptimizePolicy.candidate(item(.xcodeArchive, file)) == nil)
        let link = root.appending(path: "linked-cache")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(OptimizePolicy.candidate(item(.cache, link)) == nil)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        precondition(!OptimizePolicy.unchanged(candidate!))
        precondition(OptimizePolicy.candidate(item(.cache, file)) == nil)
        precondition(SystemDataScanner.dockerBuildCacheBytes("Build Cache     0  0  0B  0B") == 0)
        precondition(SystemDataScanner.dockerBuildCacheBytes("Build Cache     22  0  26.08GB  26.08GB") == 26_080_000_000)
        precondition(SystemDataScanner.dockerBuildCacheBytes("Local Volumes 12 4 5.289GB 5.007GB") == nil)
        precondition(SystemDataScanner.dockerBuildCacheBytes("Build Cache 1 0 broken 0B") == nil)
        precondition(SystemDataScanner.dockerBuildCacheBytes("Build Cache 1 0 -5GB 0B") == nil)
        // System Data measures in-process here; the app uses the read-only worker.
        let reader = DiskMapService.inProcessReader
        let measured = SystemDataScanner.measure(name: "Fixture", url: root, note: "", reader: reader)
        precondition(!measured.partial && measured.bytes == FileSizeCalculator.allocatedSize(of: root) && measured.children.count <= 6)
        let missing = SystemDataScanner.measure(name: "Missing", url: root.appending(path: "missing"), note: "", reader: reader)
        precondition(missing.partial && missing.bytes == nil && missing.diagnostic.contains("missing"))
        let locked = root.appending(path: "locked-area")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let restricted = SystemDataScanner.measure(name: "Restricted", url: root, note: "", reader: reader)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        precondition(restricted.partial && restricted.bytes != nil && restricted.diagnostic.contains("Full Disk Access"))
        let late = SystemDataScanner.measure(name: "Late", url: root, note: "") { _, _, _ in
            .failure(DiskScanFailure(message: "late", timedOut: true))
        }
        precondition(late.partial && late.bytes == nil && late.diagnostic.contains("timed out"))
        let optimizer = OptimizerModel()
        optimizer.includeDocker = true
        precondition(!optimizer.hasActions)
        optimizer.report = SystemDataReport(areas: [], dockerOutput: "Build Cache 0 0 0B 0B", date: Date())
        precondition(!optimizer.dockerAvailable && !optimizer.hasActions)
        optimizer.report = SystemDataReport(areas: [], dockerOutput: "Build Cache 2 0 1GB 1GB", date: Date())
        precondition(optimizer.dockerAvailable && optimizer.hasActions)
        print("PASS: Docker zero/positive/unknown sizes, scan coverage and real folder measurements")
        print("PASS: old cache, personal-file exclusions, symlink rejection and changed-file revalidation")
    }
}
