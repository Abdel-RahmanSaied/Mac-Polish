import Foundation

/// What to collect about every entry while a tree is read. Optional in `DiskTreeOptions`, so callers that
/// only need folder totals pay nothing.
struct DiskInsightOptions: Codable, Sendable, Equatable {
    /// How many of the largest files to keep across the whole tree (0 keeps none).
    var largestFiles = 200
    /// Age buckets are measured from this moment; nil means when the scan starts.
    var referenceDate: Date?
}

/// Facts about every file the walk reached, independent of which rows the tree keeps for display:
/// a file folded into "Smaller items" is still counted here by kind, age and visibility.
struct DiskInsights: Codable, Sendable, Equatable {
    /// A coarse, explainable grouping by file extension and by the package or folder a file lives in.
    /// It is a reading aid for where space goes, not a judgement about what is safe to remove.
    enum Kind: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
        case video, audio, images, documents, archives, diskImages, applications, developer
        case virtualMachines, databases, caches, logs, other

        var displayName: String {
            switch self {
            case .video: "Video"
            case .audio: "Music & audio"
            case .images: "Photos & images"
            case .documents: "Documents"
            case .archives: "Archives"
            case .diskImages: "Disk images & installers"
            case .applications: "Apps & frameworks"
            case .developer: "Developer & code"
            case .virtualMachines: "Virtual machines"
            case .databases: "Databases"
            case .caches: "Caches"
            case .logs: "Logs"
            case .other: "Other"
            }
        }

        var icon: String {
            switch self {
            case .video: "film"
            case .audio: "music.note"
            case .images: "photo"
            case .documents: "doc.text"
            case .archives: "archivebox"
            case .diskImages: "opticaldiscdrive"
            case .applications: "app.badge"
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .virtualMachines: "server.rack"
            case .databases: "cylinder.split.1x2"
            case .caches: "shippingbox"
            case .logs: "doc.text.magnifyingglass"
            case .other: "questionmark.folder"
            }
        }
    }

    /// Last modification, relative to the reference date. Modification is not last use.
    enum Age: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
        case lastMonth, lastYear, oneToThreeYears, olderThanThreeYears, unknown

        var displayName: String {
            switch self {
            case .lastMonth: "Changed in the last 30 days"
            case .lastYear: "30 days to 1 year"
            case .oneToThreeYears: "1 to 3 years"
            case .olderThanThreeYears: "Older than 3 years"
            case .unknown: "Date unknown"
            }
        }
    }

    struct Total: Codable, Sendable, Equatable {
        var bytes: Int64 = 0
        var files = 0
        mutating func add(_ bytes: Int64, files: Int = 1) { self.bytes += bytes; self.files += files }
    }

    struct LargeFile: Codable, Sendable, Hashable {
        var path: String
        var bytes: Int64
        var modified: Date?
        var kind: Kind

        /// Largest first; the path breaks ties so results never depend on thread scheduling.
        static func ranks(_ lhs: Self, above rhs: Self) -> Bool {
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.path < rhs.path
        }
    }

    var largestFiles: [LargeFile] = []
    var kinds: [Kind: Total] = [:]
    var ages: [Age: Total] = [:]
    /// Folders that were opened and listed (unreadable and unscanned folders are counted in the tree).
    var folders = 0
    var hidden = Total()
    var emptyFiles = 0
    /// Symbolic links, sockets, pipes and devices: listed, never followed, never sized.
    var specialEntries = 0
    /// Deepest folder level reached below the scanned root.
    var deepestLevel = 0

    var files: Int { kinds.values.reduce(0) { $0 + $1.files } }
    var bytes: Int64 { kinds.values.reduce(0) { $0 + $1.bytes } }

    /// Adds another part of the same disk that was read separately (never an overlapping part).
    mutating func merge(_ other: DiskInsights, keepingLargest limit: Int) {
        largestFiles = Array((largestFiles + other.largestFiles).sorted(by: LargeFile.ranks).prefix(limit))
        for (kind, total) in other.kinds { kinds[kind, default: Total()].add(total.bytes, files: total.files) }
        for (age, total) in other.ages { ages[age, default: Total()].add(total.bytes, files: total.files) }
        folders += other.folders
        hidden.add(other.hidden.bytes, files: other.hidden.files)
        emptyFiles += other.emptyFiles
        specialEntries += other.specialEntries
        deepestLevel = max(deepestLevel, other.deepestLevel)
    }

    static func merged(_ parts: [DiskInsights?], keepingLargest limit: Int) -> DiskInsights? {
        let present = parts.compactMap { $0 }
        guard var first = present.first else { return nil }
        for part in present.dropFirst() { first.merge(part, keepingLargest: limit) }
        return first
    }

    // MARK: Classification

    /// A folder's own kind: packages and well-known folders give every file inside them one kind.
    static func folderKind(_ name: String) -> Kind? {
        if let named = folderNames[name] { return named }
        guard let ext = lowercasedExtension(name) else { return nil }
        return packageExtensions[ext]
    }

    static func fileKind(_ name: String) -> Kind {
        guard let ext = lowercasedExtension(name) else { return .other }
        return fileExtensions[ext] ?? .other
    }

    static func age(of modified: Date?, now: Date) -> Age {
        guard let modified else { return .unknown }
        let days = now.timeIntervalSince(modified) / 86_400
        switch days {
        case ..<30: return .lastMonth
        case ..<365: return .lastYear
        case ..<(3 * 365): return .oneToThreeYears
        default: return .olderThanThreeYears
        }
    }

    /// The text after the last dot, lowercased; nil for no extension, a leading-dot name or an implausibly long one.
    static func lowercasedExtension(_ name: String) -> String? {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return nil }
        let start = utf8.index(after: dot)
        let length = utf8.distance(from: start, to: utf8.endIndex)
        guard length > 0, length <= 16 else { return nil }
        return String(decoding: utf8[start...], as: UTF8.self).lowercased()
    }

    private static let folderNames: [String: Kind] = [
        "Caches": .caches, "Cache": .caches, ".cache": .caches, "Logs": .logs,
        "node_modules": .developer, ".git": .developer, "DerivedData": .developer, ".build": .developer,
        ".npm": .developer, ".cargo": .developer, ".gradle": .developer, ".m2": .developer, ".pub-cache": .developer,
        "CoreSimulator": .developer, "Docker.raw": .virtualMachines
    ]

    private static let packageExtensions: [String: Kind] = [
        "app": .applications, "framework": .applications, "bundle": .applications, "appex": .applications,
        "plugin": .applications, "kext": .applications, "xpc": .applications, "component": .applications,
        "photoslibrary": .images, "photolibrary": .images, "aplibrary": .images,
        "musiclibrary": .audio, "logicx": .audio, "band": .audio,
        "fcpbundle": .video, "imovielibrary": .video, "tvlibrary": .video, "theater": .video,
        "sparsebundle": .diskImages, "xcarchive": .developer, "xcodeproj": .developer, "xcworkspace": .developer,
        "utm": .virtualMachines, "vmwarevm": .virtualMachines, "pvm": .virtualMachines, "vbox": .virtualMachines,
        "logarchive": .logs
    ]

    private static let fileExtensions: [String: Kind] = {
        var table: [String: Kind] = [:]
        func add(_ kind: Kind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { table[String(ext)] = kind }
        }
        add(.video, "mov mp4 m4v mkv avi wmv flv webm mpg mpeg mts m2ts 3gp braw r3d mxf prores hevc")
        add(.audio, "mp3 m4a aac wav aiff aif flac alac ogg opus caf mid midi m4p m4b wma")
        add(.images, "jpg jpeg png heic heif gif tiff tif bmp webp raw cr2 cr3 nef arw dng orf rw2 psd psb ai svg ico icns avif jxl")
        add(.documents, "pdf doc docx pages key keynote numbers xls xlsx csv ppt pptx txt md rtf rtfd odt ods odp epub tex")
        add(.archives, "zip tar gz tgz bz2 xz zst 7z rar lz4 lzma cpio jar war ear aar whl gem nupkg")
        add(.diskImages, "dmg iso img sparseimage xip pkg mpkg ipsw cdr toast")
        add(.applications, "dylib so a o")
        add(.developer, "swift m mm h hpp c cc cpp cs java kt kts go rs py pyc rb php js mjs cjs ts tsx jsx vue svelte dart scala ex exs hs ml lua r pl sh zsh bash sql graphql proto json yaml yml toml xml plist lock map wasm class dex pch pcm swiftmodule swiftinterface ipa")
        add(.virtualMachines, "vmdk vdi qcow2 vhd vhdx hdd vmem vmsn qcow")
        add(.databases, "sqlite sqlite3 db db-wal db-shm sqlite-wal sqlite-shm realm sqlitedb ldb mdb accdb parquet")
        add(.logs, "log trace tracev3 crash ips diag spin hang")
        return table
    }()
}

/// One thread's share of the insights. Owned by a single thread, merged once when the thread exits.
final class DiskInsightCollector {
    private let limit: Int
    private let now: Date
    private(set) var insights = DiskInsights()
    /// Min-heap on `LargeFile.ranks`: the root is the smallest file kept.
    private var heap: [DiskInsights.LargeFile] = []

    init(limit: Int, now: Date) {
        self.limit = max(0, limit)
        self.now = now
        heap.reserveCapacity(self.limit)
    }

    func folder(depth: Int) {
        insights.folders += 1
        if depth > insights.deepestLevel { insights.deepestLevel = depth }
    }

    func special() { insights.specialEntries += 1 }

    func file(name: String, in folderPath: String, bytes: Int64, modified: Date?, inheritedKind: DiskInsights.Kind?) {
        let kind = inheritedKind ?? DiskInsights.fileKind(name)
        insights.kinds[kind, default: DiskInsights.Total()].add(bytes)
        insights.ages[DiskInsights.age(of: modified, now: now), default: DiskInsights.Total()].add(bytes)
        if bytes == 0 { insights.emptyFiles += 1 }
        if name.utf8.first == UInt8(ascii: ".") { insights.hidden.add(bytes) }
        guard limit > 0, bytes > 0 else { return }
        if heap.count == limit, let smallest = heap.first, bytes < smallest.bytes { return }
        let candidate = DiskInsights.LargeFile(path: folderPath == "/" ? "/" + name : folderPath + "/" + name,
                                               bytes: bytes, modified: modified, kind: kind)
        if heap.count < limit {
            heap.append(candidate)
            siftUp(heap.count - 1)
        } else if DiskInsights.LargeFile.ranks(candidate, above: heap[0]) {
            heap[0] = candidate
            siftDown(0)
        }
    }

    func finish() -> DiskInsights {
        var result = insights
        result.largestFiles = heap.sorted(by: DiskInsights.LargeFile.ranks)
        return result
    }

    /// True when `lhs` should sit above `rhs` in the min-heap, i.e. it ranks lower.
    private func lower(_ lhs: Int, _ rhs: Int) -> Bool { DiskInsights.LargeFile.ranks(heap[rhs], above: heap[lhs]) }

    private func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard lower(child, parent) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var lowest = parent
            if left < heap.count, lower(left, lowest) { lowest = left }
            if right < heap.count, lower(right, lowest) { lowest = right }
            guard lowest != parent else { return }
            heap.swapAt(parent, lowest)
            parent = lowest
        }
    }
}
