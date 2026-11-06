import AppKit
import SwiftUI

struct ApplicationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Applications",
                subtitle: "Inspect application size, versions, and related leftover files.",
                buttonTitle: "Refresh",
                isBusy: model.applicationState == .loading,
                onCancel: { model.cancelApplications() },
                action: { model.loadApplications(force: true) }
            )

            moduleContent
        }
        .searchable(text: $model.applicationSearchText, placement: .toolbar, prompt: "Search applications")
        .task { model.loadApplications() }
        .cleanupConfirmation($model.applicationConfirmation, onConfirm: { _ in model.removeSelectedApplications() })
    }

    @ViewBuilder
    private var moduleContent: some View {
        let presentation = ModulePresentation.of(model.applicationState, hasResults: !model.applications.isEmpty)
        if !presentation.showsResults {
            ModuleStateView(presentation: presentation, subject: "Applications", loadingTitle: "Inspecting installed applications…",
                            emptyTitle: "No applications found", emptyDetail: "No apps were found in the Applications folders.",
                            start: { model.loadApplications(force: true) }, onReviewPermissions: { model.access.presented = true })
        } else if filteredApplications.isEmpty {
            ModuleNotice(presentation: presentation)
            ContentUnavailableView("No applications found", systemImage: "square.grid.2x2", description: Text("Try refreshing the application scan."))
        } else {
            ModuleNotice(presentation: presentation)
            List(filteredApplications) { application in
                HStack(spacing: 14) {
                    Toggle("", isOn: selectionBinding(for: application))
                        .labelsHidden()
                        .disabled(!application.canRemove || application.removalNote != nil)
                    Image(nsImage: AppIconCache.icon(for: application.url))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(application.name).font(.headline)
                            if !application.canRemove {
                                Label("Protected", systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if application.removalNote != nil {
                                Label("Needs an administrator", systemImage: "person.badge.key")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text([application.version.map { "Version \($0)" }, application.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ApplicationInsightSlot(model: model.appInsights, url: application.url)
                        if !application.leftoverURLs.isEmpty {
                            Text("\(application.leftoverURLs.count) related item(s) · \(application.leftoverSize.formattedBytes)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let note = application.removalNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(application.totalSize.formattedBytes)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                }
                .padding(.vertical, 6)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([application.url]) }
                }
            }
            .listStyle(.inset)
            .disabled(model.applicationState == .loading)

            HStack {
                Text("\(model.applications.count) apps · \(selectedApplications.count) selected (\(model.selectedApplicationsSize.formattedBytes))"
                     + (hiddenSelectionCount > 0 ? " · \(hiddenSelectionCount) hidden by search" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Uninstall Selected…", role: .destructive) {
                    model.applicationConfirmation = .forApplications(selectedApplications, hiddenBySearch: hiddenSelectionCount)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.applications.contains(where: \.isSelected) || model.applicationState == .loading)
            }
            .padding(20)
            .background(.bar)
        }
    }

    private var filteredApplications: [ApplicationItem] {
        guard !model.applicationSearchText.isEmpty else { return model.applications }
        return model.applications.filter {
            $0.name.localizedCaseInsensitiveContains(model.applicationSearchText)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(model.applicationSearchText) ?? false)
        }
    }

    private var selectedApplications: [ApplicationItem] { model.applications.filter(\.isSelected) }

    private var hiddenSelectionCount: Int {
        let visible = Set(filteredApplications.map(\.id))
        return selectedApplications.filter { !visible.contains($0.id) }.count
    }

    /// The row value comes from the current model list, so reading it is O(1) instead of searching per row.
    private func selectionBinding(for application: ApplicationItem) -> Binding<Bool> {
        Binding(
            get: { application.isSelected },
            set: { model.setApplicationSelection($0, id: application.id) }
        )
    }
}

/// App icons are decoded once per path rather than on every list update.
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}

/// A module that has not run yet (for example while scan permissions are being reviewed) is not "empty".
struct NotScannedView: View {
    let subject: String
    let start: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("\(subject) not scanned yet", systemImage: "magnifyingglass",
                                   description: Text("The scan starts after scan permissions are reviewed, or when you start it."))
            Button("Start Scan", action: start).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DuplicatesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Duplicate Finder",
                subtitle: "Byte-accurate SHA-256 matching across personal folders.",
                buttonTitle: "Scan Again",
                isBusy: model.duplicateState == .loading,
                onCancel: { model.cancelDuplicates() },
                action: { model.findDuplicates(force: true) }
            )

            if let warning = model.duplicateWarning, model.duplicateState == .ready {
                HStack(spacing: 10) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Review Scan Permissions…") { model.access.presented = true }
                }
                .padding(.horizontal, 30).padding(.bottom, 12)
            }

            let presentation = ModulePresentation.of(model.duplicateState, hasResults: !model.duplicateGroups.isEmpty)
            if !presentation.showsResults {
                ModuleStateView(presentation: presentation, subject: "Duplicates", loadingTitle: "Hashing possible duplicates…",
                                emptyTitle: "No duplicates found", emptyDetail: "Files smaller than 1 MB are skipped.",
                                start: { model.findDuplicates(force: true) }, onReviewPermissions: { model.access.presented = true })
            } else {
                ModuleNotice(presentation: presentation)
                List {
                    ForEach(model.duplicateGroups) { group in
                        Section {
                            ForEach(group.files) { file in
                                HStack(spacing: 12) {
                                    Toggle("", isOn: duplicateBinding(for: file))
                                        .labelsHidden()
                                    Image(systemName: "doc")
                                        .foregroundStyle(.purple)
                                        .frame(width: 30, height: 30)
                                        .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.url.lastPathComponent).lineLimit(1)
                                        Text(file.url.deletingLastPathComponent().path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(file.size.formattedBytes)
                                        .font(.system(.body, design: .monospaced))
                                }
                                .padding(.vertical, 4)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(group.files.count) identical files")
                                Spacer()
                                Text("\(group.reclaimableSize.formattedBytes) estimated on disk")
                                Button("Select extras") { selectExtras(in: group) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .disabled(model.duplicateState == .loading)

                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc").foregroundStyle(.purple)
                    Text("Keep one copy of each file. Remove all extra copies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All Duplicates", role: .destructive) {
                        model.prepareAllDuplicateRemoval()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.duplicateState == .loading || model.duplicateGroups.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.purple.opacity(0.06))

                HStack {
                    Text("\(model.duplicateRemovalPlan.count) to move · \(model.selectedDuplicateSize.formattedBytes)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Move Selected to Trash…", role: .destructive) { model.requestDuplicateRemoval() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.duplicateRemovalPlan.isEmpty || model.duplicateState == .loading)
                }
                .padding(20)
                .background(.bar)
            }
        }
        .task { model.findDuplicates() }
        .cleanupConfirmation($model.duplicateConfirmation, onConfirm: { _ in model.removeSelectedDuplicates() },
                             onCancel: { model.cancelDuplicateRemoval() })
    }

    private func duplicateBinding(for file: DuplicateFile) -> Binding<Bool> {
        Binding(
            get: { file.isSelected },
            set: { model.setDuplicateSelection($0, id: file.id) }
        )
    }

    private func selectExtras(in group: DuplicateGroup) {
        let keeper = group.files.first?.id   // groups are sorted by path
        for file in group.files { model.setDuplicateSelection(file.id != keeper, id: file.id) }
    }
}

struct StorageMapView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var path: [String] = []
    @ViewState private var inspection: FolderInspectionTarget?

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Storage Map",
                subtitle: "Every readable file on the startup disk, hidden files, app contents and the sealed macOS volume included.",
                buttonTitle: model.storageState == .loading ? "Analyzing…" : "Analyze Again",
                isBusy: model.storageState == .loading,
                onCancel: { model.cancelStorage() },
                action: { path = []; model.analyzeStorage(force: true) }
            )
            HStack {
                Button("Choose Disk or Folder…") {
                    guard model.access.authorizeScan() else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Inspect"
                    panel.message = "Choose a mounted disk or folder to inspect. This only reads files."
                    if panel.runModal() == .OK, let url = panel.url {
                        inspection = FolderInspectionTarget(url: url.resolvingSymlinksInPath())
                    }
                }
                Button("Review Scan Permissions…") {
                    model.access.step = .diskAccess
                    model.access.presented = true
                }
                Spacer()
            }.padding(.horizontal, 30).padding(.bottom, 12)
            if model.storageState == .loading, model.diskMap != nil, let started = model.storageStarted {
                ScanElapsedView(started: started).padding(.bottom, 8)
            }
            if case .failed(let message) = model.storageState, model.diskMap == nil {
                ScanFailureView(message: message)
            } else if model.storageState == .cancelled, model.diskMap == nil {
                ModuleStateView(presentation: .cancelled, subject: "Storage Map", start: { model.analyzeStorage(force: true) })
            } else if let report = model.diskMap {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if case .failed(let message) = model.storageState {
                            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        } else if model.storageState == .cancelled {
                            Label("The latest analysis was cancelled. This map is from the previous analysis.", systemImage: "stop.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        DiskSummaryCard(report: report)
                        DiskInsightsPanel(report: report)
                        DiskBrowser(root: report.tree.root, path: $path)
                    }
                    .padding(.horizontal, 30).padding(.bottom, 30)
                }
            } else if model.storageState == .loading {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Reading every folder on the startup disk…").font(.headline)
                    if let started = model.storageStarted { ScanElapsedView(started: started) }
                    Text("Folders protected by macOS are read separately. macOS may ask about Desktop, Documents and Downloads; other apps' data needs Full Disk Access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No storage data", systemImage: "chart.pie", description: Text("Start an analysis to map your storage."))
            }
        }
        .task { model.analyzeStorage() }
        .sheet(item: $inspection) { FolderInspectionView(start: $0.url) }
    }
}

private struct ScanElapsedView: View {
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Scanning · \(Int(context.date.timeIntervalSince(started)))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The whole container at a glance and how much of the used space the scan explains.
private struct DiskSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    let report: DiskMapReport

    private struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let volumes = report.volumes {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(volumes.used.formattedBytes) used of \(volumes.capacity.formattedBytes)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(volumes.free.formattedBytes) free").foregroundStyle(.secondary)
                }
                let segments = segments(volumes)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            Rectangle().fill(segment.color)
                                .frame(width: max(2, proxy.size.width * CGFloat(Double(segment.bytes) / Double(max(1, volumes.capacity)))))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                    .background(Capsule().fill(.green.opacity(0.18)))
                }
                .frame(height: 18)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        HStack(spacing: 8) {
                            Circle().fill(segment.color).frame(width: 9, height: 9)
                            Text(segment.id).font(.caption)
                            Text(segment.bytes.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Circle().fill(.green.opacity(0.35)).frame(width: 9, height: 9)
                        Text("Free").font(.caption)
                        Text(volumes.free.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let purgeable = volumes.purgeable, purgeable > 0 {
                    Text("\(purgeable.formattedBytes) of the used space is purgeable: macOS frees it automatically when space is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("The disk layout was not available, so the scan cannot be compared with macOS.").font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            if let check = report.reconciliation {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int((check.coverage * 100).rounded(.down)))%")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(check.meetsTarget ? .green : .orange)
                    Text("of the data volume explained · found \(check.found.formattedBytes) of \(check.dataUsed.formattedBytes)")
                        .font(.headline)
                }
                if check.unexplained > 0 {
                    Text(unexplainedText(check)).font(.callout).foregroundStyle(.secondary)
                }
                if check.uncertain > 0 {
                    Text("Up to \(check.uncertain.formattedBytes) may be counted in two places: copies that shared data on disk until one of them was changed (APFS clones).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if check.overcount > 0 {
                    Text("The folders add up to \(check.overcount.formattedBytes) more than macOS reports, because of the shared copies above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if report.tree.root.unreadable > 0 {
                    Button("Open Full Disk Access Settings…") { PrivacyPane.fullDiskAccess.open() }
                }
                if report.tree.root.notScanned > 0 {
                    Button("Review Scan Permissions…") { model.access.presented = true }
                }
                Spacer()
                Text(report.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func segments(_ volumes: VolumeUsage) -> [Segment] {
        let found = min(report.reconciliation?.found ?? 0, volumes.dataBytes ?? 0)
        let unexplained = max(0, (volumes.dataBytes ?? 0) - found)
        return [Segment(id: "Your files and apps", bytes: found, color: .blue),
                Segment(id: "Not explained", bytes: unexplained, color: .orange),
                Segment(id: "macOS", bytes: volumes.macOSBytes, color: .gray),
                Segment(id: "Virtual memory", bytes: volumes.virtualMemoryBytes, color: .purple),
                Segment(id: "Other volumes", bytes: max(0, volumes.otherBytes), color: .pink)]
            .filter { $0.bytes > 0 }
    }

    private func unexplainedText(_ check: StorageReconciliation) -> String {
        var reasons: [String] = []
        if check.unreadable > 0 { reasons.append("\(check.unreadable) folder\(check.unreadable == 1 ? "" : "s") macOS did not let Mac Polish read") }
        if check.notScanned > 0 { reasons.append("\(check.notScanned) folder\(check.notScanned == 1 ? "" : "s") not read in time") }
        if let snapshots = report.volumes?.snapshotCount, snapshots > 0 { reasons.append("\(snapshots) local snapshot\(snapshots == 1 ? "" : "s")") }
        reasons.append("file system overhead")
        return "\(check.unexplained.formattedBytes) is not explained by the folders below: " + reasons.joined(separator: ", ") + "."
    }
}

/// Folder-by-folder view of the map, largest first.
private struct DiskBrowser: View {
    @EnvironmentObject private var model: AppModel
    let root: DiskNode
    @Binding var path: [String]
    @ViewState private var inspection: FolderInspectionTarget?

    private var current: DiskNode {
        path.reduce(root) { node, name in node.children.first { $0.name == name && $0.kind == .folder } ?? node }
    }

    var body: some View {
        let folder = current
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button(root.name) { path = [] }.buttonStyle(.link)
                    ForEach(Array(path.enumerated()), id: \.offset) { index, name in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        Button(name) { path = Array(path.prefix(index + 1)) }.buttonStyle(.link)
                    }
                }
            }
            HStack {
                Text("\(folder.bytes.formattedBytes) · \(folder.files.formatted()) files").font(.headline)
                Spacer()
                if !path.isEmpty {
                    Button("Back") { path.removeLast() }
                }
                Button("Inspect every item…") {
                    guard model.access.authorizeScan() else { return }
                    inspection = FolderInspectionTarget(url: DiskMapService.revealURL(path))
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DiskMapService.revealURL(path)]) }
            }
            if folder.children.isEmpty {
                Text(folder.kind == .folder ? "No items large enough to list." : (folder.note ?? "Nothing to list."))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(folder.children, id: \.name) { child in
                DiskRow(node: child, parentBytes: folder.bytes,
                        open: { path.append(child.name) },
                        reveal: { NSWorkspace.shared.activateFileViewerSelecting([DiskMapService.revealURL(path + [child.name])]) })
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .sheet(item: $inspection) { FolderInspectionView(start: $0.url) }
    }
}

private struct DiskRow: View {
    let node: DiskNode
    let parentBytes: Int64
    let open: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if node.kind == .folder { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                GeometryReader { proxy in
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: max(2, proxy.size.width * CGFloat(Double(node.bytes) / Double(max(1, parentBytes)))))
                }
                .frame(height: 5)
            }
            Spacer(minLength: 12)
            Text(node.bytes.formattedBytes).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
            if node.kind == .file || node.kind == .folder {
                Button { reveal() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if node.kind == .folder { open() } }
        .contextMenu {
            if node.kind == .file || node.kind == .folder { Button("Show in Finder", action: reveal) }
        }
    }

    private var title: String {
        node.kind == .smallerItems ? "\(node.files.formatted()) smaller items" : node.name
    }

    private var detail: String? {
        switch node.kind {
        case .unreadable: "Needs Full Disk Access to measure"
        case .notScanned: node.note ?? "Not read in time"
        case .folder:
            node.unreadable > 0 ? "\(node.files.formatted()) files · \(node.unreadable) folder\(node.unreadable == 1 ? "" : "s") could not be read"
                : "\(node.files.formatted()) files"
        case .file, .smallerItems: nil
        }
    }

    private var icon: String {
        switch node.kind {
        case .folder: "folder.fill"
        case .file: "doc.fill"
        case .smallerItems: "ellipsis.circle"
        case .unreadable: "lock.fill"
        case .notScanned: "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .folder: .blue
        case .file: .cyan
        case .smallerItems: .gray
        case .unreadable, .notScanned: .orange
        }
    }
}

struct StartupItemsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Startup Items",
                subtitle: "Audit agents and daemons that can run in the background.",
                buttonTitle: "Refresh",
                isBusy: model.startupState == .loading,
                action: { model.loadStartupItems(force: true) }
            )

            if case .failed(let message) = model.startupState {
            ScanFailureView(message: message)
        } else if model.startupState == .loading && model.startupEntries.isEmpty {
                LoadingView(title: "Reading launch services…")
            } else if model.startupState == .idle {
                NotScannedView(subject: "Startup items") { model.loadStartupItems(force: true) }
            } else if model.startupEntries.isEmpty {
                ContentUnavailableView("No startup items found", systemImage: "bolt.circle", description: Text("No launch agents were detected in standard locations."))
            } else {
                List(model.startupEntries) { entry in
                    HStack(spacing: 14) {
                        Image(systemName: entry.requiresAdministrator ? "gearshape.2.fill" : "bolt.circle.fill")
                            .foregroundStyle(entry.requiresAdministrator ? .orange : .cyan)
                            .frame(width: 36, height: 36)
                            .background((entry.requiresAdministrator ? Color.orange : Color.cyan).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label).font(.headline)
                            Text(entry.program ?? entry.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if entry.runsAtLoad {
                            Text("Runs at login")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .task { model.loadStartupItems() }
    }
}

private struct LoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text("This can take a moment on large folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private func moduleHeader(title: String, subtitle: String, buttonTitle: String, isBusy: Bool = false,
                          onCancel: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .foregroundStyle(.secondary)
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


private struct ScanFailureView: View {
    @EnvironmentObject private var model: AppModel
    let message: String
    var body: some View {
        VStack(spacing: 15) {
            ContentUnavailableView("Scan incomplete", systemImage: "exclamationmark.triangle", description: Text(message))
            Button("Review Scan Permissions…") { model.access.presented = true }
                .buttonStyle(.borderedProminent).padding(.bottom, 24)
        }
    }
}


private struct FolderInspectionTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Lists every direct entry, including tiny and empty files, without retaining millions of nested rows.
private struct FolderInspectionView: View {
    let start: URL
    @Environment(\.dismiss) private var dismiss
    @ViewState private var current: URL?
    @ViewState private var result: DiskTreeResult?
    @ViewState private var failure: String?
    @ViewState private var loading = false
    @ViewState private var visibleCount = 200
    @ViewState private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Folder details", systemImage: "folder.badge.magnifyingglass").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text((current ?? start).path).font(.caption).textSelection(.enabled)
            HStack {
                Button("Up one folder") { load((current ?? start).deletingLastPathComponent()) }
                    .disabled(loading || (current ?? start).path == "/")
                Button("Refresh") { load(current ?? start) }.disabled(loading)
                Spacer()
                if loading { ProgressView().controlSize(.small); Text("Measuring…").font(.caption) }
            }
            Text("Includes hidden, small and empty entries. Folder sizes include descendants on this volume; symbolic links and other mounted volumes are not followed. Shared space is estimated.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let result {
                Text("\(result.root.bytes.formattedBytes) · \(result.root.files.formatted()) files in this tree").font(.headline)
                if result.incomplete || result.root.unreadable > 0 || result.missing {
                    Text("Incomplete coverage: \(result.root.unreadable) unreadable, \(result.root.notScanned) not scanned. Some locations may be missing or unavailable.")
                        .font(.callout).foregroundStyle(.orange)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.root.children.prefix(visibleCount).enumerated()), id: \.offset) { _, child in
                            DiskRow(node: child, parentBytes: result.root.bytes,
                                    open: { load((current ?? start).appendingPathComponent(child.name)) },
                                    reveal: { NSWorkspace.shared.activateFileViewerSelecting([(current ?? start).appendingPathComponent(child.name)]) })
                                .disabled(loading)
                        }
                        if result.root.children.count > visibleCount {
                            Button("Show next 200 items (\(result.root.children.count - visibleCount) remaining)") { visibleCount += 200 }
                        }
                        if result.root.children.isEmpty && !loading {
                            Text(result.root.unreadable > 0 || result.missing ? "This location could not be read." : "No readable entries found.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(result.unreadablePaths, id: \.self) { path in
                            Text("Could not read: " + path).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
            } else { Spacer() }
        }.padding(24).frame(width: 760, height: 600)
            .task { if current == nil { load(start) } }
            .onDisappear { requestID = UUID() }
    }

    private func load(_ url: URL) {
        let token = UUID()
        requestID = token
        current = url
        result = nil
        failure = nil
        visibleCount = 200
        loading = true
        Task {
            let answer = await BackgroundWork.run(qos: .userInitiated) {
                DiskMapService.workerReader(url.path, DiskTreeOptions.detail, 180)
            }
            guard token == requestID else { return }
            switch answer {
            case .success(let found): result = found
            case .failure(let error): failure = error.message
            }
            loading = false
        }
    }
}
