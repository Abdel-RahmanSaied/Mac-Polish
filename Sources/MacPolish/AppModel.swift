import Foundation

@MainActor
final class AppModel: ObservableObject {
    let optimizer = OptimizerModel()
    @Published var destination: SidebarDestination = .overview
    @Published var state: ScanState = .idle
    @Published var items: [ScanItem] = []
    @Published var lastCleanup: CleanupResult?
    @Published var includeLargeFiles = true
    @Published var applications: [ApplicationItem] = []
    @Published var applicationState: ModuleState = .idle
    @Published var duplicateFiles: [DuplicateFile] = []
    @Published var duplicateState: ModuleState = .idle
    @Published var storageEntries: [StorageEntry] = []
    @Published var storageState: ModuleState = .idle
    @Published var startupEntries: [StartupEntry] = []
    @Published var startupState: ModuleState = .idle
    @Published var operationMessage: String?
    @Published var applicationSearchText = ""
    @Published var confirmsApplicationRemoval = false
    @Published var confirmsDuplicateRemoval = false
    @Published var systemDataReport: SystemDataReport?
    @Published var systemDataLoading = false
    @Published var dockerCleaning = false
    @Published var confirmsDockerCleanup = false
    @Published var dockerCleanupMessage: String?

    func cleanDockerBuildCache() {
        guard !dockerCleaning, !systemDataLoading else { return }
        dockerCleaning = true
        dockerCleanupMessage = nil
        Task {
            let message = await Task.detached(priority: .utility) {
                SystemDataScanner.cleanDockerBuildCache()
            }.value
            dockerCleanupMessage = message
            dockerCleaning = false
            analyzeSystemData()
        }
    }

    func analyzeSystemData() {
        guard !systemDataLoading, !dockerCleaning else { return }
        systemDataLoading = true
        Task {
            let report = await Task.detached(priority: .utility) {
                SystemDataScanner().scan()
            }.value
            systemDataReport = report
            systemDataLoading = false
        }
    }

    private let scanner = DiskScanner()
    private let cleaner = SafeCleaner()
    private let applicationScanner = ApplicationScanner()
    private let duplicateScanner = DuplicateScanner()
    private let storageScanner = StorageScanner()
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
        duplicateFiles.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var selectedApplicationsSize: Int64 {
        applications.filter(\.isSelected).reduce(0) { $0 + $1.totalSize }
    }

    func startScan() {
        guard state != .scanning && state != .cleaning else { return }
        state = .scanning
        lastCleanup = nil

        Task {
            let includeLargeFiles = includeLargeFiles
            let results = await Task.detached(priority: .userInitiated) { [scanner] in
                scanner.scan(includeLargeFiles: includeLargeFiles)
            }.value
            items = results
            state = .finished
        }
    }

    func cleanSelected(itemIDs: Set<UUID>? = nil) {
        let selectedItems = items.filter { item in
            item.isSelected && (itemIDs?.contains(item.id) ?? true)
        }
        guard !selectedItems.isEmpty, state != .cleaning else { return }
        state = .cleaning

        Task {
            let result = await Task.detached(priority: .userInitiated) { [cleaner] in
                cleaner.clean(selectedItems)
            }.value
            items.removeAll { result.removedItemIDs.contains($0.id) }
            lastCleanup = result
            state = .finished
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
            let results = await Task.detached(priority: .userInitiated) { [applicationScanner] in
                applicationScanner.scan()
            }.value
            applications = results
            applicationState = .ready
        }
    }

    func findDuplicates(force: Bool = false) {
        guard force || duplicateFiles.isEmpty else { return }
        guard duplicateState != .loading else { return }
        duplicateState = .loading

        Task {
            let results = await Task.detached(priority: .userInitiated) { [duplicateScanner] in
                duplicateScanner.scan()
            }.value
            duplicateFiles = results
            duplicateState = .ready
        }
    }

    func analyzeStorage(force: Bool = false) {
        guard force || storageEntries.isEmpty else { return }
        guard storageState != .loading else { return }
        storageState = .loading

        Task {
            let results = await Task.detached(priority: .userInitiated) { [storageScanner] in
                storageScanner.scan()
            }.value
            storageEntries = results
            storageState = .ready
        }
    }

    func loadStartupItems(force: Bool = false) {
        guard force || startupEntries.isEmpty else { return }
        guard startupState != .loading else { return }
        startupState = .loading

        Task {
            let results = await Task.detached(priority: .userInitiated) { [startupScanner] in
                startupScanner.scan()
            }.value
            startupEntries = results
            startupState = .ready
        }
    }

    func setApplicationSelection(_ selected: Bool, id: UUID) {
        guard let index = applications.firstIndex(where: { $0.id == id }), applications[index].canRemove else { return }
        applications[index].isSelected = selected
    }

    func setDuplicateSelection(_ selected: Bool, id: UUID) {
        guard let index = duplicateFiles.firstIndex(where: { $0.id == id }) else { return }
        duplicateFiles[index].isSelected = selected
    }

    func removeSelectedApplications() {
        let selected = applications.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        applicationState = .loading

        Task {
            let result = await Task.detached(priority: .userInitiated) { [applicationUninstaller] in
                applicationUninstaller.remove(selected)
            }.value
            applications.removeAll { result.removedIDs.contains($0.id) }
            applicationState = .ready
            operationMessage = result.failures.isEmpty
                ? "Moved \(result.removedIDs.count) application(s) to Trash and reclaimed \(result.reclaimedBytes.formattedBytes)."
                : "Completed with \(result.failures.count) issue(s): \(result.failures.prefix(2).joined(separator: " · "))"
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
        let scanItems = selected.map {
            ScanItem(id: $0.id, url: $0.url, size: $0.size, category: .largeFile, modifiedAt: nil, isSelected: true)
        }

        Task {
            let result = await Task.detached(priority: .userInitiated) { [cleaner] in
                cleaner.clean(scanItems)
            }.value
            duplicateFiles.removeAll { result.removedItemIDs.contains($0.id) }
            duplicateState = .ready
            operationMessage = result.failures.isEmpty
                ? "Moved \(result.removedCount) duplicate(s) (\(result.reclaimedBytes.formattedBytes)) to Trash. Disk space is released when Trash is emptied."
                : "Completed with \(result.failures.count) issue(s): \(result.failures.prefix(2).joined(separator: " · "))"
        }
    }
}
