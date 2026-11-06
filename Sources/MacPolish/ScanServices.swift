import Foundation

/// Everything the app's own scans and cleanups need from the system. Production uses `live`; tests inject fakes, so
/// a test never reads protected folders, starts workers it did not ask for, or moves a real file to Trash.
struct ScanServices: Sendable {
    var basicScan: @Sendable (_ includeLargeFiles: Bool, ScanCancellation) -> Result<DiskScanOutcome, DiskScanFailure>
    var duplicates: @Sendable (ScanCancellation) -> Result<ScanReport<DuplicateFile>, DiskScanFailure>
    var applications: @Sendable (ScanCancellation) -> Result<[ApplicationItem], DiskScanFailure>
    var storage: @Sendable (ScanCancellation) -> Result<DiskMapReport, DiskScanFailure>
    var startupItems: @Sendable (ScanCancellation) -> Result<[StartupEntry], DiskScanFailure>
    /// nil when the measurement was cancelled.
    var systemData: @Sendable (ScanCancellation) -> SystemDataReport?
    var artifacts: @Sendable (ScanCancellation) -> Result<ScanReport<ProjectArtifact>, DiskScanFailure>
    var toolchainCaches: @Sendable (ScanCancellation) -> [SystemDataArea]
    var startupAudit: @Sendable (ScanCancellation) -> Result<ScanReport<StartupAuditEntry>, DiskScanFailure>
    var orphans: @Sendable (ScanCancellation) -> Result<ScanReport<OrphanedDataItem>, DiskScanFailure>
    var appInsights: @Sendable ([String], ScanCancellation) -> Result<[ApplicationInsight], DiskScanFailure>
    /// Moves one item to Trash. Never a permanent delete.
    var trashItem: @Sendable (URL) throws -> Void

    static let live = ScanServices(
        basicScan: { includeLargeFiles, cancellation in
            DiskScanService.scan(includeLargeFiles: includeLargeFiles, cancellation: cancellation)
        },
        duplicates: { cancellation in
            DiskScanService.readValue(ScanReport<DuplicateFile>.self, mode: "duplicates", cancellation: cancellation)
        },
        applications: { cancellation in
            DiskScanService.read(ApplicationItem.self, mode: "applications", cancellation: cancellation)
        },
        storage: { cancellation in
            DiskMapService.scan(reader: DiskMapService.workerReader(cancellation: cancellation))
        },
        startupItems: { cancellation in
            DiskScanService.read(StartupEntry.self, mode: "startup", cancellation: cancellation)
        },
        systemData: { cancellation in
            let report = SystemDataScanner().scan(cancellation: cancellation)
            return cancellation.isCancelled ? nil : report
        },
        artifacts: { ProjectArtifactScanner.partitionedRead(cancellation: $0) },
        toolchainCaches: { ToolchainCacheSpec.measureExisting(reader: DiskMapService.workerReader(cancellation: $0)) },
        startupAudit: { DiskScanService.readValue(ScanReport<StartupAuditEntry>.self, mode: "startup-audit", timeout: 90, cancellation: $0) },
        orphans: { DiskScanService.readValue(ScanReport<OrphanedDataItem>.self, mode: "orphans", timeout: 120, cancellation: $0) },
        appInsights: { paths, cancellation in
            guard let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) else {
                return .failure(DiskScanFailure(message: "The application list could not be prepared."))
            }
            return DiskScanService.readValue([ApplicationInsight].self, mode: "app-insights", arguments: ["--paths", json],
                                             timeout: 120, cancellation: cancellation)
        },
        trashItem: { url in _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    )
}

/// Why a scan the user asked for has not started, or started with limited access. Shown in the main window.
struct ScanGateNotice: Equatable {
    enum Place: Equatable {
        /// The review is open in the Settings window.
        case settings
        /// Folder checks are still running.
        case checks
        /// The setup sheet is open in the main window.
        case setup
    }

    enum Kind: Equatable {
        case waiting(Place)
        /// The review finished with some locations unreadable; the scans started and will skip those locations.
        case startedWithLimitedAccess(restricted: [String])
        /// The review was closed before it finished, so the scans did not start.
        case notStarted
    }

    let kind: Kind
    /// The scans this is about, by name.
    let scans: [String]

    var message: String {
        let names = scans.joined(separator: ", ")
        switch kind {
        case .waiting(.settings):
            return "\(names) will start when you finish the scan permission review that is open in Settings."
        case .waiting(.checks):
            return "\(names) will start when the folder access checks finish and you complete the review."
        case .waiting(.setup):
            return "\(names) will start when you complete the scan permission review."
        case .startedWithLimitedAccess(let restricted):
            let shown = restricted.prefix(4).joined(separator: ", ") + (restricted.count > 4 ? " and \(restricted.count - 4) more" : "")
            return "\(names) started with limited access. Not readable: \(shown.isEmpty ? "some protected locations" : shown). "
                + "Files there are not scanned. To include them, turn on Mac Polish in System Settings → Privacy & Security → "
                + "Full Disk Access, then scan again."
        case .notStarted:
            return "\(names) did not start because the scan permission review was closed before it was finished."
        }
    }
}
