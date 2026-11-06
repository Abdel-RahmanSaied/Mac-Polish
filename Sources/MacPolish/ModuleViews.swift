import SwiftUI

/// The page body for every state that has no result rows to show: not scanned, first scan running, nothing found,
/// failed, or cancelled. One component, so every scanner page says the same thing in the same situation.
struct ModuleStateView: View {
    let presentation: ModulePresentation
    /// What the page scans, for example "Duplicates".
    let subject: String
    var loadingTitle = "Scanning…"
    var emptyTitle = "Nothing found"
    var emptyDetail = ""
    let start: () -> Void
    var onReviewPermissions: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            switch presentation {
            case .notScanned:
                ContentUnavailableView("\(subject) not scanned yet", systemImage: "magnifyingglass",
                                       description: Text("The scan starts after scan permissions are reviewed, or when you start it."))
                Button("Start Scan", action: start).buttonStyle(.borderedProminent)
            case .loading:
                ProgressView().controlSize(.large)
                Text(loadingTitle).font(.headline)
                Text("This can take a moment on large folders. You can cancel at any time.").font(.caption).foregroundStyle(.secondary)
            case .empty:
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDetail))
            case .failed(let message):
                ContentUnavailableView("Scan incomplete", systemImage: "exclamationmark.triangle", description: Text(message))
                HStack {
                    Button("Try Again", action: start)
                    if let onReviewPermissions { Button("Review Scan Permissions…", action: onReviewPermissions).buttonStyle(.borderedProminent) }
                }
            case .cancelled:
                ContentUnavailableView("Scan cancelled", systemImage: "stop.circle",
                                       description: Text("Nothing was changed. Start the scan again when you are ready."))
                Button("Scan Again", action: start).buttonStyle(.borderedProminent)
            case .refreshing, .results, .partial, .failedWithResults, .cancelledWithResults:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A one-line notice above results that are not current or not complete (scanning again, cancelled, failed, partial).
struct ModuleNotice: View {
    let presentation: ModulePresentation

    var body: some View {
        if let text = presentation.notice {
            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30).padding(.bottom, 10)
                .accessibilityLabel(text)
        }
    }

    private var icon: String {
        switch presentation {
        case .refreshing: "arrow.triangle.2.circlepath"
        case .cancelledWithResults: "stop.circle"
        default: "exclamationmark.triangle"
        }
    }
}

/// Says why a requested scan is waiting, did not start, or started with limited access, with the one action that helps.
/// A scan is never refused without this explanation.
struct ScanGateBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let notice = model.gateNotice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(notice.kind)).foregroundStyle(.orange).font(.title3)
                Text(notice.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                actions(notice.kind)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.orange.opacity(0.08))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func actions(_ kind: ScanGateNotice.Kind) -> some View {
        switch kind {
        case .waiting(.settings):
            Button("Show Review") { openSettings() }.buttonStyle(.borderedProminent)
        case .waiting(.checks), .waiting(.setup):
            Button("Show Review") { model.access.presented = true }.buttonStyle(.borderedProminent)
        case .startedWithLimitedAccess:
            Button("Open Full Disk Access") { model.access.openFullDiskAccess() }
            Button("Dismiss") { model.dismissGateNotice() }
        case .notStarted:
            Button("Review Scan Permissions…") {
                model.dismissGateNotice()
                model.access.step = .folders
                model.access.presented = true
            }.buttonStyle(.borderedProminent)
            Button("Dismiss") { model.dismissGateNotice() }
        }
    }

    private func icon(_ kind: ScanGateNotice.Kind) -> String {
        switch kind {
        case .waiting: "hourglass"
        case .startedWithLimitedAccess: "lock.trianglebadge.exclamationmark"
        case .notStarted: "exclamationmark.triangle"
        }
    }
}
