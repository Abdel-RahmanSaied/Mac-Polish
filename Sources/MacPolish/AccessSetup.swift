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
    static func checkAll(timeout: TimeInterval = 90, reader: LocationReader? = nil,
                         onResult: (@Sendable (FolderAccessResult) -> Void)? = nil) -> (results: [FolderAccessResult], warning: String?) {
        let read = reader ?? { name, _ in
            DiskScanService.read(FolderAccessResult.self, mode: "access", arguments: ["--location", name], timeout: timeout)
        }
        let locations = locations()
        let prompting = locations.indices.filter { promptingLocations.contains(locations[$0].0) }
        let jobs = [prompting] + locations.indices.filter { !prompting.contains($0) }.map { [$0] }
        let answered = DiskScanService.concurrentMap(jobs) { job in
            job.map { index in
                let location = locations[index]
                let answer = read(location.0, location.1)
                let result: FolderAccessResult
                switch answer {
                case .success(let found):
                    result = found.first { $0.name == location.0 }
                        ?? FolderAccessResult(name: location.0, url: location.1, status: .unavailable)
                case .failure(let failure):
                    result = FolderAccessResult(name: location.0, url: location.1,
                                                status: failure.timedOut ? .timedOut : .unavailable)
                }
                onResult?(result)
                return (index, answer)
            }
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
        let personal = [ ("Desktop", home.appending(path: "Desktop")),
          ("Documents", home.appending(path: "Documents")),
          ("Downloads", home.appending(path: "Downloads")),
          ("User caches", home.appending(path: "Library/Caches")),
          ("Xcode user data", home.appending(path: "Library/Developer")),
          ("Trash", home.appending(path: ".Trash")),
          ("Pictures", home.appending(path: "Pictures")),
          ("Movies", home.appending(path: "Movies")),
          ("Music", home.appending(path: "Music")),
          ("Application support", home.appending(path: "Library/Application Support")),
          ("App containers", home.appending(path: "Library/Containers")),
          ("Shared app containers", home.appending(path: "Library/Group Containers")),
          ("Mail data", home.appending(path: "Library/Mail")),
          ("Safari data", home.appending(path: "Library/Safari")),
          ("iCloud files", home.appending(path: "Library/Mobile Documents")),
          ("Cloud providers", home.appending(path: "Library/CloudStorage")),
          ("User logs", home.appending(path: "Library/Logs")),
          ("User applications", home.appending(path: "Applications")),
          ("User startup items", home.appending(path: "Library/LaunchAgents")),
          ("Xcode build data", home.appending(path: "Library/Developer/Xcode/DerivedData")),
          ("Xcode archives", home.appending(path: "Library/Developer/Xcode/Archives")),
          ("Simulator caches", home.appending(path: "Library/Developer/CoreSimulator/Caches")) ]
        let system = [("Startup Data volume", DiskMapService.dataRoot),
                      ("Applications", "/Applications"), ("System applications", "/System/Applications"),
                      ("Shared startup agents", "/Library/LaunchAgents"), ("Shared startup services", "/Library/LaunchDaemons")]
            .map { ($0.0, URL(fileURLWithPath: $0.1)) }
        var seen: Set<String> = []
        return (personal + SystemDataScanner.specifications(home: home).map { ($0.name, $0.url) } + system)
            .filter { seen.insert($0.1.standardizedFileURL.path).inserted }
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

enum OnboardingStep: Int, CaseIterable {
    case welcome, diskAccess, folders, management, review
    var title: String {
        switch self {
        case .welcome: "Meet your Mac, in detail"
        case .diskAccess: "Unlock a broader view"
        case .folders: "Check your folders"
        case .management: "Prepare app removal"
        case .review: "Your scan readiness"
        }
    }
}

@MainActor
final class AccessSetupModel: ObservableObject {
    static let completedKey = "accessSetupCompletedV1"
    static let reviewedKey = "accessChecksReviewedV3"
    /// Remembers readable probes; cleared when the user acknowledges restricted access.
    static let fullDiskAccessSeenKey = "fullDiskAccessSeenV1"
    /// The differently signed copies the user last continued past; a new set opens setup again.
    static let dismissedCopiesKey = "otherCopiesDismissedV1"
    typealias FullDiskAccessProbe = @Sendable () -> FullDiskAccess
    typealias CopiesFinder = @Sendable () -> [AppCopy]
    private let defaults: UserDefaults
    private let probe: FullDiskAccessProbe
    private let copies: CopiesFinder
    static let stepKey = "accessOnboardingStepV2"
    @Published var step: OnboardingStep = .welcome {
        didSet { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }
    @Published var presented: Bool { didSet { reviewVisibilityChanged() } }
    @Published var settingsPresented = false { didSet { reviewVisibilityChanged() } }
    /// Set while `finish()` closes the review, so a completed review is not reported as closed early.
    private var finishing = false
    /// Called when every review sheet is closed without finishing, so waiting scans can say they did not start.
    var onReviewClosed: (@MainActor () -> Void)?

    private func reviewVisibilityChanged() {
        guard !presented, !settingsPresented, !finishing else { return }
        onReviewClosed?()
    }

    /// Locations the last check could not read (restricted, unverified or unanswered), by name. Missing folders
    /// are not access problems and are not listed.
    var limitedLocations: [String] {
        results.filter { [.restricted, .unavailable, .timedOut].contains($0.status) }.map(\.name)
    }
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
        step = defaults.object(forKey: Self.stepKey).flatMap { ($0 as? Int).flatMap(OnboardingStep.init(rawValue:)) } ?? .welcome
        presented = !defaults.bool(forKey: Self.completedKey) || defaults.object(forKey: Self.stepKey) != nil
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
    var hasIncompleteAccess: Bool {
        results.isEmpty || fullDiskAccess != .accessible
            || results.contains { $0.status != .readable && $0.status != .missing }
    }

    func check() {
        guard !checking else { return }
        checking = true
        results = []
        checkWarning = nil
        let probe = probe
        let copies = copies
        Task { [self] in
            async let measured = BackgroundWork.run(qos: .utility) {
                FolderAccessCheck.checkAll(onResult: { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.checking else { return }
                        self.results.removeAll { $0.id == result.id }
                        self.results.append(result)
                        let order = FolderAccessCheck.locations().map(\.0)
                        self.results.sort { (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0) }
                    }
                })
            }
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

    /// Setup completion requires an actual result for every location, including missing/denied ones.
    var hasCompletedChecks: Bool {
        !checking && checkedAt != nil && fullDiskAccess != nil
            && Set(results.map { $0.url.standardizedFileURL.path }) == Set(FolderAccessCheck.locations().map { $0.1.standardizedFileURL.path })
    }

    /// Every production scan entry point calls this before starting work.
    func authorizeScan() -> Bool {
        guard defaults.bool(forKey: Self.reviewedKey), !checking, !presented, !settingsPresented, !accessLost else {
            if !presented && !settingsPresented { step = .folders; presented = true }
            return false
        }
        return true
    }

    /// Called after a completed review, so scans refused by the gate can start.
    var onFinish: (@MainActor () -> Void)?

    func finish() {
        guard hasCompletedChecks else {
            step = .folders
            checkWarning = "Run the folder access checks before continuing. Opening System Settings does not verify access."
            return
        }
        defaults.set(true, forKey: Self.reviewedKey)
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
        // Continuing without Full Disk Access is the user's choice; do not reopen setup for it at every launch.
        if fullDiskAccess == .restricted { defaults.removeObject(forKey: Self.fullDiskAccessSeenKey) }
        defaults.set(Self.copiesKey(conflictingCopies), forKey: Self.dismissedCopiesKey)
        accessLost = false
        finishing = true
        presented = false
        settingsPresented = false
        finishing = false
        cleanupContext = []
        onFinish?()
    }

    func showSettings() {
        step = .welcome
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
            HStack {
                Label("MAC POLISH · SETUP", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.cyan)
                Spacer()
                Text("Step \(access.step.rawValue + 1) of \(OnboardingStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule().fill(step.rawValue <= access.step.rawValue ? Color.cyan : Color.secondary.opacity(0.2)).frame(height: 4)
                }
            }
            Text(access.step.title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Set up access once. Know exactly what your scan can see.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if access.step == .welcome { welcome }
                    if access.step == .management { management }
                    if access.step == .review { review }
                    if access.step == .diskAccess || access.step == .review {
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
                    }
                    if access.step == .diskAccess {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enable Full Disk Access for a broader scan").font(.headline)
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
                    }
                    if access.step == .folders {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Verify the locations used by the scanner").font(.headline)
                        Text("Check personal folders, app data, containers, caches, developer data, cloud folders and Trash. Respond to any macOS prompts. A readable folder does not guarantee that every child can be read.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(access.checkedAt == nil ? "Check & Request Folder Access" : "Recheck Folder Access") { access.check() }
                                .buttonStyle(.borderedProminent).disabled(access.checking)
                            if access.checking {
                                ProgressView().controlSize(.small)
                                Text("\(access.results.count) / \(FolderAccessCheck.locations().count) checked").font(.caption)
                            }
                        }
                        if let warning = access.checkWarning {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(access.results) { result in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name)
                                    if result.name == "Xcode user data" {
                                        Text("Optional ~/Library/Developer folder; not the Xcode installation")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
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
                if access.step != .welcome {
                    Button("Back") { access.step = OnboardingStep(rawValue: access.step.rawValue - 1) ?? .welcome }
                        .disabled(access.checking)
                }
                if access.step == .review {
                    Button(access.hasIncompleteAccess ? "Continue with limited access" : "Open Mac Polish") { access.finish() }
                        .buttonStyle(.borderedProminent).disabled(!access.hasCompletedChecks)
                } else {
                    Button("Continue") { access.step = OnboardingStep(rawValue: access.step.rawValue + 1) ?? .review }
                        .buttonStyle(.borderedProminent)
                        .disabled(access.checking || (access.step == .folders && !access.hasCompletedChecks))
                }
            }
        }.padding(28).frame(width: 650, height: 620)
            .interactiveDismissDisabled(access.checking)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 64)).foregroundStyle(.cyan.gradient)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            Text("A complete picture starts with access.").font(.title2.bold())
            Label("Map accessible files on your startup Data volume, including hidden files and app bundles.", systemImage: "chart.pie")
            Label("Inspect smaller files and additional disks or folders on demand from Storage Map.", systemImage: "folder.badge.magnifyingglass")
            Label("Review cleanup suggestions before moving anything to Trash.", systemImage: "checkmark.shield")
            Text("macOS keeps some system files and other users’ data protected. Setup cannot bypass those restrictions. Missing or denied locations remain visible in scan results.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(20).background(.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Optional · only for removing applications", systemImage: "app.badge.checkmark").font(.headline)
            Text("App Management lets macOS allow changes to other apps. It is not required to measure disk usage. If Mac Polish appears in this Settings pane, enable it when you want to use the uninstaller.")
            Button("Open App Management") { PrivacyPane.appManagement.open() }.buttonStyle(.borderedProminent)
            Text("macOS may request this permission when an app removal is attempted. There is no reliable read-only check for every removal. We never delete an app just to trigger a prompt.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Label("External disks and selected folders", systemImage: "externaldrive")
            Text("Use Choose Disk or Folder in Storage Map. Select a mounted disk or folder and respond to any macOS access request. Disconnected disks and cloud-only files cannot be fully measured locally.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Memory monitoring needs no extra permission. Screen Recording, Accessibility and Contacts access are not needed.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(access.results.isEmpty ? "Folder access has not been checked" : "\(access.results.filter { $0.status == .readable }.count) locations readable",
                  systemImage: "checklist").font(.title3.bold())
            if let status = access.fullDiskAccess { Text("Protected locations: " + status.label).font(.callout) }
            ForEach(access.results.filter { $0.status != .readable }) { result in
                HStack {
                    Text(result.name)
                    Spacer()
                    Text(result.status.rawValue).foregroundStyle(.secondary)
                }.font(.callout)
            }
            Text("Not present means an optional folder does not exist. Restricted, unverified or timed-out locations mean the scan may be incomplete. You can continue and fix access later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Review folder checks") { access.step = .folders }
            Text("Nothing is cleaned during setup. Each scan reports its own coverage; these checks do not certify every file on the device.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
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
