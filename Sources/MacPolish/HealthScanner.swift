import AppKit
import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - Vocabulary

/// The seven areas Mac Health reads. Each becomes one card and contributes at most one deduction (Security: one per
/// setting, capped), so related findings never stack.
enum HealthCategory: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    case battery, storage, memory, temperature, diskHealth, security, updates

    var displayName: String {
        switch self {
        case .battery: "Battery"
        case .storage: "Storage"
        case .memory: "Memory"
        case .temperature: "Temperature"
        case .diskHealth: "Disk Health"
        case .security: "Security"
        case .updates: "System Updates"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .storage: "internaldrive"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .diskHealth: "externaldrive.badge.checkmark"
        case .security: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// How one category (or one item inside it) reads. Always shown as an icon plus this label, never by color alone.
enum HealthState: String, Codable, Sendable, CaseIterable {
    case healthy, attention, critical, unknown

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .attention: "Attention"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    /// Each state has its own shape, so icons stay distinct without color.
    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        case .unknown: "questionmark.circle"
        }
    }

    /// Severity: critical 3 > attention 2 > healthy 1 > unknown 0. Unknown is "not measured", not "better".
    var severityRank: Int {
        switch self {
        case .critical: 3
        case .attention: 2
        case .healthy: 1
        case .unknown: 0
        }
    }
}

enum HealthConfidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// Display order: high first.
    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}

enum HealthTrend: String, Codable, Sendable {
    case stable, improving, gettingWorse, notEnoughData

    var label: String {
        switch self {
        case .stable: "Stable"
        case .improving: "Improving"
        case .gettingWorse: "Getting worse"
        case .notEnoughData: "Not enough data"
        }
    }

    var symbol: String {
        switch self {
        case .stable: "equal.circle"
        case .improving: "arrow.up.right.circle"
        case .gettingWorse: "arrow.down.right.circle"
        case .notEnoughData: "minus.circle"
        }
    }
}

/// What a check reads. Neither mode changes anything.
enum HealthMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case quick, extended

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick: "Quick"
        case .extended: "Extended"
        }
    }

    var scope: String {
        switch self {
        case .quick:
            "Battery, storage, current memory pressure with recent history, three thermal readings, security settings, "
                + "update preferences and the SMART status of the startup disk."
        case .extended:
            "Everything in Quick, plus repeated memory-pressure and thermal readings over about 20 seconds, the SMART "
                + "status of every physical disk, and the software update list macOS has already downloaded."
        }
    }

    var thermalSampler: HealthScanner.ThermalSampler {
        switch self {
        case .quick: .quick
        case .extended: .extended
        }
    }

    var memorySampler: HealthScanner.MemorySampler {
        switch self {
        case .quick: .quick
        case .extended: .extended
        }
    }
}

// MARK: - Results

/// One reading shown on a card. A nil value is shown as "Not Available".
struct HealthMeasurement: Sendable, Equatable {
    static let notAvailable = "Not Available"
    let label: String
    let value: String?
    var note: String?

    init(_ label: String, _ value: String?, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }

    var displayValue: String { value ?? Self.notAvailable }
}

/// Status of one security setting or one physical disk.
enum HealthItemStatus: String, Codable, Sendable {
    // Security settings
    case enabled, disabled
    // Physical disks
    case healthy, failing, permissionLimited
    // Either
    case unsupported, unreadable, unknown

    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .healthy: "Healthy"
        case .failing: "Failing"
        case .permissionLimited: "Permission Limited"
        case .unsupported: "Unsupported"
        case .unreadable: "Unreadable"
        case .unknown: "Unknown"
        }
    }

    var state: HealthState {
        switch self {
        case .enabled, .healthy: .healthy
        case .disabled: .attention
        case .failing: .critical
        case .permissionLimited, .unsupported, .unreadable, .unknown: .unknown
        }
    }
}

/// A System Settings destination for a recommendation. Only offered where the destination is reliable.
enum HealthSettingsLink: String, Codable, Sendable, CaseIterable {
    case battery, storage, privacySecurity, network, softwareUpdate

    var url: URL {
        switch self {
        case .battery: URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        case .storage: URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        case .privacySecurity: URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        case .network: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
        case .softwareUpdate: URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
        }
    }

    var title: String {
        switch self {
        case .battery: "Open Battery Settings"
        case .storage: "Open Storage Settings"
        case .privacySecurity: "Open Privacy & Security"
        case .network: "Open Network Settings"
        case .softwareUpdate: "Open Software Update"
        }
    }

    /// Opened when the pane URL is refused, like `PrivacyPane.open()`.
    static let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// Tries the pane, then System Settings itself. `opener` is injectable so checks never open anything.
    @discardableResult
    func open(with opener: (URL) -> Bool) -> Bool {
        opener(url) || opener(Self.systemSettingsURL)
    }
}

/// One security setting or one physical disk.
struct HealthItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let status: HealthItemStatus
    /// Extra wording for the status, e.g. "custom configuration".
    var statusDetail: String?
    let severity: String
    let confidence: HealthConfidence
    let whyItMatters: String
    /// What was read, e.g. "csrutil reports: enabled."
    var detail: String
    var recommendation: String?
    var settingsLink: HealthSettingsLink?
    /// Points this item took off the score (Security only); filled in by `HealthScoring`.
    var points = 0

    var state: HealthState { status.state }
    var statusLabel: String { statusDetail.map { "\(status.label) (\($0))" } ?? status.label }

    init(id: String, title: String, status: HealthItemStatus, statusDetail: String? = nil, severity: String,
         confidence: HealthConfidence, whyItMatters: String, detail: String, recommendation: String? = nil,
         settingsLink: HealthSettingsLink? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.statusDetail = statusDetail
        self.severity = severity
        self.confidence = confidence
        self.whyItMatters = whyItMatters
        self.detail = detail
        self.recommendation = recommendation
        self.settingsLink = settingsLink
    }
}

/// The numbers a category saves to history. No names, no paths.
struct HealthMetrics: Sendable, Equatable {
    var storageFree: Int64?
    var storageTotal: Int64?
    var swapUsed: UInt64?
    var pressureLevel: Int?
    var thermalState: Int?
    var batteryMaxCapacity: Int?
    var batteryCycles: Int?

    mutating func merge(_ other: HealthMetrics) {
        storageFree = storageFree ?? other.storageFree
        storageTotal = storageTotal ?? other.storageTotal
        swapUsed = swapUsed ?? other.swapUsed
        pressureLevel = pressureLevel ?? other.pressureLevel
        thermalState = thermalState ?? other.thermalState
        batteryMaxCapacity = batteryMaxCapacity ?? other.batteryMaxCapacity
        batteryCycles = batteryCycles ?? other.batteryCycles
    }
}

/// A name and size shown as context (largest storage categories, apps using the most memory). Never scored or saved.
struct HealthContextEntry: Sendable, Equatable {
    let name: String
    let bytes: Int64
}

struct HealthCategoryResult: Identifiable, Sendable, Equatable {
    var id: HealthCategory { category }
    let category: HealthCategory
    var state: HealthState
    /// One or two plain sentences.
    var summary: String
    /// The first is the card's main measurement.
    var measurements: [HealthMeasurement] = []
    var recommendation: String?
    var confidence: HealthConfidence
    var observedAt: Date
    var items: [HealthItem] = []
    var trend: HealthTrend = .notEnoughData
    /// For a repeated or sustained non-healthy state: when it was first and last seen.
    var firstObserved: Date?
    var lastObserved: Date?
    /// True when earlier checks reported the same non-healthy state without a healthy check in between.
    var repeated = false
    var comparison: String?
    /// Storage only.
    var forecast: String?
    var contextTitle: String?
    var context: [String] = []
    /// Informational notes that do not change the state (for example "momentary — check again later").
    var notes: [String] = []
    var settingsLink: HealthSettingsLink?
    /// Set when the category was not checked because the check was cancelled.
    var cancelledReason: String?
    /// Set when the readings could not be taken; the category is Unknown and the result partial.
    var failedReason: String?
    /// Filled in by `HealthScoring` only.
    var deductions: [HealthDeduction] = []
    var zeroPointNotes: [String] = []
    var metrics = HealthMetrics()

    init(category: HealthCategory, state: HealthState = .unknown, summary: String = "",
         confidence: HealthConfidence = .low, observedAt: Date) {
        self.category = category
        self.state = state
        self.summary = summary
        self.confidence = confidence
        self.observedAt = observedAt
    }

    mutating func apply(_ outcome: HealthScoring.Outcome) {
        state = outcome.state
        confidence = outcome.confidence
        deductions = outcome.deductions
        zeroPointNotes = outcome.zeroPointNotes
    }

    /// A category that did not finish: Unknown, no deduction.
    static func notChecked(_ category: HealthCategory, cancelled: Bool, reason: String? = nil, at date: Date) -> Self {
        var result = HealthCategoryResult(category: category, observedAt: date)
        if cancelled {
            result.summary = "Not checked — cancelled."
            result.cancelledReason = "Not checked — cancelled"
            result.zeroPointNotes = ["\(category.displayName) not checked — cancelled"]
        } else {
            let reason = reason ?? "The check did not finish"
            result.summary = "Not checked — \(reason.lowercasedFirst)."
            result.failedReason = reason
            result.zeroPointNotes = ["\(category.displayName) not checked"]
        }
        return result
    }
}

/// Points one category (or one Security setting) took off the score, and why. Produced only by `HealthScoring`.
struct HealthDeduction: Identifiable, Sendable, Equatable {
    let id: String
    let category: HealthCategory
    let reason: String
    let severity: HealthState
    let confidence: HealthConfidence
    let points: Int
    let recommendation: String
}

/// 100 minus the deductions, floored at 0, with every line of the calculation.
struct HealthScore: Sendable, Equatable {
    static let disclaimer = "An estimate from a few readings reported by macOS — not a hardware diagnosis or a security audit."
    let base = 100
    /// Largest first.
    let deductions: [HealthDeduction]
    /// Readings that were considered and deliberately cost nothing, e.g. "Temporary high temperature".
    let zeroPointNotes: [String]

    init(deductions: [HealthDeduction], zeroPointNotes: [String]) {
        self.deductions = deductions
        self.zeroPointNotes = zeroPointNotes
    }

    var totalDeducted: Int { deductions.reduce(0) { $0 + $1.points } }
    var final: Int { max(0, base - totalDeducted) }

    static func lineLabel(_ deduction: HealthDeduction) -> String {
        "\(deduction.category.displayName): \(deduction.reason)"
    }

    /// The table behind "Why this score?": base, every deduction, every zero-point note, then the final score.
    var lines: [(label: String, value: String)] {
        var lines: [(label: String, value: String)] = [(label: "Base score", value: "\(base)")]
        lines += deductions.map { (label: Self.lineLabel($0), value: "−\($0.points)") }
        lines += zeroPointNotes.map { (label: $0, value: "0") }
        lines.append((label: totalDeducted > base ? "Final score (never below 0)" : "Final score", value: "\(final)"))
        return lines
    }

    /// "100 − 23 = 77".
    var arithmetic: String {
        totalDeducted > base ? "\(base) − \(totalDeducted), floored at 0 = \(final)" : "\(base) − \(totalDeducted) = \(final)"
    }
}

// MARK: - Scoring rules

/// The one rule table behind the score. Pure functions of the readings; nothing else assigns states or points.
///
/// Principles:
/// - Each category contributes at most one deduction, for its worst condition, so related readings (battery
///   condition and capacity, low free space and percentage, memory pressure and swap) never stack. Security is the
///   exception: its settings are independent protections, so each one that is off counts, capped at 20 in total.
/// - Unknown never deducts: a reading that could not be taken neither lowers nor raises the score.
/// - Temporary readings never deduct: memory pressure and thermal state rise briefly in normal use, so only
///   sustained or repeated conditions count. Momentary ones are listed with 0 points so the user sees they counted.
/// - The caps keep the categories in proportion: a SMART failure (25) outweighs everything else, then security
///   (20), battery service and very low storage (15 each), memory pressure (12), heat and updates (8 each).
enum HealthScoring {
    static let caps: [HealthCategory: Int] = [.battery: 15, .storage: 15, .memory: 12, .temperature: 8,
                                              .diskHealth: 25, .security: 20, .updates: 8]

    struct Outcome: Sendable, Equatable {
        var state: HealthState
        var confidence: HealthConfidence
        var deductions: [HealthDeduction] = []
        var zeroPointNotes: [String] = []
    }

    static func score(_ categories: [HealthCategoryResult]) -> HealthScore {
        let deductions = categories.flatMap(\.deductions).enumerated()
            .sorted { $0.element.points != $1.element.points ? $0.element.points > $1.element.points : $0.offset < $1.offset }
            .map(\.element)
        return HealthScore(deductions: deductions, zeroPointNotes: categories.flatMap(\.zeroPointNotes))
    }

    // MARK: Battery (cap 15)

    /// Rationale cited on the card: Apple's published battery guidance.
    static let batteryGuidance = "Apple's published battery guidance: Mac notebook batteries are designed to retain up to "
        + "80% of their original capacity at their rated maximum cycle count."
    static let batteryCapacityThreshold = 80
    /// Conditions macOS reports when it recommends service. Matched case-insensitively.
    static let batteryServiceConditions = ["service recommended", "service battery", "check battery", "replace soon",
                                           "replace now", "poor", "permanent battery failure"]

    static func batteryNeedsService(_ condition: String) -> Bool {
        let text = condition.lowercased()
        return batteryServiceConditions.contains { text.contains($0) }
    }

    /// 1. A condition macOS reports is the strongest signal: a service condition is Critical (−15, high confidence);
    ///    a normal condition is Healthy even with capacity below 80%, because macOS has not flagged the battery.
    /// 2. Without a condition, capacity below 80% or cycles at or past the rated count is Attention (−5, low
    ///    confidence: a heuristic based on Apple's guidance, not a macOS verdict).
    /// 3. Otherwise Healthy (medium confidence without a condition), or Unknown when nothing was readable.
    static func battery(condition: String?, capacity: Int?, cycles: Int?, designCycles: Int?) -> Outcome {
        let lowCapacity = capacity.map { $0 < batteryCapacityThreshold } ?? false
        let pastRated = cycles.flatMap { cycles in designCycles.map { cycles >= $0 } } ?? false
        if let condition, !condition.isEmpty {
            if batteryNeedsService(condition) {
                return Outcome(state: .critical, confidence: .high, deductions: [HealthDeduction(
                    id: "battery", category: .battery, reason: "macOS reports the battery condition “\(condition)”",
                    severity: .critical, confidence: .high, points: 15,
                    recommendation: "Contact Apple or an Apple Authorized Service Provider about a battery service. "
                        + "Battery settings show the same condition.")])
            }
            var outcome = Outcome(state: .healthy, confidence: .high)
            if lowCapacity || pastRated {
                outcome.zeroPointNotes = ["Battery wear — macOS reports “\(condition)” and has not flagged it for service"]
            }
            return outcome
        }
        guard capacity != nil || cycles != nil else {
            return Outcome(state: .unknown, confidence: .low, zeroPointNotes: ["Battery readings not available"])
        }
        guard lowCapacity || pastRated else { return Outcome(state: .healthy, confidence: .medium) }
        var reasons: [String] = []
        if let capacity, lowCapacity { reasons.append("maximum capacity \(capacity)% is below 80%") }
        if let cycles, let designCycles, pastRated {
            reasons.append("\(cycles.formatted()) cycles is at or past the rated \(designCycles.formatted())")
        }
        return Outcome(state: .attention, confidence: .low, deductions: [HealthDeduction(
            id: "battery", category: .battery, reason: reasons.joined(separator: "; ").capitalizedFirst,
            severity: .attention, confidence: .low, points: 5,
            recommendation: "Check Battery Health in Battery settings and consider a battery service if macOS recommends one. "
                + batteryGuidance)])
    }

    // MARK: Storage (cap 15)

    static let gigabyte: Int64 = 1_000_000_000

    /// Free space counts purgeable space macOS can clear on demand. Both the absolute amount and the percentage
    /// matter: a small disk with little free space needs attention, but a 2 TB disk at 8% (160 GB free) does not.
    /// - Critical (−15, high): under 5 GB, or under 5% and under 20 GB — too little room for updates and swap.
    /// - Attention (−8, high): under 15 GB, or under 10% and under 50 GB.
    /// - Otherwise Healthy.
    static func storage(free: Int64, total: Int64) -> Outcome {
        let fraction = total > 0 ? Double(free) / Double(total) : 0
        let measured = "\(free.formattedBytes) free (\(HealthFormat.percent(fraction)) of \(total.formattedBytes))"
        if free < 5 * gigabyte || (fraction < 0.05 && free < 20 * gigabyte) {
            let rule = free < 5 * gigabyte ? "under 5 GB" : "under 5% and under 20 GB"
            return Outcome(state: .critical, confidence: .high, deductions: [HealthDeduction(
                id: "storage", category: .storage, reason: "\(measured): \(rule)",
                severity: .critical, confidence: .high, points: 15,
                recommendation: "Free up space soon: macOS needs room for updates and virtual memory. Review large items "
                    + "in Storage settings or Mac Polish's Storage Map, then empty the Trash.")])
        }
        if free < 15 * gigabyte || (fraction < 0.10 && free < 50 * gigabyte) {
            let rule = free < 15 * gigabyte ? "under 15 GB" : "under 10% and under 50 GB"
            return Outcome(state: .attention, confidence: .high, deductions: [HealthDeduction(
                id: "storage", category: .storage, reason: "\(measured): \(rule)",
                severity: .attention, confidence: .high, points: 8,
                recommendation: "Free up some space: review large items in Storage settings or Mac Polish's Storage Map, "
                    + "then empty the Trash.")])
        }
        return Outcome(state: .healthy, confidence: .high)
    }

    // MARK: Memory (cap 12)

    /// Memory pressure readings, deduplicated, within 10 minutes of the newest one.
    struct PressureWindow: Sendable, Equatable {
        static let minimumReadings = 3
        static let minimumSpan: TimeInterval = 60
        static let window: TimeInterval = 600

        var readings = 0
        var elevated = 0
        var critical = 0
        var span: TimeInterval = 0
        var latest: Int?
        var firstElevated: Date?
        var lastElevated: Date?

        init(readings: Int, elevated: Int, critical: Int = 0, span: TimeInterval, latest: Int?) {
            self.readings = readings
            self.elevated = elevated
            self.critical = critical
            self.span = span
            self.latest = latest
        }

        init(samples: [MemorySample]) {
            var seen = Set<UUID>()
            let known = samples
                .filter { [1, 2, 4].contains($0.pressure ?? 0) && seen.insert($0.id).inserted }
                .sorted { $0.date < $1.date }
            guard let newest = known.last else { return }
            let recent = known.filter { newest.date.timeIntervalSince($0.date) <= Self.window }
            let high = recent.filter { ($0.pressure ?? 0) >= 2 }
            readings = recent.count
            elevated = high.count
            critical = recent.filter { $0.pressure == 4 }.count
            span = newest.date.timeIntervalSince(recent[0].date)
            latest = newest.pressure
            firstElevated = high.first?.date
            lastElevated = high.last?.date
        }

        /// At least 3 readings over at least a minute, with Warning or Critical in at least half of them.
        var isSustained: Bool {
            readings >= Self.minimumReadings && span >= Self.minimumSpan && elevated > 0 && elevated * 2 >= readings
        }

        /// Critical in at least half of the readings.
        var isCriticalMajority: Bool { critical > 0 && critical * 2 >= readings }
    }

    static let swapGrowthThreshold: Int64 = 1 << 30

    /// RAM usage alone never changes the state: macOS fills free memory with caches on purpose.
    /// - Sustained pressure, Critical in most readings → Critical (−12, medium confidence).
    /// - Sustained pressure (Warning or above in at least half of ≥3 readings over ≥60 s) → Attention (−6, medium).
    /// - Any elevated reading that is not sustained → Healthy with a 0-point "momentary" note.
    /// - No pressure reading → Unknown.
    /// Swap and compression only support the explanation; swap growth over 1 GB since the previous check is mentioned
    /// in the reason but adds no points.
    static func memory(_ window: PressureWindow, swapGrowth: Int64?) -> Outcome {
        guard window.readings > 0 else {
            return Outcome(state: .unknown, confidence: .low, zeroPointNotes: ["Memory pressure not available"])
        }
        let over = "\(window.readings) readings over \(HealthFormat.duration(window.span))"
        let swapNote = swapGrowth.flatMap { $0 > swapGrowthThreshold ? "; swap grew by \(HealthFormat.memory(UInt64($0))) since the previous check" : nil } ?? ""
        let recommendation = "Quit apps you are not using, starting with the largest in Activity Monitor › Memory, then "
            + "check again. If pressure stays high in normal use, restart the Mac."
        if window.isSustained && window.isCriticalMajority {
            return Outcome(state: .critical, confidence: .medium, deductions: [HealthDeduction(
                id: "memory", category: .memory,
                reason: "Critical memory pressure in \(window.critical) of \(over)\(swapNote)",
                severity: .critical, confidence: .medium, points: 12, recommendation: recommendation)])
        }
        if window.isSustained {
            return Outcome(state: .attention, confidence: .medium, deductions: [HealthDeduction(
                id: "memory", category: .memory,
                reason: "Elevated memory pressure in \(window.elevated) of \(over)\(swapNote)",
                severity: .attention, confidence: .medium, points: 6, recommendation: recommendation)])
        }
        let confident = window.readings >= PressureWindow.minimumReadings && window.span >= PressureWindow.minimumSpan
        if window.elevated > 0 {
            return Outcome(state: .healthy, confidence: .medium, zeroPointNotes: ["Momentary memory pressure"])
        }
        return Outcome(state: .healthy, confidence: confident ? .high : .medium)
    }

    // MARK: Temperature (cap 8, never Critical)

    enum ThermalPattern: String, Sendable, Equatable {
        case unknown, normal, temporary, sustainedSerious, sustainedCritical
    }

    static let thermalMinimumSpan: TimeInterval = 10
    static let thermalHistoryGap: TimeInterval = 5 * 60

    /// macOS's thermal state is a pressure level, not a temperature. Heat describes the moment, not the hardware, so
    /// it is never Critical.
    /// - Sustained: every reading Serious or Critical over at least 10 s within this check, or Serious/Critical now
    ///   and at the previous check at least 5 minutes earlier.
    /// - Sustained Critical → Attention (−8, high): macOS reports it is limiting performance to cool the Mac.
    /// - Sustained Serious → Attention (−5, medium).
    /// - A hot reading that is not sustained → Healthy with a 0-point "Temporary high temperature" note.
    static func temperature(readings: [HealthScanner.ThermalReading], previous: HealthSnapshot?, now: Date)
        -> (outcome: Outcome, pattern: ThermalPattern, viaHistory: Bool) {
        let known = readings.filter { $0.level != nil }
        guard let first = known.first, let last = known.last, let current = last.level else {
            return (Outcome(state: .unknown, confidence: .low, zeroPointNotes: ["Temperature not available"]), .unknown, false)
        }
        let hot = known.filter { ($0.level ?? 0) >= 2 }
        let span = last.date.timeIntervalSince(first.date)
        let allHot = known.count >= 2 && hot.count == known.count && span >= thermalMinimumSpan
        let previousLevel = previous.flatMap { snapshot in
            now.timeIntervalSince(snapshot.date) >= thermalHistoryGap ? snapshot.thermalState : nil
        }
        let repeatedHot = current >= 2 && (previousLevel ?? 0) >= 2
        if allHot || repeatedHot {
            let critical = allHot ? known.allSatisfy { $0.level == 3 } : (current == 3 && previousLevel == 3)
            let evidence = allHot
                ? "in all \(known.count) readings over \(HealthFormat.duration(span))"
                : "now and at the previous check"
            let recommendation = "Let the Mac cool: quit heavy apps you are not using, keep the vents clear and use it on a "
                + "hard, flat surface, then check again later."
            if critical {
                return (Outcome(state: .attention, confidence: .high, deductions: [HealthDeduction(
                    id: "temperature", category: .temperature,
                    reason: "macOS reports a critical thermal state \(evidence) and reports it is limiting performance to cool the Mac",
                    severity: .attention, confidence: .high, points: 8, recommendation: recommendation)]),
                        .sustainedCritical, !allHot)
            }
            return (Outcome(state: .attention, confidence: .medium, deductions: [HealthDeduction(
                id: "temperature", category: .temperature,
                reason: "macOS reports a serious thermal state \(evidence)",
                severity: .attention, confidence: .medium, points: 5, recommendation: recommendation)]),
                    .sustainedSerious, !allHot)
        }
        if !hot.isEmpty {
            return (Outcome(state: .healthy, confidence: .medium, zeroPointNotes: ["Temporary high temperature"]), .temporary, false)
        }
        return (Outcome(state: .healthy, confidence: known.count >= 3 ? .high : .medium), .normal, false)
    }

    // MARK: Disk Health (cap 25)

    /// SMART "Verified" is Healthy; "Failing" on any disk is Critical (−25, high) with a backup recommendation.
    /// Unsupported, permission-limited and unreadable disks are Unknown and never treated as failing. SMART cannot
    /// guarantee a disk will not fail.
    static func disk(_ items: [HealthItem]) -> Outcome {
        let failing = items.filter { $0.status == .failing }
        if !failing.isEmpty {
            return Outcome(state: .critical, confidence: .high, deductions: [HealthDeduction(
                id: "diskHealth", category: .diskHealth,
                reason: "macOS reports a SMART failure for \(HealthFormat.list(failing.map(\.title)))",
                severity: .critical, confidence: .high, points: 25, recommendation: HealthScanner.smartFailureRecommendation)])
        }
        if items.contains(where: { $0.status == .healthy }) { return Outcome(state: .healthy, confidence: .high) }
        return Outcome(state: .unknown, confidence: .low, zeroPointNotes: ["Disk health not available"])
    }

    // MARK: Security (cap 20, sum)

    /// Points for each setting that is off. Independent protections, so they add up, capped at 20 together.
    /// - System Integrity Protection off: −10, high. Developers sometimes turn it off on purpose.
    /// - FileVault off: −8, high. Can be intentional on a desktop Mac kept in a secure place.
    /// - Gatekeeper off: −6, high.
    /// - Firewall off: −2, low. It is off by default on macOS; it matters mostly on untrusted networks.
    /// Unreadable, unsupported and unknown settings cost nothing; XProtect is informational.
    static let securityPoints: [String: (points: Int, confidence: HealthConfidence)] = [
        "sip": (10, .high), "filevault": (8, .high), "gatekeeper": (6, .high), "firewall": (2, .low),
    ]
    static let securityCap = 20

    static func security(_ items: [HealthItem]) -> (outcome: Outcome, items: [HealthItem]) {
        var items = items
        let disabled = items.indices.filter { items[$0].status == .disabled }
            .sorted { (securityPoints[items[$0].id]?.points ?? 0) > (securityPoints[items[$1].id]?.points ?? 0) }
        let readable = items.filter { $0.status == .enabled || $0.status == .disabled }
        var outcome: Outcome
        if !disabled.isEmpty {
            let confident = disabled.contains { securityPoints[items[$0].id]?.confidence == .high }
            outcome = Outcome(state: .attention, confidence: confident ? .high : .low)
        } else if !readable.isEmpty {
            outcome = Outcome(state: .healthy, confidence: readable.count == items.count ? .high : .medium)
        } else {
            outcome = Outcome(state: .unknown, confidence: .low)
        }
        var remaining = securityCap
        for index in disabled {
            let item = items[index]
            let rule = securityPoints[item.id] ?? (points: 0, confidence: HealthConfidence.low)
            let points = min(rule.points, remaining)
            remaining -= points
            guard points > 0 else {
                outcome.zeroPointNotes.append("\(item.title) off — the 20-point Security limit was reached")
                continue
            }
            items[index].points = points
            let limited = points < rule.points ? " (limited by the 20-point Security cap)" : ""
            outcome.deductions.append(HealthDeduction(
                id: "security.\(item.id)", category: .security,
                reason: "\(item.title) is off, which reduces protection\(limited)",
                severity: .attention, confidence: rule.confidence, points: points,
                recommendation: item.recommendation ?? "Review this setting."))
        }
        for item in items where item.status == .unreadable || item.status == .unsupported || item.status == .unknown {
            outcome.zeroPointNotes.append("\(item.title) \(item.status.label.lowercased())")
        }
        return (outcome, items)
    }

    // MARK: System Updates (cap 8, one deduction)

    static let updateCheckMaximumAge: TimeInterval = 30 * 86_400

    /// One deduction (−4, Attention) for the first that applies: automatic checks explicitly off; the last successful
    /// check more than 30 days ago; (Extended only) recommended updates in the cached list. Further conditions are
    /// mentioned in the same reason. An absent preference is the macOS default (on) and costs nothing; Unknown when
    /// nothing could be read.
    static func updates(automaticChecks: Bool?, lastSuccessfulCheck: Date?, now: Date, recommendedUpdates: Int?) -> Outcome {
        var reasons: [String] = []
        if automaticChecks == false { reasons.append("automatic update checks are turned off") }
        if let lastSuccessfulCheck, now.timeIntervalSince(lastSuccessfulCheck) > updateCheckMaximumAge {
            let days = Int(now.timeIntervalSince(lastSuccessfulCheck) / 86_400)
            reasons.append("the last successful update check was \(days) days ago")
        }
        if let recommendedUpdates, recommendedUpdates > 0 {
            reasons.append(recommendedUpdates == 1 ? "1 recommended update is available" : "\(recommendedUpdates) recommended updates are available")
        }
        if !reasons.isEmpty {
            let confidence: HealthConfidence = automaticChecks == false || (recommendedUpdates ?? 0) > 0 ? .high : .medium
            return Outcome(state: .attention, confidence: confidence, deductions: [HealthDeduction(
                id: "updates", category: .updates, reason: reasons.joined(separator: "; ").capitalizedFirst,
                severity: .attention, confidence: confidence, points: 4,
                recommendation: "Open Software Update settings to check for updates and turn on Automatic Updates.")])
        }
        if automaticChecks == nil && lastSuccessfulCheck == nil && recommendedUpdates == nil {
            return Outcome(state: .unknown, confidence: .low, zeroPointNotes: ["Update status not available"])
        }
        return Outcome(state: .healthy, confidence: lastSuccessfulCheck == nil ? .low : .medium)
    }
}

// MARK: - Check result

struct HealthMachineInfo: Sendable, Equatable {
    var model: String?
    var identifier: String?
    var chip: String?
    var memory: String?
    var macOS: String?

    var line: String {
        [model ?? identifier, chip, memory.map { "\($0) memory" }, macOS].compactMap { $0 }.joined(separator: " · ")
    }
}

struct HealthCheckResult: Sendable {
    let mode: HealthMode
    let startedAt: Date
    var finishedAt: Date?
    /// All seven categories in display order (`HealthOrdering`).
    var categories: [HealthCategoryResult]
    var scoreDetails: HealthScore
    var isPartial: Bool
    var cancelled: Bool
    /// One calm sentence.
    var summary: String
    var machine: HealthMachineInfo?

    /// The final score, 0...100.
    var score: Int { scoreDetails.final }

    func count(_ state: HealthState) -> Int { categories.filter { $0.state == state }.count }

    func category(_ category: HealthCategory) -> HealthCategoryResult? { categories.first { $0.category == category } }

    var metrics: HealthMetrics {
        var metrics = HealthMetrics()
        for category in categories { metrics.merge(category.metrics) }
        return metrics
    }

    /// Builds the result from the categories that finished; every missing category becomes Unknown (not checked).
    static func assemble(mode: HealthMode, startedAt: Date, finishedAt: Date?,
                         finished: [HealthCategory: HealthCategoryResult], cancelled: Bool,
                         machine: HealthMachineInfo? = nil) -> HealthCheckResult {
        let date = finishedAt ?? startedAt
        let missing = HealthCategory.allCases.filter { finished[$0] == nil }
        let wasCancelled = cancelled && !missing.isEmpty
        let all = HealthCategory.allCases.map { category in
            finished[category] ?? .notChecked(category, cancelled: cancelled, at: date)
        }
        let ordered = HealthOrdering.sorted(all)
        let partial = wasCancelled || ordered.contains { $0.cancelledReason != nil || $0.failedReason != nil }
        return HealthCheckResult(mode: mode, startedAt: startedAt, finishedAt: finishedAt, categories: ordered,
                                 scoreDetails: HealthScoring.score(ordered), isPartial: partial, cancelled: wasCancelled,
                                 summary: HealthSummary.sentence(for: ordered, cancelled: wasCancelled, partial: partial),
                                 machine: machine)
    }

    /// A headed Markdown report: summary, the score calculation, then every category with its readings.
    func markdown() -> String {
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "/") }
        let date = (finishedAt ?? startedAt).formatted(date: .long, time: .shortened)
        var lines = ["# Mac Health Report", "",
                     "Checked \(date) · \(mode.label) check · Score \(score)/100 · \(count(.critical)) critical · \(count(.attention)) need attention"]
        if let machine, !machine.line.isEmpty { lines.append("This Mac: " + machine.line) }
        lines += ["", summary]
        if isPartial {
            lines += ["", cancelled
                ? "_Partial result: the check was cancelled. Categories that did not finish are marked Not checked and cost no points._"
                : "_Partial result: some readings were not available. They are marked Unknown and cost no points._"]
        }
        lines += ["", "_Read-only: nothing was changed. \(HealthScore.disclaimer)_", "", "## Why this score?", "",
                  "| Item | Points |", "| --- | ---: |"]
        for line in scoreDetails.lines { lines.append("| \(cell(line.label)) | \(line.value) |") }
        if !scoreDetails.deductions.isEmpty {
            lines.append("")
            for deduction in scoreDetails.deductions {
                lines.append("- −\(deduction.points) [\(deduction.severity.label), \(deduction.confidence.label) confidence] "
                    + "**\(deduction.category.displayName)**: \(deduction.reason). Next step: \(deduction.recommendation)")
            }
        }
        lines += ["", "Score: \(scoreDetails.arithmetic)."]
        for category in categories {
            lines += ["", "## \(category.category.displayName) — \(category.state.label)", "", category.summary]
            if let recommendation = category.recommendation { lines += ["", "Recommendation: " + recommendation] }
            lines.append("")
            for measurement in category.measurements {
                lines.append("- \(measurement.label): \(measurement.displayValue)" + (measurement.note.map { " (\($0))" } ?? ""))
            }
            for item in category.items {
                let points = item.points > 0 ? ", −\(item.points)" : ""
                lines.append("- [\(item.statusLabel)\(points)] **\(item.title)**: \(item.detail) \(item.whyItMatters)")
                if let recommendation = item.recommendation { lines.append("  - Next step: " + recommendation) }
            }
            for note in category.notes { lines.append("- Note: " + note) }
            if category.trend != .notEnoughData { lines.append("- Trend: " + category.trend.label) }
            if let first = category.firstObserved, let last = category.lastObserved {
                lines.append("- First observed \(first.formatted(date: .abbreviated, time: .shortened)); last observed \(last.formatted(date: .abbreviated, time: .shortened))")
            }
            if let comparison = category.comparison { lines.append("- " + comparison) }
            if let forecast = category.forecast { lines.append("- " + forecast) }
            // App names are left out of the report on purpose; storage categories are generic names.
            if category.category == .storage, let title = category.contextTitle, !category.context.isEmpty {
                lines.append("- \(title): " + category.context.joined(separator: "; "))
            }
            lines.append("- Confidence: \(category.confidence.label) · Observed \(category.observedAt.formatted(date: .omitted, time: .shortened))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Card order: severity (critical, attention, healthy, unknown), then confidence (high, medium, low), then the fixed
/// category order.
enum HealthOrdering {
    static func displayRank(_ state: HealthState) -> Int {
        switch state {
        case .critical: 0
        case .attention: 1
        case .healthy: 2
        case .unknown: 3
        }
    }

    static func sorted(_ results: [HealthCategoryResult]) -> [HealthCategoryResult] {
        results.sorted {
            (displayRank($0.state), $0.confidence.rank, $0.category.order) < (displayRank($1.state), $1.confidence.rank, $1.category.order)
        }
    }
}

/// The calm one-line summary above the cards. Never fear-based.
enum HealthSummary {
    static func sentence(for categories: [HealthCategoryResult], cancelled: Bool, partial: Bool) -> String {
        let critical = categories.filter { $0.state == .critical }.map(\.category.displayName)
        let attention = categories.filter { $0.state == .attention }.map(\.category.displayName)
        let measured = categories.filter { $0.state != .unknown }
        var sentence: String
        if measured.isEmpty {
            sentence = cancelled ? "The check was cancelled before any readings finished." : "No readings could be taken from macOS this time."
        } else if critical.isEmpty && attention.isEmpty {
            sentence = "No issues were found in the readings macOS reported."
        } else if critical.isEmpty {
            let hardware = categories.contains { ($0.category == .battery || $0.category == .diskHealth) && $0.state != .unknown }
            sentence = "Your Mac is generally healthy. \(HealthFormat.list(attention)) \(attention.count == 1 ? "needs" : "need") attention, "
                + "and no critical \(hardware ? "hardware " : "")condition was reported."
        } else {
            sentence = "\(HealthFormat.list(critical)) \(critical.count == 1 ? "needs" : "need") prompt attention"
            if !attention.isEmpty { sentence += ", and \(HealthFormat.list(attention)) \(attention.count == 1 ? "needs" : "need") attention" }
            sentence += ". The cards below explain what macOS reported and what to do next."
        }
        if cancelled {
            sentence += " The check was cancelled, so some categories were not checked."
        } else if partial && !measured.isEmpty {
            sentence += " Some readings were not available, so this summary is incomplete."
        }
        return sentence
    }
}

/// VoiceOver text, from the result alone so it can be checked.
enum HealthAccessibility {
    /// Category, state, main measurement, explanation, recommendation, trend and confidence.
    static func label(for result: HealthCategoryResult) -> String {
        var parts = ["\(result.category.displayName): \(result.state.label)."]
        if let main = result.measurements.first { parts.append("\(main.label): \(main.displayValue).") }
        if !result.summary.isEmpty { parts.append(result.summary) }
        if let recommendation = result.recommendation { parts.append("Recommendation: \(recommendation)") }
        if result.trend != .notEnoughData { parts.append("Trend: \(result.trend.label).") }
        parts.append("Confidence: \(result.confidence.label).")
        return parts.joined(separator: " ")
    }

    static func scoreLabel(_ score: HealthScore) -> String {
        "Health score \(score.final) of 100. \(score.totalDeducted) points deducted in \(score.deductions.count) "
            + (score.deductions.count == 1 ? "deduction." : "deductions.")
    }
}

enum HealthFormat {
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// Rounded down, so a percentage never overstates free space; "less than 1%" below one.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "?" }
        if fraction > 0 && fraction < 0.01 { return "less than 1%" }
        return "\(Int((max(0, fraction) * 100).rounded(.down)))%"
    }

    /// "45 s" or "8 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded())
        return whole < 120 ? "\(whole) s" : "\(whole / 60) min"
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int? {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: nil
        }
    }

    static func thermalName(_ level: Int?) -> String {
        switch level {
        case 0: "Nominal"
        case 1: "Fair"
        case 2: "Serious"
        case 3: "Critical"
        default: "Unknown"
        }
    }

    static func pressureName(_ level: Int?) -> String? {
        switch level {
        case 1: "Normal"
        case 2: "Warning"
        case 4: "Critical"
        default: nil
        }
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Battery parsing

/// Battery facts from the `AppleSmartBattery` registry entry. Apple Silicon reports `MaxCapacity` and
/// `CurrentCapacity` as percentages and keeps the mAh values only inside the nested `BatteryData`
/// dictionary; older macOS versions put the mAh values at the top level.
struct BatteryHealth: Sendable, Equatable {
    var cycleCount: Int?
    var designCycleCount: Int?
    /// Percent of design capacity, 0...100: macOS's own figure when reported, otherwise computed.
    var maximumCapacity: Int?
    var capacityIsComputed = false
    var designCapacity: Int?
    var rawMaxCapacity: Int?
    var nominalChargeCapacity: Int?
    var charge: Int?
    var isCharging: Bool?
    var externalConnected: Bool?
    var fullyCharged: Bool?
    /// From IOPowerSources, not the registry. macOS sets it only when it has something to say
    /// (for example "Service Recommended"); nil does not prove anything about the battery.
    var condition: String?
    var powerSourceFound = false

    /// Returns nil when the dictionary holds no battery keys (desktop Macs have no battery entry).
    static func parse(_ properties: [String: Any]) -> BatteryHealth? {
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { properties[key] ?? nested[key] }
        func int(_ key: String) -> Int? { value(key) as? Int }
        let markers = ["CycleCount", "MaxCapacity", "CurrentCapacity", "DesignCapacity", "AppleRawMaxCapacity", "BatteryData"]
        guard markers.contains(where: { properties[$0] != nil }) else { return nil }

        var battery = BatteryHealth()
        battery.cycleCount = int("CycleCount")
        battery.designCycleCount = (int("DesignCycleCount9C") ?? int("DesignCycleCount")).flatMap { $0 > 0 ? $0 : nil }
        battery.designCapacity = int("DesignCapacity").flatMap { $0 > 0 ? $0 : nil }
        // Only the top-level MaxCapacity is a percentage on Apple Silicon; above 100 it is mAh (older macOS).
        let topMax = properties["MaxCapacity"] as? Int
        battery.rawMaxCapacity = int("AppleRawMaxCapacity") ?? topMax.flatMap { $0 > 100 ? $0 : nil } ?? int("FullChargeCapacity")
        battery.nominalChargeCapacity = int("NominalChargeCapacity")
        if let topMax, (1...100).contains(topMax) {
            battery.maximumCapacity = topMax
        } else if let raw = battery.rawMaxCapacity, let design = battery.designCapacity, raw >= 0 {
            // Rounded down so a computed figure never overstates capacity.
            battery.maximumCapacity = min(100, raw * 100 / design)
            battery.capacityIsComputed = true
        }
        if let current = properties["CurrentCapacity"] as? Int, current >= 0 {
            if let topMax, topMax > 100 { battery.charge = min(100, current * 100 / topMax) }
            else if current <= 100 { battery.charge = current }
        }
        battery.isCharging = value("IsCharging") as? Bool
        battery.externalConnected = value("ExternalConnected") as? Bool
        battery.fullyCharged = value("FullyCharged") as? Bool
        return battery
    }
}

/// The `AppleSmartBattery` registry entry as read. The dictionary holds plist values only and is never mutated.
enum BatteryRegistryRead: @unchecked Sendable {
    /// No battery service: a desktop Mac.
    case noBattery
    /// A battery service exists but its properties could not be read.
    case unreadable
    case properties([String: Any])
}

/// The internal battery in IOPowerSources: whether it was found, and any condition macOS reports for it.
struct PowerSourceInfo: Sendable, Equatable {
    var found: Bool
    var condition: String?
}

struct StorageValues: Sendable, Equatable {
    var total: Int64
    /// `volumeAvailableCapacityForImportantUsage`: free space including purgeable space macOS can clear.
    var important: Int64
    /// `volumeAvailableCapacity`: free space without purgeable space.
    var available: Int64?

    /// Important minus plain available, when that is not negative.
    var purgeable: Int64? {
        guard let available, important - available >= 0 else { return nil }
        return important - available
    }
}

// MARK: - System access

/// Everything Mac Health reads, as closures, so checks run against fakes with an instant clock.
/// The live values only read: no command here changes a setting, and none needs administrator rights.
struct HealthSystem: Sendable {
    var batteryRegistry: @Sendable () -> BatteryRegistryRead
    var powerSource: @Sendable () -> PowerSourceInfo?
    var storage: @Sendable () -> StorageValues?
    var memorySample: @Sendable () -> MemorySample?
    var thermalState: @Sendable () -> ProcessInfo.ThermalState
    var now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) -> Void
    /// `(executable, arguments, timeout, cancellation) -> (output, status)`; status −1 is a timeout or launch failure,
    /// `SystemDataScanner.cancelledStatus` (−2) a cancellation.
    var run: @Sendable (String, [String], TimeInterval, ScanCancellation?) -> (output: String, status: Int32)
    var isExecutable: @Sendable (String) -> Bool
    /// A value from the com.apple.SoftwareUpdate preferences, or nil when absent.
    var preference: @Sendable (String) -> Any?
    var readFile: @Sendable (String) -> Data?
    var machine: @Sendable () -> HealthMachineInfo?

    static let live = HealthSystem(
        batteryRegistry: { HealthScanner.readBatteryRegistry() },
        powerSource: { HealthScanner.readPowerSource() },
        storage: { HealthScanner.readStorage() },
        memorySample: { MemoryReader.sample() },
        thermalState: { ProcessInfo.processInfo.thermalState },
        now: { Date() },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        run: { SystemDataScanner.run($0, $1, timeout: $2, captureErrors: true, cancellation: $3) },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        preference: { key in
            CFPreferencesCopyValue(key as CFString, "com.apple.SoftwareUpdate" as CFString,
                                   kCFPreferencesAnyUser, kCFPreferencesCurrentHost) as Any?
        },
        readFile: { FileManager.default.contents(atPath: $0) },
        machine: { HealthScanner.readMachineInfo() })
}

// MARK: - Scanner

/// Read-only checks of this Mac. Nothing here changes a setting; commands run with fixed absolute paths.
enum HealthScanner {
    static let commandTimeout: TimeInterval = 10
    static let softwareUpdateTimeout: TimeInterval = 30
    /// How often sampling loops look at the cancellation token.
    static let pollInterval: TimeInterval = 0.1
    static let smartFailureRecommendation = "Back up this disk soon, for example with Time Machine; macOS reports a SMART failure."
    static let smartLimit = "SMART status cannot guarantee that a disk will not fail; keep backups."

    // MARK: Sampling

    struct ThermalReading: Sendable, Equatable {
        let date: Date
        /// 0 nominal, 1 fair, 2 serious, 3 critical; nil when macOS reports a state this app does not know.
        let level: Int?
    }

    /// Thermal state read several times in a row, so one instant does not decide the result.
    struct ThermalSampler: Sendable, Equatable {
        var readings: Int
        var interval: TimeInterval

        /// Three readings one second apart.
        static let quick = ThermalSampler(readings: 3, interval: 1)
        /// About 20 seconds of readings, one a second.
        static let extended = ThermalSampler(readings: 21, interval: 1)

        /// Blocking; nil when cancelled. Always takes at least one reading.
        func sample(system: HealthSystem, cancellation: ScanCancellation) -> [ThermalReading]? {
            let start = system.now()
            var elapsed: TimeInterval = 0
            var readings: [ThermalReading] = []
            for index in 0..<max(1, self.readings) {
                if index > 0 {
                    guard HealthScanner.pause(interval, system: system, cancellation: cancellation) else { return nil }
                    elapsed += interval
                }
                if cancellation.isCancelled { return nil }
                let date = max(system.now(), start.addingTimeInterval(elapsed))
                readings.append(ThermalReading(date: date, level: HealthFormat.thermalLevel(system.thermalState())))
            }
            return readings
        }
    }

    /// Memory readings taken during the check, added to `MemoryMonitor.history`.
    struct MemorySampler: Sendable, Equatable {
        var readings: Int
        var interval: TimeInterval

        static let quick = MemorySampler(readings: 1, interval: 0)
        /// About 20 seconds of readings, one every 2 seconds.
        static let extended = MemorySampler(readings: 11, interval: 2)

        /// Blocking; nil when cancelled. Readings that fail are left out.
        func sample(system: HealthSystem, cancellation: ScanCancellation) -> [MemorySample]? {
            var samples: [MemorySample] = []
            for index in 0..<max(1, readings) {
                if index > 0 {
                    guard HealthScanner.pause(interval, system: system, cancellation: cancellation) else { return nil }
                }
                if cancellation.isCancelled { return nil }
                if let sample = system.memorySample() { samples.append(sample) }
            }
            return samples
        }
    }

    /// Sleeps in steps of `pollInterval`; false as soon as the check is cancelled.
    static func pause(_ seconds: TimeInterval, system: HealthSystem, cancellation: ScanCancellation) -> Bool {
        var remaining = seconds
        while remaining > 0 {
            if cancellation.isCancelled { return false }
            let step = min(pollInterval, remaining)
            system.sleep(step)
            remaining -= step
        }
        return !cancellation.isCancelled
    }

    // MARK: Running a check

    struct Request: Sendable {
        var mode: HealthMode
        /// Recent `MemoryMonitor.history`.
        var memoryHistory: [MemorySample] = []
        /// Earlier snapshots, oldest first.
        var history: [HealthSnapshot] = []
        var storageBreakdown: [HealthContextEntry] = []
        var topApps: [HealthContextEntry] = []
    }

    /// Collects results from concurrent readers; once closed, late results are dropped.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [HealthCategory: HealthCategoryResult] = [:]
        private var closed = false

        func store(_ result: HealthCategoryResult) -> Bool {
            lock.withLock {
                guard !closed else { return false }
                results[result.category] = result
                return true
            }
        }

        func close() -> [HealthCategory: HealthCategoryResult] {
            lock.withLock {
                closed = true
                return results
            }
        }
    }

    /// Blocking: runs every category at once and calls `onCategory` as each finishes (from a background thread).
    /// When `cancellation` fires, returns within about 50 ms with the categories finished so far; the rest are
    /// Unknown ("Not checked — cancelled") and the result is partial. Call it through `BackgroundWork.run`.
    static func check(_ request: Request, system: HealthSystem = .live, cancellation: ScanCancellation = ScanCancellation(),
                      onCategory: @escaping @Sendable (HealthCategoryResult) -> Void = { _ in }) -> HealthCheckResult {
        let started = system.now()
        let box = ResultBox()
        let group = DispatchGroup()
        for category in HealthCategory.allCases {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let result = read(category, request: request, system: system, cancellation: cancellation),
                      !cancellation.isCancelled else { return }
                let annotated = HealthHistory.annotate(result, history: request.history)
                if box.store(annotated) { onCategory(annotated) }
            }
        }
        while group.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { break }
        }
        let finished = box.close()
        return HealthCheckResult.assemble(mode: request.mode, startedAt: started, finishedAt: system.now(), finished: finished,
                                          cancelled: cancellation.isCancelled, machine: system.machine())
    }

    /// One category's readings and result; nil when cancelled before it finished.
    static func read(_ category: HealthCategory, request: Request, system: HealthSystem,
                     cancellation: ScanCancellation) -> HealthCategoryResult? {
        if cancellation.isCancelled { return nil }
        let previous = HealthHistory.earlier(request.history, than: system.now())
        switch category {
        case .battery:
            return batteryResult(system.batteryRegistry(), power: system.powerSource(), now: system.now())
        case .storage:
            return storageResult(system.storage(), breakdown: request.storageBreakdown, now: system.now())
        case .memory:
            guard let readings = request.mode.memorySampler.sample(system: system, cancellation: cancellation) else { return nil }
            return memoryResult(history: request.memoryHistory, readings: readings,
                                previousSwap: previous.last { $0.swapUsed != nil }?.swapUsed,
                                topApps: request.topApps, now: system.now())
        case .temperature:
            guard let readings = request.mode.thermalSampler.sample(system: system, cancellation: cancellation) else { return nil }
            return temperatureResult(readings, previous: previous.last { $0.thermalState != nil }, now: system.now())
        case .diskHealth:
            guard let read = readDisks(mode: request.mode, system: system, cancellation: cancellation) else { return nil }
            return diskResult(read.items, mode: request.mode, note: read.note, now: system.now())
        case .security:
            guard let items = readSecurity(system: system, cancellation: cancellation) else { return nil }
            return securityResult(items, now: system.now())
        case .updates:
            let preferences = readUpdatePreferences(system: system)
            var list = SoftwareUpdateListRead.notChecked
            if request.mode == .extended {
                let output = system.run("/usr/sbin/softwareupdate", ["-l", "--no-scan"], softwareUpdateTimeout, cancellation)
                if output.status == SystemDataScanner.cancelledStatus || cancellation.isCancelled { return nil }
                list = parseSoftwareUpdateList(output: output.output, status: output.status)
            }
            return updatesResult(preferences, list: list, now: system.now())
        }
    }

    // MARK: Battery

    static func batteryResult(_ registry: BatteryRegistryRead, power: PowerSourceInfo?, now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .battery, observedAt: now)
        var parsed: BatteryHealth?
        switch registry {
        case .noBattery:
            result.summary = "No battery — this appears to be a desktop Mac."
            result.measurements = [HealthMeasurement("Battery", "No battery", note: "macOS reports no internal battery.")]
            result.zeroPointNotes = ["No battery (desktop Mac)"]
            return result
        case .unreadable:
            parsed = nil
        case .properties(let properties):
            parsed = BatteryHealth.parse(properties)
        }
        guard var battery = parsed else {
            result.summary = "Battery information not available."
            result.failedReason = "Battery information not available"
            result.measurements = [HealthMeasurement("Battery", nil, note: "macOS lists a battery but its details could not be read.")]
            result.zeroPointNotes = ["Battery information not available"]
            return result
        }
        battery.powerSourceFound = power?.found ?? false
        battery.condition = power?.condition
        let outcome = HealthScoring.battery(condition: battery.condition, capacity: battery.maximumCapacity,
                                            cycles: battery.cycleCount, designCycles: battery.designCycleCount)
        result.apply(outcome)
        result.settingsLink = .battery
        result.metrics.batteryMaxCapacity = battery.maximumCapacity
        result.metrics.batteryCycles = battery.cycleCount

        let capacityText = battery.maximumCapacity.map { "\($0)%" }
        let cyclesText = battery.cycleCount.map { cycles in
            battery.designCycleCount.map { "\(cycles.formatted()) of \($0.formatted()) rated" } ?? cycles.formatted()
        }
        let reading = [capacityText.map { "Maximum capacity is \($0)" }, cyclesText.map { "cycle count \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        switch outcome.state {
        case .critical:
            result.summary = "macOS reports the battery condition “\(battery.condition ?? "")”. " + (reading.isEmpty ? "" : reading + ".")
            result.recommendation = outcome.deductions.first?.recommendation
        case .attention:
            result.summary = (reading.isEmpty ? "" : reading + ". ")
                + "That is past the point Apple designs Mac notebook batteries for, and macOS does not report a battery condition to apps here."
            result.recommendation = outcome.deductions.first?.recommendation
        case .healthy:
            if let condition = battery.condition {
                result.summary = "macOS reports the battery condition “\(condition)”." + (reading.isEmpty ? "" : " " + reading + ".")
                if !outcome.zeroPointNotes.isEmpty {
                    result.notes.append("Capacity or cycle count is past Apple's design point, but macOS has not flagged this battery for service.")
                }
            } else {
                result.summary = (reading.isEmpty ? "" : reading + ". ")
                    + "macOS does not report a battery condition to apps here, so this uses capacity and cycle count."
            }
        case .unknown:
            result.summary = "Battery capacity and cycle count were not reported."
        }

        let source = battery.capacityIsComputed
            ? "Computed from the full-charge and design capacities macOS reports, rounded down."
            : "As reported by macOS (Battery settings › Battery Health)."
        result.measurements = [
            HealthMeasurement("Maximum capacity", capacityText, note: capacityText == nil ? nil : source),
            HealthMeasurement("Cycle count", cyclesText),
            HealthMeasurement("Condition (macOS)", battery.condition,
                              note: battery.condition == nil
                                ? (battery.powerSourceFound ? "macOS does not report a battery condition to apps on this Mac." : "Power source information was unavailable.")
                                : nil),
        ]
        let state = battery.isCharging == true ? "Charging"
            : battery.fullyCharged == true ? "Fully charged"
            : battery.externalConnected == true ? "On power adapter, not charging"
            : battery.externalConnected == false ? "On battery" : nil
        let charge = [battery.charge.map { "\($0)%" }, state].compactMap { $0 }.joined(separator: " · ")
        result.measurements.append(HealthMeasurement("Charge", charge.isEmpty ? nil : charge))
        if let raw = battery.rawMaxCapacity, let design = battery.designCapacity {
            result.measurements.append(HealthMeasurement("Full-charge capacity", "\(raw.formatted()) mAh of \(design.formatted()) mAh design"))
        }
        result.measurements.append(HealthMeasurement(
            "Optimized Battery Charging", "Not available to apps",
            note: "macOS does not report this setting to apps. Check it in Battery settings."))
        result.notes.append(HealthScoring.batteryGuidance + " This reading is not a battery diagnosis.")
        return result
    }

    /// Finds the internal battery in IOPowerSources and returns any condition macOS reports for it
    /// (`BatteryHealthCondition`, or `BatteryHealth` Good/Fair/Poor). Undocumented keys are not read.
    static func readPowerSource() -> PowerSourceInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        for source in list as [CFTypeRef] {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let reported = [description[kIOPSBatteryHealthConditionKey], description[kIOPSBatteryHealthKey]]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }
            return PowerSourceInfo(found: true, condition: reported.first(where: HealthScoring.batteryNeedsService) ?? reported.first)
        }
        return PowerSourceInfo(found: false, condition: nil)
    }

    static func readBatteryRegistry() -> BatteryRegistryRead {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .noBattery }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return .unreadable }
        return .properties(properties)
    }

    // MARK: Storage

    static func readStorage() -> StorageValues? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity,
              total > 0, important >= 0 else { return nil }
        return StorageValues(total: Int64(total), important: important, available: values.volumeAvailableCapacity.map(Int64.init))
    }

    static func storageResult(_ values: StorageValues?, breakdown: [HealthContextEntry], now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .storage, observedAt: now)
        result.settingsLink = .storage
        result.contextTitle = "Largest categories from the last Storage Map"
        result.context = breakdown.isEmpty
            ? ["Run Storage Map to see what uses space."]
            : breakdown.sorted { $0.bytes > $1.bytes }.prefix(4).map { "\($0.name) — \($0.bytes.formattedBytes)" }
        guard let values, values.total > 0 else {
            result.summary = "macOS did not report the startup disk's capacity."
            result.failedReason = "Startup disk capacity was not reported"
            result.measurements = [HealthMeasurement("Free space", nil)]
            result.zeroPointNotes = ["Storage not available"]
            return result
        }
        let free = values.important
        let outcome = HealthScoring.storage(free: free, total: values.total)
        result.apply(outcome)
        result.metrics.storageFree = free
        result.metrics.storageTotal = values.total
        let fraction = Double(free) / Double(values.total)
        let reading = "\(free.formattedBytes) free of \(values.total.formattedBytes) (\(HealthFormat.percent(fraction)))"
        switch outcome.state {
        case .critical:
            result.summary = "Very little free space: \(reading). macOS needs free space for updates, virtual memory and snapshots."
        case .attention:
            result.summary = "Free space is getting low: \(reading). Low free space can slow updates and leave less room for virtual memory."
        case .healthy, .unknown:
            result.summary = "\(reading), including space macOS can free up on demand."
        }
        result.recommendation = outcome.deductions.first?.recommendation
        result.measurements = [
            HealthMeasurement("Free space", free.formattedBytes, note: "Includes purgeable space macOS can clear on demand; Finder may show a different figure."),
            HealthMeasurement("Free, as a share of capacity", HealthFormat.percent(fraction)),
            HealthMeasurement("Purgeable (included above)", values.purgeable?.formattedBytes),
            HealthMeasurement("Free without purgeable space", values.available?.formattedBytes),
            HealthMeasurement("Capacity", values.total.formattedBytes),
            HealthMeasurement("Used", max(0, values.total - free).formattedBytes),
        ]
        return result
    }

    // MARK: Memory

    static func memoryResult(history: [MemorySample], readings: [MemorySample], previousSwap: UInt64?,
                             topApps: [HealthContextEntry], now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .memory, observedAt: now)
        result.contextTitle = "Apps using the most memory right now — high usage alone is normal"
        result.context = topApps.sorted { $0.bytes > $1.bytes }.prefix(5).map { "\($0.name) — \(HealthFormat.memory(UInt64(max(0, $0.bytes))))" }
        let all = history + readings
        let window = HealthScoring.PressureWindow(samples: all)
        let current = readings.last ?? all.max { $0.date < $1.date }
        let swapGrowth: Int64? = current?.swap.flatMap { swap in previousSwap.map { Int64(clamping: swap) - Int64(clamping: $0) } }
        let outcome = HealthScoring.memory(window, swapGrowth: swapGrowth)
        result.apply(outcome)
        result.metrics.swapUsed = current?.swap
        result.metrics.pressureLevel = window.latest
        let over = "\(window.readings) \(window.readings == 1 ? "reading" : "readings")"
            + (window.readings > 1 ? " over \(HealthFormat.duration(window.span))" : "")
        let grew = swapGrowth.flatMap { $0 > HealthScoring.swapGrowthThreshold ? " Swap grew by \(HealthFormat.memory(UInt64($0))) since the previous check." : nil } ?? ""
        switch outcome.state {
        case .critical:
            result.summary = "macOS reported critical memory pressure in \(window.critical) of \(over). Apps may slow down while macOS compresses memory and uses swap." + grew
            result.firstObserved = window.firstElevated
            result.lastObserved = window.lastElevated
        case .attention:
            result.summary = "macOS reported elevated memory pressure in \(window.elevated) of \(over). Apps may slow down while it lasts." + grew
            result.firstObserved = window.firstElevated
            result.lastObserved = window.lastElevated
        case .healthy:
            if window.elevated > 0 {
                result.summary = "Memory pressure was elevated in \(window.elevated) of \(over) — momentary — check again later."
                result.notes.append("Momentary — check again later. Pressure often rises briefly in normal use; it counts only when it stays elevated for at least a minute.")
            } else {
                result.summary = "Memory pressure is Normal across \(over). High memory usage alone is normal on macOS." + grew
            }
        case .unknown:
            result.summary = all.isEmpty ? "Memory statistics could not be read." : "macOS did not report memory pressure."
            result.failedReason = "Memory pressure could not be read"
        }
        result.recommendation = outcome.deductions.first?.recommendation
        let used = current.map { sample in
            "\(HealthFormat.memory(sample.used)) of \(HealthFormat.memory(sample.total)) (\(Int(sample.percent.rounded()))%)"
        }
        result.measurements = [
            HealthMeasurement("Memory pressure now", HealthFormat.pressureName(window.latest),
                              note: "As reported by macOS. Pressure over time, not one reading, decides the state."),
            HealthMeasurement("Pressure readings", window.readings == 0 ? nil : "\(over); \(window.elevated) elevated"),
            HealthMeasurement("Swap used", current?.swap.map(HealthFormat.memory),
                              note: previousSwap.map { "\(HealthFormat.memory($0)) at the previous check." }),
            HealthMeasurement("Compressed", current.map { HealthFormat.memory($0.compressed) }),
            HealthMeasurement("Memory in use", used, note: "Memory in use alone never changes the result."),
        ]
        if let first = window.firstElevated, let last = window.lastElevated {
            result.measurements.append(HealthMeasurement("Elevated readings", "first \(HealthFormat.time(first)), last \(HealthFormat.time(last))"))
        }
        return result
    }

    // MARK: Temperature

    static func temperatureResult(_ readings: [ThermalReading], previous: HealthSnapshot?, now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .temperature, observedAt: now)
        let assessment = HealthScoring.temperature(readings: readings, previous: previous, now: now)
        result.apply(assessment.outcome)
        let known = readings.filter { $0.level != nil }
        let hot = known.filter { ($0.level ?? 0) >= 2 }
        let current = known.last?.level
        result.metrics.thermalState = current
        let span = (known.last?.date).flatMap { last in known.first.map { last.timeIntervalSince($0.date) } } ?? 0
        let over = "\(known.count) \(known.count == 1 ? "reading" : "readings")" + (known.count > 1 ? " over \(HealthFormat.duration(span))" : "")
        let pattern: String
        switch assessment.pattern {
        case .sustainedCritical:
            result.summary = assessment.viaHistory
                ? "macOS reports a critical thermal state now and at the previous check, and reports it is limiting performance to cool the Mac."
                : "macOS reports a critical thermal state in all \(over) and reports it is limiting performance to cool the Mac."
            pattern = assessment.viaHistory ? "Repeated: also at the previous check" : "Sustained during this check"
        case .sustainedSerious:
            result.summary = assessment.viaHistory
                ? "macOS reports a serious thermal state now and at the previous check; it may reduce performance to cool the Mac."
                : "macOS reports a serious thermal state in all \(over); it may reduce performance to cool the Mac."
            pattern = assessment.viaHistory ? "Repeated: also at the previous check" : "Sustained during this check"
        case .temporary:
            result.summary = "A temporary \(HealthFormat.thermalName(hot.map { $0.level ?? 0 }.max()).lowercased()) thermal state appeared in \(hot.count) of \(over). Brief peaks are normal under heavy load — check again later."
            result.notes.append("Temporary — check again later. Only a state that stays serious or critical, or repeats at the next check, lowers the score.")
            pattern = "Temporary"
        case .normal:
            result.summary = "macOS reported a \(HealthFormat.thermalName(current).lowercased()) thermal state across \(over)."
            pattern = "None elevated"
        case .unknown:
            result.summary = "macOS did not report a thermal state."
            result.failedReason = "Thermal state could not be read"
            pattern = "Not Available"
        }
        result.recommendation = assessment.outcome.deductions.first?.recommendation
        if assessment.pattern == .sustainedCritical || assessment.pattern == .sustainedSerious {
            if assessment.viaHistory, let previous {
                result.firstObserved = previous.date
                result.lastObserved = known.last?.date ?? now
            } else {
                result.firstObserved = hot.first?.date
                result.lastObserved = hot.last?.date
            }
        }
        result.measurements = [
            HealthMeasurement("Thermal state now", current == nil ? nil : HealthFormat.thermalName(current)),
            HealthMeasurement("Readings", known.isEmpty ? nil : over + ": " + known.map { HealthFormat.thermalName($0.level) }.joined(separator: ", ")),
            HealthMeasurement("Pattern", pattern),
        ]
        if let first = hot.first, let last = hot.last {
            result.measurements.append(HealthMeasurement("Elevated readings", "first \(HealthFormat.time(first.date)), last \(HealthFormat.time(last.date))"))
        }
        if let previous, let level = previous.thermalState {
            result.measurements.append(HealthMeasurement("Previous check", "\(HealthFormat.thermalName(level)) (\(previous.date.formatted(date: .abbreviated, time: .shortened)))"))
        }
        result.notes.append("This is macOS's thermal pressure level, not a temperature in degrees.")
        return result
    }

    // MARK: Disk Health

    /// Parses `diskutil info -plist <disk>` into one disk item. "Verified" is Healthy; a SMART failure is Failing;
    /// "Not Supported" or a missing status is Unsupported; a refused or failed read is Permission Limited or Unknown.
    static func diskItem(identifier: String, plistOutput: String, status: Int32) -> HealthItem {
        let why = "SMART is the disk's own self-assessment. " + smartLimit
        func item(_ title: String, _ status: HealthItemStatus, _ detail: String, recommendation: String? = nil) -> HealthItem {
            HealthItem(id: "disk:" + identifier, title: title, status: status,
                       severity: status == .failing ? "High" : status == .healthy ? "None" : "Not assessed",
                       confidence: status == .healthy || status == .failing ? .high : .low,
                       whyItMatters: why, detail: detail, recommendation: recommendation)
        }
        let plist = plistOutput.data(using: .utf8).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        guard let plist else {
            let lower = plistOutput.lowercased()
            if lower.contains("permission") || lower.contains("not permitted") {
                return item(identifier, .permissionLimited, "diskutil was not allowed to read this disk.")
            }
            return item(identifier, .unknown, status == -1 ? "diskutil timed out or could not run." : "diskutil output could not be read.")
        }
        let name = (plist["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Disk"
        let device = plist["DeviceIdentifier"] as? String ?? identifier
        let location = (plist["Internal"] as? Bool).map { $0 ? "internal" : "external" }
        let title = "\(name) (" + [device, location].compactMap { $0 }.joined(separator: ", ") + ")"
        let kind = [(plist["SolidState"] as? Bool).map { $0 ? "solid-state" : "rotational" }, plist["BusProtocol"] as? String]
            .compactMap { $0 }.joined(separator: ", ")
        let described = kind.isEmpty ? "" : " (\(kind))"
        guard let smart = plist["SMARTStatus"] as? String, !smart.isEmpty else {
            return item(title, .unsupported, "This disk does not report SMART status\(described).")
        }
        switch smart.lowercased() {
        case "verified":
            return item(title, .healthy, "diskutil reports SMART status Verified\(described).")
        case let text where text.contains("fail"):
            return item(title, .failing, "diskutil reports SMART status “\(smart)”\(described).", recommendation: smartFailureRecommendation)
        case "not supported":
            return item(title, .unsupported, "This disk does not support SMART status\(described).")
        default:
            return item(title, .unknown, "diskutil reports an unrecognized SMART status “\(smart)”\(described).")
        }
    }

    /// `WholeDisks` from `diskutil list -plist physical`.
    static func physicalDisks(listOutput: String) -> [String]? {
        guard let data = listOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = plist["WholeDisks"] as? [String] else { return nil }
        return disks
    }

    /// The physical whole disk behind the startup volume, from `diskutil info -plist /`: the first APFS physical store
    /// ("disk0s2" → "disk0"), else the parent whole disk.
    static func startupWholeDisk(infoOutput: String) -> String? {
        guard let data = infoOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let stores = plist["APFSPhysicalStores"] as? [[String: Any]]
        let store = stores?.first?["APFSPhysicalStore"] as? String ?? (stores == nil ? plist["ParentWholeDisk"] as? String : nil)
        guard let store, let range = store.range(of: #"^disk\d+"#, options: .regularExpression) else { return nil }
        return String(store[range])
    }

    /// Quick: the startup disk. Extended: every physical disk. nil when cancelled.
    static func readDisks(mode: HealthMode, system: HealthSystem, cancellation: ScanCancellation) -> (items: [HealthItem], note: String?)? {
        let diskutil = "/usr/sbin/diskutil"
        @Sendable func info(_ target: String) -> (output: String, status: Int32) {
            system.run(diskutil, ["info", "-plist", target], commandTimeout, cancellation)
        }
        var note: String?
        if mode == .extended {
            let list = system.run(diskutil, ["list", "-plist", "physical"], commandTimeout, cancellation)
            if list.status == SystemDataScanner.cancelledStatus || cancellation.isCancelled { return nil }
            if let disks = physicalDisks(listOutput: list.output), !disks.isEmpty {
                let outputs = DiskScanService.concurrentMap(disks) { info($0) }
                if outputs.contains(where: { $0.status == SystemDataScanner.cancelledStatus }) || cancellation.isCancelled { return nil }
                return (zip(disks, outputs).map { diskItem(identifier: $0, plistOutput: $1.output, status: $1.status) }, nil)
            }
            note = "The list of physical disks could not be read, so only the startup disk was checked."
        }
        let startup = info("/")
        if startup.status == SystemDataScanner.cancelledStatus || cancellation.isCancelled { return nil }
        if let whole = startupWholeDisk(infoOutput: startup.output) {
            let disk = info(whole)
            if disk.status == SystemDataScanner.cancelledStatus || cancellation.isCancelled { return nil }
            return ([diskItem(identifier: whole, plistOutput: disk.output, status: disk.status)], note)
        }
        var item = diskItem(identifier: "startup", plistOutput: startup.output, status: startup.status)
        if item.title.hasPrefix("Disk (") || item.title == "startup" {
            item = HealthItem(id: item.id, title: "Startup disk", status: item.status, severity: item.severity,
                              confidence: item.confidence, whyItMatters: item.whyItMatters, detail: item.detail,
                              recommendation: item.recommendation)
        }
        return ([item], note)
    }

    static func diskResult(_ items: [HealthItem], mode: HealthMode, note: String? = nil, now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .diskHealth, observedAt: now)
        let outcome = HealthScoring.disk(items)
        result.apply(outcome)
        result.items = items
        let verified = items.filter { $0.status == .healthy }
        switch outcome.state {
        case .critical:
            result.summary = "macOS reports a SMART failure for \(HealthFormat.list(items.filter { $0.status == .failing }.map(\.title)))."
            result.recommendation = smartFailureRecommendation
        case .healthy:
            result.summary = "SMART status is Verified for \(verified.count == 1 ? "1 disk" : "\(verified.count) disks"). " + smartLimit
        case .attention, .unknown:
            result.summary = items.isEmpty ? "No disk could be checked." : "SMART status is not available for the checked disks. This is not a sign of failure."
            if items.isEmpty || items.allSatisfy({ $0.status == .unknown }) { result.failedReason = "Disk status could not be read" }
        }
        let smartValue: String?
        switch outcome.state {
        case .critical: smartValue = "Failure reported"
        case .healthy: smartValue = "Verified"
        case .attention, .unknown: smartValue = nil
        }
        result.measurements = [
            HealthMeasurement("SMART status", smartValue, note: "As reported by diskutil for the disks checked."),
            HealthMeasurement("Disks checked", items.isEmpty ? nil : "\(items.count)",
                              note: items.isEmpty ? nil : HealthFormat.list(items.map { "\($0.title): \($0.statusLabel)" })),
        ]
        result.notes.append(mode == .quick ? "Quick checks the startup disk; Extended checks every physical disk." : "Extended checks every physical disk macOS lists.")
        if let note { result.notes.append(note) }
        return result
    }

    // MARK: Security

    static let timedOut = "The check timed out or could not run."

    private static func securityItem(_ id: String, _ title: String, _ status: HealthItemStatus, statusDetail: String? = nil,
                                     detail: String, why: String, disabledRecommendation: String? = nil,
                                     link: HealthSettingsLink? = nil) -> HealthItem {
        let rule = HealthScoring.securityPoints[id]
        let severity: String
        switch status {
        case .disabled: severity = rule?.confidence == .low ? "Low — reduces protection" : "Moderate — reduces protection"
        case .enabled: severity = "None"
        default: severity = "Not assessed"
        }
        return HealthItem(id: id, title: title, status: status, statusDetail: statusDetail, severity: severity,
                          confidence: status == .enabled || status == .disabled ? (rule?.confidence ?? .high) : .low,
                          whyItMatters: why, detail: detail,
                          recommendation: status == .disabled ? disabledRecommendation : nil,
                          settingsLink: status == .disabled ? link : nil)
    }

    static let sipWhy = "System Integrity Protection keeps system files and processes from being modified, even by administrators. "
        + "Developers sometimes turn it off on purpose."
    static let sipRecommendation = "If you did not turn it off on purpose, turn it back on from macOS Recovery (Terminal: csrutil enable), then restart. "
        + "It cannot be changed in System Settings."

    /// Parses `csrutil status`, e.g. "System Integrity Protection status: enabled."
    static func sipItem(output: String, status: Int32 = 0) -> HealthItem {
        func item(_ state: HealthItemStatus, _ detail: String, statusDetail: String? = nil) -> HealthItem {
            securityItem("sip", "System Integrity Protection", state, statusDetail: statusDetail, detail: detail, why: sipWhy,
                         disabledRecommendation: sipRecommendation, link: nil)
        }
        guard status != -1 else { return item(.unreadable, timedOut) }
        let marker = "system integrity protection status:"
        guard let line = output.lowercased().split(separator: "\n").first(where: { $0.contains(marker) }),
              let state = line.components(separatedBy: marker).last?.trimmingCharacters(in: .whitespaces) else {
            return item(.unreadable, "csrutil output was not recognized.")
        }
        if state.contains("custom") {
            return item(.disabled, "csrutil reports a custom configuration: some protections are turned off.", statusDetail: "custom configuration")
        } else if state.hasPrefix("enabled") {
            return item(.enabled, "csrutil reports SIP enabled.")
        } else if state.hasPrefix("disabled") {
            return item(.disabled, "csrutil reports SIP disabled.")
        }
        return item(.unknown, "csrutil reports a state this check does not recognize.")
    }

    static let gatekeeperWhy = "Gatekeeper checks that apps from outside the App Store come from an identified developer and are notarized before they open."

    /// Parses `spctl --status`: "assessments enabled" or "assessments disabled" (spctl exits 1 when disabled).
    static func gatekeeperItem(output: String, status: Int32 = 0) -> HealthItem {
        func item(_ state: HealthItemStatus, _ detail: String) -> HealthItem {
            securityItem("gatekeeper", "Gatekeeper", state, detail: detail, why: gatekeeperWhy,
                         disabledRecommendation: "Allow apps from the App Store and identified developers in Privacy & Security settings.",
                         link: .privacySecurity)
        }
        guard status != -1 else { return item(.unreadable, timedOut) }
        let text = output.lowercased()
        if text.contains("assessments enabled") { return item(.enabled, "spctl reports assessments enabled.") }
        if text.contains("assessments disabled") { return item(.disabled, "spctl reports assessments disabled.") }
        if text.contains("assessments") { return item(.unknown, "spctl reports a state this check does not recognize.") }
        return item(.unreadable, "spctl output was not recognized.")
    }

    static let fileVaultWhy = "FileVault encrypts the startup disk so its data cannot be read without your password if the Mac is lost or stolen. "
        + "Leaving it off can be intentional on a desktop Mac kept in a secure place."

    /// Parses `fdesetup status`, e.g. "FileVault is On." or "FileVault is Off."
    static func fileVaultItem(output: String, status: Int32 = 0) -> HealthItem {
        func item(_ state: HealthItemStatus, _ detail: String, statusDetail: String? = nil,
                  recommendation: String = "Turn on FileVault in Privacy & Security settings › FileVault.") -> HealthItem {
            securityItem("filevault", "FileVault", state, statusDetail: statusDetail, detail: detail, why: fileVaultWhy,
                         disabledRecommendation: recommendation, link: .privacySecurity)
        }
        guard status != -1 else { return item(.unreadable, timedOut) }
        let text = output.lowercased()
        if text.contains("filevault is on") {
            if text.contains("decryption in progress") {
                return item(.disabled, "fdesetup reports that the startup disk is being decrypted.", statusDetail: "turning off",
                            recommendation: "If you did not mean to turn FileVault off, turn it back on in Privacy & Security settings once decryption finishes.")
            }
            return item(.enabled, text.contains("encryption in progress")
                ? "fdesetup reports FileVault on; encryption is still in progress." : "fdesetup reports FileVault on.")
        }
        if text.contains("filevault is off") {
            if text.contains("will be enabled") {
                return item(.disabled, "fdesetup reports that FileVault turns on at the next restart.", statusDetail: "turns on after restart",
                            recommendation: "Restart the Mac (Apple menu › Restart) to finish turning on FileVault.")
            }
            return item(.disabled, "fdesetup reports FileVault off.")
        }
        if text.contains("not supported") { return item(.unsupported, "fdesetup reports FileVault is not supported on this volume.") }
        if text.contains("filevault is") { return item(.unknown, "fdesetup reports a state this check does not recognize.") }
        return item(.unreadable, "fdesetup output was not recognized.")
    }

    static let firewallWhy = "The macOS firewall is off by default; turning it on blocks unsolicited incoming connections, "
        + "which matters most on untrusted networks."

    /// Parses `socketfilterfw --getglobalstate`, e.g. "Firewall is enabled. (State = 1)".
    static func firewallItem(output: String, status: Int32 = 0) -> HealthItem {
        func item(_ state: HealthItemStatus, _ detail: String, statusDetail: String? = nil) -> HealthItem {
            securityItem("firewall", "Firewall", state, statusDetail: statusDetail, detail: detail, why: firewallWhy,
                         disabledRecommendation: "Turn on the firewall in Network settings › Firewall, especially if you use public Wi-Fi.",
                         link: .network)
        }
        guard status != -1 else { return item(.unreadable, timedOut) }
        let text = output.lowercased()
        let state = text.range(of: #"state = (\d)"#, options: .regularExpression).flatMap { Int(text[$0].filter(\.isNumber)) }
        if state == 1 || state == 2 || (state == nil && text.contains("firewall is enabled")) {
            return item(.enabled, "The application firewall reports it is on.", statusDetail: state == 2 ? "blocks all incoming" : nil)
        }
        if state == 0 || (state == nil && text.contains("firewall is disabled")) {
            return item(.disabled, "The application firewall reports it is off (the macOS default).")
        }
        if state != nil { return item(.unknown, "socketfilterfw reports a state this check does not recognize.") }
        return item(.unreadable, "socketfilterfw output was not recognized.")
    }

    /// The system copy and, on newer macOS, the copy the XProtect service updates. The newer version is shown.
    static let xprotectPlists = [
        "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist",
        "/var/protected/xprotect/XProtect.bundle/Contents/Info.plist",
    ]

    static func xprotectVersion(infoPlist: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any]
        return (plist?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func xprotectItem(_ versions: [String?]) -> HealthItem {
        let why = "XProtect is Apple's built-in malware detection. macOS updates its definitions automatically."
        guard let newest = versions.compactMap({ $0 }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            return HealthItem(id: "xprotect", title: "XProtect", status: .unreadable, severity: "Not assessed", confidence: .low,
                              whyItMatters: why, detail: "The XProtect version could not be read.")
        }
        return HealthItem(id: "xprotect", title: "XProtect", status: .enabled, statusDetail: "version \(newest)", severity: "None",
                          confidence: .medium, whyItMatters: why,
                          detail: "Installed definitions version \(newest). This shows the installed version; it does not confirm it is the latest.")
    }

    /// The four settings commands (concurrently) and XProtect. nil when cancelled.
    static func readSecurity(system: HealthSystem, cancellation: ScanCancellation) -> [HealthItem]? {
        typealias Probe = (path: String, arguments: [String], parse: @Sendable (String, Int32) -> HealthItem, title: String, id: String)
        let probes: [Probe] = [
            ("/usr/bin/csrutil", ["status"], { sipItem(output: $0, status: $1) }, "System Integrity Protection", "sip"),
            ("/usr/sbin/spctl", ["--status"], { gatekeeperItem(output: $0, status: $1) }, "Gatekeeper", "gatekeeper"),
            ("/usr/bin/fdesetup", ["status"], { fileVaultItem(output: $0, status: $1) }, "FileVault", "filevault"),
            ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], { firewallItem(output: $0, status: $1) }, "Firewall", "firewall"),
        ]
        let results = DiskScanService.concurrentMap(Array(probes.indices)) { index -> HealthItem? in
            let probe = probes[index]
            guard system.isExecutable(probe.path) else {
                return HealthItem(id: probe.id, title: probe.title, status: .unsupported, severity: "Not assessed", confidence: .low,
                                  whyItMatters: "", detail: "The tool that reports this setting is not available on this Mac.")
            }
            let output = system.run(probe.path, probe.arguments, commandTimeout, cancellation)
            if output.status == SystemDataScanner.cancelledStatus { return nil }
            return probe.parse(output.output, output.status)
        }
        if cancellation.isCancelled || results.contains(where: { $0 == nil }) { return nil }
        let xprotect = xprotectItem(xprotectPlists.map { system.readFile($0).flatMap(xprotectVersion(infoPlist:)) })
        return results.compactMap { $0 } + [xprotect]
    }

    static func securityResult(_ items: [HealthItem], now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .security, observedAt: now)
        let scored = HealthScoring.security(items)
        result.apply(scored.outcome)
        result.items = scored.items
        let off = scored.items.filter { $0.status == .disabled }
        let on = scored.items.filter { $0.status == .enabled && $0.id != "xprotect" }
        switch scored.outcome.state {
        case .attention:
            result.summary = off.count == 1
                ? "\(off[0].title) is off, which reduces protection. It can be intentional; the details below explain the trade-off."
                : "\(HealthFormat.list(off.map(\.title))) are off. Each reduces protection; the details below explain each one."
            result.recommendation = off.compactMap(\.recommendation).first
            result.settingsLink = off.compactMap(\.settingsLink).first
        case .healthy:
            result.summary = "\(HealthFormat.list(on.map(\.title))) \(on.count == 1 ? "is" : "are") on, as reported by macOS."
                + (scored.items.contains { $0.state == .unknown } ? " Some settings could not be read." : "")
        case .critical, .unknown:
            result.summary = "None of the security settings could be read."
            result.failedReason = "Security settings could not be read"
        }
        result.measurements = [HealthMeasurement("Settings on", "\(on.count) of \(scored.items.filter { $0.id != "xprotect" }.count)",
                                                 note: "System Integrity Protection, Gatekeeper, FileVault and the firewall; each is listed below.")]
        result.notes.append("These readings show whether a few built-in protections are on. They are not a security audit.")
        return result
    }

    // MARK: System Updates

    struct UpdatePreferences: Sendable, Equatable {
        /// `AutomaticCheckEnabled`; nil when absent (the macOS default, on).
        var automaticCheck: Bool?
        var lastSuccessfulCheck: Date?
        var automaticDownload: Bool?
        var criticalUpdateInstall: Bool?
    }

    enum SoftwareUpdateListRead: Sendable, Equatable {
        case notChecked
        case unreadable(String)
        case list(available: Int, recommended: Int, titles: [String])
    }

    static func boolPreference(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func readUpdatePreferences(system: HealthSystem) -> UpdatePreferences {
        UpdatePreferences(automaticCheck: boolPreference(system.preference("AutomaticCheckEnabled")),
                          lastSuccessfulCheck: system.preference("LastSuccessfulDate") as? Date,
                          automaticDownload: boolPreference(system.preference("AutomaticDownload")),
                          criticalUpdateInstall: boolPreference(system.preference("CriticalUpdateInstall")))
    }

    /// Parses `softwareupdate -l --no-scan` (the list macOS already has; no network). "No new software available."
    /// means none; each "* Label:" is one update, recommended unless its details say "Recommended: NO".
    static func parseSoftwareUpdateList(output: String, status: Int32) -> SoftwareUpdateListRead {
        if status == -1 { return .unreadable(timedOut) }
        if output.contains("No new software available") { return .list(available: 0, recommended: 0, titles: []) }
        let lines = output.components(separatedBy: "\n")
        var available = 0, recommended = 0
        var titles: [String] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("* Label:") {
            available += 1
            let details = index + 1 < lines.count ? lines[index + 1] : ""
            if !details.lowercased().contains("recommended: no") { recommended += 1 }
            if let title = details.components(separatedBy: ",").first?.components(separatedBy: "Title:").last?
                .trimmingCharacters(in: .whitespaces), !title.isEmpty {
                titles.append(title)
            }
        }
        if available == 0 && status != 0 { return .unreadable("softwareupdate could not list updates.") }
        return .list(available: available, recommended: recommended, titles: titles)
    }

    static func updatesResult(_ preferences: UpdatePreferences, list: SoftwareUpdateListRead, now: Date) -> HealthCategoryResult {
        var result = HealthCategoryResult(category: .updates, observedAt: now)
        result.settingsLink = .softwareUpdate
        var recommendedCount: Int?
        var availableText: String?
        var availableNote: String?
        switch list {
        case .notChecked:
            availableNote = "Not checked in Quick; Extended reads the list macOS has already downloaded."
        case .unreadable(let reason):
            availableNote = reason
        case .list(let available, let recommended, let titles):
            recommendedCount = recommended
            availableText = available == 0 ? "None in the list macOS has" : "\(available)" + (titles.isEmpty ? "" : ": " + titles.joined(separator: ", "))
            availableNote = "From the list macOS last downloaded; no new check was made."
        }
        let outcome = HealthScoring.updates(automaticChecks: preferences.automaticCheck, lastSuccessfulCheck: preferences.lastSuccessfulCheck,
                                            now: now, recommendedUpdates: recommendedCount)
        result.apply(outcome)
        let lastCheck = preferences.lastSuccessfulCheck.map { date -> String in
            let days = Int(now.timeIntervalSince(date) / 86_400)
            let ago = days <= 0 ? "today" : days == 1 ? "1 day ago" : "\(days) days ago"
            return "\(date.formatted(date: .abbreviated, time: .shortened)) (\(ago))"
        }
        switch outcome.state {
        case .attention:
            result.summary = (outcome.deductions.first?.reason ?? "Updates need attention") + "."
            result.recommendation = outcome.deductions.first?.recommendation
        case .healthy:
            let checks = preferences.automaticCheck == true ? "Automatic update checks are on" : "Automatic update checks are on (macOS default)"
            result.summary = checks + (lastCheck.map { "; the last successful check was \($0)." } ?? ".")
            if recommendedCount == 0 { result.summary += " No updates are waiting in the list macOS has." }
        case .critical, .unknown:
            result.summary = "Update preferences could not be read."
        }
        func onOff(_ value: Bool?, default text: String? = nil) -> String? {
            value.map { $0 ? "On" : "Off" } ?? text
        }
        result.measurements = [
            HealthMeasurement("Automatic update checks", onOff(preferences.automaticCheck, default: "On (macOS default)")),
            HealthMeasurement("Last successful check", lastCheck),
            HealthMeasurement("Download new updates automatically", onOff(preferences.automaticDownload)),
            HealthMeasurement("Install security responses and system files", onOff(preferences.criticalUpdateInstall)),
            HealthMeasurement("Available updates", availableText, note: availableNote),
        ]
        return result
    }

    // MARK: This Mac

    static func readMachineInfo() -> HealthMachineInfo {
        let memory = sysctlInt("hw.memsize").map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
        let version = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        return HealthMachineInfo(model: readProductName(), identifier: sysctlString("hw.model"),
                                 chip: sysctlString("machdep.cpu.brand_string"), memory: memory, macOS: "macOS " + version)
    }

    /// The `product-name` registry property is NUL-terminated UTF-8, e.g. "MacBook Air (13-inch, M5)".
    static func productName(from data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func readProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        return productName(from: data)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Reads 32- or 64-bit integer sysctls.
    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == MemoryLayout<Int32>.size ? Int64(Int32(truncatingIfNeeded: value)) : value
    }
}

// MARK: - Model

@MainActor
final class HealthModel: ObservableObject {
    /// The latest finished check, possibly partial (cancelled, or some readings unavailable).
    @Published var report: HealthCheckResult?
    @Published var loading = false
    /// The mode the next `refresh()` uses.
    @Published var mode: HealthMode = .quick
    /// Categories finished so far in the running check, in display order. Empty when idle.
    @Published private(set) var progress: [HealthCategoryResult] = []
    /// The mode of the running check, nil when idle.
    @Published private(set) var runningMode: HealthMode?

    /// Recent memory readings, read on the main actor when a check starts, e.g. `{ [weak monitor] in monitor?.history ?? [] }`.
    /// Empty by default, which leaves memory pressure to the readings taken during the check.
    var memoryHistory: @MainActor () -> [MemorySample]
    /// Largest storage categories from the last Storage Map, shown as context in the Storage card.
    var storageBreakdown: @MainActor () -> [(name: String, bytes: Int64)] = { [] }
    /// Apps using the most memory, shown as context only in the Memory card.
    var topApps: @MainActor () -> [(name: String, bytes: UInt64)] = { [] }

    let system: HealthSystem
    let history: HealthHistoryStore
    private let opener: @MainActor (URL) -> Bool
    private var runs = ScanRunTracker()
    private var runStartedAt: Date?

    init(system: HealthSystem = .live, history: HealthHistoryStore = HealthHistoryStore(),
         opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         memoryHistory: @escaping @MainActor () -> [MemorySample] = { [] }) {
        self.system = system
        self.history = history
        self.opener = opener
        self.memoryHistory = memoryHistory
    }

    /// Starts a check in the current `mode`; calling it while a check runs does nothing.
    func refresh() { refresh(mode: mode) }

    func refresh(mode: HealthMode) {
        guard !loading else { return }
        self.mode = mode
        let run = runs.begin()
        loading = true
        progress = []
        runningMode = mode
        runStartedAt = system.now()
        var request = HealthScanner.Request(mode: mode)
        request.memoryHistory = memoryHistory()
        request.storageBreakdown = storageBreakdown().map { HealthContextEntry(name: $0.name, bytes: $0.bytes) }
        request.topApps = topApps().map { HealthContextEntry(name: $0.name, bytes: Int64(clamping: $0.bytes)) }
        let system = system
        let store = history
        let sink: @Sendable (HealthCategoryResult) -> Void = { [weak self] category in
            guard let model = self else { return }
            Task { @MainActor in model.receive(category, run: run.id) }
        }
        Task { [weak self] in
            var request = request
            request.history = await store.snapshots()
            guard self?.runs.isCurrent(run.id) == true else { return }
            let prepared = request
            let result = await BackgroundWork.run {
                HealthScanner.check(prepared, system: system, cancellation: run.cancellation, onCategory: sink)
            }
            guard let self, self.runs.finish(run.id) else { return }
            // Categories that reached the main actor first are already shown; the final result supersedes them.
            self.complete(result)
        }
    }

    /// Stops the running check at once: finished categories are kept, the rest become "Not checked — cancelled",
    /// and a late result from the cancelled run is dropped.
    func cancel() {
        guard loading, runs.cancel() else { return }
        let finished = Dictionary(progress.map { ($0.category, $0) }, uniquingKeysWith: { $1 })
        let partial = HealthCheckResult.assemble(mode: runningMode ?? mode, startedAt: runStartedAt ?? system.now(),
                                                 finishedAt: system.now(), finished: finished, cancelled: true)
        complete(partial)
    }

    /// Opens a System Settings pane, falling back to System Settings itself.
    @discardableResult
    func open(_ link: HealthSettingsLink) -> Bool { link.open(with: opener) }

    /// What the page shows: the running check's finished categories, else the last report's.
    var displayedCategories: [HealthCategoryResult] { loading ? progress : report?.categories ?? [] }

    /// Categories the running check has not finished yet.
    var pendingCategories: [HealthCategory] {
        guard loading else { return [] }
        return HealthCategory.allCases.filter { category in !progress.contains { $0.category == category } }
    }

    private func receive(_ category: HealthCategoryResult, run: UUID) {
        guard runs.isCurrent(run) else { return }
        progress = HealthOrdering.sorted(progress.filter { $0.category != category.category } + [category])
    }

    private func complete(_ result: HealthCheckResult) {
        report = result
        loading = false
        progress = []
        runningMode = nil
        runStartedAt = nil
        history.append(HealthSnapshot(result))
    }
}
