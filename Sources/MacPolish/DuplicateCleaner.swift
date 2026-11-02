import CryptoKit
import Foundation

enum FileFingerprint {
    static func sha256(_ url: URL) throws -> String {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              TrashValidation.isUnredirected(url) else {
            throw NSError(domain: "MacPolishValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file is no longer a regular file at the scanned path."])
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hasher.update(data: data) }
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
    func clean(_ files: [DuplicateFile], trashItem: @Sendable (URL) throws -> Void = { url in
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
            var keeperIssue: CleanupIssue?
            for file in retained {
                do {
                    guard try FileFingerprint.sha256(file.url) == key else {
                        keeperIssue = CleanupIssue(url: file.url, kind: .changed, detail: "The retained copy changed. This group was skipped; scan again.")
                        continue
                    }
                    keeper = file
                    break
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
                    guard try FileFingerprint.sha256(file.url) == key else {
                        issues.append(CleanupIssue(url: file.url, kind: .changed, detail: "The duplicate changed. This item was skipped; scan again."))
                        continue
                    }
                    do {
                        guard try FileFingerprint.sha256(keeper.url) == key else {
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
                    let item = ScanItem(id: file.id, url: file.url, size: file.size, category: .largeFile,
                                        modifiedAt: before[.modificationDate] as? Date)
                    let result = SafeCleaner().clean([item], trashItem: trashItem)
                    removed.formUnion(result.removedItemIDs)
                    bytes += result.reclaimedBytes
                    issues += result.issues
                } catch { issues.append(TrashValidation.issue(for: error as NSError, url: file.url)) }
            }
        }
        return CleanupResult(removedCount: removed.count, reclaimedBytes: bytes, failures: issues.map(\.message), removedItemIDs: removed, issues: issues)
    }
}
