import Foundation

@main
enum DiskTreeCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-tree-test-" + UUID().uuidString)
        let locked = root.appending(path: "locked")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        func write(_ relative: String, bytes: Int) throws {
            let url = root.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        }
        let mib = 1 << 20
        try write("big.bin", bytes: 2 * mib)
        try write(".hidden-big", bytes: 3 * mib / 2)
        for index in 1...5 { try write("small\(index).txt", bytes: 10_000) }
        try write("App.app/Contents/payload", bytes: 6 * mib / 5)
        try write("pair/a.bin", bytes: 2 * mib)
        precondition(clonefile(root.appending(path: "pair/a.bin").path, root.appending(path: "pair/b.bin").path, 0) == 0)
        try write("skip/excluded.bin", bytes: 2 * mib)
        try write("deep/l1/l2/file.bin", bytes: 11 * mib / 10)
        try write("locked/inside.bin", bytes: 2 * mib)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        // A locked folder inside a tiny folder must stay reachable instead of folding into "Smaller items".
        let nestedLocked = root.appending(path: "tiny/vault")
        try fm.createDirectory(at: nestedLocked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nestedLocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nestedLocked.path) }

        let skip = root.appending(path: "skip").path
        let expected = FileSizeCalculator.allocatedSize(of: root) - FileSizeCalculator.allocatedSize(of: URL(fileURLWithPath: skip))
        let options = DiskTreeOptions(excluded: [skip])
        let result = DiskTreeScanner.scan(root.path, options: options)
        let tree = result.root

        // Totals: every readable file, hidden files and package contents included, clones once, exclusions out.
        precondition(tree.bytes == expected, "total \(tree.bytes) != \(expected)")
        precondition(!result.incomplete && !result.missing)
        func child(_ name: String, of node: DiskNode = tree) -> DiskNode? { node.children.first { $0.name == name } }
        precondition(child("big.bin")?.kind == .file && child(".hidden-big")?.kind == .file)
        precondition(child("App.app")?.kind == .folder && (child("App.app")?.bytes ?? 0) >= Int64(mib))
        let onePairFile = FileSizeCalculator.allocatedSize(of: root.appending(path: "pair/a.bin")) * 2
        precondition(child("pair")?.bytes == onePairFile, "clone pair counts one copy")
        precondition(child("skip") == nil, "excluded path must be absent")

        // Small entries fold into one row; totals hold at every level.
        let smaller = tree.children.filter { $0.kind == .smallerItems }
        precondition(smaller.count == 1 && smaller[0].files == 5 && tree.children.last?.kind == .smallerItems)
        func checkTotals(_ node: DiskNode) {
            guard !node.children.isEmpty else { return }
            precondition(node.children.reduce(0) { $0 + $1.bytes } == node.bytes, "children of \(node.name) must add up")
            precondition(node.children.reduce(0) { $0 + $1.files } == node.files)
            node.children.forEach(checkTotals)
        }
        checkTotals(tree)
        precondition(zip(tree.children.dropLast(), tree.children.dropLast().dropFirst()).allSatisfy { $0.bytes >= $1.bytes })

        // Unreadable folders are listed and counted instead of looking empty.
        precondition(child("locked")?.kind == .unreadable && tree.unreadable == 2)
        precondition(child("vault", of: child("tiny") ?? tree)?.kind == .unreadable, "path to a locked folder stays listed")
        precondition(result.unreadablePaths == [locked.path, nestedLocked.path].sorted())

        // The same tree with one or eight threads.
        var single = options
        single.threads = 1
        precondition(DiskTreeScanner.scan(root.path, options: single) == result)

        // Depth limit keeps totals but drops grandchildren; a child limit folds the rest.
        var shallow = options
        shallow.keepDepth = 1
        let shallowTree = DiskTreeScanner.scan(root.path, options: shallow).root
        precondition(shallowTree.bytes == tree.bytes && shallowTree.children.allSatisfy(\.children.isEmpty))
        var narrow = options
        narrow.maximumChildren = 2
        let narrowTree = DiskTreeScanner.scan(root.path, options: narrow).root
        precondition(narrowTree.children.count == 3 && narrowTree.bytes == tree.bytes)

        // A passed deadline returns at once with an incomplete result.
        var late = options
        late.deadline = Date(timeIntervalSinceNow: -1)
        let lateResult = DiskTreeScanner.scan(root.path, options: late)
        precondition(lateResult.incomplete && lateResult.root.notScanned >= 1)

        // A missing location and a single file.
        let missing = DiskTreeScanner.scan(root.appending(path: "nope").path, options: options)
        precondition(missing.missing && missing.root.bytes == 0)
        let file = DiskTreeScanner.scan(root.appending(path: "big.bin").path, options: options)
        precondition(file.root.kind == .file && file.root.bytes == child("big.bin")?.bytes)

        // Matches du for data without clones (du counts in 1 KiB blocks).
        let du = SystemDataScanner.run("/usr/bin/du", ["-sk", root.appending(path: "deep").path], timeout: 10)
        let duBytes = (Int64(du.output.split(separator: "\t").first ?? "") ?? -1) * 1_024
        precondition(abs(duBytes - (child("deep")?.bytes ?? 0)) <= 4 * 4_096, "du \(duBytes) vs \(child("deep")?.bytes ?? 0)")

        // Grafting places a separately scanned folder and updates every ancestor.
        let extra = DiskNode(name: "x", kind: .file, bytes: 5, files: 1)
        let grafted = tree.grafting(extra, at: ["deep", "new", "x"])
        precondition(grafted.bytes == tree.bytes + 5 && grafted.files == tree.files + 1)
        let deep = child("deep", of: grafted)!
        precondition(deep.bytes == child("deep")!.bytes + 5 && child("new", of: deep)?.children.first?.name == "x")
        let replaced = grafted.grafting(DiskNode(name: "x", kind: .file, bytes: 9, files: 1), at: ["deep", "new", "x"])
        precondition(replaced.bytes == tree.bytes + 9, "grafting the same path replaces it")
        checkTotals(replaced)

        print("PASS: clone-aware totals, hidden and package contents, exclusions, folding, unreadable folders, threads, depth, deadline, du parity, grafting")
    }
}
