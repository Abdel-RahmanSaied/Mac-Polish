import AppKit
import SwiftUI

/// Regenerable folders inside the user's projects, and read-only global toolchain caches.
/// Every filesystem read and move runs in `ProjectArtifactsModel` off the main thread.
struct ProjectArtifactsView: View {
    @ObservedObject var model: ProjectArtifactsModel
    /// Opens the app's scan-permission review; the button is hidden when nil.
    var onReviewPermissions: (() -> Void)? = nil
    @ViewState private var order: Order = .size
    @ViewState private var confirmation: CleanupConfirmation?

    enum Order: String, CaseIterable, Identifiable {
        case size = "Size", activity = "Last activity", project = "Project"
        var id: String { rawValue }
    }

    private var sortedArtifacts: [ProjectArtifact] {
        switch order {
        case .size: model.artifacts
        case .activity: model.artifacts.sorted {
            ($0.projectLastActivity ?? .distantFuture) < ($1.projectLastActivity ?? .distantFuture)
        }
        case .project: model.artifacts.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = model.warning, model.state == .ready {
                HStack(spacing: 10) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let onReviewPermissions {
                        Button("Review Scan Permissions…", action: onReviewPermissions)
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 12)
            }
            if let message = model.cleanupMessage {
                HStack(alignment: .top, spacing: 10) {
                    Label(message, systemImage: "trash")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.cleanupMessage = nil }.buttonStyle(.borderless)
                }
                .padding(12)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 30).padding(.bottom, 12)
            }
            content
        }
        .task { model.scan() }
        .cleanupConfirmation($confirmation, onConfirm: { _ in model.cleanSelected() })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Project Artifacts")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Build and dependency folders in your code projects that their tools can recreate.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            if model.state == .loading {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(model.state == .idle ? "Scan" : "Scan Again") { model.scan(force: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
        }
        .padding(30)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView {
                Label("Find project build folders", systemImage: "shippingbox")
            } description: {
                Text("Looks through your home folder for folders such as node_modules next to package.json or target next to Cargo.toml. Library, hidden folders and app bundles are skipped. Nothing is selected or moved until you choose.")
            } actions: {
                Button("Scan") { model.scan(force: true) }.buttonStyle(.borderedProminent)
            }
        case .loading where model.artifacts.isEmpty:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Looking for project folders…").font(.headline)
                Text("Library, hidden folders and app bundles are skipped. Large dependency folders take a moment to measure.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cancelled where model.artifacts.isEmpty:
            ModuleStateView(presentation: .cancelled, subject: "Project artifacts", start: { model.scan(force: true) })
        case .failed(let message) where model.artifacts.isEmpty:
            VStack(spacing: 15) {
                ContentUnavailableView("Scan incomplete", systemImage: "exclamationmark.triangle", description: Text(message))
                HStack {
                    if let onReviewPermissions { Button("Review Scan Permissions…", action: onReviewPermissions) }
                    Button("Scan Again") { model.scan(force: true) }.buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 24)
            }
        default:
            // Earlier results stay visible after a later scan fails, is cancelled or is still running.
            ModuleNotice(presentation: .of(model.state, hasResults: true))
            results
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Sort by", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
                Button("Select inactive 90+ days (regenerable only)") { model.selectInactive(days: 90) }
                    .help("Selects folders whose project and content have not changed for 90 days. This is a guess from dates, not proof that a project is unused; review the selection.")
                Button("Select none") { model.selectNone() }
            }
            .disabled(model.busy || model.artifacts.isEmpty)
            .padding(.horizontal, 30).padding(.bottom, 10)

            List {
                Section {
                    if model.artifacts.isEmpty {
                        Text("No project artifacts of 1 MB or more were found in the folders that could be read. A folder is only recognized next to its project file, such as node_modules next to package.json.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(sortedArtifacts) { artifact in
                        ArtifactRow(artifact: artifact, isOn: binding(for: artifact))
                    }
                } header: {
                    HStack {
                        Text("Project artifacts")
                        Spacer()
                        Text("\(model.artifacts.count) found · \(model.artifacts.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)")
                    }
                }
                Section {
                    if model.toolchainLoading && model.toolchainCaches.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Measuring toolchain caches…").font(.caption)
                        }
                    } else if model.toolchainCaches.isEmpty {
                        Text("No known toolchain caches were found.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.toolchainCaches) { area in
                        ToolchainCacheRow(area: area, spec: model.spec(for: area))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Toolchain caches")
                        Text("Read-only. Mac Polish does not remove these; use each tool's own command so its index stays consistent.")
                            .font(.caption).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            .listStyle(.inset)
            .disabled(model.cleaning)

            HStack {
                Text(model.cleaning ? "Moving folders to Trash…" : "\(model.selectedCount) selected · \(model.selectedBytes.formattedBytes)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move Selected to Trash…", role: .destructive) {
                    confirmation = model.busy ? nil : .forProjectArtifacts(model.selected)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.selectedCount == 0 || model.busy)
            }
            .padding(20)
            .background(.bar)
        }
    }

    private func binding(for artifact: ProjectArtifact) -> Binding<Bool> {
        Binding(
            get: { model.artifacts.first(where: { $0.id == artifact.id })?.isSelected ?? false },
            set: { model.setSelection($0, id: artifact.id) }
        )
    }
}

private struct ArtifactRow: View {
    let artifact: ProjectArtifact
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!artifact.isMeasurementComplete)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(artifact.kind.displayName).font(.headline)
                    Text(artifact.kind.ecosystem)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Text((artifact.projectURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(artifact.url.path)
                HStack(spacing: 4) {
                    Text("Last project activity:")
                    if let activity = artifact.projectLastActivity {
                        Text(activity.formatted(.relative(presentation: .named)))
                    } else {
                        Text("unknown")
                    }
                    Text("· Recreate with \(artifact.kind.regenerateHint)")
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !artifact.kind.isSafelyRegenerable {
                    Label("Not safely regenerable: it may contain packages installed by hand. Check before moving it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !artifact.isMeasurementComplete {
                    Label("Some folders inside could not be read, so the size is partial and it cannot be moved.",
                          systemImage: "lock")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(artifact.size.formattedBytes)
                .font(.system(.body, design: .monospaced))
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct ToolchainCacheRow: View {
    let area: SystemDataArea
    let spec: ToolchainCacheSpec?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(area.name).font(.headline)
                Spacer()
                if area.partial {
                    Text(area.bytes == nil ? "Unavailable" : "Partial").font(.caption).foregroundStyle(.orange)
                }
                Text(area.bytes?.formattedBytes ?? "—").font(.system(.body, design: .monospaced))
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([area.url]) }
                    .buttonStyle(.borderless)
            }
            Text((area.url.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let command = spec?.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(area.note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if area.partial {
                Text(area.diagnostic).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
