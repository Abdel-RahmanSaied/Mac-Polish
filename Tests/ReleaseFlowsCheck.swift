import Darwin
import Foundation

/// Critical release flows through the real models with injected permissions, scanners and Trash: permission
/// granted, denied, a review already open in Settings, closed early; duplicate-scan prevention; Deep Scan start,
/// cancel and restart; mixed success, failure and cancellation; stale results; selection and cleanup; changed items;
/// large lists and every page state; worker cancellation and parent-death cleanup. No real file is moved and no
/// real worker process is started for a scan.
@main
enum ReleaseFlowsCheck {
    @MainActor static func main() async throws {
        // A child copy of this binary: watch the parent like a scan worker does, then wait (bounded).
        if CommandLine.arguments.contains("--watch-parent-child") {
            ScanWorker.watchParent()
            Darwin.sleep(20)
            exit(0)
        }
        try await permissions()
        try await duplicatePrevention()
        try await deepScanLifecycle()
        try await mixedOutcomes()
        try await staleResults()
        try await cleanupFlows()
        try largeListsAndStates()
        try cancellationInfrastructure()
        try await historyStaysOutOfUserFile()
        print("PASS: permission granted/denied/open in Settings/closed early with clear notices and automatic start; repeated clicks start one scan; Deep Scan start, cancel (no stale loading), restart and complete; partial reports keep finished results; stale cancelled results never overwrite newer ones; hidden selections and cancelled confirmations keep selections; Trash moves remove rows and changed items/apps are skipped; 100k-item lists and every page state; cancellation ends worker processes at once, quitting ends them, and orphaned workers exit with their parent")
    }

    // MARK: Fakes

    /// A scan that runs until released or cancelled, counting how often it was started.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private(set) var starts = 0
        func release() { lock.lock(); open = true; lock.unlock() }
        func reset() { lock.lock(); open = false; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return starts }
        /// Blocks until released (returns true) or cancelled (returns false).
        func wait(_ cancellation: ScanCancellation) -> Bool {
            lock.lock(); starts += 1; lock.unlock()
            while true {
                if cancellation.isCancelled { return false }
                lock.lock(); let isOpen = open; lock.unlock()
                if isOpen { return true }
                usleep(2_000)
            }
        }
    }

    final class Trash: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL] = []
        func move(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var moved: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    struct Fakes {
        let basic = Gate(), duplicates = Gate(), applications = Gate(), storage = Gate(), startup = Gate()
        let systemData = Gate(), artifacts = Gate(), audit = Gate(), orphans = Gate()
        let trash = Trash()
        var duplicatesFail = false
        var storageIncomplete = false
        var scanItems: [ScanItem] = []
        var applicationItems: [ApplicationItem] = []

        var all: [Gate] { [basic, duplicates, applications, storage, startup, systemData, artifacts, audit, orphans] }
        func releaseAll() { all.forEach { $0.release() } }

        func services() -> ScanServices {
            let fakes = self
            func gated<T>(_ gate: Gate, _ value: @escaping @Sendable () -> Result<T, DiskScanFailure>) -> @Sendable (ScanCancellation) -> Result<T, DiskScanFailure> {
                { gate.wait($0) ? value() : .failure(.cancelledByUser) }
            }
            return ScanServices(
                basicScan: { _, cancellation in
                    fakes.basic.wait(cancellation) ? .success(DiskScanOutcome(items: fakes.scanItems, incomplete: [])) : .failure(.cancelledByUser)
                },
                duplicates: gated(duplicates) {
                    fakes.duplicatesFail ? .failure(DiskScanFailure(message: "Injected duplicate failure.")) : .success(ScanReport(items: [], deniedPaths: []))
                },
                applications: gated(applications) { .success(fakes.applicationItems) },
                storage: gated(storage) {
                    var tree = DiskTreeResult(root: DiskNode(name: "Data", kind: .folder, bytes: 1_000, files: 10))
                    if fakes.storageIncomplete { tree.root.unreadable = 3; tree.incomplete = true }
                    return .success(DiskMapReport(tree: tree, volumes: nil, reconciliation: nil, date: Date()))
                },
                startupItems: gated(startup) { .success([]) },
                systemData: { fakes.systemData.wait($0) ? SystemDataReport(areas: [], dockerOutput: "", date: Date()) : nil },
                artifacts: gated(artifacts) { .success(ScanReport(items: [], deniedPaths: [])) },
                toolchainCaches: { _ in [] },
                startupAudit: gated(audit) { .success(ScanReport(items: [], deniedPaths: [])) },
                orphans: gated(orphans) { .success(ScanReport(items: [], deniedPaths: [])) },
                appInsights: { _, _ in .success([]) },
                trashItem: { fakes.trash.move($0) })
        }
    }

    // MARK: Helpers

    static var suites: [String] = []

    @MainActor static func access(reviewed: Bool) -> AccessSetupModel {
        let suite = "MacPolish-release-" + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(reviewed, forKey: AccessSetupModel.reviewedKey)
        defaults.set(reviewed, forKey: AccessSetupModel.completedKey)
        return AccessSetupModel(defaults: defaults, probe: { .accessible }, copies: { [] })
    }

    /// Simulates the user finishing the folder checks: every location answered, some optionally restricted.
    @MainActor static func completeReview(_ access: AccessSetupModel, restricted: Set<String> = [], fullDiskAccess: FullDiskAccess = .accessible) {
        access.results = FolderAccessCheck.locations().map {
            FolderAccessResult(name: $0.0, url: $0.1, status: restricted.contains($0.0) ? .restricted : .readable)
        }
        access.checkedAt = Date()
        access.fullDiskAccess = fullDiskAccess
        access.finish()
    }

    @MainActor static func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            precondition(Date() < deadline, "timed out waiting for: \(what)")
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Permission flows

    @MainActor static func permissions() async throws {
        // Granted: waiting scans say so, then start by themselves once the review completes.
        do {
            let fakes = Fakes()
            let gate = access(reviewed: false)
            let app = AppModel(access: gate, services: fakes.services())
            app.findDuplicates()
            app.deepScan.start()
            precondition(app.duplicateState == .idle && !app.deepScan.running && gate.presented, "nothing starts before the review")
            guard case .waiting(.setup) = app.gateNotice?.kind else { preconditionFailure("a refused scan must explain itself: \(String(describing: app.gateNotice))") }
            precondition(app.gateNotice?.scans == ["Deep Scan", "Duplicates"], "the notice names every waiting scan")
            completeReview(gate)
            precondition(app.duplicateState == .loading && app.deepScan.running, "waiting scans start after the review")
            precondition(app.gateNotice == nil, "full access leaves nothing to explain")
            fakes.releaseAll()
            await eventually("deep scan finishes", timeout: 20) { !app.deepScan.running }
        }
        // Denied: scans start with limited access and say exactly what was not readable and how to grant it.
        do {
            let fakes = Fakes()
            let gate = access(reviewed: false)
            let app = AppModel(access: gate, services: fakes.services())
            app.startScan()
            completeReview(gate, restricted: ["Mail data", "Safari data"], fullDiskAccess: .restricted)
            precondition(app.state == .scanning, "a limited review still starts the scan")
            guard case .startedWithLimitedAccess(let restricted) = app.gateNotice?.kind else { preconditionFailure("limited access must be explained") }
            precondition(restricted == ["Mail data", "Safari data"], "names the locations that could not be read: \(restricted)")
            precondition(app.gateNotice!.message.contains("Full Disk Access") && app.gateNotice!.message.contains("Mail data"))
            fakes.releaseAll()
            await eventually("basic scan finishes") { app.state == .finished }
        }
        // A review already open in Settings: no second sheet, a clear wait message, automatic start afterwards.
        do {
            let fakes = Fakes()
            let gate = access(reviewed: true)
            let app = AppModel(access: gate, services: fakes.services())
            gate.showSettings()
            app.analyzeStorage()
            precondition(app.storageState == .idle && !gate.presented, "no second review sheet over the main window")
            guard case .waiting(.settings) = app.gateNotice?.kind else { preconditionFailure("must say the review is open in Settings: \(String(describing: app.gateNotice))") }
            precondition(app.gateNotice!.message.contains("Settings"))
            completeReview(gate)
            precondition(app.storageState == .loading, "the waiting scan starts when the Settings review finishes")
            fakes.storage.release()
            await eventually("storage finishes") { app.storageState == .ready }
        }
        // Closed before finishing: the scans did not start, and the notice says why; nothing runs later by surprise.
        do {
            let fakes = Fakes()
            let gate = access(reviewed: false)
            let app = AppModel(access: gate, services: fakes.services())
            app.findDuplicates()
            gate.presented = false
            guard case .notStarted = app.gateNotice?.kind else { preconditionFailure("closing early must be explained") }
            completeReview(gate)
            precondition(app.duplicateState == .idle && fakes.duplicates.count == 0, "an abandoned request does not start later")
        }
    }

    @MainActor static func duplicatePrevention() async throws {
        let fakes = Fakes()
        let gate = access(reviewed: false)
        let app = AppModel(access: gate, services: fakes.services())
        for _ in 0..<5 { app.startScan(); app.deepScan.start(); app.findDuplicates(force: true) }
        precondition(app.gateNotice?.scans == ["Deep Scan", "Duplicates", "Scan My Mac"], "each scan waits once")
        completeReview(gate)
        // Clicks while running and repeated permission changes add nothing.
        for _ in 0..<5 { app.startScan(); app.deepScan.start(); app.findDuplicates(); gate.onFinish?() }
        let steps = app.deepScan.steps.count
        await eventually("all fake scans started") { fakes.basic.count >= 1 && fakes.duplicates.count >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        precondition(fakes.basic.count == 1 && fakes.duplicates.count == 1, "one scan each: basic \(fakes.basic.count), duplicates \(fakes.duplicates.count)")
        precondition(app.deepScan.steps.count == steps, "Deep Scan did not restart while running")
        fakes.releaseAll()
        await eventually("deep scan finishes", timeout: 20) { !app.deepScan.running }
    }

    // MARK: Deep Scan

    /// Deep Scan with every step except Mac health (real, read-only readings that need no fakes).
    @MainActor static func deepScanApp(_ fakes: Fakes) -> AppModel {
        let app = AppModel(access: access(reviewed: true), services: fakes.services())
        app.deepScan.runnersOverride = { DeepScanModel.coreRunners($0).filter { $0.id != "health" } }
        return app
    }

    @MainActor static func deepScanLifecycle() async throws {
        let fakes = Fakes()
        let app = deepScanApp(fakes)
        precondition(app.deepScan.overall == .notStarted)
        app.deepScan.start()
        await eventually("every step running") { app.deepScan.steps.allSatisfy { $0.status == .running } }
        precondition(app.deepScan.overall == .scanning && app.storageState == .loading && app.artifacts.state == .loading)
        let started = Date()
        app.deepScan.cancel()
        await eventually("cancel finishes", timeout: 2) { !app.deepScan.running }
        precondition(Date().timeIntervalSince(started) < 1, "cancel is prompt")
        precondition(app.deepScan.overall == .cancelled && app.deepScan.steps.allSatisfy { $0.status == .cancelled },
                     "every step shows Cancelled: \(app.deepScan.steps.map(\.status))")
        // No stale loading indicators anywhere.
        precondition(app.state == .cancelled && app.duplicateState == .cancelled && app.applicationState == .cancelled
                     && app.storageState == .cancelled && app.storageStarted == nil && app.systemDataState == .cancelled
                     && app.artifacts.state == .cancelled && app.startupAudit.state == .cancelled && app.orphans.state == .cancelled,
                     "every page leaves its loading state")
        precondition(app.deepScan.report(.full).contains("Status: Cancelled"), "a cancelled report says so")
        // Restart, then complete.
        fakes.all.forEach { $0.reset() }
        app.deepScan.start()
        precondition(app.deepScan.running && app.deepScan.overall == .scanning && !app.deepScan.cancelledByUser)
        fakes.releaseAll()
        await eventually("restarted deep scan completes") { !app.deepScan.running }
        precondition(app.deepScan.overall == .completed, "all steps done: \(app.deepScan.steps.map(\.status))")
        precondition(!app.deepScan.isPartialReport && app.deepScan.report(.full).contains("Status: Completed"))
    }

    @MainActor static func mixedOutcomes() async throws {
        var fakes = Fakes()
        fakes.duplicatesFail = true
        fakes.storageIncomplete = true
        fakes.scanItems = [ScanItem(url: URL(fileURLWithPath: "/tmp/found-cache"), size: 10, category: .cache, modifiedAt: nil)]
        let app = deepScanApp(fakes)
        app.deepScan.start()
        await eventually("steps running") { app.deepScan.steps.allSatisfy { $0.status == .running } }
        fakes.basic.release(); fakes.duplicates.release(); fakes.storage.release(); fakes.applications.release()
        await eventually("released steps settle") { app.state == .finished && app.duplicateState != .loading && app.storageState == .ready }
        app.orphans.cancel()   // one scanner cancelled on its own
        fakes.releaseAll()
        await eventually("deep scan settles") { !app.deepScan.running }
        func status(_ id: String) -> DeepScanModel.Step.Status? { app.deepScan.steps.first { $0.id == id }?.status }
        guard case .failed = status("duplicates") else { preconditionFailure("failed step") }
        guard case .partial = status("storage") else { preconditionFailure("incomplete storage is partial, not done: \(String(describing: status("storage")))") }
        precondition(status("cleanup") == .done && status("orphans") == .cancelled)
        precondition(app.deepScan.overall == .partial && app.deepScan.isPartialReport)
        precondition(app.items.count == 1, "finished results are kept when other steps fail or are cancelled")
        let report = app.deepScan.report(.full)
        precondition(report.contains("Status: Partially completed") && report.contains("This report is partial")
                     && report.contains("Failed: Injected duplicate failure.") && report.contains("Cancelled"))

        // Privacy-safe export: identifying paths and names are gone, totals and states stay.
        let identity = ReportRedactor.Identity.current()
        let secretPath = identity.home + "/Projects/acme-secret-launch/build/keynote-final.mov"
        var insights = DiskInsights()
        insights.largestFiles = [DiskInsights.LargeFile(path: secretPath, bytes: 7_000_000_000, modified: nil, kind: .video)]
        insights.kinds = [.video: DiskInsights.Total(bytes: 7_000_000_000, files: 1)]
        var tree = DiskTreeResult(root: DiskNode(name: "Data", kind: .folder, bytes: 7_000_000_000, files: 1))
        tree.insights = insights
        app.diskMap = DiskMapReport(tree: tree, volumes: nil, reconciliation: nil, date: Date())
        let full = app.deepScan.report(.full), safe = app.deepScan.report(.privacySafe)
        precondition(full.contains(secretPath), "the full report keeps paths")
        for secret in [identity.home, identity.userName, "acme-secret-launch", "keynote-final"] where !secret.isEmpty {
            precondition(!safe.localizedCaseInsensitiveContains(secret), "the privacy-safe report must not contain \(secret)")
        }
        precondition(safe.contains("Status: Partially completed") && safe.contains(Int64(7_000_000_000).formattedBytes)
                     && safe.contains("Failed: Injected duplicate failure."), "totals and diagnostic states are kept")
        precondition(!safe.contains("Paths and file names are included"), "the safe report does not claim to include paths")
    }

    /// A cancelled run's late result never replaces a newer run's state.
    @MainActor static func staleResults() async throws {
        var services = Fakes().services()
        services.duplicates = { cancellation in
            // The run that is already cancelled when its reader starts ignores that and answers late with a result,
            // like a worker stuck in a system call. Keyed on the run's own token, not on call order: two runs'
            // readers dispatched together may execute in either order.
            if cancellation.isCancelled {
                Thread.sleep(forTimeInterval: 0.3)
                return .success(ScanReport(items: [DuplicateFile(id: UUID(), url: URL(fileURLWithPath: "/old"), size: 1, fingerprint: "a", isSelected: false),
                                                   DuplicateFile(id: UUID(), url: URL(fileURLWithPath: "/old2"), size: 1, fingerprint: "a", isSelected: false)],
                                           deniedPaths: []))
            }
            while !cancellation.isCancelled { usleep(2_000) }
            return .failure(.cancelledByUser)
        }
        let app = AppModel(access: access(reviewed: true), services: services)
        app.findDuplicates(force: true)
        app.cancelDuplicates()
        precondition(app.duplicateState == .cancelled, "cancel updates the page at once")
        app.findDuplicates(force: true)
        // Both readers have run by now: the cancelled one answered after 0.3 s, the current one is still waiting.
        try? await Task.sleep(for: .milliseconds(600))
        precondition(app.duplicateState == .loading && app.duplicateFiles.isEmpty, "the cancelled run's late answer is dropped")
        app.cancelDuplicates()
        await eventually("second run cancelled") { app.duplicateState == .cancelled }
    }

    // MARK: Cleanup

    @MainActor static func cleanupFlows() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-release-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ name: String) throws -> ScanItem {
            let url = root.appending(path: name)
            try Data(repeating: 1, count: 4_096).write(to: url)
            let modified = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            return ScanItem(url: url, size: 4_096, category: .cache, modifiedAt: modified, isSelected: true)
        }
        let fakes = Fakes()
        let app = AppModel(access: access(reviewed: true), services: fakes.services())
        // History goes to a temporary file, never the real one.
        let historyURL = root.appending(path: "history.json")
        app.cleanupHistory = CleanupHistoryModel(store: CleanupHistoryStore(url: historyURL))
        let visible = try file("visible.cache"), hidden = try file("hidden.cache"), changed = try file("changed.cache")
        app.items = [visible, hidden, changed]
        // Only the visible selection is offered; the hidden one stays selected and untouched, and the sheet says so.
        app.requestCleanup(itemIDs: [visible.id, changed.id], source: "Cleanup", hiddenBySearch: 1)
        precondition(app.pendingCleanup?.count == 2 && app.pendingCleanup?.bytes == 8_192)
        guard let sheet = app.pendingConfirmation else { preconditionFailure("a confirmation is shown") }
        precondition(sheet.count == 2 && sheet.bytes == 8_192 && sheet.hiddenBySearch == 1 && sheet.itemIDs == [visible.id, changed.id]
                     && !sheet.groups.isEmpty && sheet.groups.allSatisfy { !$0.reason.isEmpty } && sheet.names.count == 2,
                     "the confirmation lists names, count, size, hidden items and why each category is suggested")
        app.cancelCleanup()
        precondition(app.pendingConfirmation == nil && app.items.allSatisfy(\.isSelected) && fakes.trash.moved.isEmpty,
                     "cancelling a confirmation keeps every selection")
        // An item edited after the scan is skipped with a reason instead of moved.
        try? await Task.sleep(for: .milliseconds(1_100))
        try Data(repeating: 2, count: 8_192).write(to: changed.url)
        app.requestCleanup(itemIDs: [visible.id, changed.id])
        app.confirmCleanup()
        await eventually("cleanup finishes") { app.state == .finished }
        precondition(fakes.trash.moved == [visible.url], "only the unchanged visible item moves: \(fakes.trash.moved)")
        precondition(!app.items.contains { $0.id == visible.id }, "moved items leave the list")
        precondition(app.items.contains { $0.id == changed.id } && app.items.contains { $0.id == hidden.id && $0.isSelected },
                     "skipped and hidden items stay, with their selection")
        precondition(app.operationIssues.contains { $0.url == changed.url && $0.kind == .changed }, "the change is explained")
        let history = app.cleanupHistory.records
        precondition(history.count == 1 && history[0].source == "Cleanup" && history[0].moved.map(\.path) == [visible.url.path]
                     && history[0].moved.first?.bytes == 4_096 && history[0].skipped.map(\.path) == [changed.url.path]
                     && history[0].skipped.first?.reason?.isEmpty == false && !history[0].permanent,
                     "history records what moved with sizes, what was skipped with the reason, and the source: \(history)")
        let onDisk = try String(contentsOf: historyURL, encoding: .utf8)
        precondition(onDisk.contains("visible.cache") && !onDisk.contains(String(repeating: "\u{1}", count: 8)), "history holds paths, not contents")

        // An app updated after the scan is skipped, not removed.
        let apps = root.appending(path: "Apps")
        let bundle = apps.appending(path: "Tool.app/Contents")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        func plist(version: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.tool", "CFBundleShortVersionString": version],
                                               format: .xml, options: 0).write(to: bundle.appending(path: "Info.plist"))
        }
        try plist(version: "1.0")
        let item = ApplicationItem(id: UUID(), name: "Tool", url: apps.appending(path: "Tool.app"), bundleIdentifier: "com.example.tool",
                                   version: "1.0", size: 10, leftoverURLs: [], leftoverSize: 0, canRemove: true, isSelected: true)
        let trash = Trash()
        let uninstaller = ApplicationUninstaller(applicationRoots: [apps], trashItem: { trash.move($0) })
        try plist(version: "2.0")
        let updated = uninstaller.remove([item])
        precondition(updated.removedIDs.isEmpty && trash.moved.isEmpty && updated.issues.first?.kind == .changed, "an updated app is skipped")
        try plist(version: "1.0")
        precondition(uninstaller.remove([item]).removedIDs == [item.id] && trash.moved == [item.url], "the unchanged app moves")

        // Duplicates: the confirmation counts only what moves; cancelling Remove All restores the hand-made selection.
        let a = try file("dup-a.bin"), b = try file("dup-b.bin")
        let digest = try FileFingerprint.sha256(a.url)
        app.duplicateFiles = [DuplicateFile(id: UUID(), url: a.url, size: 4_096, fingerprint: digest, isSelected: true),
                              DuplicateFile(id: UUID(), url: b.url, size: 4_096, fingerprint: digest, isSelected: true)]
        app.duplicateState = .ready
        app.requestDuplicateRemoval()
        precondition(app.duplicateConfirmation?.count == 1 && app.duplicateConfirmation?.bytes == 4_096, "the kept copy is not counted")
        app.cancelDuplicateRemoval()
        precondition(app.duplicateConfirmation == nil && app.duplicateFiles.allSatisfy(\.isSelected), "cancel keeps the selection")
        app.prepareAllDuplicateRemoval()
        app.cancelDuplicateRemoval()
        precondition(app.duplicateFiles.allSatisfy(\.isSelected), "cancelling Remove All restores the previous selection")
        app.requestDuplicateRemoval()
        app.removeSelectedDuplicates()
        await eventually("duplicate cleanup") { app.duplicateState == .ready }
        precondition(fakes.trash.moved.last == b.url && app.duplicateFiles.count == 1 && app.duplicateFiles[0].url == a.url,
                     "one copy moves, the first is kept and the moved row leaves the list")
        precondition(app.cleanupHistory.records.count == 2 && app.cleanupHistory.records.contains { $0.source == "Duplicates" && $0.moved.map(\.path) == [b.url.path] },
                     "duplicate cleanups are recorded: \(app.cleanupHistory.records.map(\.source))")

        // Low-confidence items are never preselected, whatever the scanner sent.
        let orphanModel = OrphanedDataModel()
        let preselected = OrphanedDataItem(id: UUID(), url: root.appending(path: "com.gone.app"), bundleIdentifier: "com.gone.app",
                                           location: "Caches", size: 1, newestContentModifiedAt: nil, modifiedAt: nil,
                                           isMeasurementComplete: true, isSelected: true)
        orphanModel.reader = { _ in .success(ScanReport(items: [preselected], deniedPaths: [])) }
        orphanModel.scan()
        await eventually("orphans load") { orphanModel.state == .ready }
        precondition(orphanModel.items.allSatisfy { !$0.isSelected }, "leftover app data is never preselected")
    }

    // MARK: Lists and states

    static func largeListsAndStates() throws {
        // Every page state maps to one presentation, and earlier results are never hidden.
        typealias P = ModulePresentation
        precondition(P.of(ModuleState.idle, hasResults: false) == .notScanned && P.of(ModuleState.loading, hasResults: false) == .loading)
        precondition(P.of(ModuleState.loading, hasResults: true) == .refreshing && P.of(ModuleState.ready, hasResults: false) == .empty)
        precondition(P.of(ModuleState.ready, hasResults: true) == .results && P.of(ModuleState.ready, hasResults: true, warning: "w") == .partial("w"))
        precondition(P.of(ModuleState.failed("x"), hasResults: false) == .failed("x") && P.of(ModuleState.failed("x"), hasResults: true) == .failedWithResults("x"))
        precondition(P.of(ModuleState.cancelled, hasResults: false) == .cancelled && P.of(ModuleState.cancelled, hasResults: true) == .cancelledWithResults)
        precondition(P.of(ScanState.scanning, hasResults: true) == .refreshing && P.of(ScanState.cancelled, hasResults: false) == .cancelled)
        for state in [P.refreshing, .partial("w"), .failedWithResults("x"), .cancelledWithResults] {
            precondition(state.showsResults && state.notice != nil, "\(state) keeps results and explains them")
        }
        for state in [P.notScanned, .loading, .empty, .failed("x"), .cancelled] { precondition(!state.showsResults) }

        // Large lists stay fast in the computations every redraw and confirmation uses.
        let files = (0..<100_000).map { index in
            DuplicateFile(id: UUID(), url: URL(fileURLWithPath: "/fixture/\(index % 20_000)/f\(index)"), size: 1_000,
                          fingerprint: "g\(index / 4)", isSelected: index % 3 != 0, diskBytes: 1_000)
        }
        var started = Date()
        let groups = AppModel.groups(of: files)
        let groupSeconds = Date().timeIntervalSince(started)
        precondition(groups.count == 25_000 && groupSeconds < 2, "grouping 100k duplicates took \(groupSeconds) s")
        started = Date()
        let kept = Set(groups.filter { $0.files.allSatisfy(\.isSelected) }.compactMap { $0.files.first?.id })
        let plan = files.filter { $0.isSelected && !kept.contains($0.id) }
        let planSeconds = Date().timeIntervalSince(started)
        precondition(plan.count == files.filter(\.isSelected).count - kept.count && planSeconds < 1,
                     "the removal plan for 100k files took \(planSeconds) s")
        started = Date()
        let presentations = (0..<100_000).map { P.of(ModuleState.ready, hasResults: $0 % 2 == 0) }
        precondition(presentations.count == 100_000 && Date().timeIntervalSince(started) < 1)
    }

    // MARK: History location

    /// Regression: checks that run real cleanup code wrote into the user's own Cleanup History.
    @MainActor static func historyStaysOutOfUserFile() async throws {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mac Polish/cleanup-history.json").standardizedFileURL
        guard let override = ProcessInfo.processInfo.environment[CleanupHistoryStore.locationOverride] else {
            preconditionFailure("run checks with Scripts/test.sh, which keeps Cleanup History out of the user's file")
        }
        precondition(CleanupHistoryStore.defaultURL.path == override && CleanupHistoryStore.defaultURL.standardizedFileURL != real)
        let before = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        let app = AppModel(access: access(reviewed: true), services: Fakes().services())
        app.cleanupHistory.record(source: "Check", moved: [], skipped: [CleanupRecord.Entry(path: "/fixture", bytes: 1, reason: "test")])
        let after = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        precondition(before == after, "a check must never write the user's Cleanup History")
        precondition(FileManager.default.fileExists(atPath: override), "the check's history went to the throwaway file")
        // Mac Health history follows the same rule.
        let realHealth = real.deletingLastPathComponent().appending(path: "health-history.json")
        guard let healthOverride = ProcessInfo.processInfo.environment["MACPOLISH_HEALTH_HISTORY"] else {
            preconditionFailure("run checks with Scripts/test.sh, which keeps Mac Health history out of the user's file")
        }
        precondition(HealthHistoryStore.defaultURL.path == healthOverride && HealthHistoryStore.defaultURL.standardizedFileURL != realHealth)
    }

    // MARK: Workers

    static func cancellationInfrastructure() throws {
        // Cancelling ends a running worker process at once.
        let cancellation = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        var started = Date()
        let cancelled = SystemDataScanner.run("/bin/sleep", ["30"], timeout: 60, cancellation: cancellation)
        precondition(cancelled.status == SystemDataScanner.cancelledStatus && Date().timeIntervalSince(started) < 2,
                     "cancel ended the process in \(Date().timeIntervalSince(started)) s")
        precondition(WorkerProcesses.shared.count == 0, "finished processes are not tracked")
        // Already cancelled: nothing starts.
        started = Date()
        precondition(SystemDataScanner.run("/bin/sleep", ["30"], timeout: 60, cancellation: cancellation).status == SystemDataScanner.cancelledStatus
                     && Date().timeIntervalSince(started) < 0.2)
        precondition(DiskScanService.readValue(String.self, mode: "basic", cancellation: cancellation).failureCancelled, "cancelled reads report cancellation")
        // Quitting ends every tracked process.
        let quitting = ScanCancellation()
        let worker = Thread { _ = SystemDataScanner.run("/bin/sleep", ["30"], timeout: 60, cancellation: quitting) }
        worker.start()
        let deadline = Date().addingTimeInterval(2)
        while WorkerProcesses.shared.count == 0 && Date() < deadline { usleep(5_000) }
        precondition(WorkerProcesses.shared.count == 1, "the running process is tracked")
        started = Date()
        WorkerProcesses.shared.terminateAll()
        while WorkerProcesses.shared.count > 0 && Date().timeIntervalSince(started) < 3 { usleep(5_000) }
        precondition(WorkerProcesses.shared.count == 0, "quitting ended the process")

        // A worker whose app disappears exits by itself.
        let executable = Bundle.main.executableURL!.path
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" --watch-parent-child & echo $!; sleep 0.5", executable]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        shell.waitUntilExit()
        let childPID = Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        precondition(childPID > 0, "child started")
        let exitDeadline = Date().addingTimeInterval(3)
        while kill(childPID, 0) == 0 && Date() < exitDeadline { usleep(20_000) }
        let survived = kill(childPID, 0) == 0
        if survived { kill(childPID, SIGKILL) }
        precondition(!survived, "a worker exits when the app that started it is gone")
    }
}

private extension Result where Failure == DiskScanFailure {
    var failureCancelled: Bool { if case .failure(let failure) = self { failure.cancelled } else { false } }
}
