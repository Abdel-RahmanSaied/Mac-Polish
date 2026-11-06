import AppKit
import SwiftUI

/// One confirmed cleanup: what moved and what was left in place, and why.
///
/// Privacy: a record holds only paths, sizes, dates, the page that ran it and skip reasons. It never holds file
/// contents or hashes of contents. Paths are kept because they are what the user needs to put an item back.
struct CleanupRecord: Codable, Sendable, Identifiable, Equatable {
    struct Entry: Codable, Sendable, Hashable {
        let path: String
        let bytes: Int64?
        /// Why the item was skipped (`CleanupIssue.detail`); nil for moved items.
        let reason: String?

        init(path: String, bytes: Int64?, reason: String? = nil) {
            self.path = path
            self.bytes = bytes
            self.reason = reason
        }

        /// Docker build cache has no path of its own; record it with `permanent: true`.
        static func dockerBuildCache(bytes: Int64?) -> Entry {
            Entry(path: "Docker build cache (removed by Docker)", bytes: bytes)
        }
    }

    let id: UUID
    let date: Date
    let source: String
    let moved: [Entry]
    let skipped: [Entry]
    /// Removed without Trash (for example Docker build cache removed by Docker): cannot be recovered.
    var permanent = false

    init(id: UUID = UUID(), date: Date, source: String, moved: [Entry], skipped: [Entry], permanent: Bool = false) {
        self.id = id
        self.date = date
        self.source = source
        self.moved = moved
        self.skipped = skipped
        self.permanent = permanent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decode(String.self, forKey: .source)
        moved = try container.decode([Entry].self, forKey: .moved)
        skipped = try container.decode([Entry].self, forKey: .skipped)
        permanent = try container.decodeIfPresent(Bool.self, forKey: .permanent) ?? false
    }

    /// Total of the known sizes of moved items.
    var movedBytes: Int64 { moved.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

/// Local, append-only cleanup history in a JSON file that stays on this Mac.
///
/// The file is replaced atomically on every change, is readable only by the user (0600), and keeps the newest
/// `limit` records. A file that cannot be read is moved aside as `<name>.corrupt` and a new history starts.
/// Thread-safe; all access goes through one lock.
final class CleanupHistoryStore: @unchecked Sendable {
    static let recordLimit = 500

    /// ~/Library/Application Support/Mac Polish/cleanup-history.json
    /// Environment variable that moves the history file. `Scripts/test.sh` and `Scripts/perf.sh` set it, so checks that
    /// run real cleanup paths on fixtures never add records to the user's own history.
    static let locationOverride = "MACPOLISH_CLEANUP_HISTORY"

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment[locationOverride], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Mac Polish").appending(path: "cleanup-history.json")
    }

    let url: URL
    let limit: Int
    var corruptURL: URL { url.appendingPathExtension("corrupt") }

    private let lock = NSLock()
    /// Oldest first, in the order recorded.
    private var stored: [CleanupRecord] = []
    private var storedLoadNotice: String?
    private var storedSaveError: String?

    init(url: URL = CleanupHistoryStore.defaultURL, limit: Int = CleanupHistoryStore.recordLimit) {
        self.url = url
        self.limit = max(1, limit)
        load()
    }

    /// Newest first.
    var records: [CleanupRecord] { lock.withLock { stored.reversed() } }
    /// Set when the file on disk could not be read at launch.
    var loadNotice: String? { lock.withLock { storedLoadNotice } }
    /// Set when the last change could not be written; the record is still kept in memory.
    var saveError: String? { lock.withLock { storedSaveError } }

    /// Appends a record. Nothing is recorded when nothing moved and nothing was skipped.
    @discardableResult
    func record(source: String, moved: [CleanupRecord.Entry], skipped: [CleanupRecord.Entry],
                permanent: Bool = false, date: Date = Date()) -> CleanupRecord? {
        guard !moved.isEmpty || !skipped.isEmpty else { return nil }
        // Whole seconds, as written to disk, so a reloaded record equals the one returned here.
        let second = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let record = CleanupRecord(date: second, source: source, moved: moved, skipped: skipped, permanent: permanent)
        lock.withLock {
            stored.append(record)
            if stored.count > limit { stored.removeFirst(stored.count - limit) }
            save()
        }
        return record
    }

    /// Removes every record, and any history file set aside as corrupt. Never touches the cleaned items themselves.
    func clear() {
        lock.withLock {
            stored = []
            storedLoadNotice = nil
            try? FileManager.default.removeItem(at: corruptURL)
            save()
        }
    }

    // MARK: Moved and skipped entries

    /// Moved: the candidates whose id is in `removedItemIDs`. Skipped: every issue (path and `detail`), plus any
    /// candidate that neither moved nor reported an issue. Pass the confirmed items as `candidates`.
    static func entries(from result: CleanupResult, candidates: [(id: UUID, url: URL, bytes: Int64)])
        -> (moved: [CleanupRecord.Entry], skipped: [CleanupRecord.Entry]) {
        entries(removedIDs: result.removedItemIDs, issues: result.issues, candidates: candidates)
    }

    static func entries(from result: ApplicationRemovalResult, candidates: [(id: UUID, url: URL, bytes: Int64)])
        -> (moved: [CleanupRecord.Entry], skipped: [CleanupRecord.Entry]) {
        entries(removedIDs: result.removedIDs, issues: result.issues, candidates: candidates)
    }

    static func entries(removedIDs: Set<UUID>, issues: [CleanupIssue], candidates: [(id: UUID, url: URL, bytes: Int64)])
        -> (moved: [CleanupRecord.Entry], skipped: [CleanupRecord.Entry]) {
        let moved = candidates.filter { removedIDs.contains($0.id) }
            .map { CleanupRecord.Entry(path: $0.url.path, bytes: $0.bytes) }
        var bytesByPath: [String: Int64] = [:]
        for candidate in candidates where !removedIDs.contains(candidate.id) {
            bytesByPath[candidate.url.standardizedFileURL.path] = candidate.bytes
        }
        var reported = Set<String>()
        var skipped = issues.map { issue in
            let path = issue.url.standardizedFileURL.path
            reported.insert(path)
            return CleanupRecord.Entry(path: issue.url.path, bytes: bytesByPath[path], reason: issue.detail)
        }
        for candidate in candidates
        where !removedIDs.contains(candidate.id) && !reported.contains(candidate.url.standardizedFileURL.path) {
            skipped.append(CleanupRecord.Entry(path: candidate.url.path, bytes: candidate.bytes,
                                               reason: "Not moved; no reason was reported."))
        }
        return (moved, skipped)
    }

    // MARK: File

    private struct HistoryFile: Codable {
        var version = 1
        var records: [CleanupRecord]
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Called from `init` only, before the store is shared.
    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            setAside()
            return
        }
        guard !data.isEmpty else { return }
        do {
            let file = try Self.makeDecoder().decode(HistoryFile.self, from: data)
            stored = Array(file.records.suffix(limit))
        } catch {
            setAside()
        }
    }

    private func setAside() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        do {
            try fileManager.moveItem(at: url, to: corruptURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)
            storedLoadNotice = "The previous cleanup history could not be read. It was kept as "
                + corruptURL.lastPathComponent + " and a new history was started."
        } catch {
            storedLoadNotice = "The cleanup history could not be read, so a new history was started. "
                + error.localizedDescription
        }
    }

    /// Caller holds `lock`.
    private func save() {
        do {
            try write(Self.makeEncoder().encode(HistoryFile(records: stored)))
            storedSaveError = nil
        } catch {
            storedSaveError = "Cleanup history could not be saved: " + error.localizedDescription
        }
    }

    /// Writes a new 0600 file next to the history and renames it over the old one, so readers see either the old
    /// or the new history, never a partial file.
    private func write(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        let temporary = directory.appending(path: "." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        do {
            // The umask can only remove bits; set the exact mode in case it removed the owner's.
            guard fchmod(descriptor, 0o600) == 0 else { throw Self.posixError() }
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw Self.posixError() }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw Self.posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
        renamed = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// The history for SwiftUI. Record from the main actor after each cleanup finishes.
@MainActor
final class CleanupHistoryModel: ObservableObject {
    @Published private(set) var records: [CleanupRecord]
    /// A load or save problem to show the user; nil when the history is healthy.
    @Published private(set) var notice: String?
    let store: CleanupHistoryStore

    init(store: CleanupHistoryStore = CleanupHistoryStore()) {
        self.store = store
        records = store.records
        notice = store.saveError ?? store.loadNotice
    }

    func record(source: String, moved: [CleanupRecord.Entry], skipped: [CleanupRecord.Entry], permanent: Bool = false) {
        store.record(source: source, moved: moved, skipped: skipped, permanent: permanent)
        refresh()
    }

    /// Records a finished cleanup. `candidates` are the items the user confirmed.
    func record(source: String, result: CleanupResult, candidates: [(id: UUID, url: URL, bytes: Int64)]) {
        let entries = CleanupHistoryStore.entries(from: result, candidates: candidates)
        record(source: source, moved: entries.moved, skipped: entries.skipped)
    }

    func record(source: String, result: ApplicationRemovalResult, candidates: [(id: UUID, url: URL, bytes: Int64)]) {
        let entries = CleanupHistoryStore.entries(from: result, candidates: candidates)
        record(source: source, moved: entries.moved, skipped: entries.skipped)
    }

    /// Forgets the history. No file other than the history itself is touched.
    func clear() {
        store.clear()
        refresh()
    }

    private func refresh() {
        records = store.records
        notice = store.saveError ?? store.loadNotice
    }
}

/// Past cleanups, newest first, with what moved, what was skipped, and how to put items back.
/// Mac Polish never restores items itself: recovery is Finder's Put Back, or dragging the item back.
struct CleanupHistoryView: View {
    @ObservedObject var model: CleanupHistoryModel
    @ViewState private var expanded: Set<UUID> = []
    @ViewState private var confirmsClear = false

    static let recoveryText = "To recover an item, open Trash, select it and choose File → Put Back. If Put Back is not available, drag it to the original location listed here. Items removed permanently (marked) cannot be recovered."

    static var trashURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".Trash") }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 8) {
                Label(Self.recoveryText, systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30).padding(.bottom, 12)

            if model.records.isEmpty {
                ContentUnavailableView("No cleanups recorded", systemImage: "clock.arrow.circlepath",
                                       description: Text("Each cleanup you confirm is listed here with what moved to Trash and what was skipped."))
            } else {
                List {
                    ForEach(model.records) { record in
                        DisclosureGroup(isExpanded: expansion(for: record.id)) {
                            details(record)
                        } label: {
                            summary(record)
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack(alignment: .top) {
                Text("This history stays on this Mac (\(CleanupConfirmation.displayPath(model.store.url)), readable only by your account). It lists paths, sizes, dates and reasons — never file contents — and keeps the newest \(model.store.limit) cleanups.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear History…", role: .destructive) { confirmsClear = true }
                    .disabled(model.records.isEmpty)
            }
            .padding(20)
            .background(.bar)
        }
        .alert("Clear cleanup history?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                expanded = []
                model.clear()
            }
        } message: {
            Text("This forgets the list of past cleanups. It does not touch any files: items stay in Trash until you empty it, and you can still put them back from Trash.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cleanup History")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("What each cleanup moved to Trash or left in place.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Trash") { NSWorkspace.shared.open(Self.trashURL) }
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            })
    }

    private func summary(_ record: CleanupRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.permanent ? "exclamationmark.octagon" : "trash")
                .foregroundStyle(record.permanent ? .red : .blue)
                .frame(width: 30, height: 30)
                .background((record.permanent ? Color.red : Color.blue).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.source).font(.headline)
                    if record.permanent {
                        Text("Removed permanently").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                }
                Text(record.date, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(record.permanent ? "Removed" : "Moved") \(CleanupConfirmation.countText(record.moved.count)) · \(record.movedBytes.formattedBytes)")
                    .monospacedDigit()
                if !record.skipped.isEmpty {
                    Text("\(record.skipped.count) skipped").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func details(_ record: CleanupRecord) -> some View {
        if !record.moved.isEmpty {
            Text(record.permanent ? "Removed permanently (cannot be recovered)" : "Moved to Trash")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(record.moved.enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
            }
        }
        if !record.skipped.isEmpty {
            Text("Skipped (left in place)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(record.skipped.enumerated()), id: \.offset) { _, entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: CleanupRecord.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path).font(.caption).textSelection(.enabled).lineLimit(3)
                if let reason = entry.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(entry.bytes?.formattedBytes ?? "Size unknown")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
