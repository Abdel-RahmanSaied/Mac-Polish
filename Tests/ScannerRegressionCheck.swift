import Foundation
import Darwin

@main
enum ScannerRegressionCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-scanner-test-" + UUID().uuidString)
        let downloads = root.appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let installer = downloads.appending(path: "Xcode-fixture.xip")
        try Data(repeating: 7, count: 8192).write(to: installer)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: installer.path)
        let pipe = downloads.appending(path: "unrelated-pipe")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        let start = Date()
        let found = DiskScanner(home: root, applicationsRoot: root.appending(path: "Applications")).scan()
        precondition(Date().timeIntervalSince(start) < 5)
        precondition(found.contains { $0.url == installer && $0.category == .xcodeDownload && !$0.isSelected })
        precondition(!found.contains { $0.url == pipe })
        print("PASS: isolated Downloads scan ignores special entries and detects only aged Xcode installers without metadata prefetch hangs")
    }
}
