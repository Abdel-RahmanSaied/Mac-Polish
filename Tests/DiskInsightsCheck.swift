import Darwin
import Foundation

@main
enum DiskInsightsCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-insights-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func write(_ relative: String, bytes: Int, age days: Double? = nil) throws {
            let url = root.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: bytes).write(to: url)
            if let days { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path) }
        }
        try write("Movies/trip.mov", bytes: 300_000)
        try write("Movies/clip.MP4", bytes: 200_000, age: 400)
        try write("Music/song.m4a", bytes: 50_000, age: 1_200)
        try write("Docs/report.pdf", bytes: 40_000)
        try write("Docs/.hidden-notes.txt", bytes: 9_000)
        try write("Docs/empty.txt", bytes: 0)
        try write("Downloads/Installer.dmg", bytes: 250_000, age: 45)
        try write("Downloads/bundle.tar.gz", bytes: 30_000)
        // Every file inside a package or a well-known folder takes that folder's kind, whatever its extension.
        try write("Apps/Tool.app/Contents/Resources/icon.png", bytes: 20_000)
        try write("Apps/Tool.app/Contents/MacOS/Tool", bytes: 60_000)
        try write("Library/Caches/com.example/data.png", bytes: 70_000)
        try write("Code/app/node_modules/pkg/index.js", bytes: 8_000)
        try write("Code/app/main.swift", bytes: 3_000)
        try write("Deep/a/b/c/d/e/f/g/leaf.bin", bytes: 1_000)
        precondition(symlink("/", root.appending(path: "Docs/to-root").path) == 0)
        precondition(mkfifo(root.appending(path: "Docs/pipe").path, 0o600) == 0)

        let options = DiskTreeOptions(insights: DiskInsightOptions(largestFiles: 5))
        let result = DiskTreeScanner.scan(root.path, options: options)
        guard let insights = result.insights else { preconditionFailure("insights requested but missing") }

        // Accounting: every file in the tree is counted once by kind and once by age.
        precondition(insights.files == result.root.files, "kind totals must cover every file: \(insights.files) vs \(result.root.files)")
        precondition(insights.bytes == result.root.bytes, "kind bytes must equal the tree total")
        precondition(insights.ages.values.reduce(0) { $0 + $1.files } == result.root.files, "age totals must cover every file")
        precondition(result.root.files == 14)
        func files(_ kind: DiskInsights.Kind) -> Int { insights.kinds[kind]?.files ?? 0 }
        precondition(files(.video) == 2, "mov and upper-case MP4 are video")
        precondition(files(.audio) == 1 && files(.documents) == 3 && files(.diskImages) == 1 && files(.archives) == 1)
        precondition(files(.applications) == 2, "both files inside Tool.app are the app's, png included")
        precondition(files(.caches) == 1, "a png inside Library/Caches is cache")
        precondition(files(.developer) == 2, "node_modules content and source code")
        precondition(files(.other) == 1, "leaf.bin has no known kind")
        // 45 days → under a year; 400 days → 1–3 years; 1,200 days → older than 3 years; the rest are new.
        precondition(insights.ages[.lastYear]?.files == 1 && insights.ages[.oneToThreeYears]?.files == 1
                     && insights.ages[.olderThanThreeYears]?.files == 1 && insights.ages[.lastMonth]?.files == 11,
                     "age buckets: \(insights.ages)")
        precondition(insights.hidden.files == 1 && insights.emptyFiles == 1 && insights.specialEntries == 2,
                     "hidden \(insights.hidden.files), empty \(insights.emptyFiles), special \(insights.specialEntries)")
        precondition(insights.deepestLevel == 8, "deepest level \(insights.deepestLevel)")

        // Largest files: exact order, full paths, independent of what the tree folds into "Smaller items".
        let names = insights.largestFiles.map { ($0.path as NSString).lastPathComponent }
        precondition(names == ["trip.mov", "Installer.dmg", "clip.MP4", "data.png", "Tool"], "largest: \(names)")
        precondition(insights.largestFiles.allSatisfy { $0.path.hasPrefix(root.path + "/") && fm.fileExists(atPath: $0.path) })
        let folded = DiskTreeScanner.scan(root.path, options: DiskTreeOptions(minimumListedBytes: 1 << 30, insights: options.insights))
        precondition(folded.insights == insights, "folding rows must not change insights")
        precondition(folded.root.children.allSatisfy { $0.kind == .smallerItems || $0.kind == .folder })

        // Deterministic across thread counts, including largest-file ties broken by path.
        try write("Ties/b.bin", bytes: 300_000)
        try write("Ties/a.bin", bytes: 300_000)
        let single = DiskTreeScanner.scan(root.path, options: DiskTreeOptions(threads: 1, insights: options.insights))
        for threads in [2, 8, 16] {
            let many = DiskTreeScanner.scan(root.path, options: DiskTreeOptions(threads: threads, insights: options.insights))
            precondition(many.insights == single.insights && many.root.bytes == single.root.bytes, "threads \(threads) differ")
        }
        let tieOrder = single.insights!.largestFiles.prefix(3).map { ($0.path as NSString).lastPathComponent }
        precondition(tieOrder == ["trip.mov", "a.bin", "b.bin"], "ties must break by path: \(tieOrder)")

        // Disjoint parts read separately merge into the same facts as one read (minus the shared root folder).
        let whole = DiskTreeScanner.scan(root.path, options: DiskTreeOptions(insights: options.insights)).insights!
        let parts = try fm.contentsOfDirectory(atPath: root.path).map {
            DiskTreeScanner.scan(root.appending(path: $0).path, options: DiskTreeOptions(insights: options.insights)).insights
        }
        var merged = DiskInsights.merged(parts, keepingLargest: 5)!
        merged.folders += 1
        merged.deepestLevel += 1
        precondition(merged == whole, "merged parts must match one read")

        // Off by default: existing callers pay nothing and results compare equal as before.
        precondition(DiskTreeScanner.scan(root.path).insights == nil)
        // Survives the worker's JSON round trip.
        let decoded = try JSONDecoder().decode(DiskTreeResult.self, from: JSONEncoder().encode(single))
        precondition(decoded == single, "insights must survive JSON transfer")

        // Classification edges.
        precondition(DiskInsights.lowercasedExtension(".zshrc") == nil && DiskInsights.lowercasedExtension("a.") == nil
                     && DiskInsights.lowercasedExtension("x.TAR.GZ") == "gz")
        precondition(DiskInsights.folderKind("Photos Library.photoslibrary") == .images && DiskInsights.folderKind("src") == nil)

        // System volume: firmlinked folders belong to the data volume and must be excluded.
        let exclusions = DiskMapService.systemVolumeExclusions(firmlinks: "/Applications\tApplications\n/Users\tUsers\n/usr/local\tusr/local\n")
        precondition(exclusions == ["/Applications", "/System/Volumes", "/Users", "/dev", "/usr/local"], "\(exclusions)")
        precondition(DiskMapService.systemVolumeExclusions(firmlinks: "").contains("/Users"), "fallback list when firmlinks are unreadable")
        precondition(DiskMapService.familiarPath("/System/Volumes/Data/Users/me/a") == "/Users/me/a"
                     && DiskMapService.familiarPath("/System/Library/x") == "/System/Library/x")

        // Fixture data roots never trigger a real walk of `/`.
        let fake = root.appending(path: "FakeData")
        try fm.createDirectory(at: fake.appending(path: "Users/me"), withIntermediateDirectories: true)
        try write("FakeData/Users/me/file.bin", bytes: 4_096)
        let map = try DiskMapService.scan(home: URL(fileURLWithPath: "/Users/me"), dataRoot: fake.path,
                                          reader: DiskMapService.inProcessReader, volumes: { nil }).get()
        precondition(map.systemTree == nil, "a fixture data root has no system volume")
        precondition(map.tree.insights?.files == map.tree.root.files, "disk map carries insights for every file")

        // Real, read-only: the sealed system volume walk must land near what APFS reports for the System volume.
        let started = Date()
        let system = DiskTreeScanner.scan("/", options: DiskTreeOptions(minimumListedBytes: 16 << 20, maximumChildren: 50, keepDepth: 4,
                                                                        excluded: DiskMapService.systemVolumeExclusions(),
                                                                        deadline: Date().addingTimeInterval(120),
                                                                        insights: DiskMapService.insightOptions))
        let seconds = Date().timeIntervalSince(started)
        precondition(!system.incomplete, "system volume walk should finish well inside two minutes")
        if case .success(let usage) = VolumeUsage.read(), let sealed = usage.volumes.first(where: { $0.role == "System" })?.bytes, sealed > 0 {
            let ratio = Double(system.root.bytes) / Double(sealed)
            print(String(format: "  system volume: %@ walked vs %@ reported (%.0f%%), %d files in %.1f s",
                         system.root.bytes.formattedBytes, sealed.formattedBytes, ratio * 100, system.root.files, seconds))
            precondition(ratio > 0.5 && ratio < 1.25, "system volume walk must not double-count the data volume (ratio \(ratio))")
        } else {
            print("  system volume: \(system.root.bytes.formattedBytes), \(system.root.files) files in \(String(format: "%.1f", seconds)) s (APFS layout unavailable for comparison)")
        }
        print("PASS: per-file kinds, ages, hidden/empty/special counts and largest files cover every file, survive folding, threads, merging and JSON; system volume walk excludes firmlinks")
    }
}
