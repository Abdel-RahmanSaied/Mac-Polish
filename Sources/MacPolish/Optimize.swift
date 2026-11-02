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
    static let categories: Set<ScanCategory> = [.cache, .logs, .derivedData, .xcodeCache, .simulatorCache, .diagnostics]

    static func candidate(_ item: ScanItem, now: Date = Date()) -> OptimizeCandidate? {
        guard categories.contains(item.category), item.size > 0 else { return nil }
        let excluded = ["go-build", "gomodcache", "node_modules", "org.swift.swiftpm", "codex", "docker"]
        guard !excluded.contains(where: { item.url.path.lowercased().contains($0) }),
              item.url.standardizedFileURL == item.url.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > 7 * 86400 else { return nil }
        return OptimizeCandidate(item: item,
                                 reason: "Cache or log; last modified more than 7 days ago. Apps may recreate it.",
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
    @Published var coverage = ""
    @Published var reviewCount = 0
    @Published var includeDocker = false
    @Published var confirm = false
    @Published var results: [String] = []
    @Published var completed = false
    var selectedBytes: Int64 { candidates.filter(\.selected).reduce(0) { $0 + $1.item.size } }
    var selectedCount: Int { candidates.filter(\.selected).count }
    var hasActions: Bool { selectedCount > 0 || includeDocker }
    var dockerAvailable: Bool { report?.dockerOutput.contains("Build Cache") == true }

    func scan() {
        guard !busy else { return }
        busy = true
        completed = false
        results = []
        candidates = []
        includeDocker = false
        phase = "Inspecting accessible folders across the Mac…"
        Task {
            let disk = await Task.detached(priority: .utility) {
                SystemDataScanner.run("/usr/bin/du", ["-x", "-k", "-d", "1", "/System/Volumes/Data"], timeout: 90)
            }.value
            diskAreas = SystemDataScanner.parseDU(disk.output)
                .filter { $0.url.path != "/System/Volumes/Data" }
                .sorted { $0.bytes > $1.bytes }
            coverage = disk.status == 0
                ? "Measured the accessible startup data volume. External drives are not included."
                : "Partial disk scan: macOS protected some folders or the scan reached its time limit. External drives are not included."
            phase = "Analyzing system data, developer storage and Docker…"
            report = await Task.detached(priority: .utility) { SystemDataScanner().scan() }.value
            phase = "Preparing cleanup recommendations…"
            let found = await Task.detached(priority: .utility) { DiskScanner().scan() }.value
            candidates = found.compactMap { OptimizePolicy.candidate($0) }
                .sorted { $0.item.size > $1.item.size }
            reviewCount = found.filter { !OptimizePolicy.categories.contains($0.category) && $0.category != .trash }.count
            phase = "Review your optimization plan"
            busy = false
        }
    }

    func execute() {
        guard !busy, !completed, hasActions else { return }
        let plan = candidates.filter(\.selected)
        let docker = includeDocker
        busy = true
        running = true
        confirm = false
        phase = "Moving reviewed cache and log files to Trash…"
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> [String] in
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
                messages += result.failures
                return messages
            }.value
            results = outcome
            if docker {
                phase = "Cleaning Docker build cache…"
                let message = await Task.detached(priority: .utility) {
                    SystemDataScanner.cleanDockerBuildCache()
                }.value
                results.append(message)
            }
            phase = "Updating storage measurements…"
            report = await Task.detached(priority: .utility) { SystemDataScanner().scan() }.value
            candidates = []
            includeDocker = false
            completed = true
            phase = "Optimization finished — review the results below"
            running = false
            busy = false
        }
    }
}

struct OptimizeView: View {
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
                    if !optimizer.coverage.isEmpty {
                        Label(optimizer.coverage, systemImage: "info.circle").font(.caption)
                    }
                    if !optimizer.diskAreas.isEmpty {
                        DisclosureGroup("Disk usage · accessible folders") {
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
                            ForEach(Array(optimizer.results.enumerated()), id: \.offset) { _, message in
                                Text(message).font(.callout).textSelection(.enabled)
                            }
                        }.padding(20).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if optimizer.report != nil && !optimizer.completed {
                        HStack {
                            Text("Suggested cleanup").font(.title3.bold())
                            Spacer()
                            Text("\(optimizer.selectedBytes.formattedBytes) selected").foregroundStyle(.secondary)
                        }
                        if optimizer.candidates.isEmpty {
                            Text("No older cache or log candidates found. Review System Data for other large locations.")
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
