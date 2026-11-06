import SwiftUI

extension HealthState {
    /// System colors, so they adapt to Dark Mode. Always paired with `symbol` and `label`, never used alone.
    var color: Color {
        switch self {
        case .healthy: .green
        case .attention: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

/// Read-only health dashboard. It never changes settings; buttons only open the relevant System Settings pane.
/// Severity is always an icon plus its text label, text uses semantic styles (Dynamic Type), and there are no
/// animations.
struct HealthView: View {
    @ObservedObject var model: HealthModel
    @ViewState private var showsScore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.loading {
                        progressSummary
                    } else if let report = model.report {
                        summary(report)
                        if report.isPartial { partialNotice(report) }
                    }
                    if model.loading || model.report != nil {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(model.displayedCategories) { result in
                                HealthCategoryCard(result: result) { model.open($0) }
                            }
                            ForEach(model.pendingCategories, id: \.self) { category in
                                HealthPendingCard(category: category, reduceMotion: reduceMotion)
                            }
                        }
                        Text("Mac Health only reads information and changes nothing. Temporary readings, such as a brief memory or "
                             + "thermal peak, and readings that could not be taken cost no points. " + HealthScore.disclaimer)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ContentUnavailableView("No health check yet", systemImage: "stethoscope",
                                               description: Text("Choose Quick or Extended, then Run Check."))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 30)
            }
        }
        .task { if model.report == nil && !model.loading { model.refresh() } }
        .sheet(isPresented: $showsScore) {
            if let report = model.report { HealthScoreSheet(score: report.scoreDetails) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Mac Health").font(.largeTitle.bold())
                Text(model.report?.machine?.line.nonEmpty ?? "Read-only readings reported by macOS.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("Check type", selection: $model.mode) {
                        ForEach(HealthMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.loading)
                    .accessibilityLabel("Check type")
                    if model.loading {
                        Button("Cancel") { model.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("Cancel the running health check")
                    } else {
                        Button(model.report == nil ? "Run Check" : "Run Again") { model.refresh() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Run a \(model.mode.label) health check")
                    }
                }
                Text(model.mode.scope)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 440, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(30)
    }

    // MARK: Summary

    private var progressSummary: some View {
        let done = model.displayedCategories.count
        return HStack(spacing: 14) {
            if !reduceMotion { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Checking this Mac (\(model.runningMode?.label ?? model.mode.label))…").font(.headline)
                Text("\(done) of \(HealthCategory.allCases.count) categories finished. Results appear as each one finishes; you can cancel at any time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func summary(_ report: HealthCheckResult) -> some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(spacing: 2) {
                Text("\(report.score)").font(.largeTitle.bold()).monospacedDigit()
                Text("of 100").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 84)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HealthAccessibility.scoreLabel(report.scoreDetails))

            VStack(alignment: .leading, spacing: 8) {
                Text(report.summary).font(.title3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    countLabel(report.count(.critical), "critical", .critical)
                    countLabel(report.count(.attention), "need attention", .attention)
                    Text("\(report.mode.label) check · \((report.finishedAt ?? report.startedAt).formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Button("Why this score?") { showsScore = true }
                    .accessibilityLabel("Why this score? Shows how the score of \(report.score) was calculated")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func countLabel(_ count: Int, _ text: String, _ state: HealthState) -> some View {
        Label("\(count) \(text)", systemImage: state.symbol)
            .foregroundStyle(count > 0 ? state.color : .secondary)
    }

    private func partialNotice(_ report: HealthCheckResult) -> some View {
        Label(report.cancelled
              ? "The check was cancelled. Categories that finished are shown; the others are marked Not checked and cost no points."
              : "Some readings were not available. They are marked Unknown and cost no points; run the check again to retry.",
              systemImage: report.cancelled ? "stop.circle" : "exclamationmark.triangle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Icon plus text: severity never depends on color alone.
struct HealthStateBadge: View {
    let state: HealthState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(state.color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// One category. The summary part is a single accessibility element (`HealthAccessibility.label`); the buttons and
/// the technical details stay separately reachable by keyboard and VoiceOver.
struct HealthCategoryCard: View {
    let result: HealthCategoryResult
    let open: (HealthSettingsLink) -> Void
    @ViewState private var showsDetails = false

    init(result: HealthCategoryResult, expanded: Bool = false, open: @escaping (HealthSettingsLink) -> Void) {
        self.result = result
        self.open = open
        _showsDetails = ViewState(wrappedValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overview
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(HealthAccessibility.label(for: result))
            if let link = result.settingsLink {
                Button(link.title) { open(link) }
                    .accessibilityLabel("\(link.title), for \(result.category.displayName)")
            }
            DisclosureGroup("Technical details", isExpanded: $showsDetails) { details.padding(.top, 6) }
                .font(.callout)
                .accessibilityLabel("Technical details for \(result.category.displayName)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(result.state.color.opacity(0.35)))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(result.category.displayName, systemImage: result.category.symbol).font(.headline)
                Spacer(minLength: 8)
                HealthStateBadge(state: result.state)
            }
            if let main = result.measurements.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(main.label).font(.caption).foregroundStyle(.secondary)
                    Text(main.displayValue).font(.title2.weight(.semibold)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(result.summary).fixedSize(horizontal: false, vertical: true)
            if let recommendation = result.recommendation {
                Label(recommendation, systemImage: "arrow.forward.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.trend != .notEnoughData {
                Label("Trend: \(result.trend.label)", systemImage: result.trend.symbol).font(.callout)
            }
            if let first = result.firstObserved, let last = result.lastObserved {
                Label(result.repeated
                      ? "Reported at every check since \(first.formatted(date: .abbreviated, time: .shortened)); last observed \(last.formatted(date: .abbreviated, time: .shortened))"
                      : "First observed \(first.formatted(date: .omitted, time: .standard)); last observed \(last.formatted(date: .omitted, time: .standard))",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let forecast = result.forecast {
                Label(forecast, systemImage: "chart.line.downtrend.xyaxis")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = result.contextTitle, !result.context.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(result.context.enumerated()), id: \.offset) { _, line in
                        Text("• " + line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Confidence: \(result.confidence.label) · Checked \(result.observedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(result.measurements.enumerated()), id: \.offset) { _, measurement in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(measurement.label)
                        Spacer(minLength: 12)
                        Text(measurement.displayValue)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    if let note = measurement.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(result.items) { item in
                itemRow(item)
            }
            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let comparison = result.comparison {
                Text(comparison).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func itemRow(_ item: HealthItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.state.symbol).foregroundStyle(item.state.color).accessibilityHidden(true)
                    Text(item.title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(item.statusLabel + (item.points > 0 ? " · −\(item.points)" : "")).foregroundStyle(item.state.color)
                }
                Text(item.detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                if !item.whyItMatters.isEmpty {
                    Text(item.whyItMatters).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Severity: \(item.severity) · Confidence: \(item.confidence.label)").font(.caption).foregroundStyle(.secondary)
                if let recommendation = item.recommendation {
                    Text("Next step: " + recommendation).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if let link = item.settingsLink {
                Button(link.title) { open(link) }
                    .controlSize(.small)
                    .accessibilityLabel("\(link.title), for \(item.title)")
            }
        }
        .padding(.vertical, 2)
    }
}

struct HealthPendingCard: View {
    let category: HealthCategory
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label(category.displayName, systemImage: category.symbol).font(.headline)
            Spacer()
            if !reduceMotion { ProgressView().controlSize(.small) }
            Text("Checking…").foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.displayName): checking")
    }
}

/// The full calculation behind the score: base, every deduction with its reason, severity, confidence and next
/// step, every zero-point note, the final score and the disclaimer.
struct HealthScoreSheet: View {
    let score: HealthScore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Why this score?").font(.title2.bold())
            Text("The score starts at 100. Each category subtracts points for its worst condition only, so related readings never "
                 + "count twice; Security settings that are off each count, up to 20 together. Unknown and temporary readings subtract nothing.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Item").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Points").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    Divider()
                    GridRow {
                        Text("Base score")
                        Text("\(score.base)").monospacedDigit()
                    }
                    ForEach(score.deductions) { deduction in
                        GridRow(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(HealthScore.lineLabel(deduction)).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                                Label("\(deduction.severity.label) · \(deduction.confidence.label) confidence", systemImage: deduction.severity.symbol)
                                    .font(.caption).foregroundStyle(deduction.severity.color)
                                Text("Next step: " + deduction.recommendation)
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("−\(deduction.points)").monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(Array(score.zeroPointNotes.enumerated()), id: \.offset) { _, note in
                        GridRow {
                            Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("0").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Divider()
                    GridRow {
                        Text(score.totalDeducted > score.base ? "Final score (never below 0)" : "Final score").bold()
                        Text("\(score.final)").bold().monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
            }
            Text(score.arithmetic).font(.callout).monospacedDigit()
            Text(HealthScore.disclaimer).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close the score calculation")
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 680)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
