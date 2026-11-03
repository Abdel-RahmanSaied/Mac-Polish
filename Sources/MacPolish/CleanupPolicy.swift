import Foundation

/// One rule for what Mac Polish pre-selects in Cleanup pages and suggests in Optimize.
enum CleanupPolicy {
    /// Categories that hold regenerable caches and logs.
    static let suggestedCategories: Set<ScanCategory> = [.cache, .logs, .derivedData, .xcodeCache, .simulatorCache, .diagnostics]
    static let staleAge: TimeInterval = 7 * 86_400

    /// Folders inside cache locations that hold managed packages or working state
    /// (Go and Node dependencies, SwiftPM, Docker, Codex, Poetry virtual environments, Playwright browsers).
    static let protectedPathFragments = ["go-build", "gomodcache", "node_modules", "org.swift.swiftpm",
                                         "codex", "docker", "pypoetry", "ms-playwright"]

    static func isProtected(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return protectedPathFragments.contains { path.contains($0) }
    }

    /// Nothing inside the item changed for longer than `staleAge`. Unknown dates are never stale.
    static func isStale(newest: Date?, now: Date = Date()) -> Bool {
        guard let newest else { return false }
        return now.timeIntervalSince(newest) > staleAge
    }

    static func shouldPreselect(_ item: ScanItem, now: Date = Date()) -> Bool {
        item.isMeasurementComplete && suggestedCategories.contains(item.category) && !isProtected(item.url)
            && isStale(newest: item.newestContentModifiedAt, now: now)
    }
}
