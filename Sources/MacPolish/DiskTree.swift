import Darwin
import Foundation

/// One row of the storage map. Sizes include everything below the row, even rows that were folded away.
struct DiskNode: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case folder, file
        /// Entries too small to list on their own, added together.
        case smallerItems
        /// A folder macOS would not let Mac Polish open.
        case unreadable
        /// A folder that was not read: time limit, or no answer to a macOS access request.
        case notScanned
    }

    static let smallerItemsName = "Smaller items"

    var name: String
    var kind: Kind
    var bytes: Int64 = 0
    var files: Int = 0
    /// Shared data of modified clones that may also be counted elsewhere (see FileAttributes.uncertainBytes).
    var uncertainBytes: Int64 = 0
    var unreadable: Int = 0
    var notScanned: Int = 0
    var note: String?
    var children: [DiskNode] = []

    enum CodingKeys: String, CodingKey {
        case name = "n", kind = "k", bytes = "b", files = "f", uncertainBytes = "u"
        case unreadable = "r", notScanned = "s", note = "t", children = "c"
    }

    var isFolderLike: Bool { kind == .folder }

    /// Largest first, names breaking ties, "Smaller items" always last.
    static func ordered(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
        if (lhs.kind == .smallerItems) != (rhs.kind == .smallerItems) { return rhs.kind == .smallerItems }
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.name < rhs.name
    }

    mutating func add(_ other: DiskNode, sign: Int64 = 1) {
        bytes += sign * other.bytes
        files += Int(sign) * other.files
        uncertainBytes += sign * other.uncertainBytes
        unreadable += Int(sign) * other.unreadable
        notScanned += Int(sign) * other.notScanned
    }

    /// Places `node` at `components` below this folder, replacing what was there and creating missing
    /// folders, and updates the totals of every folder on the way.
    func grafting(_ node: DiskNode, at components: [String]) -> DiskNode {
        guard let first = components.first else { return self }
        var copy = self
        let index = copy.children.firstIndex { $0.name == first && $0.kind != .smallerItems
            && (components.count == 1 || $0.kind == .folder) }
        let updated: DiskNode
        if components.count == 1 {
            var placed = node
            placed.name = first
            updated = placed
        } else {
            let existing = index.map { copy.children[$0] } ?? DiskNode(name: first, kind: .folder)
            updated = existing.grafting(node, at: Array(components.dropFirst()))
        }
        if let index {
            copy.add(copy.children[index], sign: -1)
            copy.children[index] = updated
        } else {
            copy.children.append(updated)
        }
        copy.add(updated)
        copy.children.sort(by: Self.ordered)
        return copy
    }
}

struct DiskTreeOptions: Codable, Sendable, Equatable {
    /// Files and folders smaller than this are added into one "Smaller items" row.
    var minimumListedBytes: Int64 = 1 << 20
    /// Rows listed per folder before the rest are folded.
    var maximumChildren = 200
    /// Folders deeper than this keep their totals but not their rows (0 = only the root total).
    var keepDepth = Int.max
    /// Absolute folder paths to skip, for example folders scanned separately.
    var excluded: [String] = []
    /// After this moment, folders not yet read are reported as not scanned.
    var deadline: Date?
    var threads = 8
}

struct DiskTreeResult: Codable, Sendable, Equatable {
    var root: DiskNode
    /// True when the time limit stopped part of the scan.
    var incomplete = false
    /// True when the location does not exist.
    var missing = false
    /// The first unreadable folders found (at most 50), sorted.
    var unreadablePaths: [String] = []
}

/// Reads a folder tree with several threads, keeping only rows large enough to matter.
enum DiskTreeScanner {
    static func scan(_ path: String, options: DiskTreeOptions = DiskTreeOptions()) -> DiskTreeResult {
        let name = (path as NSString).lastPathComponent
        guard let item = FileAttributes.read(path: path) else {
            if errno == EACCES || errno == EPERM {
                return DiskTreeResult(root: DiskNode(name: name, kind: .unreadable, unreadable: 1), unreadablePaths: [path])
            }
            return DiskTreeResult(root: DiskNode(name: name, kind: .notScanned, note: "Location missing or changed during scan."),
                                  missing: true)
        }
        switch item.kind {
        case .file:
            return DiskTreeResult(root: DiskNode(name: name, kind: .file, bytes: item.attributedBytes, files: 1,
                                                 uncertainBytes: item.uncertainBytes))
        case .symlink, .other:
            return DiskTreeResult(root: DiskNode(name: name, kind: .file))
        case .folder:
            return Engine(options: options, device: item.device).run(root: path, name: name)
        }
    }

    /// Folder being read. Its parent waits until every sub-folder has reported back.
    private final class Pending: @unchecked Sendable {
        let name: String
        let path: String
        let depth: Int
        let parent: Pending?
        var kind = DiskNode.Kind.folder
        var remaining = 0
        var subfolders: [DiskNode] = []
        var listedFiles: [DiskNode] = []
        var own = DiskNode(name: "", kind: .folder)
        var small = DiskNode(name: DiskNode.smallerItemsName, kind: .smallerItems)

        init(name: String, path: String, depth: Int, parent: Pending?) {
            self.name = name
            self.path = path
            self.depth = depth
            self.parent = parent
        }
    }

    private final class Engine: @unchecked Sendable {
        let options: DiskTreeOptions
        let device: Int32
        let excluded: Set<String>
        let condition = NSCondition()
        // Guarded by `condition`.
        var stack: [Pending] = []
        var finished: DiskNode?
        var unreadablePaths: [String] = []
        var incomplete = false

        init(options: DiskTreeOptions, device: Int32) {
            self.options = options
            self.device = device
            excluded = Set(options.excluded.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        }

        func run(root: String, name: String) -> DiskTreeResult {
            stack = [Pending(name: name, path: root, depth: 0, parent: nil)]
            for _ in 0..<max(1, options.threads) {
                let thread = Thread { [self] in work() }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            condition.lock()
            while finished == nil { condition.wait() }
            let result = DiskTreeResult(root: finished!, incomplete: incomplete, unreadablePaths: unreadablePaths.sorted())
            condition.unlock()
            return result
        }

        private func work() {
            while true {
                condition.lock()
                while stack.isEmpty && finished == nil { condition.wait() }
                if finished != nil { condition.unlock(); return }
                let folder = stack.removeLast()
                condition.unlock()
                process(folder)
            }
        }

        private func process(_ folder: Pending) {
            if let deadline = options.deadline, Date() >= deadline {
                folder.kind = .notScanned
                folder.own.notScanned = 1
                condition.lock(); incomplete = true; condition.unlock()
                complete(folder)
                return
            }
            let listing = BulkDirectoryReader.entries(of: folder.path)
            if listing.error != nil {
                if listing.entries.isEmpty { folder.kind = .unreadable }
                folder.own.unreadable += 1
                condition.lock()
                if unreadablePaths.count < 50 { unreadablePaths.append(folder.path) }
                condition.unlock()
            }
            var children: [Pending] = []
            for entry in listing.entries {
                guard entry.error == 0 else { folder.own.unreadable += 1; continue }
                switch entry.kind {
                case .file:
                    let file = DiskNode(name: entry.name, kind: .file, bytes: entry.attributedBytes, files: 1,
                                        uncertainBytes: entry.uncertainBytes)
                    folder.own.add(file)
                    if file.bytes >= options.minimumListedBytes { folder.listedFiles.append(file) } else { folder.small.add(file) }
                case .folder:
                    guard entry.device == device, !entry.isMountPoint else { continue }
                    let path = folder.path == "/" ? "/" + entry.name : folder.path + "/" + entry.name
                    guard !excluded.contains(path) else { continue }
                    children.append(Pending(name: entry.name, path: path, depth: folder.depth + 1, parent: folder))
                case .symlink, .other:
                    continue
                }
            }
            guard !children.isEmpty else { complete(folder); return }
            condition.lock()
            folder.remaining = children.count
            stack.append(contentsOf: children)
            condition.broadcast()
            condition.unlock()
        }

        /// Builds the finished folder's row and reports it upward; the last sub-folder finishes its parent.
        private func complete(_ folder: Pending) {
            var current = folder
            while true {
                let node = build(current)
                guard let parent = current.parent else {
                    condition.lock()
                    finished = node
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                condition.lock()
                parent.subfolders.append(node)
                parent.remaining -= 1
                let parentDone = parent.remaining == 0
                condition.unlock()
                guard parentDone else { return }
                current = parent
            }
        }

        private func build(_ folder: Pending) -> DiskNode {
            var node = DiskNode(name: folder.name, kind: folder.kind)
            node.add(folder.own)
            for subfolder in folder.subfolders { node.add(subfolder) }
            guard folder.depth < options.keepDepth else { return node }

            var small = folder.small
            var kept: [DiskNode] = []
            for entry in (folder.subfolders + folder.listedFiles).sorted(by: DiskNode.ordered) {
                // Folders leading to unread content stay listed so the locked folder can be reached.
                let important = entry.bytes >= options.minimumListedBytes || entry.unreadable > 0 || entry.notScanned > 0
                if important && kept.count < options.maximumChildren {
                    kept.append(entry)
                } else {
                    small.add(entry)
                }
            }
            if small.bytes > 0 || small.files > 0 { kept.append(small) }
            node.children = kept
            return node
        }
    }
}
