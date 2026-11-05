import Foundation

@MainActor
final class AppModel: ObservableObject {
    let access = AccessSetupModel()
    lazy var optimizer: OptimizerModel = {
        let optimizer = OptimizerModel()
        optimizer.onOutcome = { [weak self] outcome in
            self?.cleanupOutcome = outcome
            self?.operationIssues = outcome.issues
        }
        // Optimize maps the whole disk too; share the result with the Storage Map.
        optimizer.onDiskMap = { [weak self] report in
            self?.diskMap = report
            self?.storageState = .ready
        }
        return optimizer
    }()
    let memory = MemoryMonitor()
    let updates = UpdateChecker()
    @Published var destination: SidebarDestination = .overview
    @Published var state: ScanState = .idle
    @Published var items: [ScanItem] = []
    @Published var lastCleanup: CleanupResult?
    /// Set when some scan sections could not be read; the other results are still shown.
    @Published var scanWarning: String?
    @Published var includeLargeFiles = true
    @Published var applications: [ApplicationItem] = []
    @Published var applicationState: ModuleState = .idle
    @Published var duplicateFiles: [DuplicateFile] = []
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
    @Published var systemDataLoading = false
    @Published var dockerCleaning = false
    @Published var confirmsDockerCleanup = false
    @Published var dockerCleanupMessage: String?

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
            analyzeSystemData()
        }
    }

    func analyzeSystemData() {
        guard !systemDataLoading, !dockerCleaning else { return }
        systemDataLoading = true
        Task {
            let report = await BackgroundWork.run(qos: .utility) {
                SystemDataScanner().scan()
            }
            systemDataReport = report
            systemDataLoading = false
        }
    }

    private let scanner = DiskScanner()
    private let cleaner = SafeCleaner()
    private let applicationScanner = ApplicationScanner()
    private let duplicateScanner = DuplicateScanner()
    private let startupScanner = StartupScanner()
    private let applicationUninstaller = ApplicationUninstaller()

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

    var duplicateGroups: [DuplicateGroup] {
        Dictionary(grouping: duplicateFiles, by: \.fingerprint)
            .map { DuplicateGroup(id: $0.key, files: $0.value) }
            .filter { $0.files.count > 1 }
            .sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    func prepareAllDuplicateRemoval() {
        guard duplicateState != .loading else { return }
        let extras = DuplicateSelection.extras(in: duplicateFiles)
        for index in duplicateFiles.indices {
            duplicateFiles[index].isSelected = extras.contains(duplicateFiles[index].id)
        }
        confirmsDuplicateRemoval = !extras.isEmpty
    }

    var selectedDuplicateSize: Int64 {
        duplicateFiles.filter(\.isSelected).reduce(0) { $0 + $1.estimatedDiskBytes }
    }

    var selectedApplicationsSize: Int64 {
        applications.filter(\.isSelected).reduce(0) { $0 + $1.totalSize }
    }

    func startScan() {
        guard state != .scanning && state != .cleaning else { return }
        state = .scanning
        lastCleanup = nil
        scanWarning = nil

        Task {
            let includeLargeFiles = includeLargeFiles
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DiskScanService.scan(includeLargeFiles: includeLargeFiles)
            }
            switch result {
            case .success(let outcome):
                items = outcome.items
                scanWarning = outcome.warning
                state = .finished
            case .failure(let failure):
                state = .failed(failure.message)
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
    func requestCleanup(itemIDs: Set<UUID>) {
        let selected = items.filter { $0.isSelected && itemIDs.contains($0.id) }
        guard !selected.isEmpty, state != .cleaning, state != .scanning else { return }
        pendingCleanup = PendingCleanup(itemIDs: Set(selected.map(\.id)), count: selected.count,
                                        bytes: selected.reduce(0) { $0 + $1.size })
    }

    func cancelCleanup() {
        pendingCleanup = nil
    }

    func confirmCleanup() {
        guard let pending = pendingCleanup else { return }
        pendingCleanup = nil
        cleanSelected(itemIDs: pending.itemIDs)
    }

    func cleanSelected(itemIDs: Set<UUID>? = nil) {
        let selectedItems = items.filter { item in
            item.isSelected && (itemIDs?.contains(item.id) ?? true)
        }
        guard !selectedItems.isEmpty, state != .cleaning, state != .scanning else { return }
        state = .cleaning

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { [cleaner] in
                cleaner.clean(selectedItems)
            }
            items.removeAll { result.removedItemIDs.contains($0.id) }
            lastCleanup = result
            state = .finished
            showCleanupOutcome(removedCount: result.removedCount, bytes: result.reclaimedBytes, issues: result.issues)
        }
    }

    func setSelection(_ selected: Bool, for category: ScanCategory) {
        for index in items.indices where items[index].category == category {
            items[index].isSelected = selected
        }
    }

    func loadApplications(force: Bool = false) {
        guard force || applications.isEmpty else { return }
        guard applicationState != .loading else { return }
        applicationState = .loading

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DiskScanService.read(ApplicationItem.self, mode: "applications")
            }
            switch result {
            case .success(let results):
                applications = results
                applicationState = .ready
            case .failure(let failure):
                applicationState = .failed(failure.message)
            }
        }
    }

    func findDuplicates(force: Bool = false) {
        guard force || duplicateFiles.isEmpty else { return }
        guard duplicateState != .loading else { return }
        duplicateState = .loading
        duplicateWarning = nil

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DiskScanService.readValue(ScanReport<DuplicateFile>.self, mode: "duplicates")
            }
            switch result {
            case .success(let report):
                duplicateFiles = report.items
                duplicateWarning = report.warning(purpose: "checked for duplicates")
                duplicateState = .ready
            case .failure(let failure):
                duplicateState = .failed(failure.message)
            }
        }
    }

    func analyzeStorage(force: Bool = false) {
        guard force || diskMap == nil else { return }
        guard storageState != .loading else { return }
        storageState = .loading
        storageStarted = Date()

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { DiskMapService.scan() }
            storageStarted = nil
            switch result {
            case .success(let report):
                diskMap = report
                storageState = .ready
            case .failure(let failure):
                storageState = .failed(failure.message)
            }
        }
    }

    func loadStartupItems(force: Bool = false) {
        guard force || startupEntries.isEmpty else { return }
        guard startupState != .loading else { return }
        startupState = .loading

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DiskScanService.read(StartupEntry.self, mode: "startup")
            }
            switch result {
            case .success(let results):
                startupEntries = results
                startupState = .ready
            case .failure(let failure):
                startupState = .failed(failure.message)
            }
        }
    }

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
        let selected = applications.filter(\.isSelected)
        guard !selected.isEmpty, applicationState != .loading else { return }
        applicationState = .loading

        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { [applicationUninstaller] in
                applicationUninstaller.remove(selected)
            }
            applications.removeAll { result.removedIDs.contains($0.id) }
            applicationState = .ready
            showCleanupOutcome(removedCount: result.removedIDs.count, bytes: result.reclaimedBytes, issues: result.issues)
        }
    }

    func removeSelectedDuplicates() {
        guard duplicateState != .loading else { return }
        // Preserve one copy even if every checkbox in a group was selected.
        for group in duplicateGroups where group.files.allSatisfy(\.isSelected) {
            if let keeper = group.files.sorted(by: { $0.url.path < $1.url.path }).first {
                setDuplicateSelection(false, id: keeper.id)
            }
        }
        let selected = duplicateFiles.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        duplicateState = .loading
        let snapshot = duplicateFiles
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) {
                DuplicateCleaner().clean(snapshot)
            }
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
        // Dismiss the result alert before presenting the permissions sheet.
        Task { @MainActor in
            await Task.yield()
            access.presented = true
        }
    }

}
