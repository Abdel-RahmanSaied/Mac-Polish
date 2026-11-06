import AppKit
import SwiftUI

/// Per-file facts from the whole-disk walk: coverage, space by kind and age, and the largest files anywhere.
/// One series per chart, so bars share one hue; text stays in text colors and every bar has an exact tooltip.
struct DiskInsightsPanel: View {
    let report: DiskMapReport
    @ViewState private var search = ""
    @ViewState private var visibleFiles = 25

    private var insights: DiskInsights? { report.tree.insights }

    var body: some View {
        if let insights {
            VStack(alignment: .leading, spacing: 18) {
                coverage(insights)
                HStack(alignment: .top, spacing: 18) {
                    breakdown("Space by kind", rows: DiskInsights.Kind.allCases.compactMap { kind in
                        insights.kinds[kind].map { (kind.displayName, kind.icon, $0) }
                    })
                    breakdown("Space by last change", rows: DiskInsights.Age.allCases.compactMap { age in
                        insights.ages[age].map { (age.displayName, "calendar", $0) }
                    }, keepOrder: true,
                       footnote: "Modification dates, not last use. Old does not mean unneeded.")
                }
                largestFiles(insights)
            }
        }
    }

    private func coverage(_ insights: DiskInsights) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Every file the scan could reach was counted", systemImage: "checklist.checked").font(.headline)
            let system = report.systemTree
            Text("\(report.filesCounted.formatted()) files in \((insights.folders + (system?.insights?.folders ?? 0)).formatted()) folders"
                 + (system.map { " · \($0.root.files.formatted()) on the sealed macOS volume (\($0.root.bytes.formattedBytes))" } ?? "")
                 + (report.duration > 0 ? " · \(String(format: "%.0f", report.duration)) s" : ""))
                .font(.callout.monospacedDigit())
            Text("\(insights.hidden.files.formatted()) hidden files (\(insights.hidden.bytes.formattedBytes)) · \(insights.emptyFiles.formatted()) empty files · "
                 + "\(insights.specialEntries.formatted()) links and special entries listed but not followed · deepest folder level \(insights.deepestLevel)")
                .font(.caption).foregroundStyle(.secondary)
            let tree = report.tree.root
            if tree.unreadable > 0 || tree.notScanned > 0 {
                Label("\(tree.unreadable.formatted()) folders could not be opened and \(tree.notScanned.formatted()) were not reached in time; their files are not in these totals.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func breakdown(_ title: String, rows: [(String, String, DiskInsights.Total)], keepOrder: Bool = false,
                           footnote: String? = nil) -> some View {
        let sorted = keepOrder ? rows : rows.sorted { $0.2.bytes > $1.2.bytes }
        let largest = max(1, sorted.map(\.2.bytes).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(sorted, id: \.0) { name, icon, total in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(name, systemImage: icon).font(.caption)
                        Spacer()
                        Text(total.bytes.formattedBytes).font(.caption.monospacedDigit())
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(4, geometry.size.width * CGFloat(Double(total.bytes) / Double(largest))))
                        }
                    }
                    .frame(height: 6)
                }
                .contentShape(Rectangle())
                .help("\(name): \(total.bytes.formattedBytes) in \(total.files.formatted()) files")
                .accessibilityElement(children: .combine)
            }
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func largestFiles(_ insights: DiskInsights) -> some View {
        let matches = insights.largestFiles.filter {
            search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Largest files anywhere on this disk").font(.headline)
                Spacer()
                TextField("Filter by name or path", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            Text("The \(insights.largestFiles.count) largest readable files on the data volume, wherever they are, hidden files and app contents included. Review only: nothing here is selected for cleanup.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(matches.prefix(visibleFiles), id: \.path) { file in
                let path = DiskMapService.familiarPath(file.path)
                HStack(spacing: 10) {
                    Image(systemName: file.kind.icon).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                        Text((path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let modified = file.modified {
                        Text(modified, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(file.bytes.formattedBytes).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
                    Button("Reveal") {
                        let url = URL(fileURLWithPath: FileManager.default.fileExists(atPath: path) ? path : file.path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }.buttonStyle(.borderless)
                }
                .font(.callout)
                .help(path)
            }
            if matches.count > visibleFiles {
                Button("Show 25 more (\(matches.count - visibleFiles) remaining)") { visibleFiles += 25 }
            } else if matches.isEmpty {
                Text(search.isEmpty ? "No readable files were found." : "No large file matches “\(search)”.").foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
