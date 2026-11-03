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

        // APFS clones share their data blocks and hard links share one file: each is real space only once.
        let shared = root.appending(path: "shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let original = shared.appending(path: "original.bin")
        try Data((0..<(4 << 20)).map { _ in UInt8.random(in: 0...255) }).write(to: original)
        let oneCopy = Int64(try original.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        precondition(clonefile(original.path, shared.appending(path: "clone.bin").path, 0) == 0, "clonefile failed")
        try fm.linkItem(at: original, to: shared.appending(path: "hard-link.bin"))
        let sharedSize = FileSizeCalculator.allocatedSize(of: shared)
        precondition(oneCopy > 0 && sharedSize == oneCopy, "clone and hard link must count once: \(sharedSize) vs \(oneCopy)")
        // original.bin shares its data with clone.bin (2 clones) and its file with hard-link.bin (2 links).
        precondition(FileSizeCalculator.allocatedSize(of: original) == oneCopy / 4, "each path carries its share")
        precondition(FileSizeCalculator.allocatedSize(of: shared.appending(path: "clone.bin")) == oneCopy / 2)

        // A folder macOS will not open is reported, not silently counted as empty.
        let locked = root.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: locked.appending(path: "inside"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        precondition(FileSizeCalculator.measure(root).unreadableFolders == 1)
        precondition(FileSizeCalculator.measure(shared).unreadableFolders == 0)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        let started = Date()
        let timeout = SystemDataScanner.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.05)
        precondition(timeout.status == -1 && Date().timeIntervalSince(started) < 4)
        let output = SystemDataScanner.run("/usr/bin/printf", ["fixture"], timeout: 2)
        precondition(output.status == 0 && output.output == "fixture")
        let missing = SystemDataScanner.run("/not/a/real/tool", [], timeout: 1)
        precondition(missing.status == -1 && !missing.output.isEmpty)
        print("PASS: package/hidden allocated sizes, clone and hard-link sharing, unreadable folders, symlink exclusion, bounded process timeout and launch failure")
    }
}
