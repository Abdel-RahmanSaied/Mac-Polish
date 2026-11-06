import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// One action that runs every scanner at once, shows each one's progress, and writes one combined report.
/// Each step uses the same entry point, access gate, worker processes and time limits as its own page,
/// so a deep scan never reads anything a page would not, and its results appear on those pages too.
@MainActor
final class DeepScanModel: ObservableObject {
    struct Step: Identifiable, Equatable {
        enum Status: Equatable {
            case waiting, running, done
            /// Finished, but some locations were not read (denied, time limit); the results shown are real but incomplete.
            case partial(String)
            case failed(String)
            case cancelled
        }
        let id: String
        let title: String
        let destination: SidebarDestination
        var status: Status = .waiting
        var summary = ""
        var duration: TimeInterval?
    }

    /// The whole deep scan, as one state the UI and the report can show.
    enum Overall: Equatable {
        case notStarted, scanning, cancelled, failed, partial, completed

        var label: String {
            switch self {
            case .notStarted: "Not started"
            case .scanning: "Scanning"
            case .cancelled: "Cancelled"
            case .failed: "Failed"
            case .partial: "Partially completed"
            case .completed: "Completed"
            }
        }
    }

    /// How one module ended, read from its published state.
    enum Outcome: Equatable { case finished, failed(String), cancelled, notStarted }

    /// How to start one module, stop it, wait for it, and describe what it found.
    struct Runner {
        let id: String
        let title: String
        let destination: SidebarDestination
        let start: @MainActor () -> Void
        let cancel: @MainActor () -> Void
        let settle: @MainActor () async -> Outcome
        let summary: @MainActor () -> String
        /// Why finished results are incomplete, or nil when they are complete.
        var partial: @MainActor () -> String? = { nil }
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false
    @Published private(set) var cancelling = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    /// True when the last run ended because the user cancelled it.
    @Published private(set) var cancelledByUser = false
    /// Extra modules register here without changing the core list.
    var additionalRunners: [@MainActor (AppModel) -> Runner] = []
    /// Replaces the built-in steps; tests use it to drive scanners that succeed, fail or hang on purpose.
    var runnersOverride: (@MainActor (AppModel) -> [Runner])?

    private unowned let app: AppModel
    private var activeRunners: [Runner] = []
    private var remaining = 0
    init(app: AppModel) { self.app = app }

    var duration: TimeInterval? { startedAt.flatMap { start in finishedAt.map { $0.timeIntervalSince(start) } } }

    var overall: Overall {
        if steps.isEmpty { return .notStarted }
        if running { return .scanning }
        if cancelledByUser { return .cancelled }
        if steps.allSatisfy({ $0.status == .done }) { return .completed }
        if steps.allSatisfy({ if case .failed = $0.status { true } else { false } }) { return .failed }
        return .partial
    }

    /// A report from a run that did not complete every step must say so.
    var isPartialReport: Bool { overall != .completed }

    func start() {
        guard !running else { return }
        guard app.authorize("deepScan", retry: { [weak self] in self?.start() }) else { return }
        let runners = runnersOverride?(app) ?? (Self.coreRunners(app) + additionalRunners.map { $0(app) })
        activeRunners = runners
        steps = runners.map { Step(id: $0.id, title: $0.title, destination: $0.destination) }
        running = true
        cancelling = false
        cancelledByUser = false
        startedAt = Date()
        finishedAt = nil
        remaining = runners.count
        // Every step runs at once; each is a main-actor task that waits on its module's published state.
        for runner in runners {
            Task { [weak self] in
                await self?.run(runner)
                self?.stepFinished()
            }
        }
    }

    /// Stops every step still running. Their worker processes end within a fraction of a second; steps that already
    /// finished keep their results, and the report is marked as cancelled.
    func cancel() {
        guard running, !cancelling else { return }
        cancelling = true
        cancelledByUser = true
        for runner in activeRunners { runner.cancel() }
    }

    private func stepFinished() {
        remaining -= 1
        guard remaining == 0 else { return }
        finishedAt = Date()
        running = false
        cancelling = false
        activeRunners = []
    }

    private func run(_ runner: Runner) async {
        let started = Date()
        update(runner.id) { $0.status = .running }
        runner.start()
        let outcome = await runner.settle()
        update(runner.id) {
            $0.duration = Date().timeIntervalSince(started)
            switch outcome {
            case .finished:
                $0.summary = runner.summary()
                $0.status = runner.partial().map { .partial($0) } ?? .done
            case .failed(let message): $0.status = .failed(message)
            case .cancelled: $0.status = .cancelled
            case .notStarted: $0.status = .failed("Did not start. Review scan permissions, then run the deep scan again.")
            }
        }
    }

    private func update(_ id: String, _ change: (inout Step) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[index])
    }

    /// The first value from `publisher` that satisfies `done`. `@Published` publishers start with the current
    /// value, so a module that never started (refused or already finished) settles at once.
    static func first<T: Sendable>(_ publisher: Published<T>.Publisher, where done: @escaping (T) -> Bool) async -> T? {
        for await value in publisher.values where done(value) { return value }
        return nil
    }

    static func moduleSettle(_ publisher: Published<ModuleState>.Publisher) -> @MainActor () async -> Outcome {
        {
            switch await first(publisher, where: { $0 != .loading }) {
            case .failed(let message): .failed(message)
            case .cancelled: .cancelled
            case .idle, nil: .notStarted
            case .ready, .loading: .finished
            }
        }
    }

    static func coreRunners(_ app: AppModel) -> [Runner] {
        [
            Runner(id: "health", title: "Mac health", destination: .health,
                   start: { app.health.refresh(mode: .quick) },
                   cancel: { app.health.cancel() },
                   settle: {
                       _ = await first(app.health.$loading, where: { !$0 })
                       return app.health.report == nil ? .failed("Health readings are unavailable.") : .finished
                   },
                   summary: {
                       guard let report = app.health.report else { return "" }
                       return "Score \(report.score) · \(report.count(.critical)) critical · \(report.count(.attention)) need attention"
                   }),
            Runner(id: "storage", title: "Every file on the startup disk", destination: .storage,
                   start: { app.analyzeStorage(force: true) },
                   cancel: { app.cancelStorage() },
                   settle: moduleSettle(app.$storageState),
                   summary: {
                       guard let map = app.diskMap else { return "" }
                       let coverage = map.reconciliation.map { " · \(Int(($0.coverage * 100).rounded(.down)))% of used space explained" } ?? ""
                       return "\(map.filesCounted.formatted()) files counted" + coverage
                   },
                   partial: {
                       guard let root = app.diskMap?.tree.root else { return nil }
                       return root.unreadable > 0 || root.notScanned > 0 || app.diskMap?.tree.incomplete == true
                           ? "\(root.unreadable) folders unreadable, \(root.notScanned) not reached in time" : nil
                   }),
            Runner(id: "cleanup", title: "Caches, logs, developer and large files", destination: .cleanup,
                   start: { app.startScan() },
                   cancel: { app.cancelBasicScan() },
                   settle: {
                       switch await first(app.$state, where: { $0 != .scanning }) {
                       case .failed(let message): return .failed(message)
                       case .cancelled: return .cancelled
                       case .idle, nil: return .notStarted
                       default: return .finished
                       }
                   },
                   summary: {
                       let suggested = app.items.filter(\.isSelected)
                       return "\(app.items.count) items · \(suggested.reduce(0) { $0 + $1.size }.formattedBytes) suggested for cleanup"
                   },
                   partial: { app.scanWarning == nil ? nil : "Some locations could not be read" }),
            Runner(id: "duplicates", title: "Duplicate files", destination: .duplicates,
                   start: { app.findDuplicates(force: true) },
                   cancel: { app.cancelDuplicates() },
                   settle: moduleSettle(app.$duplicateState),
                   summary: {
                       let groups = app.duplicateGroups
                       return "\(groups.count) groups · \(groups.reduce(0) { $0 + $1.reclaimableSize }.formattedBytes) in extra copies"
                   },
                   partial: { app.duplicateWarning == nil ? nil : "Some files were not checked" }),
            Runner(id: "artifacts", title: "Project build folders", destination: .artifacts,
                   start: { app.artifacts.scan(force: true) },
                   cancel: { app.artifacts.cancel() },
                   settle: moduleSettle(app.artifacts.$state),
                   summary: {
                       "\(app.artifacts.artifacts.count) folders · \(app.artifacts.artifacts.reduce(0) { $0 + $1.size }.formattedBytes)"
                   },
                   partial: { app.artifacts.warning == nil ? nil : "Some folders were not checked" }),
            Runner(id: "applications", title: "Applications and leftovers", destination: .applications,
                   start: { app.loadApplications(force: true) },
                   cancel: { app.cancelApplications() },
                   settle: moduleSettle(app.$applicationState),
                   summary: {
                       "\(app.applications.count) apps · \(app.applications.reduce(0) { $0 + $1.leftoverSize }.formattedBytes) in related library data"
                   }),
            Runner(id: "startup", title: "Startup items security audit", destination: .startup,
                   start: { app.startupAudit.scan(force: true) },
                   cancel: { app.startupAudit.cancel() },
                   settle: moduleSettle(app.startupAudit.$state),
                   summary: {
                       let entries = app.startupAudit.entries
                       return "\(entries.count) launch items · \(entries.filter(\.isAtRisk).count) need review"
                   },
                   partial: { app.startupAudit.warning == nil ? nil : "Some locations could not be read" }),
            Runner(id: "orphans", title: "Leftover data of removed apps", destination: .orphanedData,
                   start: { app.orphans.scan(force: true) },
                   cancel: { app.orphans.cancel() },
                   settle: moduleSettle(app.orphans.$state),
                   summary: {
                       "\(app.orphans.items.count) items · \(app.orphans.items.reduce(0) { $0 + $1.size }.formattedBytes)"
                   },
                   partial: { app.orphans.warning == nil ? nil : "Some locations could not be read" }),
            Runner(id: "systemData", title: "System Data locations", destination: .systemData,
                   start: { app.analyzeSystemData() },
                   cancel: { app.cancelSystemData() },
                   settle: moduleSettle(app.$systemDataState),
                   summary: {
                       guard let report = app.systemDataReport else { return "" }
                       return "\(report.measuredBytes.formattedBytes) measured in \(report.areas.count) locations"
                   },
                   partial: {
                       let partial = app.systemDataReport?.areas.filter(\.partial).count ?? 0
                       return partial > 0 ? "\(partial) locations measured partially" : nil
                   })
        ]
    }

    // MARK: Report

    static func statusText(_ status: Step.Status, summary: String) -> String {
        switch status {
        case .waiting: "Not run"
        case .running: "Still running"
        case .done: summary
        case .partial(let reason): summary + " (partial: " + reason + ")"
        case .failed(let message): "Failed: " + message
        case .cancelled: "Cancelled"
        }
    }

    /// A Markdown report of the last results on every page. `path` and `text` format every path and every
    /// free-text value (the privacy-safe report redacts through them); totals, counts and states are kept.
    func markdown(now: Date = Date(), path: (String) -> String = { $0 }, text: (String) -> String = { $0 },
                  header: String? = nil) -> String {
        func cell(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "/") }
        var lines = ["# Mac Polish deep scan report", "",
                     "Created \(now.formatted(date: .long, time: .shortened)).",
                     header ?? "Read-only scan results. Paths and file names are included; review before sharing.", ""]
        lines.append("**Status: \(overall.label).**" + (isPartialReport && !steps.isEmpty
            ? " This report is partial: steps that did not finish are marked, and their totals are missing or incomplete." : ""))
        if let duration { lines.append("Deep scan duration: \(Int(duration.rounded())) s.") }
        lines += ["", "## Steps", "", "| Step | Result | Time |", "| --- | --- | --- |"]
        for step in steps {
            lines.append("| \(step.title) | \(cell(text(Self.statusText(step.status, summary: step.summary)))) | \(step.duration.map { "\(Int($0.rounded())) s" } ?? "—") |")
        }
        if let health = app.health.report {
            lines += ["", text(health.markdown())]
        }
        if let map = app.diskMap {
            lines += ["", "## Storage", ""]
            if let volumes = map.volumes {
                lines.append("- \(volumes.used.formattedBytes) used of \(volumes.capacity.formattedBytes); \(volumes.free.formattedBytes) free.")
            }
            if let check = map.reconciliation {
                lines.append("- Found \(check.found.formattedBytes) of \(check.dataUsed.formattedBytes) used on the data volume (\(Int((check.coverage * 100).rounded(.down)))%).")
            }
            lines.append("- \(map.filesCounted.formatted()) files counted; \(map.tree.root.unreadable) folders unreadable, \(map.tree.root.notScanned) not reached in time.")
            if let system = map.systemTree {
                lines.append("- Sealed macOS volume: \(system.root.files.formatted()) files, \(system.root.bytes.formattedBytes).")
            }
            if let insights = map.tree.insights {
                lines += ["", "### Space by kind", "", "| Kind | Size | Files |", "| --- | ---: | ---: |"]
                for (kind, total) in insights.kinds.sorted(by: { $0.value.bytes > $1.value.bytes }) {
                    lines.append("| \(kind.displayName) | \(total.bytes.formattedBytes) | \(total.files.formatted()) |")
                }
                lines += ["", "### Largest files", "", "| File | Size | Modified |", "| --- | ---: | --- |"]
                for file in insights.largestFiles.prefix(25) {
                    lines.append("| `\(cell(path(DiskMapService.familiarPath(file.path))))` | \(file.bytes.formattedBytes) | \(file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—") |")
                }
            }
        }
        lines += ["", "## Cleanup opportunities", ""]
        let byCategory = Dictionary(grouping: app.items, by: \.category)
        for category in ScanCategory.allCases {
            guard let found = byCategory[category], !found.isEmpty else { continue }
            lines.append("- \(category.rawValue): \(found.count) items, \(found.reduce(0) { $0 + $1.size }.formattedBytes)")
        }
        if !app.duplicateGroups.isEmpty {
            lines.append("- Duplicates: \(app.duplicateGroups.count) groups, \(app.duplicateGroups.reduce(0) { $0 + $1.reclaimableSize }.formattedBytes) in extra copies (estimate)")
        }
        if !app.orphans.items.isEmpty {
            lines.append("- Leftover data of removed apps: \(app.orphans.items.count) items, \(app.orphans.items.reduce(0) { $0 + $1.size }.formattedBytes) (review: matched by bundle identifier)")
        }
        if !app.artifacts.artifacts.isEmpty {
            lines.append("- Project build folders: \(app.artifacts.artifacts.count), \(app.artifacts.artifacts.reduce(0) { $0 + $1.size }.formattedBytes)")
            for artifact in app.artifacts.artifacts.prefix(15) {
                lines.append("  - `\(cell(path(artifact.url.path)))`: \(artifact.size.formattedBytes)")
            }
        }
        let atRisk = app.startupAudit.entries.filter(\.isAtRisk)
        if !atRisk.isEmpty {
            lines += ["", "## Startup items to review", ""]
            for entry in atRisk.prefix(30) {
                lines.append("- `\(cell(text(entry.label)))` (\(text(entry.findings.joined(separator: "; "))))")
            }
        }
        lines += ["", "Nothing was moved or deleted by this report. Sizes are allocated disk space; moving files to Trash frees space only when Trash is emptied."]
        return lines.joined(separator: "\n")
    }
}

struct DeepScanCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deepScan: DeepScanModel
    @ViewState private var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEEP SCAN").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.teal)
                    Text("Every scanner at once: every file on the disk, health, duplicates, projects, apps and startup items.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !deepScan.steps.isEmpty && !deepScan.running {
                    Button("Export Report…") { previewing = true }
                }
                if deepScan.running {
                    Button(deepScan.cancelling ? "Cancelling…" : "Cancel") { deepScan.cancel() }
                        .disabled(deepScan.cancelling)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(deepScan.steps.isEmpty ? "Run Deep Scan" : "Run Again") { deepScan.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if !deepScan.steps.isEmpty {
                Label(deepScan.overall.label + (deepScan.overall == .partial ? " — some steps did not finish; their results are incomplete." : ""),
                      systemImage: overallIcon)
                    .font(.callout.weight(.medium))
                VStack(spacing: 8) {
                    ForEach(deepScan.steps) { step in
                        Button { model.destination = step.destination } label: {
                            HStack(spacing: 10) {
                                icon(step.status).frame(width: 18)
                                Text(step.title).foregroundStyle(.primary)
                                Spacer()
                                Text(detail(step)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                                if let duration = step.duration {
                                    Text("\(Int(duration.rounded())) s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(detail(step))
                        .accessibilityLabel("\(step.title): \(detail(step))")
                    }
                }
                if let duration = deepScan.duration {
                    Text("Finished in \(Int(duration.rounded())) s. Select a step to review its results.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $previewing) { ReportPreviewSheet(deepScan: deepScan) }
    }

    private var overallIcon: String {
        switch deepScan.overall {
        case .notStarted: "circle"
        case .scanning: "arrow.triangle.2.circlepath"
        case .cancelled: "stop.circle"
        case .failed: "xmark.octagon"
        case .partial: "exclamationmark.triangle"
        case .completed: "checkmark.seal"
        }
    }

    @ViewBuilder private func icon(_ status: DeepScanModel.Step.Status) -> some View {
        switch status {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial: Image(systemName: "checkmark.circle.trianglebadge.exclamationmark").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func detail(_ step: DeepScanModel.Step) -> String {
        step.status == .running ? "Scanning…" : DeepScanModel.statusText(step.status, summary: step.summary)
    }
}
