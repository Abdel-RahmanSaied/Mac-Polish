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

/// Observed read access to selected protected locations; this does not certify the TCC grant.
/// None of them shows a macOS prompt, so checking is always silent.
enum FullDiskAccess: String, Codable, Sendable {
    case accessible, restricted, unknown

    static func probes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC"),
         home.appending(path: ".Trash"),
         home.appending(path: "Library/Safari"),
         home.appending(path: "Library/Mail")]
    }

    /// Reports only access to the tested locations, not the macOS Full Disk Access grant.
    /// A denial takes precedence regardless of probe order; missing/failed probes leave uncertainty.
    static func status(probes: [URL] = probes()) -> FullDiskAccess {
        var readable = false
        var uncertain = false
        for url in probes {
            switch FolderAccessCheck.check(name: url.lastPathComponent, url: url).status {
            case .readable: readable = true
            case .restricted: return .restricted
            case .missing, .unavailable, .timedOut: uncertain = true
            }
        }
        return readable && !uncertain ? .accessible : .unknown
    }
}

/// How this copy is signed. macOS stores each privacy permission with the app's designated requirement.
extension FullDiskAccess {
    var label: String {
        switch self {
        case .accessible: "Tested locations readable"
        case .restricted: "Some access restricted"
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

/// Another copy of Mac Polish on this Mac.
struct AppCopy: Identifiable, Sendable, Equatable {
    var id: String { url.path }
    let url: URL
    let version: String?
    /// False when the copy does not meet the running copy's signing requirement, so it can take its permissions.
    let sameSignature: Bool
}

/// Copies of Mac Polish known to Launch Services. macOS keeps one permission entry per bundle identifier:
/// opening a differently signed copy, or adding it in Full Disk Access, moves the permission to that copy.
enum AppCopies {
    static let bundleIdentifier = "com.asaied.macpolish"

    /// Existing copies other than `running`, outside the Trash, sorted by path.
    static func others(running: URL = Bundle.main.bundleURL,
                       requirement: String? = SigningIdentity.currentRequirement(),
                       registered: [URL]? = nil) -> [AppCopy] {
        let candidates = registered ?? NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        var seen: Set<String> = [running.resolvingSymlinksInPath().standardizedFileURL.path]
        return candidates.compactMap { url -> AppCopy? in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted, !resolved.path.contains("/.Trash/"),
                  FileManager.default.fileExists(atPath: resolved.path) else { return nil }
            let version = Bundle(url: resolved)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return AppCopy(url: resolved, version: version,
                           sameSignature: requirement.map { satisfies(resolved, requirement: $0) } ?? false)
        }.sorted { $0.url.path < $1.url.path }
    }

    /// The designated requirement of the bundle at `url`.
    static func requirement(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// True when the bundle at `url` has a valid signature that meets `requirement`, the check macOS makes
    /// before it honours a stored permission.
    static func satisfies(_ url: URL, requirement: String) -> Bool {
        guard let code = staticCode(url) else { return false }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
        return SecStaticCodeCheckValidity(code, [], compiled) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}

@MainActor
final class AccessSetupModel: ObservableObject {
    static let completedKey = "accessSetupCompletedV1"
    /// Remembers readable probes; cleared when the user acknowledges restricted access.
    static let fullDiskAccessSeenKey = "fullDiskAccessSeenV1"
    /// The differently signed copies the user last continued past; a new set opens setup again.
    static let dismissedCopiesKey = "otherCopiesDismissedV1"
    typealias FullDiskAccessProbe = @Sendable () -> FullDiskAccess
    typealias CopiesFinder = @Sendable () -> [AppCopy]
    private let defaults: UserDefaults
    private let probe: FullDiskAccessProbe
    private let copies: CopiesFinder
    @Published var presented: Bool
    @Published var settingsPresented = false
    @Published var checking = false
    @Published var results: [FolderAccessResult] = []
    @Published var checkedAt: Date?
    @Published var checkWarning: String?
    @Published var cleanupContext: [CleanupIssue] = []
    @Published var fullDiskAccess: FullDiskAccess?
    /// Previously readable probes now include a restricted location.
    @Published var accessLost = false
    /// Other copies of Mac Polish on this Mac.
    @Published var otherCopies: [AppCopy] = []
    /// Copies that can take this copy's permissions if they are opened or added in Full Disk Access.
    var conflictingCopies: [AppCopy] { otherCopies.filter { !$0.sameSignature } }
    /// True for an ad-hoc signed copy: macOS asks for every permission again after each update.
    let permissionsResetOnUpdate = SigningIdentity.currentRequirement().map(SigningIdentity.pinsPermissionsToBuild) ?? false

    init(defaults: UserDefaults = .standard, probe: FullDiskAccessProbe? = nil, copies: CopiesFinder? = nil) {
        self.defaults = defaults
        self.copies = copies ?? { AppCopies.others() }
        // The worker reads with the app's identity, exactly as scans do.
        self.probe = probe ?? {
            (try? DiskScanService.readValue(FullDiskAccess.self, mode: "full-disk-access", timeout: 20).get()) ?? .unknown
        }
        presented = !defaults.bool(forKey: Self.completedKey)
    }

    /// Reopens setup if previously readable probes become restricted.
    /// Also opens setup once for each new set of differently signed copies of Mac Polish.
    func verifyOnLaunch() async {
        let probe = probe
        let copies = copies
        async let status = BackgroundWork.run(qos: .utility) { probe() }
        async let found = BackgroundWork.run(qos: .utility) { copies() }
        record(await status)
        otherCopies = await found
        let conflicting = Self.copiesKey(conflictingCopies)
        if !conflicting.isEmpty && conflicting != defaults.string(forKey: Self.dismissedCopiesKey) { presented = true }
    }

    private static func copiesKey(_ copies: [AppCopy]) -> String {
        copies.map(\.url.path).sorted().joined(separator: "\n")
    }

    private func record(_ status: FullDiskAccess) {
        fullDiskAccess = status
        switch status {
        case .accessible:
            defaults.set(true, forKey: Self.fullDiskAccessSeenKey)
            accessLost = false
        case .restricted where defaults.bool(forKey: Self.fullDiskAccessSeenKey):
            accessLost = true
            presented = true
        case .restricted, .unknown:
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
        let copies = copies
        Task {
            async let measured = BackgroundWork.run(qos: .utility) { FolderAccessCheck.checkAll() }
            async let status = BackgroundWork.run(qos: .utility) { probe() }
            async let found = BackgroundWork.run(qos: .utility) { copies() }
            let folders = await measured
            record(await status)
            otherCopies = await found
            results = folders.results
            checkWarning = folders.warning
            checkedAt = Date()
            checking = false
        }
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        // Continuing without Full Disk Access is the user's choice; do not reopen setup for it at every launch.
        if fullDiskAccess == .restricted { defaults.removeObject(forKey: Self.fullDiskAccessSeenKey) }
        defaults.set(Self.copiesKey(conflictingCopies), forKey: Self.dismissedCopiesKey)
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
                            Label("Access to protected locations changed", systemImage: "exclamationmark.shield").font(.headline)
                            Text("Previously readable locations are now restricted. Review folder permissions and privacy settings; an update with a different signing identity can also affect access.")
                                .font(.callout)
                            Text("If Mac Polish still looks enabled in Full Disk Access, select it, remove it with −, then add this copy again with +.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !access.otherCopies.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(access.conflictingCopies.isEmpty ? "Other copies of Mac Polish" : "Another copy can take Full Disk Access",
                                  systemImage: "square.on.square").font(.headline)
                            Text("macOS keeps one permission entry for Mac Polish. Opening another copy, or adding it in Full Disk Access, can move the permission to that copy. Keep the copy you use and move the others to the Trash.")
                                .font(.callout)
                            Text("This copy: " + Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
                            ForEach(access.otherCopies) { copy in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(copy.url.path).font(.caption).textSelection(.enabled).lineLimit(2)
                                        Text([copy.version.map { "Version " + $0 }, copy.sameSignature ? nil : "signed differently"]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(copy.sameSignature ? Color.secondary : Color.orange)
                                    }
                                    Spacer()
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([copy.url]) }
                                        .controlSize(.small)
                                }
                            }
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
                        Text("Add this copy: " + Bundle.main.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let status = access.fullDiskAccess {
                            HStack {
                                Text("Protected locations")
                                Spacer()
                                Label(status.label, systemImage: status == .accessible ? "checkmark.circle.fill" : "info.circle")
                                    .foregroundStyle(status == .accessible ? Color.green : Color.secondary)
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
                    Text("Checks verify directory reading at the tested locations, not the Full Disk Access setting or permission to delete every file. Other protected areas may still be unavailable. You can continue with a limited scan and revisit this setup in Settings.")
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
