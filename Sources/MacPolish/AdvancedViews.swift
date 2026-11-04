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
                action: { model.loadApplications(force: true) }
            )

            moduleContent
        }
        .searchable(text: $model.applicationSearchText, placement: .toolbar, prompt: "Search applications")
        .task { model.loadApplications() }
        .alert("Uninstall selected applications?", isPresented: $model.confirmsApplicationRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeSelectedApplications() }
        } message: {
            Text("The selected apps and detected user-library leftovers will be moved to Trash. System apps are protected. Apps marked as needing an administrator can be removed in Finder.")
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        if case .failed(let message) = model.applicationState {
            ScanFailureView(message: message)
        } else if model.applicationState == .loading && model.applications.isEmpty {
            LoadingView(title: "Inspecting installed applications…")
        } else if filteredApplications.isEmpty {
            ContentUnavailableView("No applications found", systemImage: "square.grid.2x2", description: Text("Try refreshing the application scan."))
        } else {
            List(filteredApplications) { application in
                HStack(spacing: 14) {
                    Toggle("", isOn: selectionBinding(for: application))
                        .labelsHidden()
                        .disabled(!application.canRemove || application.removalNote != nil)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
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
                Text("\(model.applications.count) apps · \(model.selectedApplicationsSize.formattedBytes) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Uninstall Selected", role: .destructive) { model.confirmsApplicationRemoval = true }
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

    private func selectionBinding(for application: ApplicationItem) -> Binding<Bool> {
        Binding(
            get: { model.applications.first(where: { $0.id == application.id })?.isSelected ?? false },
            set: { model.setApplicationSelection($0, id: application.id) }
        )
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

            if case .failed(let message) = model.duplicateState {
            ScanFailureView(message: message)
        } else if model.duplicateState == .loading && model.duplicateFiles.isEmpty {
                LoadingView(title: "Hashing possible duplicates…")
            } else if model.duplicateGroups.isEmpty {
                ContentUnavailableView("No duplicates found", systemImage: "doc.on.doc", description: Text("Files smaller than 1 MB are skipped."))
            } else {
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
                                Text("Up to \(group.reclaimableSize.formattedBytes) reclaimable")
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
                    Text("\(model.duplicateFiles.filter(\.isSelected).count) selected · \(model.selectedDuplicateSize.formattedBytes)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Move Selected to Trash", role: .destructive) { model.confirmsDuplicateRemoval = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!model.duplicateFiles.contains(where: \.isSelected) || model.duplicateState == .loading)
                }
                .padding(20)
                .background(.bar)
            }
        }
        .task { model.findDuplicates() }
        .alert("Remove selected duplicates?", isPresented: $model.confirmsDuplicateRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeSelectedDuplicates() }
        } message: {
            Text("\(model.duplicateFiles.filter(\.isSelected).count) selected files (\(model.selectedDuplicateSize.formattedBytes)) will be moved to Trash. At least one copy per group is kept. Remove All keeps the first path alphabetically; cancel to review or change the selection.")
        }
    }

    private func duplicateBinding(for file: DuplicateFile) -> Binding<Bool> {
        Binding(
            get: { model.duplicateFiles.first(where: { $0.id == file.id })?.isSelected ?? false },
            set: { model.setDuplicateSelection($0, id: file.id) }
        )
    }

    private func selectExtras(in group: DuplicateGroup) {
        let keeper = group.files.sorted { $0.url.path < $1.url.path }.first?.id
        for file in group.files { model.setDuplicateSelection(file.id != keeper, id: file.id) }
    }
}

struct StorageMapView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Storage Map",
                subtitle: "Everything on your startup disk, measured the way APFS stores it.",
                buttonTitle: model.storageState == .loading ? "Analyzing…" : "Analyze Again",
                isBusy: model.storageState == .loading,
                action: { path = []; model.analyzeStorage(force: true) }
            )
            if model.storageState == .loading, model.diskMap != nil, let started = model.storageStarted {
                ScanElapsedView(started: started).padding(.bottom, 8)
            }
            if case .failed(let message) = model.storageState, model.diskMap == nil {
                ScanFailureView(message: message)
            } else if let report = model.diskMap {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if case .failed(let message) = model.storageState {
                            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        DiskSummaryCard(report: report)
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
    let root: DiskNode
    @Binding var path: [String]

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
private func moduleHeader(title: String, subtitle: String, buttonTitle: String, isBusy: Bool = false, action: @escaping () -> Void) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button(buttonTitle, action: action)
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
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
