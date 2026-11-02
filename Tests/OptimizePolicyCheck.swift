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
        precondition(SystemDataScanner.measurementStatus(status: 1, output: "du: /private: Operation not permitted", hasTotal: true).contains("Access restricted"))
        precondition(SystemDataScanner.measurementStatus(status: -1, output: "", hasTotal: false).contains("timed out"))
        let measured = SystemDataScanner.measure(name: "Fixture", url: root, note: "")
        precondition(!measured.partial && measured.bytes != nil)
        let missing = SystemDataScanner.measure(name: "Missing", url: root.appending(path: "missing"), note: "")
        precondition(missing.partial && missing.bytes == nil && missing.diagnostic.contains("missing"))
        precondition(SystemDataScanner.parseDU("du: denied\n4\t/tmp/folder with spaces\n-1\t/tmp/invalid").count == 1)
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
