import CryptoKit
import Foundation

enum FileFingerprint {
    struct DeadlineReached: Error {}

    static func checkDeadline(_ deadline: Date?) throws {
        if let deadline, Date() >= deadline { throw DeadlineReached() }
    }

    /// A cheap rejection filter only. Matching samples still require a complete SHA-256 pass.
    static func sample(_ url: URL, length: Int64, deadline: Date? = nil) throws -> String {
        try checkDeadline(deadline)
        guard TrashValidation.isUnredirected(url) else { throw CocoaError(.fileReadInvalidFileName) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk: Int64 = 64 * 1024
        let offsets = Set([Int64(0), max(0, (length - chunk) / 2), max(0, length - chunk)]).sorted()
        var hash = SHA256()
        for offset in offsets {
            try checkDeadline(deadline)
            // FileHandle returns autoreleased buffers; without a pool, a worker hashing thousands of files
            // keeps every byte it read until it exits (measured: +4.6 GB footprint for 4.7 GB read).
            try autoreleasepool {
                try handle.seek(toOffset: UInt64(offset))
                hash.update(data: try handle.read(upToCount: Int(min(chunk, length - offset))) ?? Data())
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ url: URL, deadline: Date? = nil) throws -> String {
        try checkDeadline(deadline)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              TrashValidation.isUnredirected(url) else {
            throw NSError(domain: "MacPolishValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file is no longer a regular file at the scanned path."])
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try checkDeadline(deadline)
            let finished: Bool = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if finished { break }
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
            throw NSError(domain: "MacPolishValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The file changed while being verified. Scan again."])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DuplicateCleaner: Sendable {
    /// Identity of a verified file: any write changes the modification date, size or file number.
    private static func identity(_ url: URL) throws -> [AnyHashable] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let parts: [AnyHashable?] = [attributes[.modificationDate] as? Date, attributes[.size] as? NSNumber,
                                     attributes[.systemFileNumber] as? NSNumber]
        return parts.map { $0 ?? AnyHashable("unknown") }
    }

    /// `deadline` bounds the whole cleanup: hashing a stalled cloud or network file must not leave the page busy forever.
    func clean(_ files: [DuplicateFile], deadline: Date? = Date().addingTimeInterval(600),
               trashItem: @Sendable (URL) throws -> Void = { url in
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) -> CleanupResult {
        var removed: Set<UUID> = []
        var bytes: Int64 = 0
        var issues: [CleanupIssue] = []
        let groups = Dictionary(grouping: files, by: \.fingerprint)
        for key in groups.keys.sorted() {
            let group = groups[key]!.sorted { $0.url.path < $1.url.path }
            var selected = group.filter(\.isSelected)
            guard group.count > 1, !selected.isEmpty else { continue }
            var retained = group.filter { !$0.isSelected }
            if retained.isEmpty {
                retained = [group[0]]
                selected.removeAll { $0.id == group[0].id }
            }
            var keeper: DuplicateFile?
            var keeperIdentity: [AnyHashable] = []
            var keeperIssue: CleanupIssue?
            for file in retained {
                do {
                    let identity = try Self.identity(file.url)
                    guard try FileFingerprint.sha256(file.url, deadline: deadline) == key, try Self.identity(file.url) == identity else {
                        keeperIssue = CleanupIssue(url: file.url, kind: .changed, detail: "The retained copy changed. This group was skipped; scan again.")
                        continue
                    }
                    keeper = file
                    keeperIdentity = identity
                    break
                } catch is FileFingerprint.DeadlineReached {
                    keeperIssue = CleanupIssue(url: file.url, kind: .other, detail: "Verification reached its time limit. Nothing in this group was moved.")
                } catch { keeperIssue = TrashValidation.issue(for: error as NSError, url: file.url) }
            }
            guard let keeper else {
                if let keeperIssue { issues.append(keeperIssue) }
                continue
            }
            for file in selected {
                do {
                    // Hash the source first, then the retained copy; compare source identity again
                    // so edits made while verifying the keeper cannot slip into the cleanup plan.
                    let before = try FileManager.default.attributesOfItem(atPath: file.url.path)
                    guard try FileFingerprint.sha256(file.url, deadline: deadline) == key else {
                        issues.append(CleanupIssue(url: file.url, kind: .changed, detail: "The duplicate changed. This item was skipped; scan again."))
                        continue
                    }
                    // The keeper's content was hashed once for this group; a cheap identity check per file
                    // catches any later write without reading a large keeper again for every copy.
                    do {
                        guard try Self.identity(keeper.url) == keeperIdentity else {
                            issues.append(CleanupIssue(url: keeper.url, kind: .changed, detail: "The retained copy changed. This group was skipped; scan again."))
                            break
                        }
                    } catch {
                        issues.append(TrashValidation.issue(for: error as NSError, url: keeper.url))
                        break
                    }
                    let after = try FileManager.default.attributesOfItem(atPath: file.url.path)
                    guard before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                          before[.size] as? NSNumber == after[.size] as? NSNumber,
                          before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
                        issues.append(CleanupIssue(url: file.url, kind: .changed, detail: "The duplicate changed during validation. Scan again."))
                        continue
                    }
                    let item = ScanItem(id: file.id, url: file.url, size: file.estimatedDiskBytes, category: .largeFile,
                                        modifiedAt: before[.modificationDate] as? Date)
                    let result = SafeCleaner().clean([item], trashItem: trashItem)
                    removed.formUnion(result.removedItemIDs)
                    bytes += result.reclaimedBytes
                    issues += result.issues
                } catch is FileFingerprint.DeadlineReached {
                    issues.append(CleanupIssue(url: file.url, kind: .other, detail: "Verification reached its time limit. This item was not moved."))
                } catch { issues.append(TrashValidation.issue(for: error as NSError, url: file.url)) }
            }
        }
        return CleanupResult(removedCount: removed.count, reclaimedBytes: bytes, failures: issues.map(\.message), removedItemIDs: removed, issues: issues)
    }
}
