import Foundation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case optimize = "Optimize"
    case memory = "Memory"
    case cleanup = "Cleanup"
    case largeFiles = "Large Files"
    case duplicates = "Duplicates"
    case storage = "Storage Map"
    case systemData = "System Data"
    case developer = "Developer Cleanup"
    case oldFiles = "Old Files"
    case applications = "Applications"
    case startup = "Startup Items"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "sparkles"
        case .optimize: "wand.and.stars.inverse"
        case .memory: "memorychip"
        case .cleanup: "wand.and.stars"
        case .largeFiles: "externaldrive"
        case .duplicates: "doc.on.doc"
        case .storage: "chart.pie"
        case .systemData: "internaldrive"
        case .developer: "hammer"
        case .oldFiles: "clock.arrow.circlepath"
        case .applications: "square.grid.2x2"
        case .startup: "bolt.circle"
        }
    }
}

enum ScanCategory: String, CaseIterable, Hashable, Sendable, Codable {
    case cache = "Application Caches"
    case logs = "Old Logs"
    case trash = "Trash"
    case largeFile = "Large Files"
    case derivedData = "Xcode Derived Data"
    case xcodeCache = "Xcode Caches"
    case xcodeArchive = "Xcode Archives"
    case deviceSupport = "Old Device Support"
    case simulatorCache = "Simulator Caches"
    case oldXcode = "Old Xcode Copies"
    case xcodeDownload = "Xcode Installers"
    case diagnostics = "Diagnostic Reports"
    case deviceBackup = "Device Backups"
    case oldInstaller = "macOS Installers"

    var icon: String {
        switch self {
        case .cache: "shippingbox"
        case .logs: "doc.text.magnifyingglass"
        case .trash: "trash"
        case .largeFile: "doc.badge.ellipsis"
        case .derivedData: "hammer"
        case .xcodeCache: "shippingbox"
        case .xcodeArchive: "archivebox"
        case .deviceSupport: "iphone"
        case .simulatorCache: "desktopcomputer"
        case .oldXcode: "hammer.circle"
        case .xcodeDownload: "arrow.down.app"
        case .diagnostics: "waveform.path.ecg"
        case .deviceBackup: "externaldrive.badge.timemachine"
        case .oldInstaller: "macwindow.badge.plus"
        }
    }

    var tintName: String {
        switch self {
        case .cache: "blue"
        case .logs: "orange"
        case .trash: "pink"
        case .largeFile: "purple"
        case .derivedData, .xcodeCache, .simulatorCache: "blue"
        case .xcodeArchive, .deviceSupport, .oldXcode, .xcodeDownload: "indigo"
        case .diagnostics: "orange"
        case .deviceBackup, .oldInstaller: "pink"
        }
    }
}

struct ScanItem: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let url: URL
    let size: Int64
    let category: ScanCategory
    let modifiedAt: Date?
    /// Newest modification date of the item or anything inside it. A folder's own date only
    /// changes when direct entries are added or removed, so it cannot show recent use alone.
    let newestContentModifiedAt: Date?
    /// False when any part of the item could not be measured.
    let isMeasurementComplete: Bool
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        size: Int64,
        category: ScanCategory,
        modifiedAt: Date?,
        newestContentModifiedAt: Date? = nil,
        isMeasurementComplete: Bool = true,
        isSelected: Bool = true
    ) {
        self.id = id
        self.url = url
        self.size = size
        self.category = category
        self.modifiedAt = modifiedAt
        self.isMeasurementComplete = isMeasurementComplete
        self.newestContentModifiedAt = newestContentModifiedAt
        self.isSelected = isSelected
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

enum ScanState: Equatable {
    case idle
    case scanning
    case finished
    case cleaning
    case failed(String)
}

enum ModuleState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

struct ApplicationItem: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let name: String
    let url: URL
    let bundleIdentifier: String?
    let version: String?
    let size: Int64
    let leftoverURLs: [URL]
    let leftoverSize: Int64
    let canRemove: Bool
    var isSelected: Bool
    /// Why this app cannot be moved to Trash by Mac Polish (for example, another account owns it).
    var removalNote: String? = nil

    var totalSize: Int64 { size + leftoverSize }
}

struct DuplicateFile: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let url: URL
    let size: Int64
    let fingerprint: String
    var isSelected: Bool
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let files: [DuplicateFile]

    var fileSize: Int64 { files.first?.size ?? 0 }
    var reclaimableSize: Int64 { fileSize * Int64(max(0, files.count - 1)) }
}

struct StartupEntry: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let label: String
    let url: URL
    let program: String?
    let runsAtLoad: Bool
    let requiresAdministrator: Bool
}

struct CleanupIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// macOS privacy protection refused (EPERM): Full Disk Access or Files & Folders.
        case permission
        /// Another account owns the item (EACCES): an administrator must move it, for example in Finder.
        case ownership
        /// macOS App Management refused changing another app's bundle.
        case appManagement
        case managedCache, locked, readOnly, missing, unsafe, changed, alreadyInTrash, other
    }
    var id: String { url.path + ":" + kind.rawValue }
    let url: URL
    let kind: Kind
    let detail: String
    /// A macOS privacy setting can fix this; ownership and read-only problems cannot.
    var needsAccess: Bool { kind == .permission || kind == .appManagement }
    var message: String { url.lastPathComponent + ": " + detail }

    static func summary(_ issues: [Self]) -> String {
        let denied = issues.filter { $0.kind == .permission }.count
        let appManagement = issues.filter { $0.kind == .appManagement }.count
        let ownership = issues.filter { $0.kind == .ownership }.count
        let managed = issues.filter { $0.kind == .managedCache }.count
        let restricted = issues.filter { $0.kind == .locked || $0.kind == .readOnly }.count
        var messages: [String] = []
        if denied > 0 {
            messages.append("\(denied) item(s) could not be moved because macOS denied access. Review Full Disk Access for Mac Polish, then retry the selected items.")
        }
        if appManagement > 0 {
            messages.append("\(appManagement) app(s) could not be removed because macOS App Management blocked it. Allow Mac Polish in Privacy & Security → App Management, then retry.")
        }
        if ownership > 0 {
            messages.append("\(ownership) item(s) belong to another account, often an installer. An administrator must remove them: use Show in Finder, then Move to Trash, and enter an administrator password.")
        }
        if managed > 0 {
            messages.append("Skipped \(managed) managed dependency item(s). Use the owning package manager to manage these files; Full Disk Access does not change their filesystem permissions.")
        }
        if restricted > 0 { messages.append("\(restricted) item(s) are locked or in read-only locations. Review them in Finder.") }
        let other = issues.filter { ![.permission, .appManagement, .ownership, .managedCache, .locked, .readOnly].contains($0.kind) }
        messages += other.prefix(2).map(\.message)
        return messages.joined(separator: "\n\n")
    }
}

struct ApplicationRemovalResult: Sendable {
    let removedIDs: Set<UUID>
    let reclaimedBytes: Int64
    let failures: [String]
    var issues: [CleanupIssue] = []
}

struct CleanupResult: Sendable {
    let removedCount: Int
    let reclaimedBytes: Int64
    let failures: [String]
    let removedItemIDs: Set<UUID>
    var issues: [CleanupIssue] = []
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
