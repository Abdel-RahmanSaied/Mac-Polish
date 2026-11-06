import Foundation
import Darwin

/// One past health check, kept so later checks can show trends, repeated warnings and a storage estimate.
///
/// Privacy: a snapshot holds only dates, the check mode, the score, a state per category and a few numbers
/// (free and total storage, swap, pressure level, thermal level, battery capacity and cycles). It never holds file
/// contents, paths, process or app lists, disk or volume names, or anything typed by the user.
struct HealthSnapshot: Codable, Sendable, Equatable {
    var date: Date
    var mode: HealthMode
    var score: Int
    var partial: Bool
    var states: [HealthCategory: HealthState]
    var storageFree: Int64?
    var storageTotal: Int64?
    var swapUsed: UInt64?
    /// 1 normal, 2 warning, 4 critical, as `MemorySample.pressure`.
    var pressureLevel: Int?
    /// 0 nominal, 1 fair, 2 serious, 3 critical (`ProcessInfo.ThermalState`).
    var thermalState: Int?
    var batteryMaxCapacity: Int?
    var batteryCycles: Int?

    init(date: Date, mode: HealthMode = .quick, score: Int = 100, partial: Bool = false,
         states: [HealthCategory: HealthState] = [:], storageFree: Int64? = nil, storageTotal: Int64? = nil,
         swapUsed: UInt64? = nil, pressureLevel: Int? = nil, thermalState: Int? = nil,
         batteryMaxCapacity: Int? = nil, batteryCycles: Int? = nil) {
        // Whole seconds, as written to disk, so a reloaded snapshot equals the one saved.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.mode = mode
        self.score = score
        self.partial = partial
        self.states = states
        self.storageFree = storageFree
        self.storageTotal = storageTotal
        self.swapUsed = swapUsed
        self.pressureLevel = pressureLevel
        self.thermalState = thermalState
        self.batteryMaxCapacity = batteryMaxCapacity
        self.batteryCycles = batteryCycles
    }

    init(_ result: HealthCheckResult) {
        let metrics = result.metrics
        self.init(date: result.finishedAt ?? result.startedAt, mode: result.mode, score: result.score,
                  partial: result.isPartial,
                  states: Dictionary(uniqueKeysWithValues: result.categories.map { ($0.category, $0.state) }),
                  storageFree: metrics.storageFree, storageTotal: metrics.storageTotal, swapUsed: metrics.swapUsed,
                  pressureLevel: metrics.pressureLevel, thermalState: metrics.thermalState,
                  batteryMaxCapacity: metrics.batteryMaxCapacity, batteryCycles: metrics.batteryCycles)
    }

    /// A category counts for trends only when it was actually measured (not Unknown, not cancelled).
    func isMeaningful(for category: HealthCategory) -> Bool {
        guard let state = states[category] else { return false }
        return state != .unknown
    }
}

/// Pure helpers that compare the current reading of one category with earlier snapshots. No I/O.
enum HealthHistory {
    /// Two checks closer together than this are not compared for a trend: they would mostly show noise.
    static let trendGap: TimeInterval = 30 * 60
    static let gigabyte: Int64 = 1_000_000_000
    /// Storage free-space change that counts as a trend: more than 5 GB, or more than 5% of capacity.
    static let storageTrendBytes: Int64 = 5 * gigabyte
    static let storageTrendFraction = 0.05
    /// Battery maximum capacity drop, in percentage points, that counts as getting worse.
    static let batteryTrendPoints = 2
    /// Swap change that counts as a trend.
    static let swapTrendBytes: Int64 = 1 << 30

    /// Oldest first, without snapshots at or after `date` (the current check itself).
    static func earlier(_ history: [HealthSnapshot], than date: Date) -> [HealthSnapshot] {
        history.filter { $0.date < date }.sorted { $0.date < $1.date }
    }

    /// The most recent earlier snapshot in which `category` was measured, at least `gap` before `date`.
    static func previousMeaningful(_ category: HealthCategory, before date: Date, in history: [HealthSnapshot],
                                   gap: TimeInterval = 0) -> HealthSnapshot? {
        earlier(history, than: date).last { $0.isMeaningful(for: category) && date.timeIntervalSince($0.date) >= gap }
    }

    /// Compares the current result with the most recent meaningful snapshot at least 30 minutes older.
    /// A state change decides the direction; with the same state, a clear change in the category's main
    /// number does (storage free space, battery capacity, swap); otherwise stable. Without an earlier
    /// meaningful snapshot (fewer than two checks) there is not enough data.
    static func trend(for result: HealthCategoryResult, history: [HealthSnapshot]) -> HealthTrend {
        guard result.state != .unknown,
              let previous = previousMeaningful(result.category, before: result.observedAt, in: history, gap: trendGap),
              let previousState = previous.states[result.category] else { return .notEnoughData }
        if previousState.severityRank != result.state.severityRank {
            return result.state.severityRank > previousState.severityRank ? .gettingWorse : .improving
        }
        let metrics = result.metrics
        switch result.category {
        case .storage:
            guard let free = metrics.storageFree, let old = previous.storageFree else { return .stable }
            let delta = free - old
            let total = metrics.storageTotal ?? previous.storageTotal ?? 0
            let fractionThreshold = Int64(Double(total) * storageTrendFraction)
            guard abs(delta) > storageTrendBytes || (total > 0 && abs(delta) > fractionThreshold) else { return .stable }
            return delta < 0 ? .gettingWorse : .improving
        case .battery:
            guard let capacity = metrics.batteryMaxCapacity, let old = previous.batteryMaxCapacity else { return .stable }
            // Capacity readings recalibrate upward now and then; only a drop is a trend.
            return old - capacity >= batteryTrendPoints ? .gettingWorse : .stable
        case .memory:
            guard let swap = metrics.swapUsed, let old = previous.swapUsed else { return .stable }
            let delta = Int64(clamping: swap) - Int64(clamping: old)
            if delta >= swapTrendBytes { return .gettingWorse }
            if delta <= -swapTrendBytes { return .improving }
            return .stable
        case .temperature, .diskHealth, .security, .updates:
            return .stable
        }
    }

    /// When the current state is Attention or Critical and the most recent earlier meaningful snapshots were too,
    /// the date of the oldest snapshot in that unbroken run. nil when the state is new at this check.
    static func repeatedSince(_ category: HealthCategory, state: HealthState, now: Date, history: [HealthSnapshot]) -> Date? {
        guard state == .attention || state == .critical else { return nil }
        var first: Date?
        for snapshot in earlier(history, than: now).reversed() {
            guard let previous = snapshot.states[category], previous != .unknown else { continue }
            guard previous == .attention || previous == .critical else { break }
            first = snapshot.date
        }
        return first
    }

    /// One plain sentence comparing the current result with the most recent earlier meaningful check.
    static func comparison(for result: HealthCategoryResult, history: [HealthSnapshot]) -> String? {
        guard result.state != .unknown,
              let previous = previousMeaningful(result.category, before: result.observedAt, in: history),
              let previousState = previous.states[result.category] else { return nil }
        let when = previous.date.formatted(date: .abbreviated, time: .shortened)
        var text = previousState == result.state
            ? "Same as the previous check (\(when)): \(previousState.label)."
            : "At the previous check (\(when)) this was \(previousState.label); now it is \(result.state.label)."
        let metrics = result.metrics
        switch result.category {
        case .storage:
            if let old = previous.storageFree, let free = metrics.storageFree {
                text += " Free space was \(old.formattedBytes); now \(free.formattedBytes)."
            }
        case .battery:
            if let old = previous.batteryMaxCapacity, let capacity = metrics.batteryMaxCapacity {
                text += " Maximum capacity was \(old)%; now \(capacity)%."
            }
        case .memory:
            if let old = previous.swapUsed, let swap = metrics.swapUsed {
                text += " Swap used was \(HealthFormat.memory(old)); now \(HealthFormat.memory(swap))."
            }
        case .temperature:
            if let old = previous.thermalState {
                text += " The thermal state was \(HealthFormat.thermalName(old))."
            }
        case .diskHealth, .security, .updates:
            break
        }
        return text
    }

    /// Minimum readings, span and fit before a storage estimate is shown.
    static let forecastMinimumSnapshots = 4
    static let forecastMinimumSpan: TimeInterval = 3 * 86_400
    static let forecastWindow: TimeInterval = 30 * 86_400
    static let forecastMinimumFit = 0.7
    static let forecastThresholdFraction = 0.10

    /// An estimate of when free space may fall below 10% of capacity, from a least-squares line through free space
    /// over the last 30 days. Shown only with at least 4 readings (including this one) spanning 3 days, a falling
    /// line that fits well (R² ≥ 0.7), and a projected time between 1 and 90 days. nil otherwise, and when free
    /// space is already below 10%.
    static func storageForecast(free: Int64, total: Int64, now: Date, history: [HealthSnapshot]) -> String? {
        guard total > 0 else { return nil }
        let threshold = Double(total) * forecastThresholdFraction
        guard Double(free) > threshold else { return nil }
        var points: [(x: Double, y: Double)] = earlier(history, than: now)
            .filter { now.timeIntervalSince($0.date) <= forecastWindow }
            .compactMap { snapshot in snapshot.storageFree.map { (x: snapshot.date.timeIntervalSince(now) / 86_400, y: Double($0)) } }
        points.append((x: 0, y: Double(free)))
        guard points.count >= forecastMinimumSnapshots,
              let first = points.map(\.x).min(), (0 - first) * 86_400 >= forecastMinimumSpan,
              let fit = leastSquares(points), fit.slope < 0, fit.r2 >= forecastMinimumFit else { return nil }
        let days = (Double(free) - threshold) / -fit.slope
        guard days >= 1, days <= 90 else { return nil }
        let amount: String
        if days < 14 {
            let whole = Int(days.rounded())
            amount = whole == 1 ? "1 day" : "\(whole) days"
        } else {
            let weeks = Int((days / 7).rounded())
            amount = weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        return "Estimate: at the recent rate of change, free space may fall below 10% in about \(amount)."
    }

    /// Slope (y per x) and coefficient of determination. nil when x or y does not vary.
    static func leastSquares(_ points: [(x: Double, y: Double)]) -> (slope: Double, r2: Double)? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for point in points {
            let dx = point.x - meanX, dy = point.y - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        let slope = sxy / sxx
        return (slope, (sxy * sxy) / (sxx * syy))
    }

    /// Adds trend, repeated-warning dates, the comparison and (for storage) the forecast to a fresh result.
    static func annotate(_ result: HealthCategoryResult, history: [HealthSnapshot]) -> HealthCategoryResult {
        var result = result
        guard result.cancelledReason == nil, result.failedReason == nil else { return result }
        result.trend = trend(for: result, history: history)
        result.comparison = comparison(for: result, history: history)
        if let since = repeatedSince(result.category, state: result.state, now: result.observedAt, history: history) {
            result.firstObserved = min(since, result.firstObserved ?? since)
            result.lastObserved = result.observedAt
            result.repeated = true
        }
        if result.category == .storage, let free = result.metrics.storageFree, let total = result.metrics.storageTotal {
            result.forecast = storageForecast(free: free, total: total, now: result.observedAt, history: history)
        }
        return result
    }
}

/// Local health history in a small JSON file that stays on this Mac.
///
/// Every read and write runs on one private serial queue, never on the main thread. The file is replaced
/// atomically, is readable only by the user (0600), and keeps the newest 90 snapshots no older than 90 days. A file
/// that cannot be read is moved aside as `<name>.corrupt` and a new history starts.
final class HealthHistoryStore: @unchecked Sendable {
    static let snapshotLimit = 90
    static let maximumAge: TimeInterval = 90 * 86_400
    /// Environment variable that moves the history file. `Scripts/test.sh` and `Scripts/perf.sh` set it, so checks
    /// never add snapshots to the user's own history.
    static let locationOverride = "MACPOLISH_HEALTH_HISTORY"

    /// ~/Library/Application Support/Mac Polish/health-history.json, unless `MACPOLISH_HEALTH_HISTORY` names a file.
    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment[locationOverride], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Mac Polish").appending(path: "health-history.json")
    }

    let url: URL
    var corruptURL: URL { url.appendingPathExtension("corrupt") }
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "MacPolish.HealthHistory", qos: .utility)
    // Confined to `queue`.
    private var loaded = false
    private var stored: [HealthSnapshot] = []
    private var storedLoadNotice: String?
    private var storedSaveError: String?

    /// Cheap: nothing is read until the first request, and then only on the store's queue.
    init(url: URL = HealthHistoryStore.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// Snapshots oldest first, loaded off the main thread.
    func snapshots() async -> [HealthSnapshot] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.loadedSnapshots()) }
        }
    }

    /// Adds one snapshot in the background; retention is applied before the atomic write.
    func append(_ snapshot: HealthSnapshot) {
        queue.async {
            var snapshots = self.loadedSnapshots()
            snapshots.append(snapshot)
            self.stored = Self.retained(snapshots, now: max(self.now(), snapshot.date))
            self.save()
        }
    }

    /// Waits for every queued read and write. For tests and for orderly shutdown; never call it on a hot path.
    func flush() { queue.sync {} }

    /// Synchronous read for tests (after `flush()`); performs the first load if needed.
    var storedSnapshots: [HealthSnapshot] { queue.sync { loadedSnapshots() } }
    var loadNotice: String? { queue.sync { storedLoadNotice } }
    var saveError: String? { queue.sync { storedSaveError } }

    /// Newest 90 no older than 90 days, oldest first.
    static func retained(_ snapshots: [HealthSnapshot], now: Date) -> [HealthSnapshot] {
        let recent = snapshots.filter { now.timeIntervalSince($0.date) <= maximumAge }.sorted { $0.date < $1.date }
        return Array(recent.suffix(snapshotLimit))
    }

    // MARK: File (queue only)

    private struct HistoryFile: Codable {
        var version = 1
        var snapshots: [HealthSnapshot]
    }

    private func loadedSnapshots() -> [HealthSnapshot] {
        dispatchPrecondition(condition: .onQueue(queue))
        if !loaded {
            loaded = true
            load()
        }
        return stored
    }

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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            stored = Self.retained(try decoder.decode(HistoryFile.self, from: data).snapshots, now: now())
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
            storedLoadNotice = "The previous health history could not be read. It was kept as "
                + corruptURL.lastPathComponent + " and a new history was started."
        } catch {
            storedLoadNotice = "The health history could not be read, so a new history was started."
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try write(encoder.encode(HistoryFile(snapshots: stored)))
            storedSaveError = nil
        } catch {
            storedSaveError = "Health history could not be saved: " + error.localizedDescription
        }
    }

    /// Writes a new 0600 file next to the history and renames it over the old one, so a reader sees either the old
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
