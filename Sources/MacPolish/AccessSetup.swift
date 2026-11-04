import AppKit
import Foundation
import Security
import SwiftUI

struct FolderAccessResult: Identifiable, Sendable, Codable {
    enum Status: String, Sendable, Codable {
        case readable = "Readable"
        case restricted = "Access restricted"
        case missing = "Not present"
        case unavailable = "Could not verify"
        case timedOut = "No answer in time"
    }
    var id: String { url.path }
    let name: String
    let url: URL
    let status: Status
}

/// Privacy & Security panes Mac Polish can open. The user decides there; Mac Polish never changes settings.
enum PrivacyPane: String, CaseIterable, Sendable {
    case fullDiskAccess = "Privacy_AllFiles"
    case filesAndFolders = "Privacy_FilesAndFolders"
    case appManagement = "Privacy_AppBundles"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?" + rawValue)! }

    @MainActor func open() {
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

enum FolderAccessCheck {
    /// Tests directory listing only. This does not certify Full Disk Access or write permission.
    static func check(name: String, url: URL) -> FolderAccessResult {
        let status: FolderAccessResult.Status
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            status = .readable
        } catch {
            status = classify(error as NSError)
        }
        return FolderAccessResult(name: name, url: url, status: status)
    }

    static func classify(_ error: NSError, depth: Int = 0) -> FolderAccessResult.Status {
        guard depth < 8 else { return .unavailable }
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoPermissionError { return .restricted }
            if error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return .missing }
        }
        if error.domain == NSPOSIXErrorDomain {
            if error.code == Int(EACCES) || error.code == Int(EPERM) { return .restricted }
            if error.code == Int(ENOENT) { return .missing }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying, depth: depth + 1)
        }
        return .unavailable
    }

    /// Folders macOS asks about with a prompt (Files & Folders). macOS shows one prompt at a time.
    static let promptingLocations = ["Desktop", "Documents", "Downloads"]

    typealias LocationReader = @Sendable (String, URL) -> Result<[FolderAccessResult], DiskScanFailure>

    /// Checks each folder in its own worker. A macOS access prompt waits for the user, so a folder
    /// that does not answer in time is reported on its own instead of failing the whole check.
    /// Prompting folders are checked one after another, each with the full `timeout`: started together,
    /// the prompts would queue on screen while their deadlines ran at the same time.
    static func checkAll(timeout: TimeInterval = 90, reader: LocationReader? = nil) -> (results: [FolderAccessResult], warning: String?) {
        let read = reader ?? { name, _ in
            DiskScanService.read(FolderAccessResult.self, mode: "access", arguments: ["--location", name], timeout: timeout)
        }
        let locations = locations()
        let prompting = locations.indices.filter { promptingLocations.contains(locations[$0].0) }
        let jobs = [prompting] + locations.indices.filter { !prompting.contains($0) }.map { [$0] }
        let answered = DiskScanService.concurrentMap(jobs) { job in
            job.map { ($0, read(locations[$0].0, locations[$0].1)) }
        }.flatMap { $0 }
        let byIndex = Dictionary(uniqueKeysWithValues: answered)
        let answers = locations.indices.map { byIndex[$0]! }
        let results = zip(locations, answers).map { location, answer -> FolderAccessResult in
            switch answer {
            case .success(let found):
                return found.first { $0.name == location.0 } ?? FolderAccessResult(name: location.0, url: location.1, status: .unavailable)
            case .failure(let failure):
                return FolderAccessResult(name: location.0, url: location.1, status: failure.timedOut ? .timedOut : .unavailable)
            }
        }
        let waiting = results.contains { $0.status == .timedOut }
        return (results, waiting
            ? "Some folders did not answer in time. If macOS is showing an access request, respond to it, then choose Recheck Folder Access."
            : nil)
    }

    static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(String, URL)] {
        [ ("Desktop", home.appending(path: "Desktop")),
          ("Documents", home.appending(path: "Documents")),
          ("Downloads", home.appending(path: "Downloads")),
          ("User caches", home.appending(path: "Library/Caches")),
          ("Xcode user data", home.appending(path: "Library/Developer")),
          ("Trash", home.appending(path: ".Trash")) ]
    }
}

/// Whether Mac Polish has Full Disk Access, read from folders that only Full Disk Access opens.
/// None of them shows a macOS prompt, so checking is always silent.
enum FullDiskAccess: String, Codable, Sendable {
    case granted, notGranted, unknown

    static func probes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC"),
         home.appending(path: ".Trash"),
         home.appending(path: "Library/Safari"),
         home.appending(path: "Library/Mail")]
    }

    /// One readable probe proves the grant; a refused probe with none readable means no grant.
    static func status(probes: [URL] = probes()) -> FullDiskAccess {
        var refused = false
        for url in probes {
            switch FolderAccessCheck.check(name: url.lastPathComponent, url: url).status {
            case .readable: return .granted
            case .restricted: refused = true
            case .missing, .unavailable, .timedOut: continue
            }
        }
        return refused ? .notGranted : .unknown
    }
}

/// How this copy is signed. macOS stores each privacy permission with the app's designated requirement.
extension FullDiskAccess {
    var label: String {
        switch self {
        case .granted: "On"
        case .notGranted: "Off"
        case .unknown: "Could not verify"
        }
    }
}

enum SigningIdentity {
    /// The designated requirement of the running code, for example `cdhash H"…"` for an ad-hoc signature.
    static func currentRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// True when the requirement names one exact build, so every update starts without permissions.
    static func pinsPermissionsToBuild(_ requirement: String) -> Bool {
        requirement.trimmingCharacters(in: .whitespaces).hasPrefix("cdhash")
    }
}

@MainActor
final class AccessSetupModel: ObservableObject {
    static let completedKey = "accessSetupCompletedV1"
    /// Set while Full Disk Access is seen granted; cleared when the user continues without it.
    static let fullDiskAccessSeenKey = "fullDiskAccessSeenV1"
    typealias FullDiskAccessProbe = @Sendable () -> FullDiskAccess
    private let defaults: UserDefaults
    private let probe: FullDiskAccessProbe
    @Published var presented: Bool
    @Published var settingsPresented = false
    @Published var checking = false
    @Published var results: [FolderAccessResult] = []
    @Published var checkedAt: Date?
    @Published var checkWarning: String?
    @Published var cleanupContext: [CleanupIssue] = []
    @Published var fullDiskAccess: FullDiskAccess?
    /// Full Disk Access was on at an earlier launch and is off now (an update signed differently, or a settings change).
    @Published var accessLost = false
    /// True for an ad-hoc signed copy: macOS asks for every permission again after each update.
    let permissionsResetOnUpdate = SigningIdentity.currentRequirement().map(SigningIdentity.pinsPermissionsToBuild) ?? false

    init(defaults: UserDefaults = .standard, probe: FullDiskAccessProbe? = nil) {
        self.defaults = defaults
        // The worker reads with the app's identity, exactly as scans do.
        self.probe = probe ?? {
            (try? DiskScanService.readValue(FullDiskAccess.self, mode: "full-disk-access", timeout: 20).get()) ?? .unknown
        }
        presented = !defaults.bool(forKey: Self.completedKey)
    }

    /// Run at launch. Reopens setup when Full Disk Access was granted before and is missing now.
    func verifyOnLaunch() async {
        let probe = probe
        record(await BackgroundWork.run(qos: .utility) { probe() })
    }

    private func record(_ status: FullDiskAccess) {
        fullDiskAccess = status
        switch status {
        case .granted:
            defaults.set(true, forKey: Self.fullDiskAccessSeenKey)
            accessLost = false
        case .notGranted where defaults.bool(forKey: Self.fullDiskAccessSeenKey):
            accessLost = true
            presented = true
        case .notGranted, .unknown:
            break
        }
    }

    /// True when a folder check found a folder macOS refused, which Files & Folders can allow.
    var hasRestrictedFolder: Bool { results.contains { $0.status == .restricted } }

    func check() {
        guard !checking else { return }
        checking = true
        results = []
        checkWarning = nil
        let probe = probe
        Task {
            async let measured = BackgroundWork.run(qos: .utility) { FolderAccessCheck.checkAll() }
            async let status = BackgroundWork.run(qos: .utility) { probe() }
            let folders = await measured
            record(await status)
            results = folders.results
            checkWarning = folders.warning
            checkedAt = Date()
            checking = false
        }
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        // Continuing without Full Disk Access is the user's choice; do not reopen setup for it at every launch.
        if fullDiskAccess == .notGranted { defaults.removeObject(forKey: Self.fullDiskAccessSeenKey) }
        accessLost = false
        presented = false
        settingsPresented = false
        cleanupContext = []
    }

    func showSettings() {
        cleanupContext = []
        settingsPresented = true
    }

    /// True when macOS App Management blocked removing an app, which Full Disk Access does not cover.
    var needsAppManagement: Bool { cleanupContext.contains { $0.kind == .appManagement } }

    func openFullDiskAccess() {
        PrivacyPane.fullDiskAccess.open()
    }
}

struct AccessSetupView: View {
    @ObservedObject var access: AccessSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Prepare your scan", systemImage: "lock.shield").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Set up file access once, before scanning.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if access.accessLost {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Full Disk Access is off", systemImage: "exclamationmark.shield").font(.headline)
                            Text("Mac Polish had Full Disk Access before. macOS turns it off when an update is signed differently, or when it is turned off in System Settings.")
                                .font(.callout)
                            Text("If Mac Polish still looks enabled in Full Disk Access, select it, remove it with −, then add this copy again with +.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !access.cleanupContext.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Cleanup needs file access", systemImage: "exclamationmark.lock").font(.headline)
                            Text("macOS denied moving these items. Check file access here, then retry the selected files in the app. No cleanup resumes automatically.")
                                .font(.callout)
                            ForEach(access.cleanupContext.prefix(3)) { issue in
                                Text(issue.url.path).font(.caption).textSelection(.enabled).lineLimit(2)
                            }
                            if access.needsAppManagement {
                                Text("Removing apps also needs App Management: System Settings → Privacy & Security → App Management. Enable Mac Polish there.")
                                    .font(.callout)
                                Button("Open App Management") { PrivacyPane.appManagement.open() }
                            }
                            Text("Full Disk Access does not unlock files or change ownership, folder write permissions or ACLs. If access still fails, review the containing folder in Finder.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Enable Full Disk Access for a broader scan").font(.headline)
                        Text("This allows Mac Polish to read protected files, including data belonging to other apps. Choose whether to allow it in System Settings → Privacy & Security → Full Disk Access.")
                        Text("Enable Mac Polish there. If it is missing, use + to add this application. Follow any macOS request to quit and reopen it, then return here to verify access.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Open Full Disk Access") { access.openFullDiskAccess() }
                            Button("Show This App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        }
                        if let status = access.fullDiskAccess {
                            HStack {
                                Text("Full Disk Access")
                                Spacer()
                                Label(status.label, systemImage: status == .granted ? "checkmark.circle.fill" : "info.circle")
                                    .foregroundStyle(status == .granted ? Color.green : Color.secondary)
                            }.font(.callout)
                        }
                        if access.permissionsResetOnUpdate {
                            Text("This copy is signed for this build only, so macOS asks for these permissions again after each update.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2 · Check folder access together").font(.headline)
                        Text("Check Desktop, Documents, Downloads, caches, developer files and Trash. macOS may ask about individual folders; respond to its prompts to prepare them before the scan.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(access.checkedAt == nil ? "Check & Request Folder Access" : "Recheck Folder Access") { access.check() }
                                .buttonStyle(.borderedProminent).disabled(access.checking)
                            if access.checking { ProgressView().controlSize(.small) }
                        }
                        if let warning = access.checkWarning {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(access.results) { result in
                            HStack {
                                Text(result.name)
                                Spacer()
                                Label(result.status.rawValue, systemImage: result.status == .readable ? "checkmark.circle.fill" : "info.circle")
                                    .foregroundStyle(result.status == .readable ? Color.green : Color.secondary)
                            }.font(.callout)
                        }
                        if access.hasRestrictedFolder {
                            HStack(alignment: .firstTextBaseline) {
                                Text("If you chose Don't Allow for a folder, allow Mac Polish for it in Files & Folders, or turn on Full Disk Access.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Open Files & Folders") { PrivacyPane.filesAndFolders.open() }.controlSize(.small)
                            }
                        }
                        Text("Xcode user data checks ~/Library/Developer only. This optional folder may not exist until Xcode or simulators create it. It does not indicate whether Command Line Tools are installed.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let checkedAt = access.checkedAt {
                            Text("Checked at " + checkedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Checks verify directory reading, not permission to delete every file. Full Disk Access is read from folders only it opens; this never shows a prompt. Protected areas may still be unavailable. You can continue with a limited scan and revisit this setup in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Memory monitoring works without additional permissions.", systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("You control access in macOS.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Continue to Mac Polish") { access.finish() }
                    .buttonStyle(.borderedProminent).disabled(access.checking)
            }
        }.padding(28).frame(width: 650, height: 620)
            .interactiveDismissDisabled(access.checking)
    }
}

struct AccessSetupPresenter: ViewModifier {
    @ObservedObject var access: AccessSetupModel
    func body(content: Content) -> some View {
        content.sheet(isPresented: $access.presented) { AccessSetupView(access: access) }
    }
}

struct AccessSettings: View {
    @ObservedObject var access: AccessSetupModel
    var body: some View {
        Section("File access") {
            Button("Review Scan Permissions…") { access.showSettings() }
            Text("Prepare folder access and Full Disk Access before scanning.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $access.settingsPresented) { AccessSetupView(access: access) }
    }
}
