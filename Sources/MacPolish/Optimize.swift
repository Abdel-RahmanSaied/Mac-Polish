import Foundation
import SwiftUI
import AppKit

struct OptimizeCandidate: Identifiable, Sendable {
    var id: UUID { item.id }
    let item: ScanItem
    let reason: String
    let scannedModification: Date
    var selected = true
}

enum OptimizePolicy {
    static let categories = CleanupPolicy.suggestedCategories

    static func candidate(_ item: ScanItem, now: Date = Date()) -> OptimizeCandidate? {
        guard categories.contains(item.category), item.size > 0, !CleanupPolicy.isProtected(item.url),
              item.url.standardizedFileURL == item.url.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        // A folder's own date ignores edits inside it; require the scanned content date for folders.
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        if isDirectory && item.newestContentModifiedAt == nil { return nil }
        let newest = max(modified, item.newestContentModifiedAt ?? modified)
        guard CleanupPolicy.isStale(newest: newest, now: now) else { return nil }
        return OptimizeCandidate(item: item,
                                 reason: "Cache or log; nothing inside changed for more than 7 days. Apps may recreate it.",
                                 scannedModification: modified)
    }

    static func unchanged(_ candidate: OptimizeCandidate) -> Bool {
        let url = candidate.item.url
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return modified == candidate.scannedModification
    }
}

@MainActor
final class OptimizerModel: ObservableObject {
    @Published var busy = false
    @Published var running = false
    @Published var phase = "Ready for a comprehensive scan"
    @Published var candidates: [OptimizeCandidate] = []
    @Published var report: SystemDataReport?
    @Published var diskAreas: [SystemDataChild] = []
    @Published var reviewAreas: [SystemDataArea] = []
    @Published var freeBytes: Int64?
    @Published var totalBytes: Int64?
    @Published var coverage = ""
    @Published var recommendationWarning: String?
    /// True when no scan section could be read, so no recommendations exist at all.
    @Published var recommendationsUnavailable = false
    @Published var reviewCount = 0
    @Published var includeDocker = false
    @Published var confirm = false
    @Published var results: [String] = []
    @Published var cleanupIssues: [CleanupIssue] = []
    @Published var completed = false
    var onOutcome: (@MainActor (CleanupOutcome) -> Void)?
    var onDiskMap: (@MainActor (DiskMapReport) -> Void)?
    var selectedBytes: Int64 { candidates.filter(\.selected).reduce(0) { $0 + $1.item.size } }
    var selectedCount: Int { candidates.filter(\.selected).count }
    var hasActions: Bool { selectedCount > 0 || (includeDocker && dockerAvailable) }
    var dockerAvailable: Bool { (SystemDataScanner.dockerBuildCacheBytes(report?.dockerOutput ?? "") ?? 0) > 0 }

    func refreshCapacity() {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)
        freeBytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        totalBytes = (attributes?[.systemSize] as? NSNumber)?.int64Value
    }

    func scan() {
        guard !busy else { return }
        busy = true
        completed = false
        results = []
        cleanupIssues = []
        candidates = []
        includeDocker = false
        report = nil
        diskAreas = []
        reviewAreas = []
        reviewCount = 0
        coverage = ""
        recommendationWarning = nil
        recommendationsUnavailable = false
        refreshCapacity()
        phase = "Mapping the whole startup disk…"
        Task {
            let map = await BackgroundWork.run(qos: .utility) { DiskMapService.scan() }
            switch map {
            case .success(let report):
                onDiskMap?(report)
                diskAreas = report.tree.root.children.filter { $0.kind != .smallerItems && $0.bytes > 0 }.prefix(12)
                    .map { SystemDataChild(url: DiskMapService.revealURL([$0.name]), bytes: $0.bytes) }
                coverage = Self.coverageText(report)
            case .failure(let failure):
                coverage = failure.message + " External drives are not included."
            }
            phase = "Analyzing system data, developer storage and Docker…"
            report = await BackgroundWork.run(qos: .utility) { SystemDataScanner().scan() }
            phase = "Measuring locations for manual review…"
            reviewAreas = await BackgroundWork.run(qos: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let specs = [SystemDataScanner.Spec(name: "Trash", url: home.appending(path: ".Trash"), note: "Review in Finder. Emptying Trash permanently removes its contents."),
                             SystemDataScanner.Spec(name: "Downloads", url: home.appending(path: "Downloads"), note: "Review installers and downloads you no longer need."),
                             SystemDataScanner.Spec(name: "Documents", url: home.appending(path: "Documents"), note: "Personal files and projects; review individually."),
                             SystemDataScanner.Spec(name: "Applications", url: URL(fileURLWithPath: "/Applications"), note: "Review unused apps in Applications; app data may remain elsewhere.")]
                return SystemDataScanner.measureAll(specs) { SystemDataScanner.measure(name: $0.name, url: $0.url, note: $0.note) }
            }
            refreshCapacity()
            phase = "Preparing cleanup recommendations…"
            // Policy checks stat every item, so they run with the scan instead of on the main thread.
            let found = await BackgroundWork.run(qos: .utility) {
                DiskScanService.scan().map { outcome in
                    (outcome, outcome.items.compactMap { OptimizePolicy.candidate($0) }.sorted { $0.item.size > $1.item.size })
                }
            }
            switch found {
            case .success(let (outcome, suggested)):
                candidates = suggested
                reviewCount = outcome.items.filter { !OptimizePolicy.categories.contains($0.category) && $0.category != .trash }.count
                recommendationWarning = outcome.warning
                phase = outcome.incomplete.isEmpty ? "Review your optimization plan" : "Review your optimization plan · some locations were not read"
            case .failure(let failure):
                recommendationWarning = failure.message
                recommendationsUnavailable = true
                phase = "Scan incomplete — review access or try again"
            }
            busy = false
        }
    }

    static func coverageText(_ report: DiskMapReport) -> String {
        guard let check = report.reconciliation else {
            return "Measured the startup data volume. External drives are not included."
        }
        var text = "Found \(check.found.formattedBytes) of the \(check.dataUsed.formattedBytes) used on the startup data volume "
            + "(\(Int((check.coverage * 100).rounded(.down)))%). "
        if check.unexplained > 0 { text += "\(check.unexplained.formattedBytes) is in folders Mac Polish could not read, snapshots or file system overhead. " }
        return text + "External drives are not included. See Storage Map for details."
    }

    func execute() {
        guard !busy, !completed, hasActions else { return }
        let plan = candidates.filter(\.selected)
        let docker = includeDocker && dockerAvailable
        refreshCapacity()
        let beforeFree = freeBytes
        busy = true
        running = true
        confirm = false
        phase = "Moving reviewed cache and log files to Trash…"
        Task {
            let outcome = await BackgroundWork.run(qos: .utility) { () -> (messages: [String], issues: [CleanupIssue], removedIDs: Set<UUID>, movedBytes: Int64) in
                var messages: [String] = []
                var safe: [ScanItem] = []
                for candidate in plan {
                    guard OptimizePolicy.unchanged(candidate) else {
                        messages.append("Skipped changed or missing item: " + candidate.item.url.path)
                        continue
                    }
                    var item = candidate.item
                    item.isSelected = true
                    safe.append(item)
                }
                let result = SafeCleaner().clean(safe)
                messages.insert("Moved \(result.removedCount) items (\(result.reclaimedBytes.formattedBytes)) to Trash. Space is released after Trash is emptied.", at: 0)
                if !result.issues.isEmpty { messages.append(CleanupIssue.summary(result.issues)) }
                return (messages, result.issues, result.removedItemIDs, result.reclaimedBytes)
            }
            results = outcome.messages
            cleanupIssues = outcome.issues
            onOutcome?(CleanupOutcome(date: Date(), movedCount: outcome.removedIDs.count, movedBytes: outcome.movedBytes, issues: outcome.issues))
            if docker {
                phase = "Cleaning Docker build cache…"
                let message = await BackgroundWork.run(qos: .utility) {
                    SystemDataScanner.cleanDockerBuildCache()
                }
                results.append(message)
            }
            phase = "Updating storage measurements…"
            // Keep recovery responsive instead of waiting for another full scan after access failures.
            if cleanupIssues.isEmpty || docker {
                report = await BackgroundWork.run(qos: .utility) { SystemDataScanner().scan() }
            }
            refreshCapacity()
            if let beforeFree, let afterFree = freeBytes {
                let delta = afterFree - beforeFree
                results.append("Available space now: \(afterFree.formattedBytes). Observed change: \(delta >= 0 ? "+" : "−")\(abs(delta).formattedBytes). Other apps and macOS can affect this measurement.")
            }
            candidates.removeAll { outcome.removedIDs.contains($0.id) }
            includeDocker = false
            reviewAreas = []
            diskAreas = []
            completed = candidates.isEmpty
            phase = cleanupIssues.isEmpty ? "Optimization finished — review the results below" : "Some items need your review before retrying"
            running = false
            busy = false
        }
    }
}

struct OptimizeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var optimizer: OptimizerModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Optimize", systemImage: "wand.and.stars").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(optimizer.phase).foregroundStyle(.secondary)
                }
                Spacer()
                if optimizer.busy { ProgressView().controlSize(.small) }
                Button("Scan My Mac") { optimizer.scan() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(optimizer.busy)
            }.padding(30)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Scan → Review → Optimize")
                        .font(.headline).foregroundStyle(.teal)
                    Text("Analyze disk usage, system data, developer files and personal-file sizes. Cleanup suggestions focus on older caches and logs. Close the apps whose cache you choose before optimizing.")
                        .foregroundStyle(.secondary)
                    if let free = optimizer.freeBytes, let total = optimizer.totalBytes {
                        Label("\(free.formattedBytes) available · \(total.formattedBytes) capacity", systemImage: "internaldrive")
                            .font(.title3.bold())
                        Text("Current filesystem free space. Folder sizes are not a promise of space reclaimed; APFS snapshots and shared blocks can affect the result.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !optimizer.busy && !optimizer.reviewAreas.isEmpty {
                        Text("Review large locations").font(.title3.bold())
                        Text("These locations are not selected for automatic cleanup.").font(.caption).foregroundStyle(.secondary)
                        ForEach(optimizer.reviewAreas) { area in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(area.name).font(.headline)
                                    Text(area.note).font(.caption)
                                    Text(area.diagnostic).font(.caption).foregroundStyle(area.partial ? .orange : .secondary)
                                }
                                Spacer()
                                Text(area.bytes?.formattedBytes ?? "—").monospacedDigit()
                                Button("Review in Finder") { NSWorkspace.shared.open(area.url) }
                            }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if let warning = optimizer.recommendationWarning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        Button("Review Scan Permissions…") { model.access.presented = true }
                    }
                    if !optimizer.coverage.isEmpty {
                        Label(optimizer.coverage, systemImage: "info.circle").font(.caption)
                    }
                    if !optimizer.diskAreas.isEmpty {
                        DisclosureGroup("Disk usage · whole startup disk") {
                            ForEach(optimizer.diskAreas) { area in
                                HStack {
                                    Text(area.url.lastPathComponent)
                                    Spacer()
                                    Text(area.bytes.formattedBytes).monospacedDigit()
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if !optimizer.results.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Results").font(.title3.bold())
                            if optimizer.cleanupIssues.contains(where: \.needsAccess) {
                                Button("Review Permissions…") {
                                    model.operationIssues = optimizer.cleanupIssues
                                    model.reviewCleanupPermissions()
                                }
                            }
                            ForEach(Array(optimizer.results.enumerated()), id: \.offset) { _, message in
                                Text(message).font(.callout).textSelection(.enabled)
                            }
                        }.padding(20).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if optimizer.report != nil && !optimizer.completed && !optimizer.busy {
                        HStack {
                            Text("Suggested cleanup").font(.title3.bold())
                            Spacer()
                            Text("\(optimizer.selectedBytes.formattedBytes) selected").foregroundStyle(.secondary)
                        }
                        if optimizer.candidates.isEmpty {
                            Text(optimizer.recommendationsUnavailable
                                 ? "Cleanup recommendations are unavailable for this scan. Review access and try again."
                                 : "No eligible older caches or logs were found in the locations that could be read. This is not a complete bill of health; review scan coverage and large locations.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach($optimizer.candidates) { $candidate in
                            HStack(spacing: 14) {
                                Toggle("", isOn: $candidate.selected).labelsHidden()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.item.displayName).font(.headline)
                                    Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                                    Text(candidate.item.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Text(candidate.item.size.formattedBytes).monospacedDigit()
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([candidate.item.url]) }
                            }
                            .padding(15).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let report = optimizer.report {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Also clean Docker build cache", isOn: $optimizer.includeDocker)
                                    .disabled(!optimizer.dockerAvailable)
                                Text("Optional · permanent cache removal, not Trash. Docker volumes are not targeted. Future builds may take longer.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    Text(report.dockerOutput).font(.system(size: 11, design: .monospaced))
                                }
                            }.padding(18).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text("\(optimizer.reviewCount) other file candidates require individual review in Large Files, Developer Cleanup or Old Files. Apps, backups, project dependencies and system databases are not part of this automatic cleanup.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 25)
                .disabled(optimizer.busy)
            }
            HStack {
                Text(optimizer.running ? "Optimization in progress…" : "\(optimizer.selectedCount) files selected" + (optimizer.includeDocker ? " + Docker build cache" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Optimize Now") { optimizer.confirm = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(optimizer.busy || optimizer.completed || !optimizer.hasActions)
            }.padding(20).background(.bar)
        }
        .alert("Run this optimization plan?", isPresented: $optimizer.confirm) {
            Button("Cancel", role: .cancel) {}
            Button("Optimize Now", role: .destructive) { optimizer.execute() }
        } message: {
            Text("Move \(optimizer.selectedCount) reviewed files (\(optimizer.selectedBytes.formattedBytes)) to Trash."
                 + (optimizer.includeDocker ? " Permanently remove Docker Desktop build cache as well." : "")
                 + " Close affected apps first. Changed or missing file paths will be skipped.")
        }
    }
}
