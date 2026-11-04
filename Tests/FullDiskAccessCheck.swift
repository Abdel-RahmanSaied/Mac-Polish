import AppKit
import Foundation

/// Setup must describe observed protected-folder access and notice new restrictions,
/// and link to every Privacy & Security pane it mentions.
@main
enum FullDiskAccessCheck {
    @MainActor
    static func main() async throws {
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-fda-" + UUID().uuidString)
        let open = root.appending(path: "open")
        let closed = root.appending(path: "closed")
        for folder in [open, closed] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            try? fm.removeItem(at: root)
        }
        let missing = root.appending(path: "missing")

        // Probe results describe observed access, never the system Full Disk Access toggle.
        precondition(FullDiskAccess.status(probes: [open]) == .accessible)
        precondition(FullDiskAccess.status(probes: [closed, open]) == .restricted)
        precondition(FullDiskAccess.status(probes: [missing, closed]) == .restricted, "A refused probe means no grant")
        precondition(FullDiskAccess.status(probes: [open, closed]) == .restricted, "A later denial cannot be hidden by an earlier readable folder")
        precondition(FullDiskAccess.status(probes: [open, missing]) == .unknown)
        precondition(FullDiskAccess.status(probes: []) == .unknown)
        precondition(FullDiskAccess.accessible.label == "Tested locations readable")
        precondition(FullDiskAccess.restricted.label == "Some access restricted")
        precondition(FullDiskAccess.status(probes: [missing]) == .unknown, "No probe present: cannot tell")
        let defaults = FullDiskAccess.probes().map(\.path)
        precondition(defaults.contains("/Library/Application Support/com.apple.TCC") && defaults.contains { $0.hasSuffix("/.Trash") },
                     "Default probes include folders that never show a prompt")
        print("  this process: protected-location access \(FullDiskAccess.status().rawValue)")

        // The worker answers the same question with the app's identity.
        guard case .success = DiskScanService.readValue(FullDiskAccess.self, mode: "full-disk-access", timeout: 30) else {
            preconditionFailure("The worker reports Full Disk Access")
        }

        // Launch check: a grant seen before and missing now reopens setup with an explanation.
        // No copies are injected: other copies of the app installed on this Mac are AppCopiesCheck's concern.
        let suite = "MacPolish-fda-test-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: AccessSetupModel.completedKey)
        let granted = AccessSetupModel(defaults: store, probe: { .accessible }, copies: { [] })
        await granted.verifyOnLaunch()
        precondition(granted.fullDiskAccess == .accessible && !granted.presented && !granted.accessLost)
        precondition(store.bool(forKey: AccessSetupModel.fullDiskAccessSeenKey), "A grant is remembered")

        // Break caught: an update signed differently silently dropping Full Disk Access.
        let lost = AccessSetupModel(defaults: store, probe: { .restricted }, copies: { [] })
        precondition(!lost.presented, "Completed setup does not open by itself")
        await lost.verifyOnLaunch()
        precondition(lost.presented && lost.accessLost && lost.fullDiskAccess == .restricted, "A lost grant reopens setup")
        // Continuing without it is the user's choice: do not ask again at every launch.
        lost.finish()
        precondition(!lost.accessLost && !store.bool(forKey: AccessSetupModel.fullDiskAccessSeenKey))
        let acknowledged = AccessSetupModel(defaults: store, probe: { .restricted }, copies: { [] })
        await acknowledged.verifyOnLaunch()
        precondition(!acknowledged.presented && !acknowledged.accessLost, "An acknowledged choice is respected")
        let undecided = AccessSetupModel(defaults: store, probe: { .unknown }, copies: { [] })
        await undecided.verifyOnLaunch()
        precondition(!undecided.presented && undecided.fullDiskAccess == .unknown)

        // Every pane the setup links to opens in System Settings.
        precondition(PrivacyPane.fullDiskAccess.url.absoluteString.hasSuffix("?Privacy_AllFiles"))
        precondition(PrivacyPane.filesAndFolders.url.absoluteString.hasSuffix("?Privacy_FilesAndFolders"))
        for pane in PrivacyPane.allCases {
            guard let handler = NSWorkspace.shared.urlForApplication(toOpen: pane.url) else {
                preconditionFailure("No app opens \(pane.url)")
            }
            precondition(handler.lastPathComponent == "System Settings.app", "\(pane) opens \(handler.lastPathComponent)")
        }

        // Signing: macOS keeps permissions for the designated requirement. A cdhash requirement names one build only.
        precondition(SigningIdentity.pinsPermissionsToBuild(#"cdhash H"2ab1e0dd5e868d19f53e18072840848f62709e94""#))
        precondition(!SigningIdentity.pinsPermissionsToBuild(#"identifier "com.asaied.macpolish" and certificate leaf = H"2ed03a84""#))
        guard let own = SigningIdentity.currentRequirement() else { preconditionFailure("The running code has a designated requirement") }
        // swiftc signs test binaries ad hoc, so this one is pinned to its build.
        precondition(SigningIdentity.pinsPermissionsToBuild(own), "Ad-hoc test binary requirement: \(own)")
        print("PASS: protected-location probes preserve uncertainty and denials, lost access reopens setup once, panes open System Settings, build-pinned signing is detected")
    }
}
