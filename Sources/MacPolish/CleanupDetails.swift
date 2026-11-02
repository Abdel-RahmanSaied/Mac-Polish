import AppKit
import SwiftUI

struct CleanupOutcome: Sendable {
    let date: Date
    let movedCount: Int
    let movedBytes: Int64
    let issues: [CleanupIssue]
}

struct CleanupDetailsView: View {
    let outcome: CleanupOutcome
    let onPermissions: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Cleanup Results", systemImage: "checklist").font(.title2.bold())
            Text("Moved \(outcome.movedCount) item(s) · \(outcome.movedBytes.formattedBytes) to Trash")
                .font(.headline)
            Text("Space is released after Trash is emptied. Failed items were left in place; no retry runs automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text(outcome.date, style: .time).font(.caption).foregroundStyle(.secondary)
            if outcome.issues.isEmpty {
                ContentUnavailableView("All reviewed items moved", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(outcome.issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label(issue.url.lastPathComponent, systemImage: issue.needsAccess ? "lock.shield" : "info.circle")
                                        .font(.headline)
                                    Spacer()
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([issue.url]) }
                                }
                                Text(issue.url.path).font(.caption).textSelection(.enabled)
                                Text(issue.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            HStack {
                if outcome.issues.contains(where: \.needsAccess) {
                    Button("Review Permissions…", action: onPermissions)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 680, height: 560)
    }
}
