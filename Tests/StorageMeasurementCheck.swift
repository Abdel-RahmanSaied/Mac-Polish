import Foundation

@main
enum StorageMeasurementCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-size-test-" + UUID().uuidString)
        try fm.createDirectory(at: root.appending(path: "Example.app/Contents/.hidden"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let files = [root.appending(path: "Example.app/Contents/binary"), root.appending(path: "Example.app/Contents/.hidden/data")]
        for file in files { try Data(repeating: 7, count: 32768).write(to: file) }
        let expected = try files.reduce(Int64(0)) { total, file in
            let value = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return total + Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0)
        }
        precondition(expected > 0 && FileSizeCalculator.allocatedSize(of: root) == expected)
        let link = root.appending(path: "external-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: fm.homeDirectoryForCurrentUser)
        precondition(FileSizeCalculator.allocatedSize(of: link) == 0)
        precondition(FileSizeCalculator.allocatedSize(of: root) == expected)
        let started = Date()
        let timeout = SystemDataScanner.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.05)
        precondition(timeout.status == -1 && Date().timeIntervalSince(started) < 4)
        let output = SystemDataScanner.run("/usr/bin/printf", ["fixture"], timeout: 2)
        precondition(output.status == 0 && output.output == "fixture")
        let missing = SystemDataScanner.run("/not/a/real/tool", [], timeout: 1)
        precondition(missing.status == -1 && !missing.output.isEmpty)
        print("PASS: package/hidden allocated sizes, symlink exclusion, bounded process timeout and launch failure")
    }
}
