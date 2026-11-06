import CryptoKit
import Darwin
import Foundation

/// Opt-in performance and load suite for the disk engine (run with Scripts/perf.sh, compiled with -O).
///
/// Every scenario builds its fixture with direct Darwin calls in a unique temporary folder, computes the expected
/// result while generating it (independently of the engine), asserts correctness exactly, and checks performance
/// against generous budgets that can be overridden from the environment. Fixtures are always removed, also when a
/// check fails (`fail` cleans up before stopping) or the run is interrupted (SIGINT/SIGTERM/SIGHUP).
///
/// Environment:
///   MACPOLISH_PERF_SCALE            smoke | standard (default) | heavy
///   MACPOLISH_PERF_REAL=1           also benchmark a read-only pass over /System/Volumes/Data (privacy folders skipped)
///   MACPOLISH_PERF_BUDGETS=warn     report performance budget overruns without failing
///   MACPOLISH_PERF_STRICT=1         fail on known engine findings instead of reporting them
///   MACPOLISH_PERF_OUT              folder for the metrics JSON (default .build/perf)
///   Budgets: MACPOLISH_PERF_MAX_SCAN_MB, MACPOLISH_PERF_MAX_BYTES_PER_FILE, MACPOLISH_PERF_THREAD_TOLERANCE,
///            MACPOLISH_PERF_DEADLINE_SLACK, MACPOLISH_PERF_MAX_JSON_MB, MACPOLISH_PERF_MIN_FILES_PER_SEC,
///            MACPOLISH_PERF_TIME_FACTOR (multiplies every time budget),
///            MACPOLISH_PERF_DUP_MEMORY_FRACTION (safety cap on bytes the duplicate fixture reads, share of RAM, default 1.0)
@main
enum PerformanceLoadCheck {
    static func main() throws {
        // The worker-transfer scenarios launch this binary as its own read-only scan worker, like the app does.
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        Fixtures.installSignalCleanup()
        MemorySampler.shared.start()
        let started = Clock.now()
        defer { Fixtures.cleanupAll() }

        var plan = Plan.make(Settings.requestedScale)
        let free = FS.freeBytes(Fixtures.temporaryBase)
        var fixturesAllowed = true
        while free < 3 * plan.peakFootprint {
            guard let smaller = plan.scale.smaller else {
                Log.line("NOTICE: \(Format.mib(free)) free in \(Fixtures.temporaryBase); even the smoke fixtures need 3 × "
                         + "\(Format.mib(plan.peakFootprint)). Fixture scenarios are skipped.")
                fixturesAllowed = false
                break
            }
            Log.line("NOTICE: \(Format.mib(free)) free is less than 3 × the \(plan.scale.rawValue) footprint "
                     + "(\(Format.mib(plan.peakFootprint))); scaling down to \(smaller.rawValue).")
            plan = Plan.make(smaller)
        }
        Report.shared.scale = plan.scale.rawValue
        Log.line("Mac Polish performance and load suite: scale \(plan.scale.rawValue) (requested \(Settings.requestedScale.rawValue)), "
                 + "fixtures in \(Fixtures.runRoot), \(Format.mib(free)) free, budgets \(Budgets.enforce ? "enforced" : "warn only")")

        if fixturesAllowed {
            Fixtures.createRunRoot()
            // Each scenario drains its own autorelease pool, so one scenario's Foundation objects never weigh on the next.
            autoreleasepool { BulkScenarios.run(plan) }
            autoreleasepool { WideScenario.run(plan) }
            autoreleasepool { DeepScenario.run(plan) }
            autoreleasepool { CloneScenario.run(plan) }
            autoreleasepool { PathologicalScenario.run(plan) }
            autoreleasepool { PermissionScenario.run(plan) }
            autoreleasepool { DuplicateScenario.run(plan) }
            autoreleasepool { SectionScenario.run(plan) }
        }
        if Settings.flag("MACPOLISH_PERF_REAL") { autoreleasepool { RealDiskScenario.run() } }

        Fixtures.cleanupAll()
        let total = Clock.now() - started
        Report.shared.printTable(totalSeconds: total)
        let file = Report.shared.writeJSON(totalSeconds: total)
        let findings = Report.shared.findings.count
        let warnings = Report.shared.budgetWarnings.count
        Log.line("PASS: \(Report.shared.scenarios.count) performance and load scenarios at \(plan.scale.rawValue) scale in "
                 + String(format: "%.1f s", total) + "; totals exact against generated ground truth"
                 + (findings > 0 ? "; \(findings) engine finding(s) reported" : "")
                 + (warnings > 0 ? "; \(warnings) budget warning(s)" : "")
                 + "; metrics in \(file)")
    }
}

// MARK: - Settings and budgets

enum PerfScale: String {
    case smoke, standard, heavy
    var smaller: PerfScale? {
        switch self {
        case .heavy: .standard
        case .standard: .smoke
        case .smoke: nil
        }
    }
}

enum Settings {
    static let environment = ProcessInfo.processInfo.environment
    static func double(_ name: String, _ fallback: Double) -> Double {
        environment[name].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
    }
    static func flag(_ name: String) -> Bool { ["1", "true", "yes"].contains(environment[name]?.lowercased() ?? "") }
    static var requestedScale: PerfScale {
        let raw = environment["MACPOLISH_PERF_SCALE"]?.lowercased() ?? "standard"
        guard let scale = PerfScale(rawValue: raw) else {
            preconditionFailure("MACPOLISH_PERF_SCALE must be smoke, standard or heavy, not \(raw)")
        }
        return scale
    }
}

enum Budgets {
    static let enforce = Settings.environment["MACPOLISH_PERF_BUDGETS"]?.lowercased() != "warn"
    static let strictFindings = Settings.flag("MACPOLISH_PERF_STRICT")
    static let timeFactor = Settings.double("MACPOLISH_PERF_TIME_FACTOR", 1)
    static let bytesPerFile = Settings.double("MACPOLISH_PERF_MAX_BYTES_PER_FILE", 48)
    /// Below this growth the per-file check is noise, not a signal of linear growth.
    static let linearFloorMB = 32.0
    static let threadTolerance = Settings.double("MACPOLISH_PERF_THREAD_TOLERANCE", 0.10)
    static let deadlineSlack = Settings.double("MACPOLISH_PERF_DEADLINE_SLACK", 2.0)
    static let maxJSONMB = Settings.double("MACPOLISH_PERF_MAX_JSON_MB", 25)
    static let minFilesPerSecond = Settings.double("MACPOLISH_PERF_MIN_FILES_PER_SEC", 25_000)
    static func seconds(_ base: Double) -> Double { base * timeFactor }

    static var summary: [String: Any] {
        ["enforced": enforce, "strictFindings": strictFindings, "timeFactor": timeFactor, "maxBytesPerFile": bytesPerFile,
         "linearFloorMB": linearFloorMB, "threadTolerance": threadTolerance, "deadlineSlackSeconds": deadlineSlack,
         "maxJSONMB": maxJSONMB, "minFilesPerSecond": minFilesPerSecond]
    }
}

struct Plan {
    var scale: PerfScale
    var bulkFiles: Int, bulkFolders: Int, tops = 16
    var wideEntries: Int
    var deepLevels = 400
    var cloneOriginals: Int, clonesPerFile = 3
    var pathoSets: Int
    var permFiles: Int, permFolders: Int, lockedFolders: Int
    var dupFiles: Int, dupGroups: Int, dupLinkPairs: Int
    var cacheFolders: Int, downloadFiles: Int
    var concurrentScans: Int
    var memoryBudgetMB: Double

    static func make(_ scale: PerfScale) -> Plan {
        switch scale {
        case .smoke:
            Plan(scale: scale, bulkFiles: 50_000, bulkFolders: 1_000, wideEntries: 30_000, cloneOriginals: 200, pathoSets: 100,
                 permFiles: 20_000, permFolders: 400, lockedFolders: 12, dupFiles: 4_000, dupGroups: 100, dupLinkPairs: 50,
                 cacheFolders: 1_000, downloadFiles: 500, concurrentScans: 8, memoryBudgetMB: 192)
        case .standard:
            Plan(scale: scale, bulkFiles: 300_000, bulkFolders: 3_000, wideEntries: 100_000, cloneOriginals: 1_000, pathoSets: 500,
                 permFiles: 100_000, permFolders: 2_000, lockedFolders: 30, dupFiles: 20_000, dupGroups: 500, dupLinkPairs: 200,
                 cacheFolders: 5_000, downloadFiles: 2_000, concurrentScans: 16, memoryBudgetMB: 256)
        case .heavy:
            Plan(scale: scale, bulkFiles: 1_200_000, bulkFolders: 10_000, wideEntries: 300_000, cloneOriginals: 3_000,
                 pathoSets: 2_000, permFiles: 300_000, permFolders: 5_000, lockedFolders: 45, dupFiles: 40_000, dupGroups: 1_000,
                 dupLinkPairs: 400, cacheFolders: 10_000, downloadFiles: 5_000, concurrentScans: 16, memoryBudgetMB: 512)
        }
    }

    var maxScanMB: Double { Settings.double("MACPOLISH_PERF_MAX_SCAN_MB", memoryBudgetMB) }

    /// The most disk one scenario holds at a time: each scenario removes its fixture before the next starts.
    var peakFootprint: Int64 {
        let bulk = Int64(bulkFiles) * 3_300
        let duplicates = Int64(dupFiles + dupGroups * 3 + dupLinkPairs) * 20_000 + Int64(dupGroups) * 3 * 262_144
        return max(bulk, duplicates, Int64(permFiles) * 3_300, Int64(wideEntries) * 1_500, 64 << 20)
    }
}

// MARK: - Failure, budgets, findings

enum Log {
    static func line(_ text: String) {
        print(text)
        fflush(stdout)
    }
}

/// Stops the run with a precise message after removing every fixture (a crash would skip `defer`).
func fail(_ message: String) -> Never {
    // While an interrupt removes the fixtures, checks see files vanish; that is not a result. The handler exits.
    while Fixtures.interrupted.value { sleep(1) }
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    Fixtures.cleanupAll()
    preconditionFailure(message)
}

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { fail(message()) }
}

/// Performance budgets fail the run unless MACPOLISH_PERF_BUDGETS=warn.
func budget(_ scenario: ScenarioRecord, _ ok: Bool, _ message: @autoclosure () -> String) {
    guard !ok else { return }
    let text = "[\(scenario.id) \(scenario.name)] \(message())"
    if Budgets.enforce {
        fail("performance budget exceeded: \(text). Override the named variable or set MACPOLISH_PERF_BUDGETS=warn.")
    }
    Log.line("BUDGET WARNING \(text)")
    scenario.status = "budget-warning"
    Report.shared.budgetWarnings.append(text)
}

/// A real engine problem found by the suite: reported loudly and recorded, not fixed here.
func finding(_ scenario: ScenarioRecord, _ title: String, _ detail: String) {
    Log.line("ENGINE FINDING [\(scenario.id) \(scenario.name)] \(title): \(detail)")
    Report.shared.findings.append(["scenario": scenario.id, "title": title, "detail": detail])
    scenario.status = "finding"
    if Budgets.strictFindings { fail("engine finding (MACPOLISH_PERF_STRICT=1): \(title): \(detail)") }
}

// MARK: - Time and memory

enum Clock {
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    static func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = now()
        let value = body()
        return (value, now() - start)
    }
}

/// Samples the process footprint (what Activity Monitor shows as Memory) from a background thread.
final class MemorySampler: @unchecked Sendable {
    static let shared = MemorySampler()
    private let lock = NSLock()
    private var peak: UInt64 = 0

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func maxRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss) // bytes on macOS
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                observe(Self.footprint())
                usleep(4_000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func observe(_ value: UInt64) {
        lock.lock()
        if value > peak { peak = value }
        lock.unlock()
    }

    func reset() -> UInt64 {
        let value = Self.footprint()
        lock.lock()
        peak = value
        lock.unlock()
        return value
    }

    func peakSinceReset() -> UInt64 {
        observe(Self.footprint())
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

struct Measured<T> {
    let value: T
    let seconds: Double
    let baseline: UInt64
    let peak: UInt64
    var growth: Int64 { max(0, Int64(peak) - Int64(baseline)) }
}

func measured<T>(_ body: () -> T) -> Measured<T> {
    let baseline = MemorySampler.shared.reset()
    let (value, seconds) = Clock.timed(body)
    return Measured(value: value, seconds: seconds, baseline: baseline, peak: MemorySampler.shared.peakSinceReset())
}

// MARK: - Fixture file system helpers (Darwin calls, never FileManager per file)

func errorText(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

/// Random bytes shared by every generated file (read-only after creation).
enum Fill {
    static let count = 4 << 20
    nonisolated(unsafe) static let base: UnsafeMutableRawPointer = {
        let pointer = malloc(count)!
        arc4random_buf(pointer, count)
        return pointer
    }()
}

enum FS {
    static func makeDir(_ path: String, mode: mode_t = 0o755) {
        if mkdir(path, mode) != 0 && errno != EEXIST { fail("mkdir \(path): \(errorText())") }
    }

    /// Creates `path` with `size` bytes of fill data and returns the allocated bytes fstat reports.
    @discardableResult
    static func makeFile(_ path: String, size: Int, seed: Int = 0) -> Int64 {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o644)
        if descriptor < 0 { fail("create \(path): \(errorText())") }
        var remaining = size
        var position = Int(UInt(bitPattern: seed) % UInt(Fill.count / 2))
        while remaining > 0 {
            let written = write(descriptor, Fill.base + position, min(remaining, Fill.count - position))
            if written < 0 {
                if errno == EINTR { continue }
                let code = errno
                close(descriptor)
                fail("write \(path): \(errorText(code))")
            }
            remaining -= written
            position += written
            if position >= Fill.count { position = 0 }
        }
        var info = stat()
        fstat(descriptor, &info)
        close(descriptor)
        return Int64(info.st_blocks) * 512
    }

    /// A file with a large logical size and no data blocks.
    static func makeSparse(_ path: String, logicalSize: Int64) {
        let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o644)
        if descriptor < 0 { fail("create \(path): \(errorText())") }
        defer { close(descriptor) }
        check(ftruncate(descriptor, off_t(logicalSize)) == 0, "ftruncate \(path): \(errorText())")
    }

    static func patch(_ path: String, at offset: Int, _ bytes: [UInt8]) {
        let descriptor = open(path, O_WRONLY | O_CLOEXEC)
        if descriptor < 0 { fail("open \(path): \(errorText())") }
        let written = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
        close(descriptor)
        check(written == bytes.count, "pwrite \(path): \(errorText())")
    }

    static func clone(_ source: String, _ destination: String) {
        check(clonefile(source, destination, 0) == 0, "clonefile \(source) -> \(destination): \(errorText())")
    }

    static func hardLink(_ source: String, _ destination: String) {
        check(link(source, destination) == 0, "link \(source) -> \(destination): \(errorText())")
    }

    static func symbolicLink(_ target: String, at path: String) {
        check(symlink(target, path) == 0, "symlink \(path) -> \(target): \(errorText())")
    }

    static func allocated(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { fail("lstat \(path): \(errorText())") }
        return Int64(info.st_blocks) * 512
    }

    static func inode(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { fail("lstat \(path): \(errorText())") }
        return UInt64(info.st_ino)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func freeBytes(_ path: String) -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    static func setModified(_ path: String, daysAgo: Double) {
        let seconds = Int(Date().timeIntervalSince1970 - daysAgo * 86_400)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        check(utimes(path, &times) == 0, "utimes \(path): \(errorText())")
    }

    /// Binds a UNIX socket at `path`, leaving the socket file behind. Not thread-safe when the path is long
    /// (the relative bind changes the working directory briefly).
    static func makeSocket(_ path: String) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        check(descriptor >= 0, "socket: \(errorText())")
        defer { close(descriptor) }
        var target = path
        var restore: Int32 = -1
        if path.utf8.count >= 104 {
            restore = open(".", O_RDONLY | O_CLOEXEC)
            check(chdir((path as NSString).deletingLastPathComponent) == 0, "chdir for socket: \(errorText())")
            target = (path as NSString).lastPathComponent
        }
        defer {
            if restore >= 0 {
                fchdir(restore)
                close(restore)
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(target.utf8)
        check(bytes.count < 104, "socket name too long: \(target)")
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        check(result == 0, "bind \(path): \(errorText())")
    }
}

/// Deterministic pseudo-random numbers for fixture shapes.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// A value shared between concurrent fixture workers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
    var value: Value { with { $0 } }
}

// MARK: - Fixture lifetime

enum Fixtures {
    static let runID = String(UUID().uuidString.prefix(8)).lowercased()
    /// The real path of the temporary folder (no /var symlink), so scanned paths match what the engine reports.
    static let temporaryBase: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let temporary = FileManager.default.temporaryDirectory.path
        return realpath(temporary, &buffer) != nil ? String(cString: buffer) : temporary
    }()
    static let runRoot = temporaryBase + "/MacPolish-perf-" + runID
    private static let state = Locked<(roots: [String], locked: [String])>(([], []))
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    /// Set once SIGINT/SIGTERM/SIGHUP starts removing fixtures.
    static let interrupted = Locked(false)

    static func createRunRoot() {
        FS.makeDir(runRoot, mode: 0o700)
        register(runRoot)
    }

    static func register(_ root: String) { state.with { $0.roots.append(root) } }

    /// Removes permissions from a folder and remembers to restore them before cleanup.
    static func lock(_ path: String, mode: mode_t) {
        state.with { $0.locked.append(path) }
        check(chmod(path, mode) == 0, "chmod \(path): \(errorText())")
    }

    private static func unlock(under root: String) {
        let paths = state.with { state -> [String] in
            let matching = state.locked.filter { $0 == root || $0.hasPrefix(root + "/") }
            state.locked.removeAll { $0 == root || $0.hasPrefix(root + "/") }
            return matching
        }
        // Outer folders were locked last; restore them first so the inner ones can be reached.
        for path in paths.reversed() { chmod(path, 0o755) }
    }

    /// Removes a fixture folder quickly: second-level entries in parallel, then the rest.
    static func remove(_ root: String) {
        unlock(under: root)
        guard FS.exists(root) else { return }
        let fm = FileManager.default
        var items: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + name
            if FS.isDirectory(path), let inner = try? fm.contentsOfDirectory(atPath: path), !inner.isEmpty {
                items += inner.map { path + "/" + $0 }
            } else {
                items.append(path)
            }
        }
        let all = items
        DispatchQueue.concurrentPerform(iterations: all.count) { index in
            let path = all[index]
            if unlink(path) != 0 { try? FileManager.default.removeItem(atPath: path) }
        }
        try? fm.removeItem(atPath: root)
        if FS.exists(root) {
            _ = SystemDataScanner.run("/bin/chmod", ["-R", "u+rwx", root], timeout: 120)
            _ = SystemDataScanner.run("/bin/rm", ["-rf", root], timeout: 600)
        }
        if FS.exists(root) { FileHandle.standardError.write(Data("WARNING: could not remove fixture \(root)\n".utf8)) }
        state.with { $0.roots.removeAll { $0 == root } }
    }

    static func cleanupAll() {
        let roots = state.with { $0.roots }
        for root in roots.reversed() { remove(root) }
    }

    static func installSignalCleanup() {
        for code in [SIGINT, SIGTERM, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
            source.setEventHandler {
                guard !interrupted.with({ value in defer { value = true }; return value }) else { return }
                FileHandle.standardError.write(Data("Interrupted: removing fixtures\n".utf8))
                cleanupAll()
                FileHandle.standardError.write(Data("Interrupted: fixtures removed\n".utf8))
                exit(128 + code)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

// MARK: - Report

final class ScenarioRecord {
    let id: String
    let name: String
    var metrics: [(String, Any)] = []
    var summary = ""
    var status = "pass"
    var seconds = 0.0

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    func set(_ key: String, _ value: Any) {
        metrics.removeAll { $0.0 == key }
        metrics.append((key, value))
    }
}

final class Report: @unchecked Sendable {
    static let shared = Report()
    var scenarios: [ScenarioRecord] = []
    var findings: [[String: String]] = []
    var budgetWarnings: [String] = []
    var scale = ""

    func begin(_ id: String, _ name: String) -> ScenarioRecord {
        Log.line("-- \(id) \(name)")
        return ScenarioRecord(id: id, name: name)
    }

    func end(_ record: ScenarioRecord) {
        scenarios.append(record)
        let values = record.metrics.map { "\($0.0)=\(Format.value($0.1))" }.joined(separator: " ")
        Log.line("[\(record.id) \(record.name)] \(record.status.uppercased()) \(String(format: "%.3f s", record.seconds)) | \(values)")
    }

    func printTable(totalSeconds: Double) {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? String(text.prefix(width)) : text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        Log.line("")
        Log.line("==== Mac Polish performance and load (\(scale)) ====")
        Log.line(pad("ID", 5) + pad("Scenario", 26) + pad("Status", 15) + pad("Seconds", 10) + "Summary")
        for record in scenarios.sorted(by: { Int($0.id.dropFirst()) ?? 0 < Int($1.id.dropFirst()) ?? 0 }) {
            Log.line(pad(record.id, 5) + pad(record.name, 26) + pad(record.status, 15)
                     + pad(String(format: "%.3f", record.seconds), 10) + record.summary)
        }
        Log.line(String(format: "Total %.1f s, peak RSS %@", totalSeconds, Format.mib(MemorySampler.maxRSS())))
        for item in findings { Log.line("FINDING \(item["scenario"] ?? ""): \(item["title"] ?? "")") }
    }

    func writeJSON(totalSeconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        // ISO 8601 basic format (no colons, safe in file names): perf-20261106T094957Z.json
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: Date())
        let directory = Settings.environment["MACPOLISH_PERF_OUT"] ?? ".build/perf"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/perf-\(stamp).json"
        let document: [String: Any] = [
            "schema": 1,
            "date": ISO8601DateFormatter().string(from: Date()),
            "scale": scale,
            "requestedScale": Settings.requestedScale.rawValue,
            "machine": Machine.describe(),
            "budgets": Budgets.summary,
            "totalSeconds": Format.json(totalSeconds),
            "peakRSSBytes": MemorySampler.maxRSS(),
            "findings": findings,
            "budgetWarnings": budgetWarnings,
            "scenarios": scenarios.map { record -> [String: Any] in
                var metrics: [String: Any] = [:]
                for (key, value) in record.metrics { metrics[key] = Format.json(value) }
                return ["id": record.id, "name": record.name, "status": record.status,
                        "seconds": Format.json(record.seconds), "summary": record.summary, "metrics": metrics]
            }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not write metrics JSON \(path): \(error)")
        }
        return path
    }
}

enum Machine {
    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
    }

    static func describe() -> [String: Any] {
        var volume = statfs()
        let fsType = statfs(Fixtures.temporaryBase, &volume) == 0
            ? withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : "unknown"
        return ["model": sysctlString("hw.model"), "cpu": sysctlString("machdep.cpu.brand_string"),
                "logicalCPUs": ProcessInfo.processInfo.activeProcessorCount,
                "performanceCores": sysctlInt("hw.perflevel0.physicalcpu"),
                "efficiencyCores": sysctlInt("hw.perflevel1.physicalcpu"),
                "memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "fixtureFileSystem": fsType, "fixtureFreeBytes": FS.freeBytes(Fixtures.temporaryBase),
                "commit": Settings.environment["MACPOLISH_PERF_COMMIT"] ?? "unknown"]
    }
}

enum Format {
    static func mib(_ bytes: Int64) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
    static func rate(_ value: Double) -> String {
        value >= 1e6 ? String(format: "%.2fM/s", value / 1e6) : String(format: "%.0fk/s", value / 1e3)
    }
    static func value(_ value: Any) -> String {
        switch value {
        case let double as Double: return abs(double) >= 1_000 ? String(format: "%.0f", double) : String(format: "%.3f", double)
        default: return "\(value)"
        }
    }
    static func json(_ value: Any) -> Any {
        if let double = value as? Double { return double.isFinite ? (double * 1_000_000).rounded() / 1_000_000 : 0 }
        return value
    }
}

func perSecond(_ count: Int, _ seconds: Double) -> Double { seconds > 0 ? Double(count) / seconds : 0 }

// MARK: - Tree helpers

/// Every folder's rows must add up to the folder; violations name the path.
func checkTotals(_ node: DiskNode, _ context: String, path: String = "") {
    guard !node.children.isEmpty else { return }
    let here = path + "/" + node.name
    var sum = DiskNode(name: "", kind: .folder)
    for child in node.children { sum.add(child) }
    check(sum.bytes == node.bytes && sum.files == node.files && sum.unreadable == node.unreadable
          && sum.notScanned == node.notScanned && sum.uncertainBytes == node.uncertainBytes,
          "\(context): rows of \(here) do not add up (bytes \(sum.bytes)/\(node.bytes), files \(sum.files)/\(node.files), "
          + "unreadable \(sum.unreadable)/\(node.unreadable), not scanned \(sum.notScanned)/\(node.notScanned))")
    check(node.children.filter { $0.kind == .smallerItems }.count <= 1 && (node.children.last?.kind == .smallerItems
          || !node.children.contains { $0.kind == .smallerItems }), "\(context): 'Smaller items' must be one row, last, in \(here)")
    for child in node.children { checkTotals(child, context, path: here) }
}

func rowCount(_ node: DiskNode) -> Int { 1 + node.children.reduce(0) { $0 + rowCount($1) } }
func treeHeight(_ node: DiskNode) -> Int { node.children.isEmpty ? 0 : 1 + node.children.map(treeHeight).max()! }
func fileRows(_ node: DiskNode) -> [DiskNode] { (node.kind == .file ? [node] : []) + node.children.flatMap(fileRows) }

func encodeJSON<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

// MARK: - Generated trees

struct Truth {
    var files = 0
    var folders = 0
    /// Files of at least 1 MiB, which the default options list as their own rows.
    var listed = 0
    var bytes: Int64 = 0
    var logical: Int64 = 0
    mutating func add(_ other: Truth) {
        files += other.files
        folders += other.folders
        listed += other.listed
        bytes += other.bytes
        logical += other.logical
    }
}

struct GeneratedTree {
    let root: String
    let truth: Truth
    let tops: [String]
    let topTruths: [Truth]
    let mids: Int
    let leaves: Int
}

/// Mixed sizes: most files empty or tiny, a few large enough to be listed (>= 1 MiB).
func bulkFileSize(_ random: inout SplitMix) -> Int {
    let draw = random.unit()
    if draw < 1.0 / 8_000 { return (1 << 20) + Int(random.next() % (1 << 20)) }
    if draw < 0.78 { return 0 }
    if draw < 0.96 { return 1 + Int(random.next() % 512) }
    if draw < 0.997 { return 4_097 + Int(random.next() % 28_000) }
    return 65_536 + Int(random.next() % 196_608)
}

/// root/tNN/dM/eL with files spread over every folder, generated in parallel per (top, mid) unit.
func generateTree(at root: String, files: Int, folders: Int, tops: Int, seed: UInt64) -> GeneratedTree {
    FS.makeDir(root)
    let perTop = max(3, folders / tops)
    let mids = max(1, Int(Double(perTop).squareRoot()))
    let leaves = max(0, (perTop - 1 - mids) / mids)
    let topPaths = (0..<tops).map { root + String(format: "/t%02d", $0) }
    for top in topPaths {
        FS.makeDir(top)
        for mid in 0..<mids { FS.makeDir(top + "/d\(mid)") }
    }
    let results = Locked([Truth](repeating: Truth(), count: tops))
    DispatchQueue.concurrentPerform(iterations: tops * mids) { unit in
        let top = unit / mids, mid = unit % mids
        let midPath = topPaths[top] + "/d\(mid)"
        var folders = mid == 0 ? [topPaths[top], midPath] : [midPath]
        for leaf in 0..<leaves {
            let path = midPath + "/e\(leaf)"
            FS.makeDir(path)
            folders.append(path)
        }
        var local = Truth()
        local.folders = leaves + 1 + (mid == 0 ? 1 : 0)
        let topFiles = files / tops + (top < files % tops ? 1 : 0)
        let count = topFiles / mids + (mid < topFiles % mids ? 1 : 0)
        var random = SplitMix(seed: seed ^ (UInt64(unit + 1) &* 0x9E37_79B9_7F4A_7C15))
        for index in 0..<count {
            let size = bulkFileSize(&random)
            let name = index % 7 == 3 ? "report-\(index)-with-a-longer-file-name.dat" : "f\(index)"
            let bytes = FS.makeFile(folders[index % folders.count] + "/" + name, size: size,
                                    seed: Int(truncatingIfNeeded: random.next()))
            local.files += 1
            local.bytes += bytes
            local.logical += Int64(size)
            if bytes >= 1 << 20 { local.listed += 1 }
        }
        results.with { $0[top].add(local) }
    }
    let topTruths = results.value
    var truth = Truth()
    truth.folders = 1
    for item in topTruths { truth.add(item) }
    return GeneratedTree(root: root, truth: truth, tops: topPaths, topTruths: topTruths, mids: mids, leaves: leaves)
}

func checkTotalsAgainst(_ result: DiskTreeResult, _ truth: Truth, _ context: String, unreadable: Int = 0) {
    let root = result.root
    check(root.files == truth.files, "\(context): files \(root.files) != generated \(truth.files)")
    check(root.bytes == truth.bytes, "\(context): bytes \(root.bytes) != generated \(truth.bytes) (diff \(root.bytes - truth.bytes))")
    check(root.unreadable == unreadable, "\(context): unreadable \(root.unreadable) != \(unreadable)")
    check(root.notScanned == 0 && !result.incomplete && !result.missing,
          "\(context): complete scan expected (notScanned \(root.notScanned), incomplete \(result.incomplete), missing \(result.missing))")
}

// MARK: - S1, S2, S8, S9, S10, S11: one bulk tree, many measurements

enum BulkScenarios {
    static func run(_ plan: Plan) {
        let root = Fixtures.runRoot + "/bulk"
        let (tree, generation) = Clock.timed {
            generateTree(at: root, files: plan.bulkFiles, folders: plan.bulkFolders, tops: plan.tops, seed: 0xB01C)
        }
        defer { Fixtures.remove(root) }
        Log.line("   generated \(tree.truth.files) files in \(tree.truth.folders) folders (\(Format.mib(tree.truth.bytes)) allocated) in "
                 + String(format: "%.1f s (%@ files)", generation, Format.rate(perSecond(tree.truth.files, generation))))

        let baseline = bulkTree(plan, tree, generation: generation)
        let (t1, t8) = threadScaling(tree, baseline: baseline.result)
        deadline(tree, t1: t1, t8: t8)
        concurrentLoad(plan, tree)
        transfer(plan, tree, baseline: baseline.result, inProcessSeconds: t8)
        sizeCalculator(tree, treeSeconds: t8)
    }

    // S1
    static func bulkTree(_ plan: Plan, _ tree: GeneratedTree, generation: Double) -> (result: DiskTreeResult, seconds: Double) {
        let record = Report.shared.begin("S1", "bulk tree")
        let first = measured { DiskTreeScanner.scan(tree.root) }
        checkTotalsAgainst(first.value, tree.truth, "S1 bulk tree")
        checkTotals(first.value.root, "S1 bulk tree")
        let rows = fileRows(first.value.root)
        check(rows.allSatisfy { $0.bytes >= DiskTreeOptions().minimumListedBytes },
              "S1: every listed file row must be at least minimumListedBytes")
        check(rows.count == tree.truth.listed, "S1: \(rows.count) listed file rows, \(tree.truth.listed) files >= 1 MiB were generated")
        let second = measured { DiskTreeScanner.scan(tree.root) }
        check(second.value == first.value, "S1: a repeated scan of an unchanged tree must be identical")
        let best = min(first.seconds, second.seconds)
        let growth = max(first.growth, second.growth)
        let throughput = perSecond(tree.truth.files, best)
        let perFile = Double(growth) / Double(max(1, tree.truth.files))
        let resultRows = rowCount(first.value.root)

        record.seconds = best
        record.set("files", tree.truth.files)
        record.set("folders", tree.truth.folders)
        record.set("allocatedBytes", tree.truth.bytes)
        record.set("logicalBytes", tree.truth.logical)
        record.set("generationSeconds", generation)
        record.set("generationFilesPerSecond", perSecond(tree.truth.files, generation))
        record.set("firstScanSeconds", first.seconds)
        record.set("warmScanSeconds", second.seconds)
        record.set("filesPerSecond", throughput)
        record.set("footprintGrowthBytes", growth)
        record.set("footprintBytesPerFile", perFile)
        record.set("footprintPeakBytes", Int64(max(first.peak, second.peak)))
        record.set("maxRSSBytes", MemorySampler.maxRSS())
        record.set("resultRows", resultRows)
        record.summary = "\(tree.truth.files) files, \(Format.rate(throughput)), mem +\(Format.mib(growth)) "
            + String(format: "(%.1f B/file)", perFile) + ", \(resultRows) rows"

        let limit = plan.maxScanMB * 1_048_576
        budget(record, Double(growth) <= limit,
               "footprint grew \(Format.mib(growth)) during the scan, budget \(plan.maxScanMB) MB (MACPOLISH_PERF_MAX_SCAN_MB)")
        budget(record, Double(growth) <= Budgets.linearFloorMB * 1_048_576 || perFile <= Budgets.bytesPerFile,
               String(format: "memory scales with the file count: %.1f bytes per file (%@ for %d files), budget %.0f "
                      + "(MACPOLISH_PERF_MAX_BYTES_PER_FILE); small entries should fold, not be retained",
                      perFile, Format.mib(growth), tree.truth.files, Budgets.bytesPerFile))
        budget(record, throughput >= Budgets.minFilesPerSecond,
               "\(Format.rate(throughput)) is below \(Budgets.minFilesPerSecond) files/s (MACPOLISH_PERF_MIN_FILES_PER_SEC)")
        Report.shared.end(record)
        return (first.value, best)
    }

    // S2
    static func threadScaling(_ tree: GeneratedTree, baseline: DiskTreeResult) -> (Double, Double) {
        let record = Report.shared.begin("S2", "thread scaling")
        // The file system's own ceiling: the same folders listed by plain parallel getattrlistbulk calls, no engine.
        var folders = [tree.root]
        for top in tree.tops {
            folders.append(top)
            for mid in 0..<tree.mids {
                folders.append(top + "/d\(mid)")
                for leaf in 0..<tree.leaves { folders.append(top + "/d\(mid)/e\(leaf)") }
            }
        }
        var times: [Int: Double] = [:]
        var raw: [Int: Double] = [:]
        // Interleaved rounds, best of each: background load and clock changes hit every configuration alike.
        let rounds = tree.truth.files < 100_000 ? 5 : 3
        // The engine's own default is measured too; it is derived from the core count (DiskTreeOptions.defaultThreads).
        let defaultThreads = DiskTreeOptions.defaultThreads
        let widths = Array(Set([1, 2, 4, 8, 16, defaultThreads])).sorted()
        for _ in 0..<rounds {
            for threads in widths {
                var options = DiskTreeOptions()
                options.threads = threads
                let (result, seconds) = Clock.timed { DiskTreeScanner.scan(tree.root, options: options) }
                check(result == baseline, "S2: \(threads) threads gave a different tree (bytes \(result.root.bytes) vs "
                      + "\(baseline.root.bytes), files \(result.root.files) vs \(baseline.root.files), unreadable "
                      + "\(result.root.unreadable) vs \(baseline.root.unreadable))")
                times[threads] = min(times[threads] ?? .infinity, seconds)
            }
            for width in [1, 4, 8] {
                let (_, seconds) = Clock.timed {
                    DispatchQueue.concurrentPerform(iterations: width) { lane in
                        for index in stride(from: lane, to: folders.count, by: width) { _ = BulkDirectoryReader.entries(of: folders[index]) }
                    }
                }
                raw[width] = min(raw[width] ?? .infinity, seconds)
            }
        }
        let t1 = times[1]!, t8 = times[8]!
        record.set("rounds", rounds)
        for width in [1, 4, 8] { record.set("rawListing\(width)Seconds", raw[width]!) }
        Log.line(String(format: "   raw getattrlistbulk ceiling over %d folders: 1 lane %.3f s, 4 lanes %.3f s (%.2fx), 8 lanes %.3f s (%.2fx)",
                        folders.count, raw[1]!, raw[4]!, raw[1]! / raw[4]!, raw[8]!, raw[1]! / raw[8]!))
        Log.line("   threads  seconds  files/s     speedup   (engine default: \(defaultThreads))")
        for threads in widths {
            let seconds = times[threads]!
            let rate = Format.rate(perSecond(tree.truth.files, seconds))
            Log.line(String(format: "   %7d  %7.3f  ", threads, seconds) + rate.padding(toLength: 12, withPad: " ", startingAt: 0)
                     + String(format: "%.2fx", t1 / seconds))
            record.set("seconds\(threads)", seconds)
            record.set("speedup\(threads)", t1 / seconds)
        }
        record.seconds = t8
        let tDefault = times[defaultThreads]!
        record.set("defaultThreads", defaultThreads)
        record.summary = String(format: "identical; speedup 2t %.2fx 4t %.2fx 8t %.2fx 16t %.2fx, default %dt %.2fx (raw 8 lanes %.2fx)",
                                t1 / times[2]!, t1 / times[4]!, t1 / t8, t1 / times[16]!, defaultThreads, t1 / tDefault, raw[1]! / raw[8]!)
        let tolerance = 1 + Budgets.threadTolerance
        let engineRatio = tDefault / t1, rawRatio = raw[8]! / raw[1]!
        let engineSpeedup4 = t1 / times[4]!, rawSpeedup4 = raw[1]! / raw[4]!
        record.set("engineSlowdown8", engineRatio)
        record.set("rawSlowdown8", rawRatio)
        record.set("rawSpeedup4", rawSpeedup4)
        // The engine's own scheduling, where the file system still scales: 4 threads must gain what 4 plain lanes gain.
        // Comparing two measured ratios compounds their noise, so this comparison gets twice the tolerance.
        budget(record, engineSpeedup4 * (1 + 2 * Budgets.threadTolerance) >= rawSpeedup4,
               String(format: "4 threads speed the scan up %.2fx, plain parallel listing 4 lanes %.2fx: the engine's scheduling "
                      + "costs more than %.0f%% (MACPOLISH_PERF_THREAD_TOLERANCE)", engineSpeedup4, rawSpeedup4,
                      2 * Budgets.threadTolerance * 100))
        if engineRatio > tolerance && rawRatio > tolerance {
            // Plain parallel getattrlistbulk slows down too: the file system is the limit at 8 lanes, not the engine's
            // scheduling. The default thread count is still a real cost, so it is reported.
            let fastest = times.min { $0.value < $1.value }!
            finding(record, "the default \(defaultThreads) threads are slower than 1 thread on this warm-metadata fixture",
                    String(format: "warm-metadata scan of %d files: 1t %.3f s, 2t %.3f s, 4t %.3f s, 8t %.3f s, %dt %.3f s (default, "
                           + "%.0f%% slower than 1t), 16t %.3f s; fastest %dt. Plain parallel BulkDirectoryReader over the same %d "
                           + "folders: 1 lane %.3f s, 4 lanes %.3f s, 8 lanes %.3f s, so concurrent getattrlistbulk calls contend "
                           + "in the kernel. The default was tuned on the real startup disk (1.15M files: 1t 18.8 s, 6t 7.2 s), "
                           + "where metadata is not all cached; compare with MACPOLISH_PERF_REAL=1 before changing it.",
                           tree.truth.files, t1, times[2]!, times[4]!, t8, defaultThreads, tDefault, (engineRatio - 1) * 100,
                           times[16]!, fastest.key, folders.count, raw[1]!, raw[4]!, raw[8]!))
        } else {
            budget(record, engineRatio <= tolerance,
                   String(format: "the default threads (%.3f s) are slower than 1 thread (%.3f s) by more than %.0f%% while plain "
                          + "parallel listing at 8 lanes is not (%.2fx) (MACPOLISH_PERF_THREAD_TOLERANCE)", tDefault, t1,
                          Budgets.threadTolerance * 100, 1 / rawRatio))
        }
        Report.shared.end(record)
        return (t1, t8)
    }

    // S8
    static func deadline(_ tree: GeneratedTree, t1: Double, t8: Double) {
        let record = Report.shared.begin("S8", "deadline under load")
        // The scan must need at least twice its deadline; on a small or very fast tree use one thread and a shorter limit.
        var threads = 8
        var limit = 0.3
        var expected = t8
        if t8 < 2 * limit {
            threads = 1
            expected = t1
            limit = min(0.3, max(0.01, t1 / 4))
        }
        var options = DiskTreeOptions()
        options.threads = threads
        options.deadline = Date(timeIntervalSinceNow: limit)
        let started = Date()
        let partial = DiskTreeScanner.scan(tree.root, options: options)
        let elapsed = Date().timeIntervalSince(started)
        check(elapsed <= limit + Budgets.deadlineSlack,
              String(format: "S8: scan with a %.2f s deadline returned after %.2f s (allowed %.2f s, MACPOLISH_PERF_DEADLINE_SLACK)",
                     limit, elapsed, limit + Budgets.deadlineSlack))
        if expected > limit * 1.5 {
            check(partial.incomplete && partial.root.notScanned > 0,
                  "S8: a \(limit) s deadline on a \(expected) s scan must be incomplete with not-scanned folders "
                  + "(incomplete \(partial.incomplete), notScanned \(partial.root.notScanned))")
        } else {
            Log.line("   NOTICE: the tree scans in \(expected) s, too fast for a meaningful \(limit) s deadline check")
        }
        check(partial.root.bytes <= tree.truth.bytes && partial.root.files <= tree.truth.files,
              "S8: a partial scan cannot exceed the full totals (\(partial.root.bytes) > \(tree.truth.bytes) or "
              + "\(partial.root.files) > \(tree.truth.files))")
        checkTotals(partial.root, "S8 partial tree")

        var past = DiskTreeOptions()
        past.deadline = Date(timeIntervalSinceNow: -1)
        let (expired, expiredSeconds) = Clock.timed { DiskTreeScanner.scan(tree.root, options: past) }
        check(expiredSeconds <= Budgets.seconds(0.5), "S8: a past deadline took \(expiredSeconds) s, it must return immediately")
        check(expired.incomplete && expired.root.notScanned == 1 && expired.root.bytes == 0 && expired.root.files == 0,
              "S8: a past deadline must report only the root as not scanned")

        let coverage = Double(partial.root.files) / Double(max(1, tree.truth.files))
        record.seconds = elapsed
        record.set("deadlineSeconds", limit)
        record.set("threads", threads)
        record.set("returnedAfterSeconds", elapsed)
        record.set("overrunSeconds", elapsed - limit)
        record.set("filesCoverage", coverage)
        record.set("notScannedFolders", partial.root.notScanned)
        record.set("pastDeadlineSeconds", expiredSeconds)
        record.summary = String(format: "%.2f s deadline (%dt): back after %.3f s, %.0f%% of files, %d folders not scanned; past: %.4f s",
                                limit, threads, elapsed, coverage * 100, partial.root.notScanned, expiredSeconds)
        Report.shared.end(record)
    }

    // S9
    static func concurrentLoad(_ plan: Plan, _ tree: GeneratedTree) {
        let record = Report.shared.begin("S9", "concurrent scans")
        let count = min(plan.concurrentScans, tree.tops.count)
        let paths = Array(tree.tops.prefix(count))
        let concurrent = measured { DiskScanService.concurrentMap(paths) { DiskTreeScanner.scan($0) } }
        var files = 0
        for (index, result) in concurrent.value.enumerated() {
            let truth = tree.topTruths[index]
            check(result.root.files == truth.files && result.root.bytes == truth.bytes && result.root.unreadable == 0
                  && !result.incomplete,
                  "S9: concurrent scan of \(paths[index]) found \(result.root.files) files / \(result.root.bytes) bytes, "
                  + "expected \(truth.files) / \(truth.bytes)")
            files += result.root.files
        }
        let (sequential, sequentialSeconds) = Clock.timed { paths.map { DiskTreeScanner.scan($0) } }
        check(sequential == concurrent.value, "S9: concurrent and sequential scans of the same folders must be identical")
        record.seconds = concurrent.seconds
        record.set("scans", count)
        record.set("files", files)
        record.set("wallSeconds", concurrent.seconds)
        record.set("aggregateFilesPerSecond", perSecond(files, concurrent.seconds))
        record.set("sequentialSeconds", sequentialSeconds)
        record.set("footprintGrowthBytes", concurrent.growth)
        record.summary = "\(count) scans x 8 threads: \(Format.rate(perSecond(files, concurrent.seconds))) aggregate, "
            + String(format: "sequential %.3f s, mem +%@", sequentialSeconds, Format.mib(concurrent.growth))
        Report.shared.end(record)
    }

    // S10
    static func transfer(_ plan: Plan, _ tree: GeneratedTree, baseline: DiskTreeResult, inProcessSeconds: Double) {
        let record = Report.shared.begin("S10", "worker transfer")
        func roundTrip(_ result: DiskTreeResult, _ label: String) -> (bytes: Int, encode: Double, decode: Double) {
            let (encoded, encodeSeconds) = Clock.timed { () -> Data in
                do { return try encodeJSON(result) } catch { fail("S10: \(label) result could not be encoded: \(error)") }
            }
            let (decoded, decodeSeconds) = Clock.timed { () -> DiskTreeResult in
                do { return try JSONDecoder().decode(DiskTreeResult.self, from: encoded) } catch {
                    fail("S10: \(label) result could not be decoded: \(error)")
                }
            }
            check(decoded == result, "S10: \(label) JSON round trip changed the tree")
            return (encoded.count, encodeSeconds, decodeSeconds)
        }
        let standard = roundTrip(baseline, "default options")
        let (detail, detailScan) = Clock.timed { DiskTreeScanner.scan(tree.root, options: .detail) }
        check(detail.root.bytes == tree.truth.bytes && detail.root.files == tree.truth.files, "S10: detail scan totals")
        check(detail.root.children.count == tree.tops.count && detail.root.children.allSatisfy { $0.children.isEmpty },
              "S10: detail options keep every immediate child and nothing deeper")
        let detailed = roundTrip(detail, "detail options")

        // The production path: a real `--scan-worker tree` child process, JSON over stdout, decoded here.
        let (worker, workerSeconds) = Clock.timed { DiskMapService.workerReader(tree.root, DiskTreeOptions(), 300) }
        guard case .success(let fromWorker) = worker else { fail("S10: the scan worker failed on the bulk tree: \(worker)") }
        check(fromWorker == baseline, "S10: the worker process and the in-process scan must produce the same tree")

        record.seconds = standard.encode + standard.decode
        record.set("defaultJSONBytes", standard.bytes)
        record.set("defaultEncodeSeconds", standard.encode)
        record.set("defaultDecodeSeconds", standard.decode)
        record.set("detailJSONBytes", detailed.bytes)
        record.set("detailScanSeconds", detailScan)
        record.set("detailEncodeSeconds", detailed.encode)
        record.set("detailDecodeSeconds", detailed.decode)
        record.set("workerSeconds", workerSeconds)
        record.set("workerOverheadSeconds", workerSeconds - inProcessSeconds)
        record.summary = String(format: "default %@ (enc %.4f s, dec %.4f s); detail %@; worker %.3f s vs in-process %.3f s",
                                Format.mib(Int64(standard.bytes)), standard.encode, standard.decode,
                                Format.mib(Int64(detailed.bytes)), workerSeconds, inProcessSeconds)
        budget(record, Double(standard.bytes) <= Budgets.maxJSONMB * 1_048_576,
               "default-options JSON is \(Format.mib(Int64(standard.bytes))), budget \(Budgets.maxJSONMB) MB (MACPOLISH_PERF_MAX_JSON_MB)")
        Report.shared.end(record)
    }

    // S11
    static func sizeCalculator(_ tree: GeneratedTree, treeSeconds: Double) {
        let record = Report.shared.begin("S11", "size calculator parity")
        let (measurement, seconds) = Clock.timed { FileSizeCalculator.measure(URL(fileURLWithPath: tree.root)) }
        check(measurement.bytes == tree.truth.bytes,
              "S11: FileSizeCalculator.measure \(measurement.bytes) != generated \(tree.truth.bytes) bytes")
        check(measurement.unreadableFolders == 0, "S11: no unreadable folders expected")
        record.seconds = seconds
        record.set("measureSeconds", seconds)
        record.set("measureFilesPerSecond", perSecond(tree.truth.files, seconds))
        record.set("treeSeconds", treeSeconds)
        record.set("treeFilesPerSecond", perSecond(tree.truth.files, treeSeconds))
        record.summary = "identical bytes; measure (1 thread) \(Format.rate(perSecond(tree.truth.files, seconds))), "
            + "tree (8 threads) \(Format.rate(perSecond(tree.truth.files, treeSeconds)))"
        Report.shared.end(record)
    }
}

// MARK: - S3 wide directory

enum WideScenario {
    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S3", "wide directory")
        let root = Fixtures.runRoot + "/wide"
        let folder = root + "/huge"
        FS.makeDir(root)
        FS.makeDir(folder)
        defer { Fixtures.remove(root) }
        let entries = plan.wideEntries
        let chunks = 64
        let truth = Locked(Truth())
        let (_, generation) = Clock.timed {
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var local = Truth()
                for index in stride(from: chunk, to: entries, by: chunks) {
                    if index % 200 == 199 {
                        let sub = folder + "/folder-\(index)"
                        FS.makeDir(sub)
                        local.bytes += FS.makeFile(sub + "/inside", size: 1 + index % 300, seed: index)
                        local.folders += 1
                    } else {
                        local.bytes += FS.makeFile(folder + "/entry-\(index)", size: index % 10 == 0 ? 1 + index % 900 : 0, seed: index)
                    }
                    local.files += 1
                }
                truth.with { $0.add(local) }
            }
        }
        let expected = truth.value

        let standard = measured { DiskTreeScanner.scan(root) }
        checkTotalsAgainst(standard.value, expected, "S3 default options")
        let huge = standard.value.root.children.first { $0.name == "huge" }
        check(huge != nil, "S3: the wide folder must be listed")
        let limit = DiskTreeOptions().maximumChildren
        check(huge!.children.count <= limit + 1, "S3: \(huge!.children.count) rows exceed maximumChildren \(limit) + 1")
        checkTotals(standard.value.root, "S3 default options")

        var narrow = DiskTreeOptions()
        narrow.minimumListedBytes = 0
        narrow.maximumChildren = 200
        let folded = measured { DiskTreeScanner.scan(folder, options: narrow) }
        checkTotalsAgainst(folded.value, expected, "S3 folded")
        check(folded.value.root.children.count == 201 && folded.value.root.children.last?.kind == .smallerItems,
              "S3: with every entry eligible, exactly 200 rows plus 'Smaller items' are kept (got \(folded.value.root.children.count))")
        checkTotals(folded.value.root, "S3 folded")

        let detail = measured { DiskTreeScanner.scan(folder, options: .detail) }
        checkTotalsAgainst(detail.value, expected, "S3 detail")
        check(detail.value.root.children.count == entries && !detail.value.root.children.contains { $0.kind == .smallerItems },
              "S3: detail must list all \(entries) entries (got \(detail.value.root.children.count))")
        let (json, encodeSeconds) = Clock.timed { (try? encodeJSON(detail.value)) ?? Data() }
        check(!json.isEmpty, "S3: the detail result must encode to JSON")
        let (decoded, decodeSeconds) = Clock.timed { try? JSONDecoder().decode(DiskTreeResult.self, from: json) }
        check(decoded == detail.value, "S3: detail JSON round trip")

        record.seconds = standard.seconds
        record.set("entries", entries)
        record.set("generationSeconds", generation)
        record.set("defaultScanSeconds", standard.seconds)
        record.set("foldedScanSeconds", folded.seconds)
        record.set("detailScanSeconds", detail.seconds)
        record.set("entriesPerSecond", perSecond(entries, standard.seconds))
        record.set("detailFootprintGrowthBytes", detail.growth)
        record.set("detailJSONBytes", json.count)
        record.set("detailEncodeSeconds", encodeSeconds)
        record.set("detailDecodeSeconds", decodeSeconds)
        record.summary = "\(entries) entries in one folder: \(Format.rate(perSecond(entries, standard.seconds))), rows <= 201; "
            + String(format: "detail %.3f s, JSON %@", detail.seconds, Format.mib(Int64(json.count)))
        budget(record, standard.seconds <= Budgets.seconds(30), "a \(entries)-entry folder took \(standard.seconds) s (budget 30 s)")
        Report.shared.end(record)
    }
}

// MARK: - S4 deep nesting

enum DeepScenario {
    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S4", "deep nesting")
        let root = Fixtures.runRoot + "/deep"
        FS.makeDir(root)
        defer { Fixtures.remove(root) }
        // 1-character folder names; the deepest file path stays under PATH_MAX (1024).
        let depth = min(plan.deepLevels, (1_023 - root.utf8.count - "/big".utf8.count) / 2)
        var truth = Truth()
        var path = root
        for _ in 0..<depth {
            path += "/a"
            FS.makeDir(path)
            truth.bytes += FS.makeFile(path + "/f", size: 100)
            truth.files += 1
        }
        // A listed file at the bottom keeps every folder on the chain listed with the default options.
        truth.bytes += FS.makeFile(path + "/big", size: 1_100_000)
        truth.files += 1
        check(path.utf8.count + 4 < Int(PATH_MAX), "S4: fixture path must stay under PATH_MAX")

        let scan = measured { DiskTreeScanner.scan(root) }
        checkTotalsAgainst(scan.value, truth, "S4 default options")
        checkTotals(scan.value.root, "S4 default options")
        let height = treeHeight(scan.value.root)
        // Rows stop at DiskTreeOptions.maximumRowDepth so any tree can leave the worker; totals still count every level.
        let expectedHeight = min(depth + 1, DiskTreeOptions.maximumRowDepth)
        check(height == expectedHeight, "S4: rows must be kept down to the row-depth cap: height \(height), expected \(expectedHeight)")
        for keep in [1, 10, 100] where keep <= depth {
            var options = DiskTreeOptions()
            options.keepDepth = keep
            let shallow = DiskTreeScanner.scan(root, options: options)
            checkTotalsAgainst(shallow, truth, "S4 keepDepth \(keep)")
            check(treeHeight(shallow.root) == keep, "S4: keepDepth \(keep) returned height \(treeHeight(shallow.root))")
        }
        var single = DiskTreeOptions()
        single.threads = 1
        check(DiskTreeScanner.scan(root, options: single) == scan.value, "S4: 1 and 8 threads must agree")
        check(FileSizeCalculator.measure(URL(fileURLWithPath: root)).bytes == truth.bytes, "S4: FileSizeCalculator parity")

        // The disk map moves trees from the worker process as JSON; find the deepest tree that can travel.
        var encodable = true
        do { _ = try encodeJSON(scan.value) } catch { encodable = false }
        var low = 1, high = depth + 1 // low encodes; find the largest keepDepth that does
        if encodable {
            low = depth + 1
        } else {
            while low + 1 < high {
                let middle = (low + high) / 2
                var options = DiskTreeOptions()
                options.keepDepth = middle
                if (try? encodeJSON(DiskTreeScanner.scan(root, options: options))) != nil { low = middle } else { high = middle }
            }
        }
        let worker = DiskMapService.workerReader(root, DiskTreeOptions(), 60)
        var workerOK = false
        if case .success(let fromWorker) = worker {
            workerOK = true
            check(fromWorker == scan.value, "S4: worker and in-process results must match")
        }
        // Formerly a finding (a 255+ level chain failed the whole Storage Map); now a hard requirement.
        check(encodable && workerOK, "S4: a \(depth)-level tree must encode as JSON and come back from a real worker")
        if !encodable || !workerOK {
            finding(record, "deep trees cannot leave the scan worker",
                    "a \(depth)-level folder chain with a 1.1 MB file at the bottom scans correctly in process "
                    + "(\(truth.files) files, height \(height)), but JSONEncoder refuses it (\"Too many nested arrays or dictionaries\": "
                    + "512 containers, and every DiskNode level is an object plus its \"c\" array), so only trees up to \(low) "
                    + "retained levels encode. The real worker (DiskMapService.workerReader -> ScanWorker \"tree\" mode: "
                    + "JSONEncoder().encode throws at ScanWorker.swift:14, caught at :43 -> exit 2) returned "
                    + "\(workerOK ? "success" : "failure"); when that is the data-volume job, DiskMapService.scan "
                    + "(DiskMapService.swift:86) fails the whole map. Trigger: any chain of more than \(low) nested folders "
                    + "ending in >= 1 MiB, or in an unreadable or not-scanned folder (always listed), because "
                    + "DiskTreeOptions.keepDepth defaults to Int.max (DiskTree.swift:85). Suggested fix: fold rows below "
                    + "~250 levels in the worker, or flatten the transport encoding.")
        }

        record.seconds = scan.seconds
        record.set("levels", depth)
        record.set("deepestPathBytes", path.utf8.count + 4)
        record.set("scanSeconds", scan.seconds)
        record.set("treeHeight", height)
        record.set("jsonEncodable", encodable)
        record.set("maxEncodableDepth", low)
        record.set("workerSucceeded", workerOK)
        record.summary = String(format: "%d levels in %.4f s, keepDepth honoured; JSON %@ (max %d levels), worker %@",
                                depth, scan.seconds, encodable ? "ok" : "FAILS", low, workerOK ? "ok" : "FAILS")
        budget(record, scan.seconds <= Budgets.seconds(10), "a \(depth)-level chain took \(scan.seconds) s (budget 10 s)")
        Report.shared.end(record)
    }
}

// MARK: - S5 clones and hard links

enum CloneScenario {
    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S5", "clones and hard links")
        let root = Fixtures.runRoot + "/clones"
        let plain = root + "/plain", modified = root + "/modified"
        for path in [root, plain, modified] { FS.makeDir(path) }
        defer { Fixtures.remove(root) }
        let groups = 32
        for base in [plain, modified] {
            for kind in ["orig", "clones", "links"] {
                FS.makeDir(base + "/" + kind)
                for group in 0..<groups { FS.makeDir(base + "/\(kind)/g\(group)") }
            }
        }
        let originals = plan.cloneOriginals, clones = plan.clonesPerFile
        let modifiedCount = max(10, originals / 10)
        struct Made { var paths: [String] = []; var unique: Int64 = 0; var logical: Int64 = 0; var links = 0 }
        let made = Locked([Made(), Made()])
        let (_, generation) = Clock.timed {
            DispatchQueue.concurrentPerform(iterations: groups * 2) { unit in
                let isModified = unit >= groups
                let group = unit % groups
                let base = isModified ? modified : plain
                var local = Made()
                for index in stride(from: group, to: isModified ? modifiedCount : originals, by: groups) {
                    let size = 16_384 + (index % 13) * 4_096 + (index % 3 == 0 ? 123 : 0)
                    let original = base + "/orig/g\(group)/o\(index)"
                    local.unique += FS.makeFile(original, size: size, seed: index &* 7_919)
                    local.paths.append(original)
                    for copy in 0..<clones {
                        let clone = base + "/clones/g\(group)/o\(index)-c\(copy)"
                        FS.clone(original, clone)
                        local.paths.append(clone)
                    }
                    if index % 4 == 0 {
                        let hardLink = base + "/links/g\(group)/o\(index)-hl"
                        FS.hardLink(original, hardLink)
                        local.paths.append(hardLink)
                        local.links += 1
                    }
                    if index % 10 == 0 {
                        let cloneLink = base + "/links/g\(group)/o\(index)-c0-hl"
                        FS.hardLink(base + "/clones/g\(group)/o\(index)-c0", cloneLink)
                        local.paths.append(cloneLink)
                        local.links += 1
                    }
                    if isModified { FS.patch(base + "/clones/g\(group)/o\(index)-c1", at: 8_192, [0x5A, 0xA5]) }
                    local.logical += Int64(size) * Int64(1 + clones + (index % 4 == 0 ? 1 : 0) + (index % 10 == 0 ? 1 : 0))
                }
                made.with {
                    $0[isModified ? 1 : 0].paths += local.paths
                    $0[isModified ? 1 : 0].unique += local.unique
                    $0[isModified ? 1 : 0].logical += local.logical
                    $0[isModified ? 1 : 0].links += local.links
                }
            }
        }
        let plainMade = made.value[0], modifiedMade = made.value[1]
        // Ground truth per path, read after every clone and link exists.
        func attributed(_ paths: [String]) -> (bytes: Int64, uncertain: Int64) {
            paths.reduce((Int64(0), Int64(0))) { total, path in
                guard let item = FileAttributes.read(path: path) else { fail("S5: cannot read \(path)") }
                return (total.0 + item.attributedBytes, total.1 + item.uncertainBytes)
            }
        }
        let plainTruth = attributed(plainMade.paths)
        let modifiedTruth = attributed(modifiedMade.paths)

        let scan = measured { DiskTreeScanner.scan(plain) }
        let plainRoot = scan.value.root
        check(plainRoot.files == plainMade.paths.count, "S5: \(plainRoot.files) files, \(plainMade.paths.count) paths were created")
        check(plainRoot.bytes == plainTruth.bytes, "S5: clone-aware total \(plainRoot.bytes) != sum of per-path shares \(plainTruth.bytes)")
        check(plainRoot.bytes <= plainMade.unique,
              "S5: clones or hard links were double counted: \(plainRoot.bytes) > unique allocation \(plainMade.unique)")
        check(plainMade.unique - plainRoot.bytes <= Int64(originals) * 4_096,
              "S5: total \(plainRoot.bytes) is not within one block per file of the unique allocation \(plainMade.unique)")
        check(plainRoot.uncertainBytes == 0, "S5: unmodified clones carry no uncertain bytes")

        let changed = DiskTreeScanner.scan(modified).root
        check(changed.files == modifiedMade.paths.count && changed.bytes == modifiedTruth.bytes
              && changed.uncertainBytes == modifiedTruth.uncertain && changed.uncertainBytes > 0,
              "S5: modified clones: files \(changed.files)/\(modifiedMade.paths.count), bytes \(changed.bytes)/\(modifiedTruth.bytes), "
              + "uncertain \(changed.uncertainBytes)/\(modifiedTruth.uncertain)")
        let whole = DiskTreeScanner.scan(root).root
        check(whole.bytes == plainRoot.bytes + changed.bytes, "S5: the parent must add both parts")
        check(FileSizeCalculator.measure(URL(fileURLWithPath: root)).bytes == whole.bytes, "S5: FileSizeCalculator parity")

        let paths = plainMade.paths.count
        record.seconds = scan.seconds
        record.set("originals", originals)
        record.set("clonesPerFile", clones)
        record.set("paths", paths)
        record.set("hardLinks", plainMade.links)
        record.set("generationSeconds", generation)
        record.set("uniqueAllocatedBytes", plainMade.unique)
        record.set("attributedBytes", plainRoot.bytes)
        record.set("logicalBytes", plainMade.logical)
        record.set("roundingLossBytes", plainMade.unique - plainRoot.bytes)
        record.set("modifiedUncertainBytes", changed.uncertainBytes)
        record.set("filesPerSecond", perSecond(paths, scan.seconds))
        record.summary = "\(paths) paths share \(Format.mib(plainMade.unique)) (logical \(Format.mib(plainMade.logical))): counted "
            + "\(Format.mib(plainRoot.bytes)), loss \(plainMade.unique - plainRoot.bytes) B; uncertain \(Format.mib(changed.uncertainBytes))"
        Report.shared.end(record)
    }
}

// MARK: - S6 pathological entries

enum PathologicalScenario {
    static let nfc = "caf\u{00E9}"
    static let nfd = "cafe\u{0301}"
    static let names = ["name with spaces.txt", "line\nbreak.txt", "emoji-\u{1F600}\u{1F680}.bin", "a:b", "-rf", ".hidden", "...",
                        String(repeating: "x", count: 251) + ".txt", String(repeating: "\u{20AC}", count: 85)]

    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S6", "pathological entries")
        let root = Fixtures.runRoot + "/patho"
        FS.makeDir(root)
        defer { Fixtures.remove(root) }
        check(names.allSatisfy { $0.utf8.count <= 255 } && names.contains { $0.utf8.count == 255 }, "S6: 255-byte names")
        let truth = Locked(Truth())
        let sets = plan.pathoSets
        let (_, generation) = Clock.timed {
            DispatchQueue.concurrentPerform(iterations: 32) { chunk in
                var local = Truth()
                for index in stride(from: chunk, to: sets, by: 32) {
                    let folder = root + "/s\(index)"
                    FS.makeDir(folder)
                    for (offset, name) in names.enumerated() {
                        local.bytes += FS.makeFile(folder + "/" + name, size: 10 + offset, seed: index)
                        local.files += 1
                    }
                    for (form, name) in [("nfc", nfc), ("nfd", nfd)] {
                        FS.makeDir(folder + "/" + form)
                        local.bytes += FS.makeFile(folder + "/\(form)/" + name, size: 3_000, seed: index)
                        local.files += 1
                    }
                    check(mkfifo(folder + "/pipe", 0o644) == 0, "mkfifo: \(errorText())")
                    FS.symbolicLink("does-not-exist", at: folder + "/dangling")
                    FS.symbolicLink("loop-b", at: folder + "/loop-a")
                    FS.symbolicLink("loop-a", at: folder + "/loop-b")
                    FS.symbolicLink("/", at: folder + "/root-link")
                    FS.symbolicLink(".", at: folder + "/self-link")
                    FS.symbolicLink("..", at: folder + "/parent-link")
                    FS.symbolicLink(root, at: folder + "/fixture-link")
                }
                truth.with { $0.add(local) }
            }
            // Sockets one by one: a long path binds relative to a briefly changed working folder.
            for index in 0..<sets { FS.makeSocket(root + "/s\(index)/sock") }
        }
        let expected = truth.value

        let scan = measured { DiskTreeScanner.scan(root) }
        checkTotalsAgainst(scan.value, expected, "S6 pathological entries (links never followed, FIFOs and sockets not counted)")
        checkTotals(scan.value.root, "S6")
        check(FileSizeCalculator.measure(URL(fileURLWithPath: root)).bytes == expected.bytes, "S6: FileSizeCalculator parity")
        let rootLink = DiskTreeScanner.scan(root + "/s0/root-link")
        check(rootLink.root.bytes == 0 && rootLink.root.files == 0 && !rootLink.incomplete, "S6: a symlink to / is never followed")

        // Names come back byte for byte: newline, emoji, 255-byte names, and both Unicode forms.
        let detail = DiskTreeScanner.scan(root + "/s0", options: .detail)
        let listed = Set(detail.root.children.map { Array($0.name.utf8) })
        for name in names { check(listed.contains(Array(name.utf8)), "S6: name \(name.debugDescription) missing or altered") }
        for (form, name) in [("nfc", nfc), ("nfd", nfd)] {
            let inner = DiskTreeScanner.scan(root + "/s0/" + form, options: .detail).root.children.map { Array($0.name.utf8) }
            check(inner == [Array(name.utf8)], "S6: \(form) name must keep its exact UTF-8 bytes, got \(inner)")
        }

        let entries = sets * (names.count + 2 + 2 + 1 + 1 + 7)
        record.seconds = scan.seconds
        record.set("sets", sets)
        record.set("entries", entries)
        record.set("regularFiles", expected.files)
        record.set("specialFiles", sets * 2)
        record.set("symlinks", sets * 7)
        record.set("generationSeconds", generation)
        record.set("scanSeconds", scan.seconds)
        record.set("entriesPerSecond", perSecond(entries, scan.seconds))
        record.summary = "\(entries) entries (\(sets * 7) links incl. / and loops, \(sets * 2) FIFOs/sockets): "
            + String(format: "%.3f s, exact names and totals", scan.seconds)
        budget(record, scan.seconds <= Budgets.seconds(10), "pathological entries took \(scan.seconds) s (budget 10 s)")
        Report.shared.end(record)
    }
}

// MARK: - S7 permission-denied subtrees under load

enum PermissionScenario {
    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S7", "denied folders under load")
        guard geteuid() != 0 else {
            Log.line("   NOTICE: running as root, which reads chmod 000 folders; scenario skipped")
            record.status = "skipped"
            record.summary = "skipped (root)"
            Report.shared.end(record)
            return
        }
        let root = Fixtures.runRoot + "/perm"
        let tree = generateTree(at: root, files: plan.permFiles, folders: plan.permFolders, tops: plan.tops, seed: 0x9E4)
        defer { Fixtures.remove(root) }
        var lockedPaths: [String] = []
        var hiddenFiles = 0
        for index in 0..<plan.lockedFolders {
            let top = tree.tops[index % tree.tops.count]
            let mid = (index / tree.tops.count) % tree.mids
            let parent = index % 2 == 1 && tree.leaves > 0 ? "\(top)/d\(mid)/e0" : "\(top)/d\(mid)"
            let locked = parent + "/locked-\(index)"
            FS.makeDir(locked)
            for file in 0..<5 { FS.makeFile(locked + "/secret-\(file)", size: 4_000, seed: file) }
            hiddenFiles += 5
            if index % 3 == 0 {
                let inner = locked + "/inner"
                FS.makeDir(inner)
                FS.makeFile(inner + "/deeper-secret", size: 9_000)
                hiddenFiles += 1
                Fixtures.lock(inner, mode: 0)
            }
            // 0o311 keeps write and search permission but not read: the listing still fails.
            Fixtures.lock(locked, mode: index % 5 == 4 ? 0o311 : 0)
            lockedPaths.append(locked)
        }

        let scan = measured { DiskTreeScanner.scan(root) }
        checkTotalsAgainst(scan.value, tree.truth, "S7 denied folders", unreadable: plan.lockedFolders)
        checkTotals(scan.value.root, "S7")
        if plan.lockedFolders <= 50 {
            check(scan.value.unreadablePaths == lockedPaths.sorted(),
                  "S7: unreadablePaths must list exactly the locked folders, got \(scan.value.unreadablePaths.count)")
        }
        for threads in [1, 16] {
            var options = DiskTreeOptions()
            options.threads = threads
            check(DiskTreeScanner.scan(root, options: options) == scan.value, "S7: \(threads) threads must give the same result")
        }
        let measurement = FileSizeCalculator.measure(URL(fileURLWithPath: root))
        check(measurement.bytes == tree.truth.bytes && measurement.unreadableFolders == plan.lockedFolders,
              "S7: FileSizeCalculator bytes \(measurement.bytes)/\(tree.truth.bytes), unreadable "
              + "\(measurement.unreadableFolders)/\(plan.lockedFolders)")

        record.seconds = scan.seconds
        record.set("files", tree.truth.files)
        record.set("lockedFolders", plan.lockedFolders)
        record.set("hiddenFiles", hiddenFiles)
        record.set("scanSeconds", scan.seconds)
        record.set("filesPerSecond", perSecond(tree.truth.files, scan.seconds))
        record.summary = "\(tree.truth.files) files, \(plan.lockedFolders) locked folders: unreadable exact, "
            + "\(Format.rate(perSecond(tree.truth.files, scan.seconds)))"
        Report.shared.end(record)
    }
}

// MARK: - S12 duplicates under load

final class HashLog {
    var calls: [String] = []
    var firstCall: Double?
}

enum DuplicateScenario {
    static let length = 256 * 1_024
    // FileFingerprint.sample reads 64 KiB at 0, (length - 64 KiB) / 2 and length - 64 KiB.
    static let firstSample = 1_024, middleSample = 128 * 1_024, unsampled = 80 * 1_024, lastSample = 200 * 1_024

    static func marker(_ tag: UInt8, _ index: Int) -> [UInt8] {
        [tag, UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF), UInt8((index >> 16) & 0xFF), 0xEE]
    }

    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S12", "duplicates under load")
        // FileFingerprint refuses paths with a symbolic link in them, and every temporary folder sits below /var or
        // /private (both redirected), so this fixture goes to a unique folder in ~/Library/Caches like the other
        // duplicate checks do.
        let root = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/MacPolish-perf-" + Fixtures.runID
        FS.makeDir(root, mode: 0o700)
        Fixtures.register(root)
        defer { Fixtures.remove(root) }
        let base = root + "/base.bin", scan = root + "/scan"
        FS.makeFile(base, size: length, seed: 0)
        FS.makeDir(scan)
        let chunks = 32
        for chunk in 0..<chunks { FS.makeDir(scan + "/c\(chunk)") }

        struct Made {
            var rejected: Set<String> = []
            var candidates: Set<String> = []
            var groupPaths: [Int: [String]] = [:]
            var groupLinks: [Int: String] = [:]
        }
        let made = Locked(Made())
        let groups = plan.dupGroups, pairs = plan.dupLinkPairs
        // DuplicateScanner used to keep every byte it read until it returned. Reads are now drained per chunk (checked
        // below); the cap stays so a regression cannot swamp the machine before the check catches it.
        let fraction = Settings.double("MACPOLISH_PERF_DUP_MEMORY_FRACTION", 1.0)
        let readPerFile = Double(3 * 65_536) + Double(length) / 3
        let allowance = fraction * Double(ProcessInfo.processInfo.physicalMemory)
        var files = plan.dupFiles
        if Double(files) * readPerFile > allowance {
            files = max(3_000, Int(allowance / readPerFile))
            Log.line("   NOTICE: \(plan.dupFiles) same-length files read about "
                     + "\(Format.mib(Int64(Double(plan.dupFiles) * readPerFile))); capped at \(files) files, "
                     + "\(Int(fraction * 100))% of RAM (MACPOLISH_PERF_DUP_MEMORY_FRACTION), in case a regression holds what it reads")
        }
        let (_, generation) = Clock.timed {
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var local = Made()
                // Same length, different content: in the first sample, in the middle sample, or only in an unsampled byte.
                for index in stride(from: chunk, to: files, by: chunks) {
                    let path = scan + "/c\(chunk)/file-\(index)"
                    FS.clone(base, path)
                    switch index % 3 {
                    case 0: FS.patch(path, at: firstSample, marker(0xA1, index)); local.rejected.insert(path)
                    case 1: FS.patch(path, at: middleSample, marker(0xB2, index)); local.rejected.insert(path)
                    default: FS.patch(path, at: unsampled, marker(0xC3, index)); local.candidates.insert(path)
                    }
                }
                // True duplicate groups: clones of one modified file, or independent written copies.
                for group in stride(from: chunk, to: groups, by: chunks) {
                    let members = 2 + group % 2
                    var paths: [String] = []
                    for member in 0..<members {
                        let path = scan + "/c\((group + member * 7) % chunks)/group-\(group)-\(member)"
                        if member == 0 || group % 2 == 1 {
                            if group % 2 == 1 {
                                FS.makeFile(path, size: length, seed: 0)
                            } else {
                                FS.clone(base, path)
                            }
                            FS.patch(path, at: lastSample, marker(0xD4, group))
                        } else {
                            FS.clone(paths[0], path)
                        }
                        paths.append(path)
                    }
                    if group % 5 == 0 {
                        let hardLink = scan + "/c\((group + 3) % chunks)/group-\(group)-hardlink"
                        FS.hardLink(paths[0], hardLink)
                        local.groupLinks[group] = hardLink
                    }
                    local.groupPaths[group] = paths
                    local.candidates.formUnion(paths)
                }
                // A file and its hard link only: one file, never a duplicate.
                for pair in stride(from: chunk, to: pairs, by: chunks) {
                    let path = scan + "/c\(chunk)/solo-\(pair)"
                    FS.clone(base, path)
                    FS.patch(path, at: firstSample + 64, marker(0xE5, pair))
                    FS.hardLink(path, scan + "/c\((chunk + 1) % chunks)/solo-\(pair)-hardlink")
                    local.rejected.insert(path)
                    local.rejected.insert(scan + "/c\((chunk + 1) % chunks)/solo-\(pair)-hardlink")
                }
                made.with {
                    $0.rejected.formUnion(local.rejected)
                    $0.candidates.formUnion(local.candidates)
                    $0.groupPaths.merge(local.groupPaths) { first, _ in first }
                    $0.groupLinks.merge(local.groupLinks) { first, _ in first }
                }
            }
        }
        let fixture = made.value
        let expectedGroups = Set(fixture.groupPaths.values.map { Set($0.map(FS.inode)) })
        let groupMembers = fixture.groupPaths.values.reduce(0) { $0 + $1.count }
        let uncertainOnly = fixture.candidates.count - groupMembers
        let expectedHashes = uncertainOnly + groupMembers
        let allowedHashes = fixture.candidates.union(fixture.groupLinks.values)
        let totalPaths = files + groupMembers + fixture.groupLinks.count + pairs * 2

        // Evidence for the memory finding: the same sample reads with and without a pool per file.
        let probe = fixture.candidates.sorted().prefix(600).map { URL(fileURLWithPath: $0) }
        let unpooled = measured { autoreleasepool { for url in probe { _ = try? FileFingerprint.sample(url, length: Int64(length)) } } }
        let pooled = measured { for url in probe { autoreleasepool { _ = try? FileFingerprint.sample(url, length: Int64(length)) } } }

        let log = HashLog()
        let started = Clock.now()
        // The pool around the call releases what the scanner kept once it returns; the peak inside is the engine's.
        let full = measured {
            autoreleasepool {
                DuplicateScanner().report(minimumSize: 1, roots: [URL(fileURLWithPath: scan)]) { url in
                    if log.firstCall == nil { log.firstCall = Clock.now() - started }
                    log.calls.append(url.path)
                    return try FileFingerprint.sha256(url)
                }
            }
        }
        let report = full.value
        check(!report.incomplete && report.deniedPaths.isEmpty, "S12: an unlimited scan must be complete with no denied paths")
        let reportedInodes = report.items.map { FS.inode($0.url.path) }
        check(Set(reportedInodes).count == reportedInodes.count, "S12: a hard link was reported as a separate duplicate")
        let found = Set(Dictionary(grouping: report.items, by: \.fingerprint).values.map { Set($0.map { FS.inode($0.url.path) }) })
        check(found == expectedGroups, "S12: found \(found.count) duplicate groups, expected exactly \(expectedGroups.count); "
              + "missing \(expectedGroups.subtracting(found).count), unexpected \(found.subtracting(expectedGroups).count)")
        check(Set(log.calls).count == log.calls.count, "S12: a file was fully hashed more than once")
        let wronglyHashed = log.calls.filter { fixture.rejected.contains($0) }
        check(wronglyHashed.isEmpty, "S12: \(wronglyHashed.count) files whose samples differ were fully hashed, e.g. \(wronglyHashed.prefix(2))")
        check(log.calls.allSatisfy { allowedHashes.contains($0) }, "S12: a file outside the sample-sharing candidates was hashed")
        check(log.calls.count == expectedHashes,
              "S12: \(log.calls.count) full hashes, expected exactly \(expectedHashes) (files sharing samples)")

        // A tight deadline in the hashing phase: only verified groups come back, marked incomplete. A quarter of the
        // folders keeps this short; the deadline lands after their sampling phase (scaled from the full run), and the
        // slowed full hashes make sure it is reached while hashing.
        let subset = (0..<(chunks / 4)).map { URL(fileURLWithPath: scan + "/c\($0)") }
        let slowStart = Clock.now()
        let hashPhase = log.firstCall ?? full.seconds
        let limit = hashPhase * 0.25 * 1.3 + 0.15
        let deadline = Date(timeIntervalSinceNow: limit)
        let partial = autoreleasepool {
            DuplicateScanner().report(minimumSize: 1, roots: subset, deadline: deadline) { url in
                usleep(1_000)
                return try FileFingerprint.sha256(url)
            }
        }
        let partialSeconds = Clock.now() - slowStart
        check(partial.incomplete, "S12: a deadline reached while hashing must mark the result incomplete")
        check(partialSeconds <= limit + Budgets.deadlineSlack,
              "S12: the duplicate scan returned \(partialSeconds) s after start with a \(limit) s deadline")
        let partialGroups = Dictionary(grouping: partial.items, by: \.fingerprint)
        for (fingerprint, members) in partialGroups {
            let inodes = Set(members.map { FS.inode($0.url.path) })
            check(members.count >= 2 && inodes.count == members.count && expectedGroups.contains { inodes.isSubset(of: $0) },
                  "S12: a partial result reported an unverified group \(members.map(\.url.lastPathComponent))")
            if let first = members.first { check((try? FileFingerprint.sha256(first.url)) == fingerprint, "S12: fingerprint mismatch") }
        }

        let sampledBytes = Int64(totalPaths - fixture.groupLinks.count - pairs) * 3 * 65_536
        let bytesRead = sampledBytes + Int64(log.calls.count) * Int64(length)
        // Formerly a finding (+4.6 GB footprint for 4.7 GB read); reads must now be released as they are hashed.
        check(full.growth < max(256 << 20, bytesRead / 10),
              "S12: the duplicate scan footprint grew \(Format.mib(full.growth)) while reading \(Format.mib(bytesRead)); "
              + "FileFingerprint reads must be drained per chunk")
        if full.growth >= 128 << 20 && Double(full.growth) >= 0.5 * Double(bytesRead) {
            finding(record, "duplicate scan memory grows with every byte it reads",
                    "DuplicateScanner.report over \(totalPaths) same-length files grew the footprint by \(Format.mib(full.growth)) "
                    + "while reading \(Format.mib(bytesRead)) (samples + \(log.calls.count) full hashes); nothing is released "
                    + "until the call returns. FileHandle.read(upToCount:) returns autoreleased Data, and FileFingerprint.sample "
                    + "(DuplicateCleaner.swift:23) and FileFingerprint.sha256 (DuplicateCleaner.swift:40) read in loops with no "
                    + "autoreleasepool, nor does DuplicateScanner.report (AdvancedScanners.swift:159-178). Same 600 samples: "
                    + "+\(Format.mib(unpooled.growth)) in \(String(format: "%.3f", unpooled.seconds)) s without a pool per file, "
                    + "+\(Format.mib(pooled.growth)) in \(String(format: "%.3f", pooled.seconds)) s with one. ScanWorker "
                    + "\"duplicates\" (ScanWorker.swift:28) runs report on the main thread with no drain, so the worker holds "
                    + "everything it read for up to 50 s: about 6 GB for 20k same-size 256 KiB files. Suggested fix: "
                    + "autoreleasepool per file (or per chunk) in sample/sha256, or read(2) into a reused buffer.")
        }
        record.seconds = full.seconds
        record.set("requestedSameLengthFiles", plan.dupFiles)
        record.set("sameLengthFiles", files)
        record.set("duplicateGroups", groups)
        record.set("hardLinkPairs", pairs)
        record.set("paths", totalPaths)
        record.set("generationSeconds", generation)
        record.set("scanSeconds", full.seconds)
        record.set("filesPerSecond", perSecond(totalPaths, full.seconds))
        record.set("fullHashes", log.calls.count)
        record.set("sampledBytesApprox", sampledBytes)
        record.set("hashPhaseStartSeconds", hashPhase)
        record.set("deadlineSeconds", limit)
        record.set("deadlineReturnedSeconds", partialSeconds)
        record.set("deadlineVerifiedGroups", partialGroups.count)
        record.set("footprintGrowthBytes", full.growth)
        record.set("bytesRead", bytesRead)
        record.set("sampleProbeGrowthWithoutPoolBytes", unpooled.growth)
        record.set("sampleProbeGrowthWithPoolBytes", pooled.growth)
        record.set("sampleProbeSecondsWithoutPool", unpooled.seconds)
        record.set("sampleProbeSecondsWithPool", pooled.seconds)
        record.summary = "\(totalPaths) paths: \(expectedGroups.count) groups exact, \(log.calls.count) full hashes (= bound), "
            + "\(Format.rate(perSecond(totalPaths, full.seconds))), mem +\(Format.mib(full.growth)); deadline: "
            + "\(partialGroups.count) verified groups"
        budget(record, full.seconds <= Budgets.seconds(180), "duplicate scan took \(full.seconds) s (budget 180 s)")
        Report.shared.end(record)
    }
}

// MARK: - S13 section scanners on a fake home

enum SectionScenario {
    static func run(_ plan: Plan) {
        let record = Report.shared.begin("S13", "section scanners")
        let root = Fixtures.runRoot + "/home-fixture"
        let home = root + "/home", applications = root + "/Applications"
        defer { Fixtures.remove(root) }
        for path in [root, home, applications, home + "/Library", home + "/Library/Caches", home + "/Library/Logs",
                     home + "/Library/Logs/DiagnosticReports", home + "/.Trash", home + "/Downloads", home + "/Documents",
                     home + "/Desktop", home + "/Library/Developer", home + "/Library/Developer/Xcode",
                     home + "/Library/Developer/Xcode/DerivedData", home + "/Library/Developer/Xcode/Archives",
                     home + "/Library/Developer/Xcode/iOS DeviceSupport", home + "/Library/Developer/CoreSimulator",
                     home + "/Library/Developer/CoreSimulator/Caches"] {
            FS.makeDir(path)
        }
        let mib = 1 << 20
        var expected: [DiskScanner.Section: (count: Int, bytes: Int64?)] = [:]

        // Caches: many folders measured one by one.
        let caches = home + "/Library/Caches"
        let cacheBytes = Locked(Int64(0))
        DispatchQueue.concurrentPerform(iterations: 32) { chunk in
            var local: Int64 = 0
            for index in stride(from: chunk, to: plan.cacheFolders, by: 32) {
                let folder = caches + "/com.example.app\(index)"
                FS.makeDir(folder)
                local += FS.makeFile(folder + "/data.bin", size: 1 + index % 300, seed: index)
                local += FS.makeFile(folder + "/empty", size: 0)
                if index % 50 == 0 {
                    FS.makeDir(folder + "/nested")
                    local += FS.makeFile(folder + "/nested/blob", size: 20_000, seed: index)
                }
            }
            cacheBytes.with { $0 += local }
        }
        for (name, count) in [("com.apple.dt.Xcode", 3), ("org.swift.swiftpm", 2)] {
            FS.makeDir(caches + "/" + name)
            for index in 0..<count {
                FS.makeDir(caches + "/\(name)/item\(index)")
                FS.makeFile(caches + "/\(name)/item\(index)/payload", size: 9_000, seed: index)
            }
        }
        FS.symbolicLink("/", at: caches + "/link-to-root")
        expected[.caches] = (plan.cacheFolders, cacheBytes.value)

        // Logs, with aged diagnostic reports that belong to "Old files".
        var logBytes: Int64 = 0
        for index in 0..<200 { logBytes += FS.makeFile(home + "/Library/Logs/app\(index).log", size: 1_000, seed: index) }
        for index in 0..<50 {
            let path = home + "/Library/Logs/DiagnosticReports/crash\(index).ips"
            FS.makeFile(path, size: 2_000, seed: index)
            FS.setModified(path, daysAgo: 60)
        }
        expected[.logs] = (200, logBytes)

        // Trash: files and folders.
        var trashBytes: Int64 = 0
        for index in 0..<300 {
            if index % 3 == 0 {
                let folder = home + "/.Trash/folder\(index)"
                FS.makeDir(folder)
                trashBytes += FS.makeFile(folder + "/a", size: 3_000, seed: index)
                trashBytes += FS.makeFile(folder + "/b", size: 5_000, seed: index)
            } else {
                trashBytes += FS.makeFile(home + "/.Trash/item\(index)", size: 5_000, seed: index)
            }
        }
        expected[.trash] = (300, trashBytes)

        // Developer files: aged DerivedData, archives, device support, simulator caches, Xcode/SwiftPM caches.
        let xcode = home + "/Library/Developer/Xcode"
        func agedFolders(_ parent: String, _ prefix: String, count: Int, daysAgo: Double) {
            for index in 0..<count {
                let folder = parent + "/\(prefix)\(index)"
                FS.makeDir(folder)
                for file in 0..<3 { FS.makeFile(folder + "/file\(file)", size: 6_000, seed: file) }
                FS.setModified(folder, daysAgo: daysAgo)
            }
        }
        agedFolders(xcode + "/DerivedData", "Project-old-", count: 20, daysAgo: 60)
        agedFolders(xcode + "/DerivedData", "Project-new-", count: 5, daysAgo: 1)
        agedFolders(xcode + "/Archives", "Archive-", count: 4, daysAgo: 200)
        agedFolders(xcode + "/iOS DeviceSupport", "17.", count: 2, daysAgo: 200)
        agedFolders(home + "/Library/Developer/CoreSimulator/Caches", "sim-", count: 10, daysAgo: 0)
        expected[.developer] = (20 + 4 + 2 + 10 + 5, nil)

        // Downloads: many small files, real large files, sparse files that must not look large, Xcode installers,
        // a hidden large file (listed), a hidden folder (not entered) and an app package (measured as one item).
        let downloads = home + "/Downloads"
        var largeNames: Set<String> = []
        for index in 0..<plan.downloadFiles {
            FS.makeFile(downloads + "/download-\(index).dat", size: index % 4 == 0 ? 0 : 100 + index % 8_000, seed: index)
        }
        for index in 0..<10 {
            FS.makeFile(downloads + "/large-\(index).zip", size: 3 * mib / 2, seed: index)
            largeNames.insert("large-\(index).zip")
            FS.makeSparse(downloads + "/sparse-\(index).img", logicalSize: 4 << 30)
        }
        for index in 0..<3 {
            let path = downloads + "/Xcode_16.\(index).xip"
            FS.makeFile(path, size: 8_000, seed: index)
            FS.setModified(path, daysAgo: 60)
        }
        FS.makeFile(downloads + "/.hidden-large.bin", size: 3 * mib / 2, seed: 5)
        largeNames.insert(".hidden-large.bin")
        FS.makeDir(downloads + "/.git")
        FS.makeFile(downloads + "/.git/pack.bin", size: 3 * mib / 2, seed: 6)
        FS.makeDir(downloads + "/Thing.app")
        FS.makeDir(downloads + "/Thing.app/Contents")
        FS.makeFile(downloads + "/Thing.app/Contents/payload", size: 3 * mib / 2, seed: 7)
        largeNames.insert("Thing.app")
        expected[.downloads] = (largeNames.count, nil)
        expected[.xcodeInstallers] = (3, nil)

        for index in 0..<100 { FS.makeFile(home + "/Documents/note\(index).txt", size: 2_000, seed: index) }
        for index in 0..<2 { FS.makeFile(home + "/Documents/movie\(index).mov", size: 3 * mib / 2, seed: index) }
        expected[.documents] = (2, nil)
        for index in 0..<50 { FS.makeFile(home + "/Desktop/shot\(index).png", size: 2_000, seed: index) }
        FS.makeFile(home + "/Desktop/video.mov", size: 3 * mib / 2, seed: 9)
        expected[.desktop] = (1, nil)

        // Old files: aged diagnostic reports plus a macOS installer in the applications folder.
        FS.makeDir(applications + "/Install macOS Fixture.app")
        FS.makeFile(applications + "/Install macOS Fixture.app/payload", size: 8_000)
        expected[.oldFiles] = (50 + 1, nil)

        let scanner = DiskScanner(home: URL(fileURLWithPath: home), applicationsRoot: URL(fileURLWithPath: applications),
                                  largeFileMinimum: Int64(mib))
        var total = 0.0
        var parts: [String] = []
        for section in DiskScanner.Section.allCases {
            let (report, seconds) = Clock.timed { scanner.report(section: section) }
            total += seconds
            guard let want = expected[section] else { fail("S13: no expectation for \(section)") }
            check(report.deniedPaths.isEmpty, "S13: \(section) reported denied paths \(report.deniedPaths)")
            check(report.items.count == want.count,
                  "S13: \(section) found \(report.items.count) items, expected \(want.count): \(report.items.map(\.url.lastPathComponent).prefix(8))")
            if let bytes = want.bytes {
                let sum = report.items.reduce(Int64(0)) { $0 + $1.size }
                check(sum == bytes, "S13: \(section) sizes add up to \(sum), generated \(bytes)")
            }
            if section == .downloads {
                check(Set(report.items.map(\.url.lastPathComponent)) == largeNames,
                      "S13: large files must be the real large files, the hidden one and the package; sparse files never "
                      + "(got \(report.items.map(\.url.lastPathComponent).sorted()))")
            }
            if section == .caches {
                check(!report.items.contains { ["com.apple.dt.Xcode", "org.swift.swiftpm"].contains($0.url.lastPathComponent) },
                      "S13: Xcode and SwiftPM caches belong to the developer section")
            }
            record.set("\(section.rawValue)Seconds", seconds)
            record.set("\(section.rawValue)Items", report.items.count)
            parts.append(String(format: "%@ %.3f", section.rawValue, seconds))
        }
        record.seconds = total
        record.set("cacheFolders", plan.cacheFolders)
        record.set("downloadFiles", plan.downloadFiles)
        record.summary = "\(plan.cacheFolders) caches, \(plan.downloadFiles) downloads; s: " + parts.joined(separator: ", ")
        budget(record, total <= Budgets.seconds(120), "all sections took \(total) s (budget 120 s)")
        Report.shared.end(record)
    }
}

// MARK: - S14 optional real-device benchmark (read-only)

enum RealDiskScenario {
    static func run() {
        let record = Report.shared.begin("S14", "real data volume")
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Like DiskMapE2E: skip the folders that can raise macOS privacy prompts (they get their own workers in the app).
        let protected = DiskMapService.protectedFolders(home: home).map { DiskMapService.dataPath(for: $0) }
        let scan = measured {
            DiskMapService.inProcessReader(DiskMapService.dataRoot, DiskTreeOptions(excluded: protected), 120)
        }
        guard case .success(let result) = scan.value else { fail("S14: the data volume could not be read") }
        var volume = statfs()
        check(statfs(DiskMapService.dataRoot, &volume) == 0, "S14: statfs \(DiskMapService.dataRoot)")
        let used = (Int64(volume.f_blocks) - Int64(volume.f_bfree)) * Int64(volume.f_bsize)
        let root = result.root
        let coverage = used > 0 ? Double(root.bytes) / Double(used) : 0
        check(root.files > 0 && root.bytes > 0, "S14: the data volume scan must find files")
        check(root.bytes <= used + root.uncertainBytes + used / 100,
              "S14: found \(Format.mib(root.bytes)) cannot exceed the used \(Format.mib(used)) beyond shared clones")
        checkTotals(root, "S14 real volume")
        record.seconds = scan.seconds
        record.set("files", root.files)
        record.set("bytes", root.bytes)
        record.set("usedBytesStatfs", used)
        record.set("coverage", coverage)
        record.set("filesPerSecond", perSecond(root.files, scan.seconds))
        record.set("unreadableFolders", root.unreadable)
        record.set("notScannedFolders", root.notScanned)
        record.set("incomplete", result.incomplete)
        record.set("footprintGrowthBytes", scan.growth)
        record.summary = String(format: "%d files, %@ in %.1f s (%@), %.0f%% of statfs used, %d unreadable%@",
                                root.files, Format.mib(root.bytes), scan.seconds, Format.rate(perSecond(root.files, scan.seconds)),
                                coverage * 100, root.unreadable, result.incomplete ? ", hit the 120 s deadline" : "")
        Report.shared.end(record)
    }
}
