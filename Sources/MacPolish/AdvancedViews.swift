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
            Text("The selected apps and detected user-library leftovers will be moved to Trash. System apps are protected.")
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
                        .disabled(!application.canRemove)
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
    private let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .green, .indigo]

    var body: some View {
        VStack(spacing: 0) {
            moduleHeader(
                title: "Storage Map",
                subtitle: "Understand which areas of your home folder use the most space.",
                buttonTitle: "Analyze Again",
                isBusy: model.storageState == .loading,
                action: { model.analyzeStorage(force: true) }
            )

            if case .failed(let message) = model.storageState {
            ScanFailureView(message: message)
        } else if model.storageState == .loading && model.storageEntries.isEmpty {
                LoadingView(title: "Measuring folders…")
            } else if model.storageEntries.isEmpty {
                ContentUnavailableView("No storage data", systemImage: "chart.pie", description: Text("Start an analysis to map your storage."))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(model.storageEntries.enumerated()), id: \.element.id) { index, entry in
                            StorageBar(entry: entry, maximum: model.storageEntries.first?.size ?? 1, color: colors[index % colors.count])
                        }
                    }
                    .padding(30)
                }
            }
        }
        .task { model.analyzeStorage() }
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

private struct StorageBar: View {
    let entry: StorageEntry
    let maximum: Int64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(entry.name, systemImage: icon)
                    .font(.headline)
                Spacer()
                Text(entry.size.formattedBytes)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, proxy.size.width * CGFloat(Double(entry.size) / Double(max(1, maximum)))))
                }
            }
            .frame(height: 16)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }

    private var icon: String {
        switch entry.name {
        case "Downloads": "arrow.down.circle"
        case "Documents": "doc"
        case "Desktop": "menubar.dock.rectangle"
        case "Pictures": "photo"
        case "Movies": "film"
        case "Music": "music.note"
        case "Library": "books.vertical"
        default: "folder"
        }
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
