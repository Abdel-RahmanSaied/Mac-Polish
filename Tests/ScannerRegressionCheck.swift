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
        // Break caught: a stalled Downloads access prompt also discarding the Xcode, DerivedData and simulator results.
        let scanner = DiskScanner(home: root, applicationsRoot: root.appending(path: "Applications"))
        precondition(!scanner.scan(section: .developer).contains { $0.category == .xcodeDownload },
                     "The developer section must not read Downloads")
        precondition(scanner.scan(section: .xcodeInstallers).contains { $0.url == installer },
                     "Xcode installers in Downloads have their own section")

        // Large Files: hidden files and packages count; files inside a package or a hidden folder (.git) are not offered.
        let mib = 1 << 20
        func write(_ relative: String, bytes: Int) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        }
        try write("Downloads/.hidden-archive.zip", bytes: 2 * mib)
        try write("Downloads/Big.app/Contents/payload", bytes: 2 * mib)
        try write("Documents/project/.git/objects/pack.bin", bytes: 2 * mib)
        try write("Documents/movie.mov", bytes: 2 * mib)
        let movie = root.appending(path: "Documents/movie.mov")
        precondition(clonefile(movie.path, root.appending(path: "Documents/movie copy.mov").path, 0) == 0)
        let large = DiskScanner(home: root, applicationsRoot: root.appending(path: "Applications"), largeFileMinimum: Int64(mib))
        let downloadItems = large.scan(section: .downloads)
        precondition(downloadItems.contains { $0.url.lastPathComponent == ".hidden-archive.zip" && !$0.isSelected }, "hidden files are listed")
        let bundle = downloadItems.filter { $0.url.path.contains("Big.app") }
        precondition(bundle.count == 1 && bundle[0].url.lastPathComponent == "Big.app" && bundle[0].size >= Int64(2 * mib),
                     "a package is one item")
        let documents = large.scan(section: .documents)
        precondition(!documents.contains { $0.url.path.contains("/.git/") }, "files inside hidden folders are not offered")
        let copies = documents.filter { $0.url.lastPathComponent.hasPrefix("movie") }
        precondition(copies.count == 2 && copies.allSatisfy { $0.size == FileSizeCalculator.allocatedSize(of: movie) }
                     && copies[0].size * 2 <= Int64(2 * mib) + 16_384, "clones share their size")
        print("PASS: isolated Downloads scan ignores special entries and detects only aged Xcode installers without metadata prefetch hangs; large files include hidden files and packages, skip hidden folders, share clone sizes")
    }
}
