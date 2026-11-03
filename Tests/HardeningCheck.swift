import Darwin
import Foundation

/// Smaller correctness and efficiency rules: uninstall leftovers, duplicate grouping,
/// concurrent measurements, memory readings and Docker size parsing.
@main
enum HardeningCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-hardening-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Break caught: an app name such as "../Mail" pointing uninstall at another Library folder.
        let library = root.appending(path: "Library")
        for folder in ["Mail", "Caches", "Application Support/Example"] {
            try fm.createDirectory(at: library.appending(path: folder), withIntermediateDirectories: true)
        }
        let crafted = ApplicationScanner.leftovers(appName: "../Mail", bundleIdentifier: "../Mail", library: library)
        precondition(crafted.isEmpty, "Names that leave their folder must not become leftovers, got \(crafted.map(\.path))")
        let normal = ApplicationScanner.leftovers(appName: "Example", bundleIdentifier: nil, library: library)
        precondition(normal.map(\.lastPathComponent) == ["Example"], "Ordinary app names still find their data")

        // Break caught: grouping duplicates by disk allocation instead of content length.
        // A sparse copy has the same bytes as a written copy but almost no allocated blocks.
        // Under ~/Library/Caches: fingerprints refuse paths with symlinked ancestors such as /var → /private/var.
        let duplicates = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-hardening-" + UUID().uuidString)
        try fm.createDirectory(at: duplicates, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: duplicates) }
        let length = 2 * 1_024 * 1_024
        try Data(repeating: 0, count: length).write(to: duplicates.appending(path: "written.bin"))
        let sparse = duplicates.appending(path: "sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(length))
        try handle.close()
        let found = DuplicateScanner().scan(minimumSize: 1_024 * 1_024, roots: [duplicates])
        precondition(found.count == 2 && Set(found.map(\.fingerprint)).count == 1, "Identical content is one duplicate group, got \(found.count) files")
        precondition(found.allSatisfy { $0.size == Int64(length) }, "Duplicate sizes are content lengths")

        // Break caught: measuring System Data locations one after another.
        let started = Date()
        let names = (0..<8).map { "area-\($0)" }
        let measured = SystemDataScanner.measureAll(names) { name in Thread.sleep(forTimeInterval: 0.4); return name }
        precondition(measured == names, "Measurements keep their order")
        precondition(Date().timeIntervalSince(started) < 1.5, "Eight 0.4 s measurements must overlap, took \(Date().timeIntervalSince(started)) s")

        // Break caught: reading per-app memory by launching `ps` every few seconds.
        guard let own = MemoryReader.residentSize(pid: getpid()) else { preconditionFailure("Own resident size must be readable") }
        let ps = SystemDataScanner.run("/bin/ps", ["-o", "rss=", "-p", String(getpid())], timeout: 3)
        let psBytes = (UInt64(ps.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1_024
        precondition(psBytes > 0 && Double(own) > Double(psBytes) * 0.75 && Double(own) < Double(psBytes) * 1.25,
                     "Resident size must match what ps reports (\(own) vs \(psBytes))")
        precondition(MemoryReader.residentSize(pid: 999_999) == nil, "A process that does not exist has no reading")

        // Break caught: Docker sizes of a terabyte or more reading as unknown.
        precondition(SystemDataScanner.dockerBuildCacheBytes("Build Cache 40 0 1.5TB 1.5TB") == 1_500_000_000_000)

        print("PASS: leftover containment, content-length duplicate groups, overlapping measurements, ps-free memory readings, TB sizes")
    }
}
