import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which report to export.
enum ReportPrivacy: String, CaseIterable, Identifiable {
    case full = "Full Report"
    case privacySafe = "Privacy-Safe Report"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .full: "Includes file names, folder paths and your user name in paths. Keep it on this Mac or share it only with people you trust."
        case .privacySafe: "Replaces your user name, home folder, project names and personal file names with placeholders. Totals, sizes, counts and diagnostic states are kept."
        }
    }
}

extension DeepScanModel {
    /// The report text for `privacy`. The privacy-safe version passes every path and free-text value through one
    /// redactor (so the same folder gets the same placeholder everywhere), then redacts the whole text once more.
    func report(_ privacy: ReportPrivacy, identity: ReportRedactor.Identity = .current(), now: Date = Date()) -> String {
        switch privacy {
        case .full:
            return markdown(now: now)
        case .privacySafe:
            var redactor = ReportRedactor(identity: identity)
            let draft = markdown(now: now, path: { redactor.path($0) }, text: { redactor.text($0) },
                                 header: ReportRedactor.privacySafeHeader())
            return redactor.text(draft)
        }
    }
}

/// Shows exactly what will be written before anything is saved.
struct ReportPreviewSheet: View {
    @ObservedObject var deepScan: DeepScanModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var privacy: ReportPrivacy = .privacySafe
    @ViewState private var text = ""
    @ViewState private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Export Deep Scan Report", systemImage: "doc.text.magnifyingglass").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Report", selection: $privacy) {
                ForEach(ReportPrivacy.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(privacy.explanation).font(.callout).foregroundStyle(.secondary)
            if deepScan.isPartialReport {
                Label("This report is \(deepScan.overall.label.lowercased()): some steps did not finish, and the report says which.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if let saveError { Label(saveError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            HStack {
                Text("\(text.split(separator: "\n").count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save…") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 760, height: 620)
        .task(id: privacy) { text = deepScan.report(privacy) }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let kind = privacy == .full ? "full" : "privacy-safe"
        panel.nameFieldStringValue = "Mac Polish report \(Date().formatted(.iso8601.year().month().day())) \(kind).md"
        panel.message = privacy.explanation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Exactly the previewed text is written.
            try text.write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            saveError = "The report could not be saved: \(error.localizedDescription)"
        }
    }
}
