import Foundation

@MainActor
final class AppModel: ObservableObject {
    let access: AccessSetupModel
    let services: ScanServices

    init(access: AccessSetupModel? = nil, services: ScanServices = .live) {
        self.access = access ?? AccessSetupModel()
        self.services = services
        // A scan refused by the access gate starts once the review is finished, instead of leaving its page idle.
        self.access.onFinish = { [weak self] in self?.runDeferredScans() }
        // A review closed before it finished: say which scans did not start instead of dropping them silently.
        self.access.onReviewClosed = { [weak self] in self?.deferredScansAbandoned() }
        appInsights.reader = services.appInsights
        // Memory pressure is judged from the monitor's recent readings, so one momentary spike costs no points.
        health.memoryHistory = { [weak memory] in memory?.history ?? [] }
        // Context only: the largest kinds from the last Storage Map, and the apps using the most memory right now.
        health.storageBreakdown = { [weak self] in
            (self?.diskMap?.tree.insights?.kinds ?? [:]).sorted { $0.value.bytes > $1.value.bytes }
                .prefix(4).map { (name: $0.key.displayName, bytes: $0.value.bytes) }
        }
        health.topApps = { [weak memory] in
            (memory?.apps ?? []).sorted { $0.bytes > $1.bytes }.prefix(3).map { (name: $0.name, bytes: $0.bytes) }
        }
        recordCleanup = { [weak self] source, candidates, result in
            self?.cleanupHistory.record(source: source, result: result, candidates: candidates)
        }
    }

    /// Local record of every cleanup. Created on first use, so merely opening the app reads nothing.
    lazy var cleanupHistory = CleanupHistoryModel()
    @Published var showsCleanupHistory = false

    // MARK: Access gate

    private struct DeferredScan {
        let title: String
        let retry: @MainActor () -> Void
    }
    /// Scans that asked for access while the review was not finished, keyed so each runs once however often it is asked.
    private var deferredScans: [String: DeferredScan] = [:]
    /// Why requested scans are waiting, did not start, or started with limited access. nil when there is nothing to say.
    @Published var gateNotice: ScanGateNotice?

    static let scanTitles: [String: String] = [
        "scan": "Scan My Mac", "duplicates": "Duplicates", "applications": "Applications", "storage": "Storage Map",
        "startup": "Startup Items", "systemData": "System Data", "optimize": "Optimize", "artifacts": "Project Artifacts",
        "startupAudit": "Startup Items", "orphans": "Leftover App Data", "deepScan": "Deep Scan"
    ]

    private var deferredTitles: [String] {
        Array(Set(deferredScans.values.map(\.title))).sorted()
    }

    /// Every scan entry point goes through the access gate. A refused scan is never dropped silently: it is
    /// remembered (once per key), the reason is shown, and it starts when the review completes.
    func authorize(_ key: String, retry: @escaping @MainActor () -> Void) -> Bool {
        guard access.authorizeScan() else {
            deferredScans[key] = DeferredScan(title: Self.scanTitles[key] ?? key, retry: retry)
            let place: ScanGateNotice.Place = access.settingsPresented ? .settings : access.checking ? .checks : .setup
            gateNotice = ScanGateNotice(kind: .waiting(place), scans: deferredTitles)
            return false
        }
        deferredScans[key] = nil
        if deferredScans.isEmpty, case .waiting = gateNotice?.kind { gateNotice = nil }
        return true
    }

    private func runDeferredScans() {
        let pending = deferredScans
        deferredScans = [:]
        guard !pending.isEmpty else { return }
        for key in pending.keys.sorted() { pending[key]?.retry() }
        let limited = access.limitedLocations
        let titles = Array(Set(pending.values.map(\.title))).sorted()
        gateNotice = limited.isEmpty && access.fullDiskAccess != .restricted
            ? nil : ScanGateNotice(kind: .startedWithLimitedAccess(restricted: limited), scans: titles)
    }

    private func deferredScansAbandoned() {
        guard !deferredScans.isEmpty else { return }
        gateNotice = ScanGateNotice(kind: .notStarted, scans: deferredTitles)
        deferredScans = [:]
    }

    func dismissGateNotice() { gateNotice = nil }

    // MARK: Modules

    lazy var optimizer: OptimizerModel = {
        let optimizer = OptimizerModel()
        optimizer.trashItem = services.trashItem
        optimizer.onCleanup = { [weak self] in self?.recordCleanup("Optimize", $0, $1) }
        optimizer.onDockerCleanup = { [weak self] in
            self?.cleanupHistory.record(source: "Optimize", moved: [.dockerBuildCache(bytes: nil)], skipped: [], permanent: true)
        }
        optimizer.authorizeScan = { [weak self] in
            self?.authorize("optimize") { [weak self] in self?.optimizer.scan() } ?? false
        }
        optimizer.onOutcome = { [weak self] outcome in
            self?.cleanupOutcome = outcome
            self?.operationIssues = outcome.issues
            // Optimize scans on its own; drop what it moved so Cleanup does not offer trashed paths again.
            self?.items.removeAll { outcome.movedURLs.contains($0.url.standardizedFileURL) }
        }
        // Optimize maps the whole disk too; share the result with the Storage Map.
        optimizer.onDiskMap = { [weak self] report in
            guard let self else { return }
            diskMap = report
            // A Storage Map analysis already running keeps its own loading state and finishes normally.
            if storageState != .loading { storageState = .ready }
        }
        return optimizer
    }()
    let memory = MemoryMonitor()
    lazy var deepScan = DeepScanModel(app: self)
    /// Signature, orphan and risk checks of launch agents and daemons (read-only).
    lazy var startupAudit: StartupAuditModel = {
        let audit = StartupAuditModel()
        audit.reader = services.startupAudit
        audit.authorizeScan = { [weak self] in
            self?.authorize("startupAudit") { [weak self] in self?.startupAudit.scan() } ?? false
        }
        return audit
    }()
    /// Library data whose app is no longer installed; review-only until the user selects items.
    lazy var orphans: OrphanedDataModel = {
        let orphans = OrphanedDataModel()
        orphans.reader = services.orphans
        orphans.authorizeScan = { [weak self] in
            self?.authorize("orphans") { [weak self] in self?.orphans.scan() } ?? false
        }
        let trashItem = services.trashItem
        orphans.cleaner = { OrphanedDataCleaner().clean($0, trashItem: trashItem) }
        orphans.onOutcome = { [weak self] outcome in
            self?.cleanupOutcome = outcome
            self?.operationIssues = outcome.issues
        }
        orphans.onCleanup = { [weak self] in self?.recordCleanup("Leftover App Data", $0, $1) }
        return orphans
    }()
    /// Architecture, signature, App Store and last-used details for the Applications list.
    let appInsights = ApplicationInsightsModel()
    /// Read-only health readings; they need no file access, so they are not behind the access gate.
    let health = HealthModel()
    lazy var artifacts: ProjectArtifactsModel = {
        let artifacts = ProjectArtifactsModel(reader: services.artifacts, cacheMeasurer: services.toolchainCaches,
                                              trashItem: services.trashItem)
        artifacts.authorizeScan = { [weak self] in
            self?.authorize("artifacts") { [weak self] in self?.artifacts.scan() } ?? false
        }
        artifacts.onOutcome = { [weak self] outcome in
            self?.cleanupOutcome = outcome
            self?.operationIssues = outcome.issues
        }
        artifacts.onCleanup = { [weak self] in self?.recordCleanup("Project Artifacts", $0, $1) }
        return artifacts
    }()
    let updates = UpdateChecker()
    @Published var destination: SidebarDestination = .overview
    @Published var state: ScanState = .idle
    @Published var items: [ScanItem] = []
    @Published var lastCleanup: CleanupResult?
    /// Set when some scan sections could not be read; the other results are still shown.
    @Published var scanWarning: String?
    @Published var includeLargeFiles = true
    /// Whether the last finished scan read the large-file folders, so an empty Large Files page can say why.
    @Published var lastScanIncludedLargeFiles = true
    @Published var applications: [ApplicationItem] = []
    @Published var applicationState: ModuleState = .idle
    @Published var duplicateFiles: [DuplicateFile] = [] {
        didSet { duplicateGroups = Self.groups(of: duplicateFiles) }
    }
    /// Kept in step with `duplicateFiles` instead of being regrouped on every view update.
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    /// The selection before Remove All replaced it, restored if that confirmation is cancelled.
    private var selectionBeforeRemoveAll: [UUID: Bool]?
    @Published var duplicateState: ModuleState = .idle
    /// Set when macOS denied some personal folders; the duplicates found elsewhere are still shown.
    @Published var duplicateWarning: String?
    @Published var diskMap: DiskMapReport?
    @Published var storageState: ModuleState = .idle
    @Published var storageStarted: Date?
    @Published var startupEntries: [StartupEntry] = []
    @Published var startupState: ModuleState = .idle
    @Published var operationMessage: String?
    @Published var operationIssues: [CleanupIssue] = []
    @Published var cleanupOutcome: CleanupOutcome?
    @Published var showsCleanupDetails = false
    @Published var applicationSearchText = ""
    @Published var confirmsApplicationRemoval = false
    @Published var confirmsDuplicateRemoval = false
    @Published var systemDataReport: SystemDataReport?
    @Published var systemDataState: ModuleState = .idle
    var systemDataLoading: Bool { systemDataState == .loading }
    @Published var dockerCleaning = false
    @Published var confirmsDockerCleanup = false
    @Published var dockerCleanupMessage: String?

    private var basicRun = ScanRunTracker()
    private var duplicatesRun = ScanRunTracker()
    private var applicationsRun = ScanRunTracker()
    private var storageRun = ScanRunTracker()
    private var startupRun = ScanRunTracker()
    private var systemDataRun = ScanRunTracker()

    /// Records each finished cleanup (moved and skipped items, sizes, which page suggested them).
    var recordCleanup: (_ source: String, _ candidates: [(id: UUID, url: URL, bytes: Int64)], _ result: CleanupResult) -> Void = { _, _, _ in }
    /// The confirmation on screen for the Cleanup, Large Files, Developer Cleanup and Old Files pages.
    @Published var pendingConfirmation: CleanupConfirmation?
    /// The confirmation on screen for duplicates.
    @Published var duplicateConfirmation: CleanupConfirmation?
    /// The confirmation on screen for uninstalling applications.
    @Published var applicationConfirmation: CleanupConfirmation?

    func cleanDockerBuildCache() {
        guard !dockerCleaning, !systemDataLoading,
              (SystemDataScanner.dockerBuildCacheBytes(systemDataReport?.dockerOutput ?? "") ?? 0) > 0 else { return }
        dockerCleaning = true
        dockerCleanupMessage = nil
        Task {
            let message = await BackgroundWork.run(qos: .utility) {
                SystemDataScanner.cleanDockerBuildCache()
            }
            dockerCleanupMessage = message
            dockerCleaning = false
            if message.hasPrefix("Build cache cleanup completed") {
                // Removed by Docker, not moved to Trash: recorded as permanent so history never suggests recovery.
                cleanupHistory.record(source: "System Data", moved: [.dockerBuildCache(bytes: nil)], skipped: [], permanent: true)
            }
            analyzeSystemData()
        }
    }

    func analyzeSystemData() {
        guard authorize("systemData", retry: { [weak self] in self?.analyzeSystemData() }) else { return }
        guard !systemDataLoading, !dockerCleaning else { return }
        let (id, cancellation) = systemDataRun.begin()
        systemDataState = .loading
        let services = services
        Task {
            let report = await BackgroundWork.run(qos: .utility) { services.systemData(cancellation) }
            guard systemDataRun.finish(id) else { return }
            if let report {
                systemDataReport = report
                systemDataState = .ready
            } else {
                systemDataState = .cancelled
            }
        }
    }

    var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    var cleanableItems: [ScanItem] {
        items.filter { [.cache, .logs, .trash].contains($0.category) }
    }

    var largeFileItems: [ScanItem] {
        items.filter { $0.category == .largeFile }
    }

    var developerItems: [ScanItem] {
        let categories: Set<ScanCategory> = [.derivedData, .xcodeCache, .xcodeArchive, .deviceSupport, .simulatorCache, .oldXcode, .xcodeDownload]
        return items.filter { categories.contains($0.category) }
    }

    var oldFileItems: [ScanItem] {
        let categories: Set<ScanCategory> = [.diagnostics, .deviceBackup, .oldInstaller]
        return items.filter { categories.contains($0.category) }
    }

    nonisolated static func groups(of files: [DuplicateFile]) -> [DuplicateGroup] {
        Dictionary(grouping: files, by: \.fingerprint)
            .map { DuplicateGroup(id: $0.key, files: $0.value.sorted { $0.url.path < $1.url.path }) }
            .filter { $0.files.count > 1 }
            .sorted { $0.reclaimableSize != $1.reclaimableSize ? $0.reclaimableSize > $1.reclaimableSize : $0.id < $1.id }
    }

    func prepareAllDuplicateRemoval() {
        guard duplicateState != .loading else { return }
        let extras = DuplicateSelection.extras(in: duplicateFiles)
        selectionBeforeRemoveAll = Dictionary(uniqueKeysWithValues: duplicateFiles.map { ($0.id, $0.isSelected) })
        var updated = duplicateFiles
        for index in updated.indices { updated[index].isSelected = extras.contains(updated[index].id) }
        duplicateFiles = updated
        confirmsDuplicateRemoval = !extras.isEmpty
        duplicateConfirmation = CleanupConfirmation.forDuplicates(duplicateRemovalPlan)
    }

    /// Asks to move the current duplicate selection (minus the copy always kept in each group).
    func requestDuplicateRemoval() {
        guard duplicateState != .loading else { return }
        duplicateConfirmation = CleanupConfirmation.forDuplicates(duplicateRemovalPlan)
        confirmsDuplicateRemoval = duplicateConfirmation != nil
    }

    /// Cancelling Remove All puts back the selection the user had made by hand.
    func cancelDuplicateRemoval() {
        duplicateConfirmation = nil
        confirmsDuplicateRemoval = false
        guard let previous = selectionBeforeRemoveAll else { return }
        selectionBeforeRemoveAll = nil
        var restored = duplicateFiles
        for index in restored.indices { restored[index].isSelected = previous[restored[index].id] ?? false }
        duplicateFiles = restored
    }

    /// What a removal would actually move: the selection, minus one kept copy in any group where every copy
    /// is selected. Confirmations and totals use this, so they never count a copy that will be kept.
    var duplicateRemovalPlan: [DuplicateFile] {
        let kept = Set(duplicateGroups.filter { $0.files.allSatisfy(\.isSelected) }.compactMap { $0.files.first?.id })
        return duplicateFiles.filter { $0.isSelected && !kept.contains($0.id) }
    }

    var selectedDuplicateSize: Int64 {
        duplicateRemovalPlan.reduce(0) { $0 + $1.estimatedDiskBytes }
    }

    var selectedApplicationsSize: Int64 {
        applications.filter(\.isSelected).reduce(0) { $0 + $1.totalSize }
    }

    func startScan() {
        guard authorize("scan", retry: { [weak self] in self?.startScan() }) else { return }
        guard state != .scanning && state != .cleaning else { return }
        let (id, cancellation) = basicRun.begin()
        state = .scanning
        lastCleanup = nil
        scanWarning = nil
        let includeLargeFiles = includeLargeFiles
        let services = services

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { services.basicScan(includeLargeFiles, cancellation) }
            guard basicRun.finish(id) else { return }
            switch result {
            case .success(let outcome):
                items = outcome.items
                scanWarning = outcome.warning
                lastScanIncludedLargeFiles = includeLargeFiles
                state = .finished
            case .failure(let failure):
                state = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    struct PendingCleanup: Equatable {
        let itemIDs: Set<UUID>
        let count: Int
        let bytes: Int64
    }
    @Published var pendingCleanup: PendingCleanup?

    /// Prepare a confirmation for the selected items among `itemIDs` (the items visible on the page).
    /// `hiddenBySearch` is how many other selected items on the page the search filter hides; they are not included.
    func requestCleanup(itemIDs: Set<UUID>, source: String = "Cleanup", hiddenBySearch: Int = 0) {
        let selected = items.filter { $0.isSelected && itemIDs.contains($0.id) }
        guard !selected.isEmpty, state != .cleaning, state != .scanning else { return }
        pendingCleanup = PendingCleanup(itemIDs: Set(selected.map(\.id)), count: selected.count,
                                        bytes: selected.reduce(0) { $0 + $1.size })
        pendingConfirmation = CleanupConfirmation.forScanItems(selected, source: source, hiddenBySearch: hiddenBySearch)
        pendingSource = source
    }
    private var pendingSource = "Cleanup"

    func cancelCleanup() {
        pendingCleanup = nil
        pendingConfirmation = nil
    }

    func confirmCleanup() {
        guard let pending = pendingCleanup else { return }
        pendingCleanup = nil
        pendingConfirmation = nil
        cleanSelected(itemIDs: pending.itemIDs, source: pendingSource)
    }

    func cleanSelected(itemIDs: Set<UUID>? = nil, source: String = "Cleanup") {
        let selectedItems = items.filter { item in
            item.isSelected && (itemIDs?.contains(item.id) ?? true)
        }
        guard !selectedItems.isEmpty, state != .cleaning, state != .scanning else { return }
        state = .cleaning
        let trashItem = services.trashItem

        Task {
            // SafeCleaner checks every item again (path, links, dates, content) and skips what changed.
            let result = await BackgroundWork.run(qos: .userInitiated) {
                SafeCleaner().clean(selectedItems, trashItem: trashItem)
            }
            items.removeAll { result.removedItemIDs.contains($0.id) }
            lastCleanup = result
            state = .finished
            recordCleanup(source, selectedItems.map { ($0.id, $0.url, $0.size) }, result)
            showCleanupOutcome(removedCount: result.removedCount, bytes: result.reclaimedBytes, issues: result.issues)
        }
    }

    func setSelection(_ selected: Bool, for category: ScanCategory) {
        for index in items.indices where items[index].category == category {
            items[index].isSelected = selected
        }
    }

    func loadApplications(force: Bool = false) {
        guard authorize("applications", retry: { [weak self] in self?.loadApplications(force: force) }) else { return }
        // Gate on whether a scan ran, not on emptiness: an empty result must not rescan on every visit.
        guard force || applicationState == .idle else { return }
        guard applicationState != .loading else { return }
        let (id, cancellation) = applicationsRun.begin()
        applicationState = .loading
        let services = services

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { services.applications(cancellation) }
            guard applicationsRun.finish(id) else { return }
            switch result {
            case .success(let results):
                applications = results
                applicationState = .ready
                appInsights.load(paths: results.map(\.url.path))
            case .failure(let failure):
                applicationState = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    func findDuplicates(force: Bool = false) {
        guard authorize("duplicates", retry: { [weak self] in self?.findDuplicates(force: force) }) else { return }
        // "No duplicates" is a normal result; revisiting the page must not start another full hash pass.
        guard force || duplicateState == .idle else { return }
        guard duplicateState != .loading else { return }
        let (id, cancellation) = duplicatesRun.begin()
        duplicateState = .loading
        duplicateWarning = nil
        let services = services

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { services.duplicates(cancellation) }
            guard duplicatesRun.finish(id) else { return }
            switch result {
            case .success(let report):
                selectionBeforeRemoveAll = nil
                duplicateFiles = report.items
                duplicateWarning = report.warning(purpose: "checked for duplicates")
                duplicateState = .ready
            case .failure(let failure):
                duplicateState = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    func analyzeStorage(force: Bool = false) {
        guard authorize("storage", retry: { [weak self] in self?.analyzeStorage(force: force) }) else { return }
        guard force || diskMap == nil else { return }
        guard storageState != .loading else { return }
        let (id, cancellation) = storageRun.begin()
        storageState = .loading
        storageStarted = Date()
        let services = services

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { services.storage(cancellation) }
            guard storageRun.finish(id) else { return }
            storageStarted = nil
            switch result {
            case .success(let report):
                diskMap = report
                storageState = .ready
            case .failure(let failure):
                storageState = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    func loadStartupItems(force: Bool = false) {
        guard authorize("startup", retry: { [weak self] in self?.loadStartupItems(force: force) }) else { return }
        guard force || startupState == .idle else { return }
        guard startupState != .loading else { return }
        let (id, cancellation) = startupRun.begin()
        startupState = .loading
        let services = services

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { services.startupItems(cancellation) }
            guard startupRun.finish(id) else { return }
            switch result {
            case .success(let results):
                startupEntries = results
                startupState = .ready
            case .failure(let failure):
                startupState = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
    }

    // MARK: Cancellation

    /// Stops one scan's workers at once. Results from an earlier finished scan stay on screen.
    func cancelBasicScan() { if basicRun.cancel() { state = .cancelled } }
    func cancelDuplicates() { if duplicatesRun.cancel() { duplicateState = .cancelled } }
    func cancelApplications() {
        if applicationsRun.cancel() { applicationState = .cancelled }
        appInsights.cancel()
    }
    func cancelStorage() {
        if storageRun.cancel() { storageState = .cancelled; storageStarted = nil }
    }
    func cancelStartupItems() { if startupRun.cancel() { startupState = .cancelled } }
    func cancelSystemData() { if systemDataRun.cancel() { systemDataState = .cancelled } }

    /// Every scan that can be running, for Cancel in Deep Scan and for quitting.
    func cancelAllScans() {
        cancelBasicScan(); cancelDuplicates(); cancelApplications(); cancelStorage(); cancelStartupItems(); cancelSystemData()
        artifacts.cancel(); startupAudit.cancel(); orphans.cancel()
        deferredScans = [:]
        if case .waiting = gateNotice?.kind { gateNotice = nil }
    }

    // MARK: Cleanup

    func setApplicationSelection(_ selected: Bool, id: UUID) {
        guard let index = applications.firstIndex(where: { $0.id == id }), applications[index].canRemove,
              applications[index].removalNote == nil else { return }
        applications[index].isSelected = selected
    }

    func setDuplicateSelection(_ selected: Bool, id: UUID) {
        guard let index = duplicateFiles.firstIndex(where: { $0.id == id }) else { return }
        duplicateFiles[index].isSelected = selected
    }

    func removeSelectedApplications() {
        applicationConfirmation = nil
        let selected = applications.filter(\.isSelected)
        guard !selected.isEmpty, applicationState != .loading else { return }
        applicationState = .loading
        let uninstaller = ApplicationUninstaller(trashItem: services.trashItem)

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { uninstaller.remove(selected) }
            applications.removeAll { result.removedIDs.contains($0.id) }
            applicationState = .ready
            recordCleanup("Applications", selected.map { ($0.id, $0.url, $0.totalSize) },
                          CleanupResult(removedCount: result.removedIDs.count, reclaimedBytes: result.reclaimedBytes,
                                        failures: result.failures, removedItemIDs: result.removedIDs, issues: result.issues))
            showCleanupOutcome(removedCount: result.removedIDs.count, bytes: result.reclaimedBytes, issues: result.issues)
        }
    }

    func removeSelectedDuplicates() {
        guard duplicateState != .loading else { return }
        selectionBeforeRemoveAll = nil
        duplicateConfirmation = nil
        confirmsDuplicateRemoval = false
        // Preserve one copy even if every checkbox in a group was selected (the same rule as the confirmation).
        let plan = Set(duplicateRemovalPlan.map(\.id))
        var adjusted = duplicateFiles
        for index in adjusted.indices where adjusted[index].isSelected && !plan.contains(adjusted[index].id) {
            adjusted[index].isSelected = false
        }
        duplicateFiles = adjusted
        let selected = duplicateFiles.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        duplicateState = .loading
        let snapshot = duplicateFiles
        let trashItem = services.trashItem
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DuplicateCleaner().clean(snapshot, trashItem: trashItem)
            }
            recordCleanup("Duplicates", selected.map { ($0.id, $0.url, $0.estimatedDiskBytes) }, result)
            finishDuplicateCleanup(result)
        }
    }
    func finishDuplicateCleanup(_ result: CleanupResult) {
        duplicateFiles.removeAll { result.removedItemIDs.contains($0.id) }
        duplicateState = .ready
        showCleanupOutcome(removedCount: result.removedCount, bytes: result.reclaimedBytes, issues: result.issues)
    }

    func showCleanupOutcome(removedCount: Int, bytes: Int64, issues: [CleanupIssue]) {
        operationIssues = issues
        cleanupOutcome = CleanupOutcome(date: Date(), movedCount: removedCount, movedBytes: bytes, issues: issues)
        let moved = "Moved \(removedCount) item(s) (\(bytes.formattedBytes)) to Trash. Disk space is released when Trash is emptied."
        operationMessage = moved + (issues.isEmpty ? "" : "\n\n" + CleanupIssue.summary(issues))
    }

    func reviewCleanupDetails() {
        operationMessage = nil
        Task { @MainActor in
            await Task.yield()
            showsCleanupDetails = true
        }
    }

    func reviewCleanupPermissions() {
        showsCleanupDetails = false
        operationMessage = nil
        access.cleanupContext = operationIssues.filter(\.needsAccess)
        // The cleanup explanation and App Management link are shown on these steps only.
        access.step = access.hasCompletedChecks ? .review : .diskAccess
        // Dismiss the result alert before presenting the permissions sheet.
        Task { @MainActor in
            await Task.yield()
            access.presented = true
        }
    }
}
