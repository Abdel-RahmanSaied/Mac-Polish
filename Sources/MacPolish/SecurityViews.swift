import AppKit
import SwiftUI

// MARK: - Models

/// Startup audit state. Scanning runs in the read-only worker (`startup-audit` mode); system extensions are
/// listed in-process. Nothing here changes a launch item.
@MainActor
final class StartupAuditModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", atRisk = "At risk", orphaned = "Orphaned", unsigned = "Unsigned", disabled = "Disabled"
        var id: String { rawValue }

        func includes(_ entry: StartupAuditEntry) -> Bool {
            switch self {
            case .all: true
            case .atRisk: entry.isAtRisk
            case .orphaned: entry.flags.contains(.orphaned)
            // No developer identity: unsigned, ad-hoc or a signature that does not hold.
            case .unsigned: !Set(entry.flags).isDisjoint(with: [.unsigned, .adHocSigned, .invalidSignature])
            case .disabled: entry.disabled == true
            }
        }
    }

    @Published var state: ModuleState = .idle
    @Published var entries: [StartupAuditEntry] = []
    @Published var extensions: [SystemExtensionInfo] = []
    /// True when `systemextensionsctl` could not be read; an empty list then means "unknown", not "none".
    @Published var extensionsUnavailable = false
    @Published var warning: String?
    @Published var filter: Filter = .all
    /// Return false to hold the scan back, for example while permission setup is on screen.
    var authorizeScan: @MainActor () -> Bool = { true }
    var reader: @Sendable (ScanCancellation) -> Result<ScanReport<StartupAuditEntry>, DiskScanFailure> = {
        DiskScanService.readValue(ScanReport<StartupAuditEntry>.self, mode: "startup-audit", timeout: 90, cancellation: $0)
    }
    private var run = ScanRunTracker()
    var extensionReader: @Sendable () -> [SystemExtensionInfo]? = { StartupAuditor.systemExtensions() }

    var filteredEntries: [StartupAuditEntry] { entries.filter(filter.includes) }

    func count(_ level: StartupAuditEntry.RiskLevel) -> Int { entries.filter { $0.riskLevel == level }.count }

    func scan(force: Bool = false) {
        guard state != .loading, force || state == .idle, authorizeScan() else { return }
        let (id, cancellation) = run.begin()
        state = .loading
        warning = nil
        let reader = reader
        let extensionReader = extensionReader
        Task {
            async let report = BackgroundWork.run(qos: .userInitiated) { reader(cancellation) }
            async let installed = BackgroundWork.run(qos: .utility, extensionReader)
            let (result, found) = await (report, installed)
            // A cancelled or replaced run never overwrites what is on screen.
            guard run.finish(id) else { return }
            extensions = found ?? []
            extensionsUnavailable = found == nil
            switch result {
            case .success(let report):
                entries = report.items
                warning = report.warning(purpose: "audited")
                state = .ready
            case .failure(let failure):
                state = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    /// Stops the audit's worker; earlier results stay on screen.
    func cancel() {
        if run.cancel() { state = .cancelled }
    }
}

/// Orphaned app data: scanned in the read-only worker (`orphans` mode), moved to Trash only after review.
@MainActor
final class OrphanedDataModel: ObservableObject {
    @Published var state: ModuleState = .idle
    @Published var items: [OrphanedDataItem] = []
    @Published var warning: String?
    @Published var confirmsCleanup = false
    @Published var cleaning = false
    /// Summary of the last move, including what was left in place and why.
    @Published var lastResult: String?
    var authorizeScan: @MainActor () -> Bool = { true }
    var onOutcome: (@MainActor (CleanupOutcome) -> Void)?
    /// Every finished cleanup with the items offered and what happened to each, for Cleanup History.
    var onCleanup: (@MainActor (_ candidates: [(id: UUID, url: URL, bytes: Int64)], _ result: CleanupResult) -> Void)?
    var reader: @Sendable (ScanCancellation) -> Result<ScanReport<OrphanedDataItem>, DiskScanFailure> = {
        DiskScanService.readValue(ScanReport<OrphanedDataItem>.self, mode: "orphans", timeout: 120, cancellation: $0)
    }
    private var run = ScanRunTracker()
    var cleaner: @Sendable ([OrphanedDataItem]) -> CleanupResult = { OrphanedDataCleaner().clean($0) }

    var selectedItems: [OrphanedDataItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func scan(force: Bool = false) {
        guard state != .loading, !cleaning, force || state == .idle, authorizeScan() else { return }
        let (id, cancellation) = run.begin()
        state = .loading
        warning = nil
        lastResult = nil
        let reader = reader
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { reader(cancellation) }
            guard run.finish(id) else { return }
            switch result {
            case .success(let report):
                // Review-only: nothing starts selected, whatever the worker sent.
                items = report.items.map { var item = $0; item.isSelected = false; return item }
                warning = report.warning(purpose: "checked")
                state = .ready
            case .failure(let failure):
                state = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    /// Stops the scan's worker; earlier results stay on screen.
    func cancel() {
        if run.cancel() { state = .cancelled }
    }

    func setSelection(_ selected: Bool, id: UUID) {
        guard !cleaning, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected = selected
    }

    func deselectAll() {
        for index in items.indices { items[index].isSelected = false }
    }

    func cleanSelected() {
        let selected = selectedItems
        guard !selected.isEmpty, !cleaning, state != .loading else { return }
        cleaning = true
        confirmsCleanup = false
        let cleaner = cleaner
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { cleaner(selected) }
            items.removeAll { result.removedItemIDs.contains($0.id) }
            cleaning = false
            onCleanup?(selected.map { ($0.id, $0.url, $0.size) }, result)
            let moved = "Moved \(result.removedCount) item(s) (\(result.reclaimedBytes.formattedBytes)) to Trash. Disk space is released when Trash is emptied."
            lastResult = moved + (result.issues.isEmpty ? "" : "\n\n" + CleanupIssue.summary(result.issues))
            onOutcome?(CleanupOutcome(date: Date(), movedCount: result.removedCount, movedBytes: result.reclaimedBytes, issues: result.issues))
        }
    }
}

/// Architecture, App Store, signature and last-use details for the Applications list, keyed by app path.
@MainActor
final class ApplicationInsightsModel: ObservableObject {
    @Published var state: ModuleState = .idle
    @Published private(set) var insights: [String: ApplicationInsight] = [:]
    var reader: @Sendable ([String], ScanCancellation) -> Result<[ApplicationInsight], DiskScanFailure> = { paths, cancellation in
        guard let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) else {
            return .failure(DiskScanFailure(message: "The application list could not be prepared."))
        }
        return DiskScanService.readValue([ApplicationInsight].self, mode: "app-insights", arguments: ["--paths", json], timeout: 120,
                                         cancellation: cancellation)
    }
    private var run = ScanRunTracker()

    func insight(for url: URL) -> ApplicationInsight? { insights[url.path] }

    /// Loads insights for apps not loaded yet (all of them with `force`).
    func load(paths: [String], force: Bool = false) {
        let missing = force ? paths : paths.filter { insights[$0] == nil }
        guard state != .loading, !missing.isEmpty else { return }
        let (id, cancellation) = run.begin()
        state = .loading
        let reader = reader
        Task {
            let result = await BackgroundWork.run(qos: .utility) { reader(missing, cancellation) }
            guard run.finish(id) else { return }
            switch result {
            case .success(let found):
                for insight in found { insights[insight.path] = insight }
                state = .ready
            case .failure(let failure):
                state = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    func cancel() {
        if run.cancel() { state = .cancelled }
    }
}

// MARK: - Startup audit

struct StartupAuditView: View {
    @ObservedObject var model: StartupAuditModel
    var onReviewPermissions: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            securityHeader(title: "Startup Items", subtitle: "Audit agents and daemons that can run in the background.",
                           buttonTitle: "Refresh", isBusy: model.state == .loading, onCancel: { model.cancel() }) { model.scan(force: true) }
            content
        }
        .task { model.scan() }
    }

    @ViewBuilder
    private var content: some View {
        let presentation = ModulePresentation.of(model.state, hasResults: !model.entries.isEmpty)
        if !presentation.showsResults && presentation != .empty {
            ModuleStateView(presentation: presentation, subject: "Startup items", loadingTitle: "Reading launch agents, daemons and signatures…",
                            start: { model.scan(force: true) }, onReviewPermissions: onReviewPermissions)
        } else {
            ModuleNotice(presentation: presentation)
            VStack(alignment: .leading, spacing: 12) {
                summary
                readOnlyNote
                if let warning = model.warning {
                    SecurityWarning(text: warning, onReviewPermissions: onReviewPermissions)
                }
                Picker("Show", selection: $model.filter) {
                    ForEach(StartupAuditModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 12)

            List {
                Section("Launch agents and daemons") {
                    let entries = model.filteredEntries
                    if entries.isEmpty {
                        Text(model.entries.isEmpty ? "No launch agents or daemons were found in the standard folders."
                                                   : "Nothing matches this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { StartupAuditRow(entry: $0) }
                    }
                }
                Section("System extensions") { extensionRows }
            }
            .listStyle(.inset)
            .disabled(model.state == .loading)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            SummaryTile(count: model.count(.high), title: "High", color: .red)
            SummaryTile(count: model.count(.medium), title: "Medium", color: .orange)
            SummaryTile(count: model.count(.low), title: "Low", color: .yellow)
            SummaryTile(count: model.count(.none), title: "No risk found", color: .green)
            SummaryTile(count: model.entries.filter { $0.disabled == true }.count, title: "Disabled", color: .secondary)
            Spacer()
            if model.state == .loading { ProgressView().controlSize(.small) }
        }
    }

    private var readOnlyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mac Polish only reports on startup items; it never loads, unloads or removes them.", systemImage: "eye")
                .font(.callout.weight(.medium))
            Text("To turn an item off, use System Settings → General → Login Items & Extensions, or the app that installed it. "
                + "Login items that apps register with macOS directly are listed only in System Settings. "
                + (model.entries.contains { $0.disabled == nil && $0.scope != .legacyStartupItem }
                    ? "The disabled state could not be read from launchctl for some items." : ""))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items & Extensions…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var extensionRows: some View {
        if model.extensionsUnavailable {
            Text("System extensions could not be listed (systemextensionsctl did not answer). This does not mean none are installed.")
                .foregroundStyle(.secondary)
        } else if model.extensions.isEmpty {
            Text("No system extensions are installed.").foregroundStyle(.secondary)
        } else {
            ForEach(model.extensions) { item in
                HStack(spacing: 14) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(item.active ? Color.accentColor : .secondary)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline)
                        Text([item.bundleID, item.version.map { "version \($0)" }, item.teamID.map { "team \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        ChipFlow {
                            SecurityChip(text: item.categoryName, color: .secondary)
                            SecurityChip(text: item.state, color: item.active ? .green : .orange)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct StartupAuditRow: View {
    let entry: StartupAuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.scope.icon)
                .foregroundStyle(riskColor(entry.riskLevel))
                .frame(width: 36, height: 36)
                .background(riskColor(entry.riskLevel).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .help(entry.scope.title)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.label).font(.headline).lineLimit(1).truncationMode(.middle)
                    if entry.riskLevel != .none {
                        SecurityChip(text: entry.riskLevel.title + " risk", color: riskColor(entry.riskLevel))
                    }
                }
                Text(entry.programPath ?? "No program")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                ChipFlow {
                    signatureChip
                    SecurityChip(text: entry.scope.title, color: .secondary)
                    ForEach(entry.flags, id: \.self) { flag in
                        SecurityChip(text: flag.title, color: riskColor(flag.level(for: entry.scope)))
                    }
                    if entry.disabled == true { SecurityChip(text: "Disabled", color: .secondary) }
                    if entry.runsAtLoad { SecurityChip(text: "Runs at load", color: .blue) }
                    if entry.keepAlive { SecurityChip(text: "Keep alive", color: .blue) }
                    if entry.isScheduled { SecurityChip(text: "Scheduled", color: .blue) }
                }
                ForEach(Array(entry.findings.enumerated()), id: \.offset) { _, finding in
                    Text(finding).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Reveal plist") { NSWorkspace.shared.activateFileViewerSelecting([entry.plistURL]) }
                Button("Reveal program") {
                    if let path = entry.programPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(!entry.programExists)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var signatureChip: some View {
        if let signature = entry.signature {
            SignatureChip(signature: signature)
        } else if entry.flags.contains(.orphaned) {
            SignatureChip(signature: CodeSignatureSummary(trust: .missing))
        } else {
            SecurityChip(text: "Signature not checked", color: .secondary)
        }
    }
}

// MARK: - Orphaned app data

struct OrphanedDataView: View {
    @ObservedObject var model: OrphanedDataModel
    var onReviewPermissions: (() -> Void)? = nil
    @ViewState private var confirmation: CleanupConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            securityHeader(title: "Leftover App Data",
                           subtitle: "Data in your Library named after apps that are no longer installed.",
                           buttonTitle: "Scan Again", isBusy: model.state == .loading || model.cleaning,
                           onCancel: model.state == .loading ? { model.cancel() } : nil) { model.scan(force: true) }
            content
        }
        .task { model.scan() }
        .cleanupConfirmation($confirmation, onConfirm: { _ in model.cleanSelected() })
    }

    @ViewBuilder
    private var content: some View {
        let presentation = ModulePresentation.of(model.state, hasResults: !model.items.isEmpty)
        if !presentation.showsResults && presentation != .empty {
            ModuleStateView(presentation: presentation, subject: "Leftover app data", loadingTitle: "Comparing Library folders with installed apps…",
                            start: { model.scan(force: true) }, onReviewPermissions: onReviewPermissions)
        } else {
            ModuleNotice(presentation: presentation)
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is selected for you. These matches are by bundle identifier: review each item, and keep anything you are unsure about.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = model.warning {
                    SecurityWarning(text: warning, onReviewPermissions: onReviewPermissions)
                }
                if let result = model.lastResult {
                    Text(result).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 12)

            if model.items.isEmpty {
                ContentUnavailableView("No leftover app data found", systemImage: "checkmark.circle",
                                       description: Text("Every app-named folder checked belongs to an installed app."))
            } else {
                let unmatched = model.items.filter { $0.sameVendorApp == nil }
                let shared = model.items.filter { $0.sameVendorApp != nil }
                List {
                    if !unmatched.isEmpty {
                        Section("Not matched to any installed app") { rows(unmatched) }
                    }
                    if !shared.isEmpty {
                        Section("Same developer as an installed app — may be shared data") { rows(shared) }
                    }
                }
                .listStyle(.inset)
                .disabled(model.state == .loading || model.cleaning)
            }

            HStack {
                Text("\(model.items.count) item(s) · \(model.totalBytes.formattedBytes) · \(model.selectedBytes.formattedBytes) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.cleaning { ProgressView().controlSize(.small) }
                Button("Deselect All") { model.deselectAll() }
                    .disabled(model.selectedItems.isEmpty || model.cleaning)
                Button("Move Selected to Trash…", role: .destructive) {
                    confirmation = model.cleaning ? nil : .forOrphanedData(model.selectedItems)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.selectedItems.isEmpty || model.cleaning || model.state == .loading)
            }
            .padding(20)
            .background(.bar)
        }
    }

    private func rows(_ items: [OrphanedDataItem]) -> some View {
        ForEach(items) { item in
            OrphanedDataRow(item: item, isSelected: Binding(
                get: { model.items.first { $0.id == item.id }?.isSelected ?? false },
                set: { model.setSelection($0, id: item.id) }))
        }
    }
}

private struct OrphanedDataRow: View {
    let item: OrphanedDataItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.bundleIdentifier).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("~/Library/\(item.location) · \(item.url.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let modified = item.newestContentModifiedAt ?? item.modifiedAt {
                    Text("Last modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let vendor = item.sameVendorApp {
                    Text("An installed app from the same developer (\(vendor)) may still use this data.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.isMeasurementComplete {
                    Text("Some content could not be read, so the size is partial and the item cannot be verified before moving.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(item.size.formattedBytes).font(.system(.body, design: .monospaced).weight(.medium))
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Application insight badges

/// A small row of badges for one app: architecture, App Store, signature and last use.
struct ApplicationInsightBadges: View {
    let insight: ApplicationInsight
    var unusedAfterDays = 90

    var body: some View {
        ChipFlow {
            architectureChip
            if insight.isAppStore { SecurityChip(text: "App Store", color: .blue) }
            if insight.signature.trust != .appStore || !insight.isAppStore { SignatureChip(signature: insight.signature) }
            usageChip
        }
    }

    @ViewBuilder
    private var architectureChip: some View {
        if insight.architectures.isEmpty {
            SecurityChip(text: "Architecture unknown", color: .secondary)
        } else if insight.isUniversal {
            SecurityChip(text: "Universal", color: .green)
        } else if insight.hasAppleSilicon {
            SecurityChip(text: "Apple silicon", color: .green)
        } else if insight.needsRosetta && ApplicationInsight.hostIsAppleSilicon {
            SecurityChip(text: "Intel only · Needs Rosetta", color: .orange)
        } else {
            SecurityChip(text: insight.architectures.joined(separator: ", "), color: .secondary)
        }
    }

    @ViewBuilder
    private var usageChip: some View {
        if let days = insight.daysSinceLastUse() {
            if insight.isUnused(days: unusedAfterDays) {
                SecurityChip(text: "Not opened in \(days) days", color: .orange)
            } else {
                SecurityChip(text: days == 0 ? "Opened today" : "Opened \(days) day\(days == 1 ? "" : "s") ago", color: .secondary)
            }
        } else {
            // Spotlight has no record: unknown, never "unused".
            SecurityChip(text: "Last used unknown", color: .secondary)
                .help("Spotlight has no last-used date for this app. That does not mean it is unused.")
        }
    }
}

/// Shows the badges for `url` once `model` has them, so a list row updates when insights arrive.
struct ApplicationInsightSlot: View {
    @ObservedObject var model: ApplicationInsightsModel
    let url: URL

    var body: some View {
        if let insight = model.insight(for: url) {
            ApplicationInsightBadges(insight: insight)
        } else if model.state == .loading {
            Text("Checking signature and architecture…").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared pieces

private struct SignatureChip: View {
    let signature: CodeSignatureSummary

    var body: some View {
        SecurityChip(text: signature.label, color: color)
            .help(signature.signingID.map { "Signing identifier: \($0)" } ?? signature.label)
    }

    private var color: Color {
        switch signature.trust {
        case .apple, .appStore, .developerID: .green
        case .otherSigned: .blue
        case .adHoc, .unsigned: .orange
        case .invalid, .missing: .red
        case .unknown: .secondary
        }
    }
}

private struct SecurityChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct SummaryTile: View {
    let count: Int
    let title: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SecurityWarning: View {
    let text: String
    let onReviewPermissions: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onReviewPermissions { Button("Review Scan Permissions…", action: onReviewPermissions) }
        }
    }
}

private struct SecurityLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text("This can take a moment.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SecurityFailureView: View {
    let message: String
    let onReviewPermissions: (() -> Void)?

    var body: some View {
        VStack(spacing: 15) {
            ContentUnavailableView("Scan incomplete", systemImage: "exclamationmark.triangle", description: Text(message))
            if let onReviewPermissions {
                Button("Review Scan Permissions…", action: onReviewPermissions)
                    .buttonStyle(.borderedProminent).padding(.bottom, 24)
            }
        }
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

@MainActor
private func securityHeader(title: String, subtitle: String, buttonTitle: String, isBusy: Bool,
                            onCancel: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary)
        }
        Spacer()
        if isBusy, let onCancel {
            ProgressView().controlSize(.small)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        } else {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
    }
    .padding(30)
}

private func riskColor(_ level: StartupAuditEntry.RiskLevel) -> Color {
    switch level {
    case .high: .red
    case .medium: .orange
    case .low: .yellow
    case .none: .green
    }
}
