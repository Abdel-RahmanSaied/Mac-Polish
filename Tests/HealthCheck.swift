import Foundation

/// A value shared with fake system closures (which may run on any thread).
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func next(_ transform: (inout Value) -> Void) { lock.withLock { transform(&stored) } }
}

/// Commands whose path is in `paths` block while the gate is active, until `open()`; they ignore cancellation on
/// purpose, like a stuck tool.
final class Gate: @unchecked Sendable {
    let paths: Set<String>
    private let lock = NSLock()
    private var active = true
    private var opened = false
    private var blockedCount = 0
    init(_ paths: Set<String>) { self.paths = paths }
    func deactivate() { lock.withLock { active = false } }
    func open() { lock.withLock { opened = true } }
    var blocked: Int { lock.withLock { blockedCount } }
    func pass(_ path: String) {
        let blocks = lock.withLock { () -> Bool in
            guard active && paths.contains(path) else { return false }
            blockedCount += 1
            return true
        }
        guard blocks else { return }
        while !lock.withLock({ opened }) { usleep(5_000) }
        lock.withLock { blockedCount -= 1 }
    }
}

/// Everything a fake `HealthSystem` returns. Defaults describe a Mac where every reading is fine.
struct Fake: @unchecked Sendable {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let gb: Int64 = 1_000_000_000

    static let appleSilicon: [String: Any] = [
        "CycleCount": 28, "DesignCycleCount9C": 1000, "MaxCapacity": 100, "CurrentCapacity": 35,
        "IsCharging": false, "ExternalConnected": false, "FullyCharged": false,
        "BatteryData": ["DesignCapacity": 4629, "AppleRawMaxCapacity": 4649, "NominalChargeCapacity": 4776,
                        "MaxCapacity": 100, "CurrentCapacity": 35] as [String: Any],
    ]

    static func plist(_ dictionary: [String: Any]) -> String {
        String(decoding: try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0), as: UTF8.self)
    }

    static func disk(_ id: String, smart: String?, name: String = "APPLE SSD AP0512Z", isInternal: Bool = true) -> String {
        var info: [String: Any] = ["DeviceIdentifier": id, "MediaName": name, "Internal": isInternal, "SolidState": true, "BusProtocol": "Apple Fabric"]
        if let smart { info["SMARTStatus"] = smart }
        return plist(info)
    }

    static let defaultOutputs: [String: (String, Int32)] = [
        "/usr/bin/csrutil status": ("System Integrity Protection status: enabled.\n", 0),
        "/usr/sbin/spctl --status": ("assessments enabled\n", 0),
        "/usr/bin/fdesetup status": ("FileVault is On.\n", 0),
        "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": ("Firewall is enabled. (State = 1)\n", 0),
        "/usr/sbin/diskutil info -plist /": (plist(["APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]], "ParentWholeDisk": "disk3",
                                                    "SMARTStatus": "Verified", "MediaName": ""]), 0),
        "/usr/sbin/diskutil info -plist disk0": (disk("disk0", smart: "Verified"), 0),
        "/usr/sbin/diskutil list -plist physical": (plist(["WholeDisks": ["disk0"]]), 0),
        "/usr/sbin/softwareupdate -l --no-scan": ("Software Update Tool\n\nNo new software available.\n", 0),
    ]

    var battery: BatteryRegistryRead = .properties(Fake.appleSilicon)
    var power: PowerSourceInfo? = PowerSourceInfo(found: true, condition: nil)
    var storage: StorageValues? = StorageValues(total: 500 * gb, important: 200 * gb, available: 180 * gb)
    /// Pressure level of each memory reading in turn; the last repeats. Readings are 2 s apart from `now`.
    var pressures: [Int?] = [1]
    var swap: UInt64? = 1 << 30
    var thermal: [ProcessInfo.ThermalState] = [.nominal]
    var outputs = Fake.defaultOutputs
    var missingTools: Set<String> = []
    var preferences: [String: Any] = ["LastSuccessfulDate": Fake.now.addingTimeInterval(-86_400), "AutomaticDownload": true,
                                      "CriticalUpdateInstall": NSNumber(value: 1)]
    var xprotect: Data? = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "5368"], format: .xml, options: 0)
    var gate: Gate?
    /// The fake clock; tests move it forward between runs. Sleeping never advances it (samplers add their own intervals).
    var clock = Shared(Fake.now)

    func system() -> HealthSystem {
        let fake = self
        let memoryCalls = Shared(0), thermalCalls = Shared(0)
        return HealthSystem(
            batteryRegistry: { fake.battery },
            powerSource: { fake.power },
            storage: { fake.storage },
            memorySample: {
                var index = 0
                memoryCalls.next { index = $0; $0 += 1 }
                let pressure = fake.pressures[min(index, fake.pressures.count - 1)]
                return MemorySample(date: fake.clock.value.addingTimeInterval(Double(index) * 2), total: 16 << 30, used: 12 << 30,
                                    compressed: 2 << 30, swap: fake.swap, pressure: pressure)
            },
            thermalState: {
                var index = 0
                thermalCalls.next { index = $0; $0 += 1 }
                return fake.thermal[min(index, fake.thermal.count - 1)]
            },
            now: { fake.clock.value },
            sleep: { _ in },
            run: { path, arguments, _, cancellation in
                fake.gate?.pass(path)
                if cancellation?.isCancelled == true { return ("", SystemDataScanner.cancelledStatus) }
                return fake.outputs[([path] + arguments).joined(separator: " ")] ?? ("unexpected command", 1)
            },
            isExecutable: { !fake.missingTools.contains($0) },
            preference: { fake.preferences[$0] },
            readFile: { $0 == HealthScanner.xprotectPlists[0] ? fake.xprotect : nil },
            machine: {
                fake.gate?.pass("machine")
                return HealthMachineInfo(model: "MacBook Air (13-inch, M5)", identifier: "Mac17,3", chip: "Apple M5", memory: "16 GB", macOS: "macOS 27.2")
            })
    }

    func check(_ mode: HealthMode = .quick, memoryHistory: [MemorySample] = [], history: [HealthSnapshot] = [],
               breakdown: [HealthContextEntry] = [], apps: [HealthContextEntry] = []) -> HealthCheckResult {
        HealthScanner.check(HealthScanner.Request(mode: mode, memoryHistory: memoryHistory, history: history,
                                                  storageBreakdown: breakdown, topApps: apps), system: system())
    }
}

/// Deterministic random numbers for the score fixtures.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@main
enum HealthCheck {
    static let gb = Fake.gb
    static let now = Fake.now
    /// Every user-facing string produced by the fixtures, for the wording checks at the end.
    nonisolated(unsafe) static var texts: [(text: String, failingDisk: Bool)] = []

    static func collect(_ result: HealthCheckResult) {
        let failing = result.categories.contains { $0.items.contains { $0.status == .failing } }
        texts.append((result.summary, failing))
        texts.append((result.markdown(), failing))
        for category in result.categories { collect(category, failing: failing) }
    }

    static func collect(_ category: HealthCategoryResult, failing: Bool? = nil) {
        let failing = failing ?? category.items.contains { $0.status == .failing }
        var strings = [category.summary, category.recommendation ?? "", category.comparison ?? "", category.forecast ?? "",
                       HealthAccessibility.label(for: category)] + category.notes + category.zeroPointNotes
        strings += category.measurements.flatMap { [$0.label, $0.displayValue, $0.note ?? ""] }
        strings += category.items.flatMap { [$0.title, $0.statusLabel, $0.detail, $0.whyItMatters, $0.recommendation ?? "", $0.severity] }
        strings += category.deductions.flatMap { [$0.reason, $0.recommendation] }
        texts += strings.map { ($0, failing) }
    }

    static func sample(_ pressure: Int?, at offset: TimeInterval, swap: UInt64? = 1 << 30) -> MemorySample {
        MemorySample(date: now.addingTimeInterval(offset), total: 16 << 30, used: 15 << 30, compressed: 1 << 30, swap: swap, pressure: pressure)
    }

    /// Readings every 5 s before now, like `MemoryMonitor.history`.
    static func monitor(_ levels: [Int]) -> [MemorySample] {
        levels.enumerated().map { sample($0.element, at: -5 * Double(levels.count - $0.offset)) }
    }

    static func reading(_ level: Int?, at offset: TimeInterval) -> HealthScanner.ThermalReading {
        HealthScanner.ThermalReading(date: now.addingTimeInterval(offset), level: level)
    }

    @MainActor static func main() async throws {
        let historyEnvironment = ProcessInfo.processInfo.environment[HealthHistoryStore.locationOverride]
        precondition(historyEnvironment != nil, "MACPOLISH_HEALTH_HISTORY must point to a throwaway file before anything uses the default store")
        let root = FileManager.default.temporaryDirectory.appending(path: "MacPolish-health-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try parsers()
        battery()
        storage()
        memory()
        temperature()
        disks()
        security()
        updates()
        settingsLinks()
        unknownAndPartial()
        trendsAndForecasts()
        let randomized = scoreInvariants()
        presentation()
        try await model(root: root)
        try await cancellation(root: root)
        let live = try await liveQuick()
        let wordingCount = wording()

        print("PASS: Mac Health — parsers (battery incl. nested BatteryData, csrutil/spctl/fdesetup/socketfilterfw, SMART, diskutil list/startup store, XProtect, softwareupdate, product name) unchanged in coverage; "
              + "battery: macOS condition beats capacity heuristics (Normal + 75% → Healthy, 0 points), service condition → Critical −15 once even with low capacity, no condition + 75% → Attention −5 low confidence, desktop → Unknown; "
              + "storage uses absolute and percentage free (small disk at 8% → Attention −8, 2 TB at 8% → Healthy, < 5 GB → Critical −15, never stacked); "
              + "memory: momentary pressure → Healthy with a 0-point note, sustained → Attention −6 / Critical −12 once even with swap growth, RAM usage alone never counts; "
              + "temperature: single or Quick-length heat → Healthy 0 points, sustained serious → Attention −5 (never Critical, no \"overheating\"), sustained critical → Attention −8, repeated across checks ≥ 5 min apart counts; "
              + "SMART: Unsupported/Permission Limited/Unknown never failing, Failing → Critical −25 with a backup recommendation, multiple disks identified; "
              + "security: disabled/unreadable/unknown/unsupported distinct, cap 20, SIP without a settings button, Gatekeeper/FileVault/Firewall/Updates with one, opener gets the exact URL then the System Settings fallback; "
              + "updates: checks off / stale / available → one −4; unknown never deducts; partial after a failing reader; "
              + "trends need two meaningful snapshots ≥ 30 min apart, forecasts hidden when insufficient/short/unstable/flat/rising/already low and shown for a steady decline; "
              + "score == 100 − Σdeductions (floored) and \"Why this score?\" lines match exactly in \(randomized) randomized results; card order, accessibility labels and \(wordingCount) strings free of fear-based phrases; "
              + "model publishes per category, saves one snapshot per run to the temp history, cancel keeps finished categories and marks the rest Not checked, a late result from the cancelled run never replaces the newer run; "
              + "live Quick check returned all 7 categories in \(String(format: "%.1f", live.elapsed)) s (score \(live.score), \(live.critical) critical, \(live.attention) need attention)")
    }

    // MARK: Parsers

    static func parsers() throws {
        // Battery, Apple Silicon on macOS 26+: percentages top-level, mAh values only inside BatteryData.
        guard let nested = BatteryHealth.parse(Fake.appleSilicon) else { preconditionFailure("nested battery parses") }
        precondition(nested.maximumCapacity == 100 && !nested.capacityIsComputed, "top-level MaxCapacity percent is preferred")
        precondition(nested.designCapacity == 4629 && nested.rawMaxCapacity == 4649 && nested.nominalChargeCapacity == 4776,
                     "mAh values are read from BatteryData")
        precondition(nested.cycleCount == 28 && nested.designCycleCount == 1000 && nested.charge == 35 && nested.isCharging == false)
        let intel: [String: Any] = ["CycleCount": 850, "DesignCycleCount9C": 1000, "MaxCapacity": 4000, "CurrentCapacity": 2000,
                                    "DesignCapacity": 5000, "AppleRawMaxCapacity": 4100, "NominalChargeCapacity": 4200]
        guard let topLevel = BatteryHealth.parse(intel) else { preconditionFailure("top-level battery parses") }
        precondition(topLevel.maximumCapacity == 82 && topLevel.capacityIsComputed && topLevel.charge == 50)
        let missing: [String: Any] = ["CycleCount": 400, "DesignCycleCount9C": 1000,
                                      "BatteryData": ["DesignCapacity": 4629, "AppleRawMaxCapacity": 3650, "MaxCapacity": 100] as [String: Any]]
        precondition(BatteryHealth.parse(missing)?.maximumCapacity == 78, "computed, rounded down, nested MaxCapacity ignored")
        precondition(BatteryHealth.parse(["BatteryData": ["DesignCapacity": 4629, "AppleRawMaxCapacity": 4649] as [String: Any]])?.maximumCapacity == 100)
        precondition(BatteryHealth.parse([:]) == nil && BatteryHealth.parse(["Serial": "x"]) == nil, "no battery keys → no battery")

        // Security parsers: enabled, disabled, unreadable (garbage / timeout), unknown (recognized tool, unknown state).
        func check(_ parse: (String, Int32) -> HealthItem, _ cases: [(String, HealthItemStatus)], _ name: String) {
            for (output, expected) in cases {
                let item = parse(output, 0)
                precondition(item.status == expected, "\(name): \(output.debugDescription) gave \(item.status), expected \(expected)")
            }
            precondition(parse(cases[0].0, -1).status == .unreadable, "\(name): a timeout is unreadable, never enabled")
        }
        check(HealthScanner.sipItem, [
            ("System Integrity Protection status: enabled.\n", .enabled), ("System Integrity Protection status: disabled.\n", .disabled),
            ("System Integrity Protection status: unknown (Custom Configuration).\n", .disabled),
            ("System Integrity Protection status: sideways.\n", .unknown), ("garbage", .unreadable), ("", .unreadable),
        ], "SIP")
        check(HealthScanner.gatekeeperItem, [("assessments enabled\n", .enabled), ("assessments disabled\n", .disabled),
                                             ("assessments paused\n", .unknown), ("garbage", .unreadable)], "Gatekeeper")
        check(HealthScanner.fileVaultItem, [
            ("FileVault is On.\n", .enabled), ("FileVault is Off.\n", .disabled),
            ("FileVault is Off, but will be enabled after the next restart.\n", .disabled),
            ("FileVault is On.\nDecryption in progress: Percent completed = 40\n", .disabled),
            ("FileVault is On.\nEncryption in progress: Percent completed = 40\n", .enabled),
            ("FileVault is Sideways.\n", .unknown), ("garbage", .unreadable),
        ], "FileVault")
        check(HealthScanner.firewallItem, [
            ("Firewall is enabled. (State = 1)\n", .enabled), ("Firewall is disabled. (State = 0)\n", .disabled),
            ("Firewall is enabled. (State = 2)\n", .enabled), ("Firewall is odd. (State = 7)\n", .unknown), ("garbage", .unreadable),
        ], "Firewall")
        precondition(HealthScanner.sipItem(output: "System Integrity Protection status: unknown (Custom Configuration).").statusLabel
                     == "Disabled (custom configuration)")
        precondition(HealthScanner.gatekeeperItem(output: "assessments disabled\n", status: 1).status == .disabled, "spctl exits 1 when disabled")

        // SMART from `diskutil info -plist`.
        let smart: [(String?, HealthItemStatus)] = [("Verified", .healthy), ("Failing", .failing), (nil, .unsupported),
                                                    ("Not Supported", .unsupported), ("Mystery", .unknown)]
        for (status, expected) in smart {
            let item = HealthScanner.diskItem(identifier: "disk0", plistOutput: Fake.disk("disk0", smart: status), status: 0)
            precondition(item.status == expected, "SMART \(status ?? "missing") gave \(item.status)")
            precondition(item.title == "APPLE SSD AP0512Z (disk0, internal)", "disks are identified by name, identifier and location: \(item.title)")
        }
        precondition(HealthScanner.diskItem(identifier: "disk0", plistOutput: "", status: -1).status == .unknown, "a timeout is unknown")
        precondition(HealthScanner.diskItem(identifier: "disk2", plistOutput: "Operation not permitted", status: 1).status == .permissionLimited)
        precondition(HealthScanner.physicalDisks(listOutput: Fake.plist(["WholeDisks": ["disk0", "disk4"]])) == ["disk0", "disk4"])
        precondition(HealthScanner.physicalDisks(listOutput: "garbage") == nil)
        precondition(HealthScanner.startupWholeDisk(infoOutput: Fake.defaultOutputs["/usr/sbin/diskutil info -plist /"]!.0) == "disk0",
                     "the APFS physical store disk0s2 resolves to disk0")
        precondition(HealthScanner.startupWholeDisk(infoOutput: Fake.plist(["ParentWholeDisk": "disk1"])) == "disk1")

        // XProtect, product name, software update list.
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "5368"], format: .xml, options: 0)
        precondition(HealthScanner.xprotectVersion(infoPlist: info) == "5368" && HealthScanner.xprotectVersion(infoPlist: Data()) == nil)
        precondition(HealthScanner.xprotectItem(["999", nil, "1000"]).statusDetail == "version 1000", "newest version by number")
        precondition(HealthScanner.xprotectItem([nil]).status == .unreadable && HealthScanner.xprotectItem([nil]).state == .unknown)
        precondition(HealthScanner.productName(from: Data("MacBook Air (13-inch, M5)\0".utf8)) == "MacBook Air (13-inch, M5)")
        precondition(HealthScanner.productName(from: Data([0])) == nil)
        let listed = """
        Software Update Tool

        Software Update found the following new or updated software:
        * Label: macOS Tahoe 27.2.1-26C10
        \tTitle: macOS Tahoe 27.2.1, Version: 27.2.1, Size: 1200000KiB, Recommended: YES, Action: restart,
        * Label: Optional Thing-1
        \tTitle: Optional Thing, Version: 1, Size: 10KiB, Recommended: NO,
        """
        precondition(HealthScanner.parseSoftwareUpdateList(output: listed, status: 0)
                     == .list(available: 2, recommended: 1, titles: ["macOS Tahoe 27.2.1", "Optional Thing"]))
        precondition(HealthScanner.parseSoftwareUpdateList(output: "Software Update Tool\n\nNo new software available.\n", status: 0)
                     == .list(available: 0, recommended: 0, titles: []))
        if case .unreadable = HealthScanner.parseSoftwareUpdateList(output: "", status: -1) {} else { preconditionFailure("timeout is unreadable") }
        if case .unreadable = HealthScanner.parseSoftwareUpdateList(output: "boom", status: 3) {} else { preconditionFailure("failure is unreadable") }
    }

    // MARK: Battery

    static func battery() {
        var low = Fake.appleSilicon
        low["MaxCapacity"] = 75
        // macOS's condition beats the capacity heuristic.
        let normal = HealthScanner.batteryResult(.properties(low), power: PowerSourceInfo(found: true, condition: "Normal"), now: now)
        precondition(normal.state == .healthy && normal.deductions.isEmpty && normal.confidence == .high, "Normal condition + 75% is Healthy")
        precondition(normal.notes.contains { $0.contains("macOS has not flagged this battery") }, "the note says macOS has not flagged it")
        precondition(normal.zeroPointNotes.count == 1, "the considered wear is listed with 0 points")
        // Service condition: Critical once, even with low capacity and many cycles.
        var worn = low
        worn["CycleCount"] = 1_200
        for condition in ["Service Recommended", "check battery", "Replace Soon", "REPLACE NOW", "Poor"] {
            let service = HealthScanner.batteryResult(.properties(worn), power: PowerSourceInfo(found: true, condition: condition), now: now)
            precondition(service.state == .critical && service.confidence == .high, "\(condition) is Critical")
            precondition(service.deductions.map(\.points) == [15], "condition + low capacity + cycles deduct once: \(service.deductions)")
            precondition(service.recommendation?.contains("battery service") == true)
            collect(service)
        }
        // No condition: heuristic, low confidence, one deduction.
        let heuristic = HealthScanner.batteryResult(.properties(worn), power: PowerSourceInfo(found: true, condition: nil), now: now)
        precondition(heuristic.state == .attention && heuristic.confidence == .low && heuristic.deductions.map(\.points) == [5],
                     "capacity < 80% and cycles ≥ rated deduct −5 once")
        precondition(heuristic.recommendation?.contains("Apple's published battery guidance") == true, "the rationale cites Apple's guidance")
        precondition(heuristic.deductions[0].reason.contains("75%") && heuristic.deductions[0].reason.contains("1,000"))
        let cyclesOnly = HealthScoring.battery(condition: nil, capacity: 90, cycles: 1_000, designCycles: 1_000)
        precondition(cyclesOnly.state == .attention && cyclesOnly.deductions.map(\.points) == [5], "cycles at the rated count")
        let fine = HealthScanner.batteryResult(.properties(Fake.appleSilicon), power: PowerSourceInfo(found: true, condition: nil), now: now)
        precondition(fine.state == .healthy && fine.deductions.isEmpty && fine.confidence == .medium)
        precondition(fine.measurements[0].label == "Maximum capacity" && fine.measurements[0].value == "100%")
        precondition(fine.measurements.contains { $0.label == "Full-charge capacity" && $0.displayValue.contains("4,649 mAh") })
        precondition(fine.measurements.contains { $0.label == "Optimized Battery Charging" && $0.value == "Not available to apps" },
                     "Optimized Battery Charging is reported as not available to apps")
        precondition(fine.measurements.contains { $0.label == "Condition (macOS)" && $0.displayValue == HealthMeasurement.notAvailable })
        precondition(fine.settingsLink == .battery && fine.metrics.batteryMaxCapacity == 100 && fine.metrics.batteryCycles == 28)
        let desktop = HealthScanner.batteryResult(.noBattery, power: nil, now: now)
        precondition(desktop.state == .unknown && desktop.summary == "No battery — this appears to be a desktop Mac." && desktop.deductions.isEmpty
                     && desktop.failedReason == nil, "a desktop is Unknown, not a failure")
        let unreadable = HealthScanner.batteryResult(.unreadable, power: nil, now: now)
        precondition(unreadable.state == .unknown && unreadable.summary == "Battery information not available." && unreadable.deductions.isEmpty)
        precondition(HealthScanner.batteryResult(.properties(["Serial": "x"]), power: nil, now: now).summary == "Battery information not available.")
        for result in [normal, heuristic, fine, desktop, unreadable] { collect(result) }
    }

    // MARK: Storage

    static func storage() {
        func result(_ free: Int64, _ total: Int64) -> HealthCategoryResult {
            HealthScanner.storageResult(StorageValues(total: total, important: free, available: free - 2 * gb), breakdown: [], now: now)
        }
        let cases: [(free: Int64, total: Int64, state: HealthState, points: Int, label: String)] = [
            (4 * gb, 2_000 * gb, .critical, 15, "under 5 GB on any disk"),
            (18 * gb, 1_000 * gb, .critical, 15, "under 5% and under 20 GB"),
            (20 * gb, 256 * gb, .attention, 8, "small disk at 8%"),
            (12 * gb, 200 * gb, .attention, 8, "under 15 GB at 6%"),
            (12 * gb, 500 * gb, .critical, 15, "under 20 GB at 2%"),
            (40 * gb, 500 * gb, .attention, 8, "8% and under 50 GB"),
            (160 * gb, 2_000 * gb, .healthy, 0, "2 TB at 8% is plenty of space"),
            (60 * gb, 500 * gb, .healthy, 0, "12% free"),
            (16 * gb, 100 * gb, .healthy, 0, "16% of a small disk"),
        ]
        for c in cases {
            let r = result(c.free, c.total)
            precondition(r.state == c.state && r.deductions.reduce(0) { $0 + $1.points } == c.points, "storage \(c.label): \(r.state) \(r.deductions)")
            precondition(r.deductions.count <= 1, "storage never stacks deductions")
            precondition(r.confidence == .high && r.settingsLink == .storage)
            precondition(r.measurements[0].label == "Free space" && r.measurements[0].value == c.free.formattedBytes)
            collect(r)
        }
        let purgeable = HealthScanner.storageResult(StorageValues(total: 500 * gb, important: 50 * gb, available: 30 * gb), breakdown: [], now: now)
        precondition(purgeable.measurements.contains { $0.label == "Purgeable (included above)" && $0.value == (20 * gb).formattedBytes })
        precondition(StorageValues(total: 1, important: 5, available: 9).purgeable == nil, "negative purgeable is not shown")
        precondition(purgeable.context == ["Run Storage Map to see what uses space."])
        let breakdown = (1...6).map { HealthContextEntry(name: "Category \($0)", bytes: Int64($0) * gb) }
        let mapped = HealthScanner.storageResult(StorageValues(total: 500 * gb, important: 50 * gb, available: nil), breakdown: breakdown, now: now)
        precondition(mapped.context.count == 4 && mapped.context[0].hasPrefix("Category 6"), "top 4 storage categories, largest first")
        let unreadable = HealthScanner.storageResult(nil, breakdown: [], now: now)
        precondition(unreadable.state == .unknown && unreadable.failedReason != nil && unreadable.deductions.isEmpty)
    }

    // MARK: Memory

    static func memory() {
        func result(_ history: [MemorySample], readings: [MemorySample] = [], previousSwap: UInt64? = nil) -> HealthCategoryResult {
            HealthScanner.memoryResult(history: history, readings: readings, previousSwap: previousSwap, topApps: [], now: now)
        }
        // Momentary: a single elevated reading, or a few among normal ones, never deducts.
        for momentary in [result([], readings: [sample(2, at: 0)]), result([], readings: [sample(4, at: 0)]),
                          result(monitor(Array(repeating: 1, count: 12)), readings: [sample(4, at: 0)]),
                          result([sample(2, at: -10), sample(2, at: -5)], readings: [sample(2, at: 0)])] {
            precondition(momentary.state == .healthy && momentary.deductions.isEmpty, "momentary pressure is Healthy")
            precondition(momentary.summary.contains("momentary — check again later"), momentary.summary)
            precondition(momentary.zeroPointNotes == ["Momentary memory pressure"], "listed as a zero-point line")
            collect(momentary)
        }
        // RAM usage alone never changes the state (15 of 16 GB in use here).
        let busy = result(monitor(Array(repeating: 1, count: 12)), readings: [sample(1, at: 0)])
        precondition(busy.state == .healthy && busy.deductions.isEmpty && busy.confidence == .high)
        precondition(busy.measurements.contains { $0.label == "Memory in use" && $0.displayValue.contains("94%") })
        // Sustained warning: −6 once, swap growth mentioned but not stacked.
        let sustained = result(monitor(Array(repeating: 2, count: 12)), readings: [sample(2, at: 0, swap: 4 << 30)], previousSwap: 1 << 30)
        precondition(sustained.state == .attention && sustained.confidence == .medium && sustained.deductions.map(\.points) == [6],
                     "sustained pressure + swap growth deduct once")
        precondition(sustained.deductions[0].reason.contains("swap grew by 3 GB"), sustained.deductions[0].reason)
        precondition(sustained.summary.contains("Swap grew by 3 GB") && sustained.firstObserved != nil && sustained.lastObserved == now)
        precondition(!sustained.recommendation!.isEmpty)
        // Critical majority: −12 once.
        let critical = result(monitor(Array(repeating: 4, count: 12)), readings: [sample(4, at: 0)])
        precondition(critical.state == .critical && critical.deductions.map(\.points) == [12])
        let mostlyWarning = result(monitor([4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]), readings: [sample(2, at: 0)])
        precondition(mostlyWarning.state == .attention && mostlyWarning.deductions.map(\.points) == [6], "a few critical among warnings is Attention")
        // Window rules.
        let half = HealthScoring.PressureWindow(samples: (0..<8).map { sample($0 < 4 ? 2 : 1, at: -Double(8 - $0) * 20) })
        precondition(half.isSustained && half.elevated == 4 && half.readings == 8, "half of 8 readings over 140 s is sustained")
        let short = HealthScoring.PressureWindow(samples: monitor([2, 2, 2, 2, 2, 2]))
        precondition(!short.isSustained, "30 s is too short")
        let stale = HealthScoring.PressureWindow(samples: (0..<10).map { sample(2, at: -1_800 - Double($0) * 5) } + [sample(1, at: 0)])
        precondition(stale.readings == 1 && stale.elevated == 0, "readings more than 10 minutes old are ignored")
        let once = sample(2, at: 0)
        precondition(HealthScoring.PressureWindow(samples: [once, once, once]).readings == 1, "the same sample counts once")
        let unknown = result([], readings: [sample(nil, at: 0)])
        precondition(unknown.state == .unknown && unknown.deductions.isEmpty && unknown.failedReason != nil, "unreadable pressure is Unknown")
        precondition(result([]).state == .unknown)
        // Top apps are context only.
        let apps = HealthScanner.memoryResult(history: [], readings: [sample(1, at: 0)], previousSwap: nil,
                                              topApps: [HealthContextEntry(name: "Safari", bytes: 2 << 30), HealthContextEntry(name: "Mail", bytes: 1 << 30)], now: now)
        precondition(apps.context == ["Safari — 2 GB", "Mail — 1 GB"] && apps.contextTitle?.contains("high usage alone is normal") == true)
        precondition(apps.state == .healthy && apps.deductions.isEmpty)
        // Extended: readings taken during the check join the monitor's history.
        var fake = Fake()
        fake.pressures = [2]
        let extended = fake.check(.extended, memoryHistory: monitor(Array(repeating: 2, count: 10)))
        precondition(extended.category(.memory)?.state == .attention, "history + 11 Extended readings over 20 s are sustained")
        let quickOnly = fake.check(.quick)
        precondition(quickOnly.category(.memory)?.state == .healthy && quickOnly.category(.memory)?.deductions.isEmpty == true,
                     "one Quick reading without history is momentary")
        for r in [sustained, critical, unknown, apps] { collect(r) }
        collect(extended)
    }

    // MARK: Temperature

    static func temperature() {
        func result(_ readings: [HealthScanner.ThermalReading], previous: HealthSnapshot? = nil) -> HealthCategoryResult {
            HealthScanner.temperatureResult(readings, previous: previous, now: now)
        }
        let single = result([reading(2, at: 0)])
        precondition(single.state == .healthy && single.deductions.isEmpty && single.zeroPointNotes == ["Temporary high temperature"],
                     "a single serious reading costs nothing")
        let mixed = result([reading(0, at: -2), reading(3, at: -1), reading(1, at: 0)])
        precondition(mixed.state == .healthy && mixed.deductions.isEmpty && mixed.measurements.contains { $0.label == "Pattern" && $0.value == "Temporary" })
        precondition(mixed.measurements.contains { $0.label == "Elevated readings" }, "first/last elevated reading times are shown")
        let quickHot = result([reading(2, at: -2), reading(2, at: -1), reading(2, at: 0)])
        precondition(quickHot.state == .healthy && quickHot.deductions.isEmpty, "three hot readings over 2 s are not sustained")
        let serious = result((0...20).map { reading($0 % 3 == 0 ? 3 : 2, at: Double($0) - 20) })
        precondition(serious.state == .attention && serious.confidence == .medium && serious.deductions.map(\.points) == [5],
                     "sustained serious is Attention −5, never Critical")
        precondition(serious.summary.contains("serious thermal state") && !serious.summary.lowercased().contains("overheat"))
        precondition(serious.firstObserved == now.addingTimeInterval(-20) && serious.lastObserved == now)
        let critical = result((0...20).map { reading(3, at: Double($0) - 20) })
        precondition(critical.state == .attention && critical.confidence == .high && critical.deductions.map(\.points) == [8])
        precondition(critical.summary.contains("macOS reports a critical thermal state") && critical.summary.contains("limiting performance to cool the Mac"))
        // Repeated across checks: now hot and at the previous check ≥ 5 minutes earlier.
        let earlier = HealthSnapshot(date: now.addingTimeInterval(-600), states: [.temperature: .healthy], thermalState: 2)
        let repeated = result([reading(2, at: 0)], previous: earlier)
        precondition(repeated.state == .attention && repeated.deductions.map(\.points) == [5] && repeated.firstObserved == earlier.date)
        precondition(repeated.measurements.contains { $0.label == "Pattern" && $0.value?.hasPrefix("Repeated") == true })
        let tooRecent = HealthSnapshot(date: now.addingTimeInterval(-120), thermalState: 3)
        precondition(result([reading(3, at: 0)], previous: tooRecent).state == .healthy, "a previous check 2 minutes ago does not make it sustained")
        let repeatedCritical = result([reading(3, at: 0)], previous: HealthSnapshot(date: now.addingTimeInterval(-900), thermalState: 3))
        precondition(repeatedCritical.deductions.map(\.points) == [8])
        let unknown = result([HealthScanner.ThermalReading(date: now, level: nil)])
        precondition(unknown.state == .unknown && unknown.deductions.isEmpty)
        // Exhaustive: never Critical, at most one deduction, at most 8.
        let levels = [0, 1, 2, 3]
        for a in levels { for b in levels { for c in levels {
            let r = result([reading(a, at: -12), reading(b, at: -6), reading(c, at: 0)])
            precondition(r.state != .critical && r.deductions.count <= 1 && (r.deductions.first?.points ?? 0) <= 8)
            precondition((r.state == .attention) == ([a, b, c].allSatisfy { $0 >= 2 }), "thermal \([a, b, c]) gave \(r.state)")
        } } }
        // Through the sampler: Extended takes ~20 s of readings; Quick three.
        var fake = Fake()
        fake.thermal = [.serious]
        let extended = fake.check(.extended)
        precondition(extended.category(.temperature)?.state == .attention && extended.category(.temperature)?.deductions.first?.points == 5)
        let quick = fake.check(.quick)
        precondition(quick.category(.temperature)?.state == .healthy, "Quick's three readings over 2 s alone never deduct")
        precondition(quick.category(.temperature)?.measurements.contains { $0.label == "Readings" && $0.displayValue.hasPrefix("3 readings over 2 s") } == true)
        precondition(HealthScanner.ThermalSampler.quick == .init(readings: 3, interval: 1) && HealthScanner.ThermalSampler.extended.readings == 21)
        for r in [single, mixed, serious, critical, repeated, unknown] { collect(r) }
    }

    // MARK: Disk Health

    static func disks() {
        var fake = Fake()
        let quick = fake.check(.quick).category(.diskHealth)!
        precondition(quick.state == .healthy && quick.items.map(\.title) == ["APPLE SSD AP0512Z (disk0, internal)"], "Quick reads the startup disk")
        precondition(quick.summary.contains("cannot guarantee"), "SMART limits are stated")
        // Extended: every physical disk, each identified; Unsupported is not failure.
        fake.outputs["/usr/sbin/diskutil list -plist physical"] = (Fake.plist(["WholeDisks": ["disk0", "disk4", "disk6"]]), 0)
        fake.outputs["/usr/sbin/diskutil info -plist disk4"] = (Fake.disk("disk4", smart: "Not Supported", name: "Portable SSD", isInternal: false), 0)
        fake.outputs["/usr/sbin/diskutil info -plist disk6"] = ("diskutil: Operation not permitted", 1)
        let extended = fake.check(.extended).category(.diskHealth)!
        precondition(extended.items.map(\.title) == ["APPLE SSD AP0512Z (disk0, internal)", "Portable SSD (disk4, external)", "disk6"])
        precondition(extended.items.map(\.status) == [.healthy, .unsupported, .permissionLimited])
        precondition(extended.state == .healthy && extended.deductions.isEmpty, "Unsupported and Permission Limited are not failures")
        // Only unsupported disks: Unknown with a zero-point note.
        let unsupported = HealthScanner.diskResult([HealthScanner.diskItem(identifier: "disk4", plistOutput: Fake.disk("disk4", smart: nil), status: 0)],
                                                   mode: .extended, now: now)
        precondition(unsupported.state == .unknown && unsupported.deductions.isEmpty && unsupported.zeroPointNotes == ["Disk health not available"])
        precondition(unsupported.summary.contains("not a sign of failure"))
        // Failing: Critical −25 with a backup recommendation, once even with two failing disks.
        fake.outputs["/usr/sbin/diskutil info -plist disk4"] = (Fake.disk("disk4", smart: "Failing", name: "Portable SSD", isInternal: false), 0)
        fake.outputs["/usr/sbin/diskutil info -plist disk6"] = (Fake.disk("disk6", smart: "Failing", name: "Archive", isInternal: false), 0)
        let failingResult = fake.check(.extended)
        let failing = failingResult.category(.diskHealth)!
        precondition(failing.state == .critical && failing.confidence == .high && failing.deductions.map(\.points) == [25])
        precondition(failing.recommendation == "Back up this disk soon, for example with Time Machine; macOS reports a SMART failure.")
        precondition(failing.items.filter { $0.status == .failing }.allSatisfy { $0.recommendation == failing.recommendation })
        precondition(failing.deductions[0].reason.contains("Portable SSD (disk4, external)") && failing.deductions[0].reason.contains("Archive (disk6, external)"))
        precondition(failingResult.categories.first?.category == .diskHealth, "the critical card comes first")
        // The list failing falls back to the startup disk with a note.
        fake.outputs["/usr/sbin/diskutil list -plist physical"] = ("garbage", 1)
        let fallback = fake.check(.extended).category(.diskHealth)!
        precondition(fallback.items.count == 1 && fallback.state == .healthy && fallback.notes.contains { $0.contains("only the startup disk") })
        for r in [quick, extended, unsupported, failing, fallback] { collect(r) }
        collect(failingResult)
    }

    // MARK: Security

    static func security() {
        var fake = Fake()
        let on = fake.check().category(.security)!
        precondition(on.state == .healthy && on.deductions.isEmpty && on.settingsLink == nil)
        precondition(on.items.map(\.id) == ["sip", "gatekeeper", "filevault", "firewall", "xprotect"])
        precondition(on.items.last?.state == .healthy && on.items.last?.statusDetail == "version 5368", "XProtect version is a Healthy item")
        precondition(!on.summary.lowercased().contains("secure"))
        // SIP off: −10, no settings button anywhere (it is changed from macOS Recovery).
        fake.outputs["/usr/bin/csrutil status"] = ("System Integrity Protection status: disabled.\n", 0)
        let sip = fake.check().category(.security)!
        precondition(sip.state == .attention && sip.deductions.map(\.points) == [10] && sip.deductions[0].confidence == .high)
        precondition(sip.settingsLink == nil && sip.items[0].settingsLink == nil, "SIP has no settings button")
        precondition(sip.items[0].recommendation?.contains("macOS Recovery") == true && sip.items[0].whyItMatters.contains("on purpose"))
        // Gatekeeper −6 and FileVault −8 link to Privacy & Security; Firewall −2 (low) to Network.
        var others = Fake()
        others.outputs["/usr/sbin/spctl --status"] = ("assessments disabled\n", 1)
        others.outputs["/usr/bin/fdesetup status"] = ("FileVault is Off.\n", 0)
        others.outputs["/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"] = ("Firewall is disabled. (State = 0)\n", 0)
        let off = others.check().category(.security)!
        let byID = Dictionary(uniqueKeysWithValues: off.items.map { ($0.id, $0) })
        precondition(byID["gatekeeper"]?.points == 6 && byID["gatekeeper"]?.settingsLink == .privacySecurity)
        precondition(byID["filevault"]?.points == 8 && byID["filevault"]?.settingsLink == .privacySecurity)
        precondition(byID["filevault"]?.whyItMatters.contains("intentional on a desktop Mac") == true)
        precondition(byID["firewall"]?.points == 2 && byID["firewall"]?.settingsLink == .network && byID["firewall"]?.confidence == .low)
        precondition(byID["firewall"]?.whyItMatters.contains("off by default") == true && byID["firewall"]?.whyItMatters.contains("untrusted networks") == true)
        precondition(off.deductions.map(\.points) == [8, 6, 2] && off.settingsLink == .privacySecurity, "independent settings add up, largest first")
        precondition(off.deductions.allSatisfy { $0.reason.contains("reduces protection") })
        // All four off: capped at 20.
        others.outputs["/usr/bin/csrutil status"] = ("System Integrity Protection status: disabled.\n", 0)
        let all = others.check().category(.security)!
        precondition(all.deductions.reduce(0) { $0 + $1.points } == 20 && all.deductions.map(\.points) == [10, 8, 2], "security is capped at 20")
        precondition(all.deductions[2].reason.contains("cap") && all.zeroPointNotes.contains { $0.hasPrefix("Firewall off") })
        // Disabled vs unreadable vs unknown vs unsupported are distinct, and only disabled deducts.
        var mixed = Fake()
        mixed.outputs["/usr/bin/csrutil status"] = ("", -1)
        mixed.outputs["/usr/sbin/spctl --status"] = ("assessments paused\n", 0)
        mixed.outputs["/usr/bin/fdesetup status"] = ("FileVault is Off.\n", 0)
        mixed.missingTools = ["/usr/libexec/ApplicationFirewall/socketfilterfw"]
        mixed.xprotect = nil
        let distinct = mixed.check().category(.security)!
        precondition(distinct.items.map(\.status) == [.unreadable, .unknown, .disabled, .unsupported, .unreadable])
        precondition(distinct.items.map(\.status.label) == ["Unreadable", "Unknown", "Disabled", "Unsupported", "Unreadable"])
        precondition(distinct.deductions.map(\.points) == [8] && distinct.state == .attention)
        precondition(distinct.zeroPointNotes.count == 4, "each unread setting is listed with 0 points: \(distinct.zeroPointNotes)")
        // Nothing readable: Unknown, no deduction.
        var none = Fake()
        for key in ["/usr/bin/csrutil status", "/usr/sbin/spctl --status", "/usr/bin/fdesetup status",
                    "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"] { none.outputs[key] = ("", -1) }
        none.xprotect = nil
        let unknown = none.check().category(.security)!
        precondition(unknown.state == .unknown && unknown.deductions.isEmpty && unknown.failedReason != nil)
        for r in [on, sip, off, all, distinct, unknown] { collect(r) }
    }

    // MARK: System Updates

    static func updates() {
        let recent = now.addingTimeInterval(-86_400), old = now.addingTimeInterval(-45 * 86_400)
        let defaultOn = HealthScoring.updates(automaticChecks: nil, lastSuccessfulCheck: recent, now: now, recommendedUpdates: nil)
        precondition(defaultOn.state == .healthy && defaultOn.deductions.isEmpty, "an absent preference is the macOS default")
        precondition(HealthScoring.updates(automaticChecks: false, lastSuccessfulCheck: recent, now: now, recommendedUpdates: nil).deductions.map(\.points) == [4])
        precondition(HealthScoring.updates(automaticChecks: nil, lastSuccessfulCheck: old, now: now, recommendedUpdates: nil).deductions.map(\.points) == [4])
        let all = HealthScoring.updates(automaticChecks: false, lastSuccessfulCheck: old, now: now, recommendedUpdates: 2)
        precondition(all.deductions.map(\.points) == [4], "one deduction for System Updates")
        precondition(all.deductions[0].reason.contains("turned off") && all.deductions[0].reason.contains("45 days") && all.deductions[0].reason.contains("2 recommended"))
        let unknown = HealthScoring.updates(automaticChecks: nil, lastSuccessfulCheck: nil, now: now, recommendedUpdates: nil)
        precondition(unknown.state == .unknown && unknown.deductions.isEmpty)
        var fake = Fake()
        let quick = fake.check(.quick).category(.updates)!
        precondition(quick.state == .healthy && quick.settingsLink == .softwareUpdate)
        precondition(quick.measurements.contains { $0.label == "Automatic update checks" && $0.value == "On (macOS default)" })
        precondition(quick.measurements.contains { $0.label == "Available updates" && $0.note?.contains("Not checked in Quick") == true })
        fake.outputs["/usr/sbin/softwareupdate -l --no-scan"] = ("""
        Software Update Tool

        Software Update found the following new or updated software:
        * Label: macOS Tahoe 27.2.1-26C10
        \tTitle: macOS Tahoe 27.2.1, Version: 27.2.1, Size: 1200000KiB, Recommended: YES, Action: restart,
        """, 0)
        let available = fake.check(.extended).category(.updates)!
        precondition(available.state == .attention && available.deductions.map(\.points) == [4] && available.summary.contains("1 recommended update is available"))
        precondition(fake.check(.quick).category(.updates)?.state == .healthy, "Quick never reads the update list")
        fake.preferences = ["AutomaticCheckEnabled": false, "LastSuccessfulDate": old]
        let off = fake.check(.quick).category(.updates)!
        precondition(off.state == .attention && off.deductions.count == 1 && off.recommendation != nil && off.settingsLink == .softwareUpdate)
        for r in [quick, available, off] { collect(r) }
    }

    // MARK: Settings links

    static func settingsLinks() {
        let expected: [HealthSettingsLink: String] = [
            .battery: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            .storage: "x-apple.systempreferences:com.apple.settings.Storage",
            .privacySecurity: "x-apple.systempreferences:com.apple.preference.security",
            .network: "x-apple.systempreferences:com.apple.Network-Settings.extension",
            .softwareUpdate: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        ]
        for link in HealthSettingsLink.allCases {
            precondition(link.url.absoluteString == expected[link], "\(link) URL")
            var opened: [URL] = []
            precondition(link.open { opened.append($0); return true } && opened == [link.url], "the opener receives the pane URL")
            opened = []
            precondition(link.open { opened.append($0); return $0 == HealthSettingsLink.systemSettingsURL }
                         && opened == [link.url, HealthSettingsLink.systemSettingsURL], "a refused URL falls back to System Settings")
        }
    }

    // MARK: Unknown values and partial results

    static func unknownAndPartial() {
        var broken = Fake()
        broken.battery = .unreadable
        broken.storage = nil
        broken.pressures = [nil]
        broken.swap = nil
        broken.thermal = [ProcessInfo.ThermalState(rawValue: 99)!]
        broken.outputs = [:]
        broken.preferences = [:]
        broken.xprotect = nil
        let result = broken.check(.extended)
        precondition(result.categories.count == 7 && result.categories.allSatisfy { $0.state == .unknown },
                     "every unreadable category is Unknown: \(result.categories.map { "\($0.category) \($0.state)" })")
        precondition(result.score == 100 && result.scoreDetails.deductions.isEmpty, "unknown values never reduce the score")
        precondition(result.isPartial && !result.cancelled, "unreadable readers make the result partial")
        precondition(result.summary == "No readings could be taken from macOS this time.")
        collect(result)
        // One failing reader: the rest is kept and scored; the result is partial.
        var oneFails = Fake()
        oneFails.storage = nil
        oneFails.outputs["/usr/bin/fdesetup status"] = ("FileVault is Off.\n", 0)
        let partial = oneFails.check()
        precondition(partial.isPartial && partial.category(.storage)?.failedReason != nil && partial.category(.storage)?.deductions.isEmpty == true)
        precondition(partial.score == 92 && partial.scoreDetails.deductions.map(\.id) == ["security.filevault"])
        precondition(partial.summary.contains("Security needs attention") && partial.summary.contains("incomplete"), partial.summary)
        precondition(partial.markdown().contains("_Partial result: some readings were not available."))
        collect(partial)
        // All fine.
        let fine = Fake().check()
        precondition(fine.score == 100 && !fine.isPartial && fine.summary == "No issues were found in the readings macOS reported.")
        precondition(fine.categories.map(\.category).count == 7 && Set(fine.categories.map(\.category)).count == 7)
        collect(fine)
    }

    // MARK: Trends and forecasts

    static func trendsAndForecasts() {
        func storageResult(free: Int64, total: Int64 = 500 * gb, at date: Date = now) -> HealthCategoryResult {
            HealthScanner.storageResult(StorageValues(total: total, important: free, available: nil), breakdown: [], now: date)
        }
        func snapshot(_ offset: TimeInterval, storage state: HealthState = .healthy, free: Int64? = nil, total: Int64 = 500 * gb) -> HealthSnapshot {
            HealthSnapshot(date: now.addingTimeInterval(offset), states: [.storage: state], storageFree: free, storageTotal: total)
        }
        let current = storageResult(free: 100 * gb)
        precondition(HealthHistory.trend(for: current, history: []) == .notEnoughData, "one check is not enough")
        precondition(HealthHistory.trend(for: current, history: [snapshot(-600, free: 150 * gb)]) == .notEnoughData, "checks 10 minutes apart are not compared")
        precondition(HealthHistory.trend(for: current, history: [snapshot(-7_200, storage: .unknown, free: 150 * gb)]) == .notEnoughData,
                     "an Unknown snapshot is not meaningful")
        precondition(HealthHistory.trend(for: current, history: [snapshot(-7_200, free: 120 * gb)]) == .gettingWorse)
        precondition(HealthHistory.trend(for: current, history: [snapshot(-7_200, free: 98 * gb)]) == .stable, "2 GB is noise on 500 GB")
        precondition(HealthHistory.trend(for: current, history: [snapshot(-7_200, free: 80 * gb)]) == .improving)
        let small = storageResult(free: 20 * gb, total: 64 * gb)
        precondition(HealthHistory.trend(for: small, history: [snapshot(-7_200, free: 24 * gb, total: 64 * gb)]) == .gettingWorse, "4 GB is over 5% of 64 GB")
        let low = storageResult(free: 30 * gb)
        precondition(HealthHistory.trend(for: low, history: [snapshot(-7_200, free: 10 * gb)]) == .gettingWorse, "Healthy → Attention is getting worse")
        precondition(HealthHistory.trend(for: current, history: [snapshot(-7_200, storage: .attention, free: 100 * gb)]) == .improving)
        let battery = HealthScanner.batteryResult(.properties(Fake.appleSilicon.merging(["MaxCapacity": 92]) { $1 }), power: PowerSourceInfo(found: true), now: now)
        precondition(HealthHistory.trend(for: battery, history: [HealthSnapshot(date: now.addingTimeInterval(-86_400), states: [.battery: .healthy], batteryMaxCapacity: 95)]) == .gettingWorse)
        precondition(HealthHistory.trend(for: battery, history: [HealthSnapshot(date: now.addingTimeInterval(-86_400), states: [.battery: .healthy], batteryMaxCapacity: 91)]) == .stable)
        let memory = HealthScanner.memoryResult(history: [], readings: [sample(1, at: 0, swap: 4 << 30)], previousSwap: nil, topApps: [], now: now)
        precondition(HealthHistory.trend(for: memory, history: [HealthSnapshot(date: now.addingTimeInterval(-3_600), states: [.memory: .healthy], swapUsed: 1 << 30)]) == .gettingWorse)
        // Repeated warnings: first/last observation of the unbroken run ending now.
        let runHistory = [snapshot(-4 * 86_400, storage: .healthy), snapshot(-3 * 86_400, storage: .attention),
                          snapshot(-2 * 86_400, storage: .unknown), snapshot(-86_400, storage: .attention)]
        let annotated = HealthHistory.annotate(low, history: runHistory)
        precondition(annotated.repeated && annotated.firstObserved == now.addingTimeInterval(-3 * 86_400) && annotated.lastObserved == now)
        precondition(annotated.comparison?.contains("Same as the previous check") == true)
        precondition(HealthHistory.repeatedSince(.storage, state: .attention, now: now, history: runHistory + [snapshot(-3_600, storage: .healthy)]) == nil)
        precondition(HealthHistory.repeatedSince(.storage, state: .healthy, now: now, history: runHistory) == nil)
        precondition(HealthHistory.comparison(for: current, history: []) == nil)
        precondition(HealthHistory.comparison(for: current, history: [snapshot(-7_200, free: 120 * gb)])?.contains("Free space was") == true)

        // Storage forecast.
        func declining(days: Int, from start: Int64, perDay: Int64, noise: [Int64] = []) -> [HealthSnapshot] {
            (0..<days).map { day in
                let free = start - Int64(day) * perDay + (noise.isEmpty ? 0 : noise[day % noise.count])
                return snapshot(-Double(days - day) * 86_400, free: free)
            }
        }
        // 2 GB a day from 100 GB: now 88 GB, threshold 50 GB → 19 days → about 3 weeks.
        let steady = declining(days: 6, from: 100 * gb, perDay: 2 * gb)
        let forecast = HealthHistory.storageForecast(free: 88 * gb, total: 500 * gb, now: now, history: steady)
        precondition(forecast == "Estimate: at the recent rate of change, free space may fall below 10% in about 3 weeks.", forecast ?? "nil")
        precondition(HealthHistory.annotate(storageResult(free: 88 * gb), history: steady).forecast == forecast, "the Storage card shows the estimate")
        precondition(HealthHistory.storageForecast(free: 88 * gb, total: 500 * gb, now: now, history: Array(steady.suffix(2))) == nil, "too few snapshots")
        let short = (0..<5).map { snapshot(-Double(5 - $0) * 30_000, free: 100 * gb - Int64($0) * 2 * gb) }
        precondition(HealthHistory.storageForecast(free: 90 * gb, total: 500 * gb, now: now, history: short) == nil, "under 3 days of data")
        let noisy = declining(days: 8, from: 100 * gb, perDay: 1 * gb, noise: [30 * gb, -25 * gb, 20 * gb, -30 * gb])
        precondition(HealthHistory.storageForecast(free: 92 * gb, total: 500 * gb, now: now, history: noisy) == nil, "an unstable trend shows no estimate")
        let flat = declining(days: 6, from: 100 * gb, perDay: 0)
        precondition(HealthHistory.storageForecast(free: 100 * gb, total: 500 * gb, now: now, history: flat) == nil, "flat shows no estimate")
        let rising = declining(days: 6, from: 100 * gb, perDay: -2 * gb)
        precondition(HealthHistory.storageForecast(free: 112 * gb, total: 500 * gb, now: now, history: rising) == nil, "rising shows no estimate")
        precondition(HealthHistory.storageForecast(free: 40 * gb, total: 500 * gb, now: now, history: declining(days: 6, from: 52 * gb, perDay: 2 * gb)) == nil,
                     "already below 10%")
        let slow = declining(days: 6, from: 300 * gb, perDay: gb / 2)
        precondition(HealthHistory.storageForecast(free: 297 * gb, total: 500 * gb, now: now, history: slow) == nil, "more than 90 days away")
        let fast = declining(days: 6, from: 140 * gb, perDay: 15 * gb)
        precondition(HealthHistory.storageForecast(free: 51 * gb, total: 500 * gb, now: now, history: fast) == nil, "less than a day away")
        let quick = declining(days: 6, from: 100 * gb, perDay: 5 * gb)
        precondition(HealthHistory.storageForecast(free: 70 * gb, total: 500 * gb, now: now, history: quick)?.hasSuffix("about 4 days.") == true)
        let ancient = (0..<6).map { snapshot(-Double(40 + $0) * 86_400, free: 200 * gb + Int64($0) * gb) }
        precondition(HealthHistory.storageForecast(free: 88 * gb, total: 500 * gb, now: now, history: ancient) == nil, "older than 30 days is ignored")
        collect(annotated)
    }

    // MARK: Score

    /// Randomized results from the real rules: the score is always 100 − Σdeductions (floored), the "Why this score?"
    /// lines are exactly the deductions and zero-point notes, and related findings never stack.
    static func scoreInvariants() -> Int {
        var random = SplitMix(state: 20_261_106)
        let conditions: [String?] = [nil, nil, "Normal", "Service Recommended", "Good", "Poor"]
        let smart: [String?] = ["Verified", "Verified", "Failing", "Not Supported", nil]
        let sipOutputs = ["System Integrity Protection status: enabled.", "System Integrity Protection status: disabled.", "garbage"]
        let rounds = 400
        for round in 0..<rounds {
            var categories: [HealthCategoryResult] = []
            let capacity = Int.random(in: 60...100, using: &random)
            var properties = Fake.appleSilicon
            properties["MaxCapacity"] = capacity
            properties["CycleCount"] = Int.random(in: 0...1_400, using: &random)
            let battery: BatteryRegistryRead = round % 17 == 0 ? .noBattery : .properties(properties)
            categories.append(HealthScanner.batteryResult(battery, power: PowerSourceInfo(found: true, condition: conditions.randomElement(using: &random)!), now: now))
            let total = [64, 256, 500, 1_000, 2_000].randomElement(using: &random)! * gb
            let free = Int64.random(in: 0...(total / 3), using: &random)
            categories.append(HealthScanner.storageResult(round % 23 == 0 ? nil : StorageValues(total: total, important: free, available: nil), breakdown: [], now: now))
            let levels = (0..<Int.random(in: 0...14, using: &random)).map { _ in [1, 1, 2, 4].randomElement(using: &random)! }
            categories.append(HealthScanner.memoryResult(history: monitor(levels), readings: [sample([1, 2, 4].randomElement(using: &random)!, at: 0, swap: UInt64.random(in: 0...(8 << 30), using: &random))],
                                                         previousSwap: UInt64.random(in: 0...(4 << 30), using: &random), topApps: [], now: now))
            let count = Int.random(in: 1...21, using: &random)
            let thermal = (0..<count).map { reading([0, 1, 2, 2, 3].randomElement(using: &random)!, at: Double($0 - count + 1)) }
            let previous = Bool.random(using: &random) ? HealthSnapshot(date: now.addingTimeInterval(-Double.random(in: 0...3_600, using: &random)), thermalState: Int.random(in: 0...3, using: &random)) : nil
            categories.append(HealthScanner.temperatureResult(thermal, previous: previous, now: now))
            let disks = (0..<Int.random(in: 1...3, using: &random)).map { index in
                HealthScanner.diskItem(identifier: "disk\(index)", plistOutput: Fake.disk("disk\(index)", smart: smart.randomElement(using: &random)!), status: 0)
            }
            categories.append(HealthScanner.diskResult(disks, mode: .extended, now: now))
            let items = [HealthScanner.sipItem(output: sipOutputs.randomElement(using: &random)!),
                         HealthScanner.gatekeeperItem(output: Bool.random(using: &random) ? "assessments enabled" : "assessments disabled"),
                         HealthScanner.fileVaultItem(output: Bool.random(using: &random) ? "FileVault is On." : "FileVault is Off."),
                         HealthScanner.firewallItem(output: Bool.random(using: &random) ? "Firewall is enabled. (State = 1)" : "Firewall is disabled. (State = 0)"),
                         HealthScanner.xprotectItem([Bool.random(using: &random) ? "5368" : nil])]
            categories.append(HealthScanner.securityResult(items, now: now))
            let prefs = HealthScanner.UpdatePreferences(automaticCheck: [nil, true, false].randomElement(using: &random)!,
                                                        lastSuccessfulCheck: Bool.random(using: &random) ? now.addingTimeInterval(-Double.random(in: 0...(60 * 86_400), using: &random)) : nil)
            let list: HealthScanner.SoftwareUpdateListRead = [.notChecked, .list(available: 1, recommended: 1, titles: ["x"]), .list(available: 0, recommended: 0, titles: [])].randomElement(using: &random)!
            categories.append(HealthScanner.updatesResult(prefs, list: list, now: now))
            // Drop some categories, as a cancelled check would.
            var finished: [HealthCategory: HealthCategoryResult] = [:]
            for category in categories where round % 5 != 0 || Bool.random(using: &random) { finished[category.category] = category }
            let result = HealthCheckResult.assemble(mode: .extended, startedAt: now, finishedAt: now, finished: finished, cancelled: finished.count < 7)
            let score = result.scoreDetails
            let sum = score.deductions.reduce(0) { $0 + $1.points }
            precondition(result.score == max(0, 100 - sum) && score.final == result.score && score.base == 100, "score == 100 − Σdeductions")
            precondition(score.deductions == HealthScoring.score(result.categories).deductions)
            let lines = score.lines
            precondition(lines.count == score.deductions.count + score.zeroPointNotes.count + 2, "one line per deduction and note")
            precondition(lines.first! == (label: "Base score", value: "100") && lines.last!.value == "\(score.final)")
            for (index, deduction) in score.deductions.enumerated() {
                precondition(lines[index + 1] == (label: HealthScore.lineLabel(deduction), value: "−\(deduction.points)"), "line \(index + 1) is the deduction")
                precondition(deduction.points > 0 && !deduction.reason.isEmpty && !deduction.recommendation.isEmpty)
            }
            for (index, note) in score.zeroPointNotes.enumerated() {
                precondition(lines[score.deductions.count + 1 + index] == (label: note, value: "0"))
            }
            precondition(zip(score.deductions, score.deductions.dropFirst()).allSatisfy { $0.points >= $1.points }, "largest first")
            for category in result.categories {
                let points = category.deductions.reduce(0) { $0 + $1.points }
                precondition(points <= HealthScoring.caps[category.category]!, "\(category.category) is within its cap")
                precondition(category.category == .security || category.deductions.count <= 1, "\(category.category) deducts at most once")
                if category.state == .unknown || category.state == .healthy { precondition(category.deductions.isEmpty, "\(category.category) \(category.state) never deducts") }
                if category.state == .attention || category.state == .critical {
                    precondition(!category.deductions.isEmpty || category.category == .security, "a non-healthy state is explained by a deduction")
                    precondition(category.recommendation != nil, "\(category.category) \(category.state) has a recommendation")
                }
                if category.category == .temperature { precondition(category.state != .critical, "temperature is never Critical") }
            }
            let markdown = result.markdown()
            precondition(score.deductions.allSatisfy { markdown.contains("−\($0.points) [\($0.severity.label)") }, "markdown lists every deduction")
            if round % 20 == 0 { collect(result) }
        }
        return rounds
    }

    // MARK: Presentation

    static func presentation() {
        // Card order: severity, then confidence, then category.
        func card(_ category: HealthCategory, _ state: HealthState, _ confidence: HealthConfidence) -> HealthCategoryResult {
            HealthCategoryResult(category: category, state: state, summary: "", confidence: confidence, observedAt: now)
        }
        let shuffled = [card(.updates, .unknown, .low), card(.battery, .healthy, .medium), card(.storage, .attention, .high),
                        card(.memory, .attention, .medium), card(.diskHealth, .critical, .high), card(.security, .healthy, .high),
                        card(.temperature, .attention, .high)]
        precondition(HealthOrdering.sorted(shuffled).map(\.category) == [.diskHealth, .storage, .temperature, .memory, .security, .battery, .updates])
        // Accessibility label: category, state, main measurement and recommendation.
        let storage = HealthScanner.storageResult(StorageValues(total: 500 * gb, important: 30 * gb, available: nil), breakdown: [], now: now)
        let label = HealthAccessibility.label(for: storage)
        precondition(label.hasPrefix("Storage: Attention.") && label.contains("Free space: \((30 * gb).formattedBytes).")
                     && label.contains("Recommendation: " + storage.recommendation!) && label.contains("Confidence: High."), label)
        let empty = HealthCategoryResult.notChecked(.memory, cancelled: true, at: now)
        precondition(HealthAccessibility.label(for: empty) == "Memory: Unknown. Not checked — cancelled. Confidence: Low.")
        // Summary sentences.
        func result(_ states: [HealthCategory: HealthState]) -> String {
            HealthSummary.sentence(for: HealthCategory.allCases.map { card($0, states[$0] ?? .healthy, .high) }, cancelled: false, partial: false)
        }
        precondition(result([.storage: .attention]) == "Your Mac is generally healthy. Storage needs attention, and no critical hardware condition was reported.")
        precondition(result([:]) == "No issues were found in the readings macOS reported.")
        precondition(result([.storage: .attention, .security: .attention]).contains("Storage and Security need attention"))
        precondition(result([.diskHealth: .critical, .storage: .attention]) == "Disk Health needs prompt attention, and Storage needs attention. The cards below explain what macOS reported and what to do next.")
        let cancelled = HealthSummary.sentence(for: [card(.battery, .healthy, .high)] + HealthCategory.allCases.dropFirst().map { _ in card(.storage, .unknown, .low) },
                                               cancelled: true, partial: true)
        precondition(cancelled.hasSuffix("The check was cancelled, so some categories were not checked."))
        for states in [[HealthCategory.storage: HealthState.attention], [:], [.diskHealth: .critical, .memory: .critical, .updates: .attention]] {
            texts.append((result(states), false))
        }
        // Markdown structure.
        var fake = Fake()
        fake.storage = StorageValues(total: 500 * gb, important: 30 * gb, available: 25 * gb)
        fake.outputs["/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"] = ("Firewall is disabled. (State = 0)\n", 0)
        let report = fake.check(breakdown: [HealthContextEntry(name: "Applications", bytes: 40 * gb)],
                                apps: [HealthContextEntry(name: "Secret App", bytes: 1 << 30)])
        precondition(report.score == 90 && report.scoreDetails.arithmetic == "100 − 10 = 90")
        precondition(report.categories.map(\.category).prefix(2) == [.storage, .security], "attention cards first, high confidence first")
        let markdown = report.markdown()
        for expected in ["# Mac Health Report", "Score 90/100 · 0 critical · 2 need attention", "## Why this score?", "| Base score | 100 |",
                         "| Storage: ", "| −8 |", "| Final score | 90 |", HealthScore.disclaimer, "## Storage — Attention", "## Battery — Healthy",
                         "Applications — 40 GB", "This Mac: MacBook Air (13-inch, M5) · Apple M5 · 16 GB memory · macOS 27.2"] {
            precondition(markdown.contains(expected), "markdown lacks \(expected.debugDescription)")
        }
        precondition(!markdown.contains("Secret App"), "app names stay out of the exported report")
        precondition("Score \(report.score)" == "Score 90", "report.score interpolates as a number")
        precondition(report.count(.attention) == 2 && report.count(.critical) == 0)
        collect(report)
    }

    // MARK: Model

    @MainActor static func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for \(what)")
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func model(root: URL) async throws {
        let url = root.appending(path: "model").appending(path: "health-history.json")
        let store = HealthHistoryStore(url: url)
        var opened: [URL] = []
        var fake = Fake()
        fake.storage = StorageValues(total: 500 * gb, important: 30 * gb, available: nil)
        let model = HealthModel(system: fake.system(), history: store, opener: { opened.append($0); return true })
        precondition(model.mode == .quick && model.report == nil && !model.loading)
        model.storageBreakdown = { [(name: "Applications", bytes: 40 * gb), (name: "Documents", bytes: 30 * gb)] }
        model.topApps = { [(name: "Safari", bytes: 2 << 30)] }
        model.memoryHistory = { monitor(Array(repeating: 2, count: 12)) }
        model.refresh()
        precondition(model.loading && model.runningMode == .quick, "refresh starts at once")
        model.refresh()   // ignored while running
        await eventually("the model to finish") { !model.loading }
        guard let report = model.report else { preconditionFailure("a report") }
        precondition(report.categories.count == 7 && report.mode == .quick && !report.isPartial)
        precondition(report.category(.memory)?.state == .attention, "the injected memory history is judged")
        precondition(report.category(.storage)?.context.first == "Applications — 40 GB" && report.category(.memory)?.context == ["Safari — 2 GB"])
        precondition(model.progress.isEmpty && model.pendingCategories.isEmpty && model.displayedCategories.count == 7)
        precondition(model.open(.storage) && opened == [HealthSettingsLink.storage.url], "the model opens settings through the injected opener")
        store.flush()
        var saved = store.storedSnapshots
        precondition(saved.count == 1 && saved[0].score == report.score && saved[0].states[.storage] == .attention && !saved[0].partial)
        precondition(FileManager.default.fileExists(atPath: url.path), "history is written to the temporary location")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600, "health history is readable only by the user")
        fake.clock.value = now.addingTimeInterval(60)
        // A second run sees the first in its history.
        model.refresh(mode: .extended)
        precondition(model.mode == .extended)
        await eventually("the second run") { !model.loading }
        store.flush()
        saved = store.storedSnapshots
        precondition(saved.count == 2 && saved[1].mode == .extended)
        precondition(model.report?.category(.storage)?.comparison?.contains("Same as the previous check") == true, "the previous run is compared")
        precondition(model.report?.category(.storage)?.repeated == true, "a repeated warning shows when it was first observed")
        precondition(model.report?.category(.storage)?.trend == .notEnoughData, "two runs seconds apart are not a trend")
        // Default init still works (the integrator's call), and its store honours the override.
        let plain = HealthModel()
        precondition(plain.history.url.path == ProcessInfo.processInfo.environment[HealthHistoryStore.locationOverride], "the default store uses the override")
        precondition(plain.report == nil && !plain.loading)
    }

    @MainActor static func cancellation(root: URL) async throws {
        let url = root.appending(path: "cancel").appending(path: "health-history.json")
        let store = HealthHistoryStore(url: url)
        // Security and disk commands hang, and so does the cancelled run's final read, so its result arrives after the newer run.
        let gate = Gate(["/usr/bin/csrutil", "/usr/sbin/spctl", "/usr/bin/fdesetup", "/usr/libexec/ApplicationFirewall/socketfilterfw",
                         "/usr/sbin/diskutil", "machine"])
        var fake = Fake()
        fake.gate = gate
        fake.thermal = [.serious]
        let model = HealthModel(system: fake.system(), history: store, opener: { _ in false })
        model.refresh(mode: .extended)
        // Battery, storage, memory, temperature and updates finish; security and disk health stay blocked.
        await eventually("five categories to publish") { model.progress.count == 5 }
        precondition(model.loading && Set(model.pendingCategories) == [.security, .diskHealth], "categories publish as each finishes")
        precondition(model.displayedCategories.first?.category == .temperature, "progress is shown in card order")
        await eventually("the blocked commands to start") { gate.blocked >= 2 }
        model.cancel()
        guard let partial = model.report else { preconditionFailure("cancel keeps a partial result") }
        precondition(!model.loading && partial.cancelled && partial.isPartial && partial.mode == .extended)
        for category in [HealthCategory.security, .diskHealth] {
            let result = partial.category(category)!
            precondition(result.state == .unknown && result.cancelledReason == "Not checked — cancelled" && result.deductions.isEmpty)
        }
        precondition(partial.category(.temperature)?.state == .attention && partial.category(.battery)?.state == .healthy, "finished categories are kept")
        precondition(partial.score == 95 && partial.scoreDetails.zeroPointNotes.contains("Security not checked — cancelled"))
        precondition(partial.summary.contains("The check was cancelled"), partial.summary)
        // A newer run starts and finishes while the cancelled run's commands are still stuck.
        gate.deactivate()
        fake.clock.value = now.addingTimeInterval(120)
        model.refresh(mode: .quick)
        await eventually("the newer run") { !model.loading }
        guard let newer = model.report else { preconditionFailure("newer report") }
        precondition(!newer.cancelled && !newer.isPartial && newer.mode == .quick && newer.categories.count == 7)
        // Now the stuck commands of the cancelled run finish: nothing of theirs may replace the newer result.
        precondition(gate.blocked >= 3, "the cancelled run is still stuck, including its final read")
        gate.open()
        await eventually("the stuck commands to return") { gate.blocked == 0 }
        try await Task.sleep(for: .milliseconds(300))
        precondition(model.report?.startedAt == newer.startedAt && model.report?.mode == .quick && model.report?.cancelled == false,
                     "a late result from the cancelled run never replaces the newer run")
        precondition(model.progress.isEmpty && !model.loading)
        store.flush()
        let saved = store.storedSnapshots
        precondition(saved.count == 2 && saved[0].partial && !saved[1].partial, "one snapshot per run, the cancelled one flagged partial")
        collect(partial)
        // The scanner itself returns promptly on cancellation even when readers never return.
        let stuck = Gate(["/usr/sbin/diskutil"])
        var direct = Fake()
        direct.gate = stuck
        let token = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let start = Date()
        let directSystem = direct.system()
        let result = await BackgroundWork.run { HealthScanner.check(.init(mode: .extended), system: directSystem, cancellation: token) }
        precondition(Date().timeIntervalSince(start) < 2, "check returns soon after cancellation")
        precondition(result.cancelled && result.category(.diskHealth)?.cancelledReason != nil && result.category(.battery)?.state == .healthy)
        stuck.open()
    }

    // MARK: Live

    @MainActor static func liveQuick() async throws -> (elapsed: TimeInterval, score: Int, critical: Int, attention: Int) {
        precondition(ProcessInfo.processInfo.environment[HealthHistoryStore.locationOverride] != nil, "never write the user's real history")
        let model = HealthModel()   // live system, default store at the throwaway override
        let start = Date()
        model.refresh(mode: .quick)
        await eventually("the live Quick check", timeout: 15) { !model.loading }
        let elapsed = Date().timeIntervalSince(start)
        guard let report = model.report else { preconditionFailure("live report") }
        precondition(elapsed < 15, "live Quick check took \(elapsed) s")
        precondition(report.categories.count == 7 && Set(report.categories.map(\.category)) == Set(HealthCategory.allCases), "all 7 categories")
        precondition(!report.cancelled && report.score == max(0, 100 - report.scoreDetails.totalDeducted))
        precondition(report.categories.allSatisfy { !$0.summary.isEmpty && !$0.measurements.isEmpty }, "every card has a summary and a main measurement")
        precondition(report.category(.temperature)?.measurements.contains { $0.label == "Readings" } == true)
        model.history.flush()
        precondition(model.history.storedSnapshots.count >= 1, "the live run saved a snapshot to the throwaway history")
        if ProcessInfo.processInfo.environment["HEALTH_CHECK_PRINT"] != nil { print(report.markdown()) }
        collect(report)
        return (elapsed, report.score, report.count(.critical), report.count(.attention))
    }

    // MARK: Wording

    /// No fear-based or absolute claims anywhere a user reads.
    static func wording() -> Int {
        let banned = ["unsafe", "damaged", "dangerous", "your mac is secure", "battery is healthy", "is secure", "are secure",
                      "at risk", "overheating", "is safe", "no problems", "nothing wrong", "all good", "is protected"]
        for (text, failingDisk) in texts {
            let lower = text.lowercased()
            if let phrase = banned.first(where: lower.contains) { preconditionFailure("banned phrase \(phrase.debugDescription) in \(text.debugDescription)") }
            if lower.contains("failing") { precondition(failingDisk, "\"failing\" only for a real SMART failure: \(text.debugDescription)") }
        }
        return texts.count
    }
}
