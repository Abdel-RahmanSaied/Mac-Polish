import SwiftUI

/// What a cleanup is about to do, shown by `CleanupConfirmationSheet` before anything moves.
///
/// Build one with the `for…` helpers below so every page explains its items the same way: how many, how much
/// space, why they are suggested, what the user may lose, and which selected items the search is hiding.
/// The helpers are pure (no file access), so they can be checked without touching the disk.
struct CleanupConfirmation: Identifiable, Sendable {
    struct Group: Sendable, Equatable {
        let title: String
        let count: Int
        let bytes: Int64
        /// Why the items are considered safe or useful to remove.
        let reason: String
        /// What the user may lose or have to redo, for example "Apps may download or rebuild this cache."
        let warning: String?
    }

    let id: UUID
    /// For example "Move 12 items to Trash?"
    let title: String
    /// The page or scanner that suggested the items, for example "Cleanup", "Duplicates", "Project Artifacts".
    let source: String
    /// Display names; the sheet shows the first `nameLimit` and then "and N more".
    let names: [String]
    let count: Int
    /// Estimated recoverable space.
    let bytes: Int64
    /// Selected items that the current search filter does not show.
    let hiddenBySearch: Int
    let groups: [Group]
    /// Extra lines, for example "At least one copy of each duplicate is kept."
    let notes: [String]
    var actionTitle = "Move to Trash"
    /// The exact items described. Confirming must run only these; empty when the caller tracks them itself.
    var itemIDs: Set<UUID> = []
    /// Set when part of the operation bypasses Trash (Docker build cache). Shown prominently: it cannot be undone.
    var permanentRemoval: String? = nil

    init(id: UUID = UUID(), title: String, source: String, names: [String], count: Int, bytes: Int64,
         hiddenBySearch: Int = 0, groups: [Group] = [], notes: [String] = [], actionTitle: String = "Move to Trash",
         itemIDs: Set<UUID> = [], permanentRemoval: String? = nil) {
        self.id = id
        self.title = title
        self.source = source
        self.names = names
        self.count = count
        self.bytes = bytes
        self.hiddenBySearch = max(hiddenBySearch, 0)
        self.groups = groups
        self.notes = notes
        self.actionTitle = actionTitle
        self.itemIDs = itemIDs
        self.permanentRemoval = permanentRemoval
    }
}

// MARK: - Text helpers

extension CleanupConfirmation {
    /// Shown on every confirmation. Moving to Trash does not free space by itself.
    static let trashExplanation =
        "Items go to Trash. Space is released when Trash is emptied; you can put items back from Trash until then."
    static let nameLimit = 8

    /// "1 item", "12 items", "3 copies".
    static func countText(_ count: Int, _ singular: String = "item", plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : (plural ?? singular + "s"))
    }

    /// "Move 12 items to Trash?"
    static func title(count: Int, _ singular: String = "item", plural: String? = nil) -> String {
        "Move \(countText(count, singular, plural: plural)) to Trash?"
    }

    /// The first `limit` names, then "and N more" when some are not shown.
    static func truncatedNames(_ names: [String], limit: Int = nameLimit) -> (shown: [String], more: String?) {
        let shown = Array(names.prefix(max(limit, 0)))
        let remaining = names.count - shown.count
        return (shown, remaining > 0 ? "and \(remaining) more" : nil)
    }

    /// The prominent line about selected items the search hides; nil when none are hidden.
    static func hiddenBySearchText(_ hidden: Int) -> String? {
        guard hidden > 0 else { return nil }
        let subject = hidden == 1 ? "1 selected item is" : "\(hidden) selected items are"
        return subject + " hidden by your search and will be included. Clear the search to review them first."
    }

    var summaryLine: String {
        "\(Self.countText(count)) · \(bytes.formattedBytes) estimated · suggested by \(source)"
    }

    /// Home-relative path for display, for example "~/Downloads/photo.jpg".
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Names ordered largest first, so the visible part of a long list shows what matters most.
    fileprivate static func orderedNames<T>(_ items: [T], name: (T) -> String, bytes: (T) -> Int64) -> [String] {
        let pairs: [(name: String, bytes: Int64)] = items.map { (name($0), bytes($0)) }
        let sorted = pairs.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sorted.map(\.name)
    }
}

// MARK: - Scan items (Cleanup, Large Files, Developer Cleanup, Old Files, Optimize)

extension CleanupConfirmation {
    /// Why items of `category` are suggested and what removing them costs. Date claims are added by `groups(for:now:)`
    /// only when the items really are older than `CleanupPolicy.staleAge`.
    static func explanation(for category: ScanCategory) -> (reason: String, warning: String?) {
        switch category {
        case .cache:
            ("Regenerated by apps", "Apps may download or rebuild this cache, so they can be slower the first time.")
        case .logs:
            ("Old log files; apps write new ones as needed", nil)
        case .trash:
            ("Already in Trash, so Mac Polish skips these. Empty Trash in Finder to release this space", nil)
        case .largeFile:
            ("Large personal file you chose; not regenerable",
             "This is your own data and nothing can recreate it. Make sure you have another copy before emptying Trash.")
        case .derivedData:
            ("Xcode build products and indexes; Xcode rebuilds them", "The next build and indexing of each project take longer.")
        case .xcodeCache:
            ("Xcode caches; Xcode recreates them", "Xcode may be slower while it rebuilds these caches.")
        case .simulatorCache:
            ("Simulator caches; the Simulator recreates them", "Simulators may be slower the first time they start again.")
        case .deviceSupport:
            ("Debug symbols for device OS versions; Xcode copies them again when such a device connects",
             "Connecting a device with that OS version makes Xcode prepare it again, which can take several minutes.")
        case .xcodeArchive:
            ("App archives built with Xcode Organizer",
             "Archives hold the debug symbols (dSYMs) of builds you distributed. Without them you cannot symbolicate crash reports for those versions, and an identical build cannot be recreated.")
        case .oldXcode:
            ("Another copy of Xcode besides the one in use",
             "Projects, scripts or xcode-select settings that use this Xcode stop working until you install it again.")
        case .xcodeDownload:
            ("Xcode installer archive; it can be downloaded again from Apple", "Downloading it again takes time and several GB.")
        case .diagnostics:
            ("Crash and diagnostic reports", "You can no longer send these reports to a developer.")
        case .deviceBackup:
            ("iPhone or iPad backup made by Finder",
             "This may be your only backup of that device. Without it you cannot restore the device's data. Check that iCloud or another backup exists first.")
        case .oldInstaller:
            ("macOS installer; it can be downloaded again from Apple",
             "Apple may no longer offer this macOS version for download.")
        }
    }

    /// One group per category present, in `ScanCategory` order, with a reason and a warning.
    static func groups(for items: [ScanItem], now: Date = Date()) -> [Group] {
        ScanCategory.allCases.compactMap { category in
            let members = items.filter { $0.category == category }
            guard !members.isEmpty else { return nil }
            var (reason, warning) = explanation(for: category)
            if CleanupPolicy.suggestedCategories.contains(category) {
                let recent = members.filter { !CleanupPolicy.isStale(newest: $0.newestContentModifiedAt, now: now) }.count
                if recent == 0 {
                    reason += "; nothing inside changed for 7+ days."
                } else {
                    reason += ". " + (recent == members.count ? "These" : "\(recent) of these")
                        + " changed in the last 7 days or have no known date, so an app may still be using them."
                    if warning == nil { warning = "An app may still be using recently changed items." }
                }
            } else {
                reason += "."
            }
            return Group(title: category.rawValue, count: members.count,
                         bytes: members.reduce(0) { $0 + $1.size }, reason: reason, warning: warning)
        }
    }

    /// Confirmation for selected scan items; nil when there is nothing to move.
    static func forScanItems(_ items: [ScanItem], source: String, hiddenBySearch: Int = 0, notes: [String] = [],
                             now: Date = Date()) -> CleanupConfirmation? {
        guard !items.isEmpty else { return nil }
        return CleanupConfirmation(
            title: title(count: items.count), source: source,
            names: orderedNames(items, name: \.displayName, bytes: \.size),
            count: items.count, bytes: items.reduce(0) { $0 + $1.size }, hiddenBySearch: hiddenBySearch,
            groups: groups(for: items, now: now),
            notes: ["Close the apps that use these files first. Items that changed since the scan are skipped."] + notes,
            itemIDs: Set(items.map(\.id)))
    }

    static let dockerPermanentNotice =
        "Docker build cache is removed permanently by Docker, not moved to Trash. It cannot be put back."

    static func dockerBuildCacheGroup(bytes: Int64) -> Group {
        Group(title: "Docker build cache", count: 1, bytes: bytes,
              reason: "Build cache that Docker recreates on future builds. Volumes, images and containers are not targeted.",
              warning: "Removed permanently, not moved to Trash. Future builds may take longer.")
    }

    /// Optimize: reviewed scan items, plus the Docker build cache when the user included it.
    static func forOptimize(_ items: [ScanItem], dockerBuildCacheBytes: Int64? = nil, now: Date = Date()) -> CleanupConfirmation? {
        guard let docker = dockerBuildCacheBytes else { return forScanItems(items, source: "Optimize", now: now) }
        let fileTitle = items.isEmpty ? nil : countText(items.count)
        return CleanupConfirmation(
            title: fileTitle.map { "Move \($0) to Trash and remove Docker build cache?" } ?? "Remove Docker build cache?",
            source: "Optimize",
            names: orderedNames(items, name: \.displayName, bytes: \.size),
            count: items.count, bytes: items.reduce(0) { $0 + $1.size } + docker,
            groups: groups(for: items, now: now) + [dockerBuildCacheGroup(bytes: docker)],
            notes: items.isEmpty ? [] : ["Close the apps that use these files first. Items that changed since the scan are skipped."],
            actionTitle: items.isEmpty ? "Remove Build Cache" : "Move to Trash and Remove Cache",
            itemIDs: Set(items.map(\.id)),
            permanentRemoval: dockerPermanentNotice)
    }
}

// MARK: - Duplicates, applications, project artifacts, leftover app data

extension CleanupConfirmation {
    static func groups(forDuplicates files: [DuplicateFile]) -> [Group] {
        guard !files.isEmpty else { return [] }
        return [Group(title: "Duplicate copies", count: files.count, bytes: files.reduce(0) { $0 + $1.estimatedDiskBytes },
                      reason: "Identical content verified by SHA-256; one copy of each is kept.",
                      warning: "A copy inside a project or app folder may be needed at that location even when an identical file exists elsewhere.")]
    }

    /// `files` is the removal plan (`AppModel.duplicateRemovalPlan`), which already leaves one copy per group.
    static func forDuplicates(_ files: [DuplicateFile], hiddenBySearch: Int = 0) -> CleanupConfirmation? {
        guard !files.isEmpty else { return nil }
        return CleanupConfirmation(
            title: title(count: files.count, "duplicate copy", plural: "duplicate copies"), source: "Duplicates",
            names: orderedNames(files, name: { displayPath($0.url) }, bytes: \.estimatedDiskBytes),
            count: files.count, bytes: files.reduce(0) { $0 + $1.estimatedDiskBytes }, hiddenBySearch: hiddenBySearch,
            groups: groups(forDuplicates: files),
            notes: ["At least one copy of each duplicate is kept.",
                    "Each file is checked again before it moves. Space is estimated: clones and shared blocks can release less."],
            itemIDs: Set(files.map(\.id)))
    }

    static func groups(forApplications apps: [ApplicationItem]) -> [Group] {
        guard !apps.isEmpty else { return [] }
        return [Group(title: "Applications", count: apps.count, bytes: apps.reduce(0) { $0 + $1.totalSize },
                      reason: "The app and its own library data: caches, preferences and support files named after its bundle identifier.",
                      warning: "Settings and data these apps keep in your Library go with them; reinstalling does not bring them back. Documents saved elsewhere are not touched.")]
    }

    static func forApplications(_ apps: [ApplicationItem], hiddenBySearch: Int = 0) -> CleanupConfirmation? {
        guard !apps.isEmpty else { return nil }
        var notes = ["System apps are protected. Quit these apps first."]
        let leftovers = apps.reduce(0) { $0 + $1.leftoverURLs.count }
        if leftovers > 0 {
            notes.append("Includes \(countText(leftovers, "library item")) (\(apps.reduce(Int64(0)) { $0 + $1.leftoverSize }.formattedBytes)) of app data.")
        }
        let blocked = apps.filter { !$0.canRemove }.count
        if blocked > 0 {
            notes.append("\(countText(blocked, "app")) need an administrator and will be skipped; remove them in Finder.")
        }
        return CleanupConfirmation(
            title: title(count: apps.count, "app"), source: "Applications",
            names: orderedNames(apps, name: \.name, bytes: \.totalSize),
            count: apps.count, bytes: apps.reduce(0) { $0 + $1.totalSize }, hiddenBySearch: hiddenBySearch,
            groups: groups(forApplications: apps), notes: notes, itemIDs: Set(apps.map(\.id)))
    }

    static func explanation(for kind: ProjectArtifactKind) -> (reason: String, warning: String?) {
        let reason = "\(kind.ecosystem) \(kind.displayName) folder. Recreate it with \(kind.regenerateHint)."
        guard kind.isSafelyRegenerable else {
            return (reason, "May contain packages installed by hand that no requirements file lists; those cannot be recreated automatically. Run pip freeze in it first if you are unsure.")
        }
        switch kind {
        case .nodeModules, .cocoaPods, .gradleCache, .dartTool, .terraform, .toxEnv, .haskellStack:
            return (reason, "Recreating it downloads dependencies again; without a lockfile, versions may differ.")
        default:
            return (reason, "The next build takes longer.")
        }
    }

    static func groups(forArtifacts artifacts: [ProjectArtifact]) -> [Group] {
        ProjectArtifactKind.allCases.compactMap { kind in
            let members = artifacts.filter { $0.kind == kind }
            guard !members.isEmpty else { return nil }
            let (reason, warning) = explanation(for: kind)
            return Group(title: kind.displayName, count: members.count, bytes: members.reduce(0) { $0 + $1.size },
                         reason: reason, warning: warning)
        }
    }

    static func forProjectArtifacts(_ artifacts: [ProjectArtifact], hiddenBySearch: Int = 0) -> CleanupConfirmation? {
        guard !artifacts.isEmpty else { return nil }
        return CleanupConfirmation(
            title: title(count: artifacts.count, "folder"), source: "Project Artifacts",
            names: orderedNames(artifacts, name: { "\($0.url.lastPathComponent) in \($0.projectURL.lastPathComponent)" }, bytes: \.size),
            count: artifacts.count, bytes: artifacts.reduce(0) { $0 + $1.size }, hiddenBySearch: hiddenBySearch,
            groups: groups(forArtifacts: artifacts),
            notes: ["Each folder is checked again first; folders that changed since the scan are skipped."],
            itemIDs: Set(artifacts.map(\.id)))
    }

    static let orphanedReason =
        "Not matched to any installed app by bundle identifier — the match can be wrong for apps on other disks, apps you will reinstall, or apps that keep data under another name."

    static func groups(forOrphanedData items: [OrphanedDataItem]) -> [Group] {
        let unmatched = items.filter { $0.sameVendorApp == nil }
        let shared = items.filter { $0.sameVendorApp != nil }
        var groups: [Group] = []
        if !unmatched.isEmpty {
            groups.append(Group(title: "Not matched to any installed app", count: unmatched.count,
                                bytes: unmatched.reduce(0) { $0 + $1.size }, reason: orphanedReason,
                                warning: "If you still use the app, or will reinstall it, its settings and data are gone once Trash is emptied."))
        }
        if !shared.isEmpty {
            let vendors = Array(Set(shared.compactMap(\.sameVendorApp))).sorted()
            groups.append(Group(title: "Same developer as an installed app", count: shared.count,
                                bytes: shared.reduce(0) { $0 + $1.size }, reason: orphanedReason,
                                warning: "May be data that an installed app from the same developer still uses ("
                                    + truncatedNames(vendors, limit: 3).shown.joined(separator: ", ")
                                    + (vendors.count > 3 ? ", …" : "") + ")."))
        }
        return groups
    }

    static func forOrphanedData(_ items: [OrphanedDataItem], hiddenBySearch: Int = 0) -> CleanupConfirmation? {
        guard !items.isEmpty else { return nil }
        return CleanupConfirmation(
            title: title(count: items.count), source: "Leftover App Data",
            names: orderedNames(items, name: { "\($0.location)/\($0.url.lastPathComponent)" }, bytes: \.size),
            count: items.count, bytes: items.reduce(0) { $0 + $1.size }, hiddenBySearch: hiddenBySearch,
            groups: groups(forOrphanedData: items),
            notes: ["Each item is checked again first; items that now match an installed app are skipped."],
            itemIDs: Set(items.map(\.id)))
    }
}

// MARK: - Sheet

/// The confirmation shown before a cleanup. Cancel is the default button (Return or Esc); the destructive
/// button must be clicked. Matches `CleanupDetailsView`.
struct CleanupConfirmationSheet: View {
    let confirmation: CleanupConfirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(confirmation.title, systemImage: confirmation.permanentRemoval == nil ? "trash" : "exclamationmark.octagon")
                .font(.title2.bold())
            Text(confirmation.summaryLine).font(.headline)

            if let hidden = CleanupConfirmation.hiddenBySearchText(confirmation.hiddenBySearch) {
                notice(hidden, systemImage: "eye.slash", tint: .yellow)
            }
            if let permanent = confirmation.permanentRemoval {
                notice(permanent, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Reasons and warnings first, so a long name list never pushes a warning out of view.
                    ForEach(Array(confirmation.groups.enumerated()), id: \.offset) { _, group in
                        groupCard(group)
                    }
                    namesCard
                    if !confirmation.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(confirmation.notes.enumerated()), id: \.offset) { _, note in
                                Label(note, systemImage: "info.circle")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .scrollIndicators(.visible)

            Label(CleanupConfirmation.trashExplanation, systemImage: "arrow.uturn.backward.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: onConfirm) {
                    Text(confirmation.actionTitle).foregroundStyle(.red)
                }
                .accessibilityHint("\(confirmation.summaryLine). " + (confirmation.permanentRemoval ?? CleanupConfirmation.trashExplanation))
            }
            .background {
                // Esc cancels too; Return already triggers the default (Cancel) button.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(24)
        .frame(width: 660, height: 580)
    }

    private var namesCard: some View {
        let names = CleanupConfirmation.truncatedNames(confirmation.names)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Items").font(.headline).padding(.bottom, 3)
            ForEach(Array(names.shown.enumerated()), id: \.offset) { _, name in
                Text(name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let more = names.more {
                Text(more).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func groupCard(_ group: CleanupConfirmation.Group) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(group.title).font(.headline)
                Spacer()
                Text("\(CleanupConfirmation.countText(group.count)) · \(group.bytes.formattedBytes)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text(group.reason).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = group.warning {
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .accessibilityLabel("Warning: " + warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Presentation

/// Lets each confirmation finish once: a double click, or a button followed by the sheet disappearing,
/// must not call back twice.
@MainActor
final class CleanupConfirmationGate {
    private var finished: Set<UUID> = []

    /// True the first time for `id`, false afterwards.
    func claim(_ id: UUID) -> Bool { finished.insert(id).inserted }
}

struct CleanupConfirmationPresenter: ViewModifier {
    @Binding var item: CleanupConfirmation?
    let onConfirm: (CleanupConfirmation) -> Void
    let onCancel: () -> Void
    @ViewState private var gate = CleanupConfirmationGate()

    func body(content: Content) -> some View {
        content.sheet(item: $item) { confirmation in
            CleanupConfirmationSheet(
                confirmation: confirmation,
                onConfirm: {
                    guard gate.claim(confirmation.id) else { return }
                    item = nil
                    onConfirm(confirmation)
                },
                onCancel: {
                    guard gate.claim(confirmation.id) else { return }
                    item = nil
                    onCancel()
                })
            // Any other dismissal (the binding cleared or replaced, the page closed) is a cancel.
            .onDisappear {
                if gate.claim(confirmation.id) { onCancel() }
            }
        }
    }
}

extension View {
    /// Presents `CleanupConfirmationSheet` while `item` is non-nil. Confirm calls `onConfirm` with the confirmation
    /// (run only its `itemIDs`); Cancel, Esc or any other dismissal calls `onCancel` exactly once. Neither path
    /// changes the page's selection.
    func cleanupConfirmation(_ item: Binding<CleanupConfirmation?>,
                             onConfirm: @escaping (CleanupConfirmation) -> Void,
                             onCancel: @escaping () -> Void = {}) -> some View {
        modifier(CleanupConfirmationPresenter(item: item, onConfirm: onConfirm, onCancel: onCancel))
    }
}
