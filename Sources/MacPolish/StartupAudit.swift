import AppKit
import Darwin
import Foundation

/// One system extension as `systemextensionsctl list` reports it (network filters, endpoint security, drivers).
struct SystemExtensionInfo: Identifiable, Codable, Sendable, Hashable {
    var id: String { [category, bundleID, version ?? "", state].joined(separator: "|") }
    /// For example `com.apple.system_extension.network_extension`.
    let category: String
    let enabled: Bool
    let active: Bool
    let teamID: String?
    let bundleID: String
    let version: String?
    let name: String
    /// The bracketed state, for example "activated enabled" or "terminated waiting to uninstall on reboot".
    let state: String

    var categoryName: String {
        switch category {
        case "com.apple.system_extension.network_extension": "Network extension"
        case "com.apple.system_extension.endpoint_security": "Endpoint security"
        case "com.apple.system_extension.driver_extension": "Driver extension"
        default: category.split(separator: ".").last.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? category
        }
    }
}

/// A launch agent, launch daemon or legacy startup item, with what its signature and location say about it.
/// Read-only: the audit never loads, unloads, disables or edits anything.
struct StartupAuditEntry: Identifiable, Codable, Sendable, Hashable {
    enum Scope: String, Codable, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents`: runs as you when you log in.
        case userAgent
        /// `/Library/LaunchAgents`: runs as every user who logs in.
        case globalAgent
        /// `/Library/LaunchDaemons`: runs as root, without anyone logged in.
        case systemDaemon
        /// `/Library/StartupItems`: not run by macOS since OS X 10.10.
        case legacyStartupItem

        var title: String {
            switch self {
            case .userAgent: "Your launch agent"
            case .globalAgent: "Launch agent for all users"
            case .systemDaemon: "Launch daemon (runs as root)"
            case .legacyStartupItem: "Legacy startup item"
            }
        }

        var icon: String {
            switch self {
            case .userAgent: "person.crop.circle"
            case .globalAgent: "person.2.circle"
            case .systemDaemon: "gearshape.2"
            case .legacyStartupItem: "clock.arrow.circlepath"
            }
        }

        var runsAsRoot: Bool { self == .systemDaemon || self == .legacyStartupItem }
    }

    enum RiskLevel: Int, Codable, Sendable, Comparable, CaseIterable {
        case none, low, medium, high

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .none: "No risk found"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    enum RiskFlag: String, Codable, Sendable, CaseIterable {
        case orphaned, unsigned, invalidSignature, adHocSigned, userWritableLocation, keepAliveAlways,
             plistNotOwnedByRoot, plistWorldWritable

        var title: String {
            switch self {
            case .orphaned: "Program missing"
            case .unsigned: "Unsigned"
            case .invalidSignature: "Invalid signature"
            case .adHocSigned: "Ad-hoc signed"
            case .userWritableLocation: "Hidden or shared location"
            case .keepAliveAlways: "Always restarted"
            case .plistNotOwnedByRoot: "Not owned by root"
            case .plistWorldWritable: "Anyone can edit"
            }
        }

        /// Code that runs as root weighs more than code that runs as you.
        func level(for scope: Scope) -> RiskLevel {
            switch self {
            case .invalidSignature, .plistWorldWritable: .high
            case .userWritableLocation, .unsigned: scope == .userAgent ? .medium : .high
            case .adHocSigned: scope.runsAsRoot ? .medium : .low
            case .plistNotOwnedByRoot: .medium
            case .orphaned, .keepAliveAlways: .low
            }
        }

        func finding(for scope: Scope) -> String {
            switch self {
            case .orphaned:
                "The program it starts no longer exists. This is usually left behind by an app that was removed."
            case .unsigned:
                "The program has no code signature, so nothing identifies who made it."
                    + (scope.runsAsRoot ? " It runs as root." : "")
            case .invalidSignature:
                "The program's signature does not match its contents. It may have been modified after signing."
            case .adHocSigned:
                "The program is ad-hoc signed: it is signed, but without a developer identity. Common for tools built locally or by Homebrew."
            case .userWritableLocation:
                "The program is in a hidden, temporary or shared folder that other software can write to."
                    + (scope == .userAgent ? "" : " It runs for every user or as root.")
            case .keepAliveAlways:
                "launchd restarts it whenever it stops (KeepAlive is always on)."
            case .plistNotOwnedByRoot:
                "Its property list in /Library is not owned by root, so a non-administrator account may be able to change what runs."
            case .plistWorldWritable:
                "Its property list can be edited by any account on this Mac."
            }
        }
    }

    var id: String { plistURL.path }
    let label: String
    /// The property list, or the folder of a legacy startup item.
    let plistURL: URL
    let scope: Scope
    /// The resolved program: `Program`, `ProgramArguments[0]`, or `BundleProgram` inside its app.
    let programPath: String?
    let programExists: Bool
    /// The script an interpreter such as /bin/sh runs, when it is named by an absolute path.
    var scriptPath: String? = nil
    /// The program's signature; nil when there is no program to check.
    let signature: CodeSignatureSummary?
    let runsAtLoad: Bool
    /// True when KeepAlive is `true` or a dictionary of conditions.
    let keepAlive: Bool
    /// True when StartInterval or StartCalendarInterval runs it on a schedule.
    let isScheduled: Bool
    let associatedBundleIdentifiers: [String]
    /// From `launchctl print-disabled`; nil when that could not be read.
    var disabled: Bool?
    let flags: [RiskFlag]
    /// Context that is not a risk by itself, for example "runs through /bin/sh".
    var notes: [String] = []

    var riskLevel: RiskLevel { flags.map { $0.level(for: scope) }.max() ?? .none }
    var findings: [String] { flags.map { $0.finding(for: scope) } + notes }
    var isAtRisk: Bool { riskLevel >= .medium }
}

enum StartupAuditor {
    struct Root: Sendable {
        let url: URL
        let scope: StartupAuditEntry.Scope
    }

    /// Per-label overrides from `launchctl print-disabled` (true = disabled). nil when the command failed.
    struct DisabledStates: Sendable, Equatable {
        var user: [String: Bool]?
        var system: [String: Bool]?
        static let unknown = DisabledStates(user: nil, system: nil)
    }

    /// The same three folders as `StartupScanner`, plus legacy `/Library/StartupItems`.
    static func defaultRoots(home: URL) -> [Root] {
        [Root(url: home.appending(path: "Library/LaunchAgents"), scope: .userAgent),
         Root(url: URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .globalAgent),
         Root(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .systemDaemon),
         Root(url: URL(fileURLWithPath: "/Library/StartupItems"), scope: .legacyStartupItem)]
    }

    /// Entry point for `--scan-worker startup-audit`.
    static func workerRun(arguments: [String] = []) -> ScanReport<StartupAuditEntry> {
        audit()
    }

    static func audit(home: URL = FileManager.default.homeDirectoryForCurrentUser, roots: [Root]? = nil,
                      disabledStates: DisabledStates? = nil,
                      appLocator: (String) -> URL? = locateApplication) -> ScanReport<StartupAuditEntry> {
        let denied = DeniedFolders()
        let states = disabledStates ?? queryDisabledStates()
        var entries: [StartupAuditEntry] = []
        for root in roots ?? defaultRoots(home: home) {
            // A missing folder is normal and not recorded; a denied one is.
            guard let children = denied.contents(of: root.url, keys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for url in children.sorted(by: { $0.path < $1.path }) {
                if root.scope == .legacyStartupItem {
                    if let entry = legacyEntry(folder: url) { entries.append(entry) }
                } else if url.pathExtension == "plist" {
                    entries.append(entry(plistURL: url, scope: root.scope, states: states, appLocator: appLocator, denied: denied))
                }
            }
        }
        entries.sort {
            $0.riskLevel != $1.riskLevel ? $0.riskLevel > $1.riskLevel
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        return ScanReport(items: entries, deniedPaths: denied.paths)
    }

    static func locateApplication(_ bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    // MARK: - Launch property lists

    static func entry(plistURL url: URL, scope: StartupAuditEntry.Scope, states: DisabledStates,
                      appLocator: (String) -> URL?, denied: DeniedFolders) -> StartupAuditEntry {
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        let fileFlags = propertyListFlags(url, scope: scope)
        var notes: [String] = []
        if (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
            notes.append("The property list is a symbolic link to \(url.resolvingSymlinksInPath().path).")
        }
        let dictionary: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            dictionary = parsed
        } catch {
            denied.note(url, error)
            let reason = FolderAccessCheck.classify(error as NSError) == .restricted
                ? "macOS did not allow reading this property list, so it could not be checked."
                : "This property list could not be parsed, so launchd cannot load it either."
            return StartupAuditEntry(label: fallbackLabel, plistURL: url, scope: scope, programPath: nil, programExists: false,
                                     signature: nil, runsAtLoad: false, keepAlive: false, isScheduled: false,
                                     associatedBundleIdentifiers: [], disabled: nil, flags: fileFlags, notes: notes + [reason])
        }

        let label = (dictionary["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLabel
        let associated: [String] = (dictionary["AssociatedBundleIdentifiers"] as? [String])
            ?? (dictionary["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        let program = resolveProgram(dictionary, associated: associated, appLocator: appLocator)
        if let note = program.note { notes.append(note) }
        let arguments = dictionary["ProgramArguments"] as? [String] ?? []
        let script = program.path.flatMap { interpreterScript(program: $0, arguments: arguments) }
        if let script {
            notes.append("Runs through \((script.interpreter as NSString).lastPathComponent). The signature shown is the interpreter's; "
                + (script.path.map { "the script it runs (\($0)) is not covered by it." } ?? "the command it runs is not covered by it."))
        }
        let signature = program.exists ? program.path.map { CodeSignatureInspector.inspect(URL(fileURLWithPath: $0)) } : nil
        if signature?.trust == .unknown, let path = program.path, access(path, R_OK) != 0 {
            notes.append("Only root can read this program, so its signature could not be checked.")
        }

        var flags: [StartupAuditEntry.RiskFlag] = []
        let scriptMissing = script?.path.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        if program.knownMissing || scriptMissing { flags.append(.orphaned) }
        flags += signatureFlags(signature)
        if [program.path, script?.path].compactMap({ $0 }).contains(where: isUserWritableLocation) {
            flags.append(.userWritableLocation)
        }
        if dictionary["KeepAlive"] as? Bool == true { flags.append(.keepAliveAlways) }
        flags += fileFlags

        let overrides = scope == .systemDaemon ? states.system : states.user
        let plistDisabled = dictionary["Disabled"] as? Bool ?? false
        let keepAlive: Bool
        if let value = dictionary["KeepAlive"] as? Bool { keepAlive = value } else { keepAlive = dictionary["KeepAlive"] is [String: Any] }

        return StartupAuditEntry(
            label: label, plistURL: url, scope: scope, programPath: program.path, programExists: program.exists,
            scriptPath: script?.path, signature: signature,
            runsAtLoad: dictionary["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
            isScheduled: dictionary["StartInterval"] != nil || dictionary["StartCalendarInterval"] != nil,
            associatedBundleIdentifiers: associated,
            // No override means the property list's own Disabled key decides.
            disabled: overrides.map { $0[label] ?? plistDisabled },
            flags: flags, notes: notes)
    }

    struct ResolvedProgram: Equatable {
        var path: String?
        var exists: Bool
        /// True only when the program is known to be absent; an unresolvable relative path is not.
        var knownMissing: Bool
        var note: String?
    }

    /// launchd searches these when ProgramArguments[0] is a bare name (`_PATH_STDPATH`).
    static let standardPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func resolveProgram(_ dictionary: [String: Any], associated: [String],
                               appLocator: (String) -> URL?) -> ResolvedProgram {
        let fm = FileManager.default
        let raw = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [String])?.first
        if let raw, !raw.isEmpty {
            if raw.hasPrefix("/") {
                let exists = fm.fileExists(atPath: raw)
                return ResolvedProgram(path: raw, exists: exists, knownMissing: !exists)
            }
            if !raw.contains("/") {
                if let found = standardPath.map({ $0 + "/" + raw }).first(where: { fm.isExecutableFile(atPath: $0) }) {
                    return ResolvedProgram(path: found, exists: true, knownMissing: false)
                }
                return ResolvedProgram(path: raw, exists: false, knownMissing: true,
                                       note: "\(raw) was not found in /usr/bin, /bin, /usr/sbin or /sbin, where launchd looks for it.")
            }
            if let directory = dictionary["WorkingDirectory"] as? String, directory.hasPrefix("/") {
                let path = URL(fileURLWithPath: directory).appending(path: raw).standardizedFileURL.path
                let exists = fm.fileExists(atPath: path)
                return ResolvedProgram(path: path, exists: exists, knownMissing: !exists)
            }
            return ResolvedProgram(path: raw, exists: false, knownMissing: false,
                                   note: "The program is a relative path, so Mac Polish could not check it.")
        }
        if let bundleProgram = dictionary["BundleProgram"] as? String, !bundleProgram.isEmpty {
            for identifier in associated {
                guard let app = appLocator(identifier) else { continue }
                let path = app.appending(path: bundleProgram).standardizedFileURL.path
                // BundleProgram must stay inside its app; a path that climbs out is not trusted.
                guard path.hasPrefix(app.standardizedFileURL.path + "/") else { continue }
                let exists = fm.fileExists(atPath: path)
                return ResolvedProgram(path: path, exists: exists, knownMissing: !exists)
            }
            if associated.isEmpty {
                return ResolvedProgram(path: nil, exists: false, knownMissing: false,
                                       note: "The program (\(bundleProgram)) is inside an app the property list does not name, so it could not be checked.")
            }
            return ResolvedProgram(path: nil, exists: false, knownMissing: true,
                                   note: "The app it belongs to (\(associated.joined(separator: ", "))) was not found.")
        }
        return ResolvedProgram(path: nil, exists: false, knownMissing: true,
                               note: "No program is set, so launchd cannot run it. An uninstaller probably left this file behind.")
    }

    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "python", "python3",
                                            "perl", "ruby", "osascript", "node", "env", "php", "tclsh"]

    /// When the program is a shell or script interpreter, the first absolute path among its arguments.
    static func interpreterScript(program: String, arguments: [String]) -> (interpreter: String, path: String?)? {
        guard interpreters.contains((program as NSString).lastPathComponent) else { return nil }
        let path = arguments.dropFirst().first { $0.hasPrefix("/") && !$0.contains(where: \.isWhitespace) }
        return (program, path)
    }

    static func signatureFlags(_ signature: CodeSignatureSummary?) -> [StartupAuditEntry.RiskFlag] {
        switch signature?.trust {
        case .unsigned: [.unsigned]
        case .invalid: [.invalidSignature]
        case .adHoc: [.adHocSigned]
        default: []
        }
    }

    /// Ownership and permission findings for the property list (or legacy item folder) itself.
    static func propertyListFlags(_ url: URL, scope: StartupAuditEntry.Scope) -> [StartupAuditEntry.RiskFlag] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }
        var flags: [StartupAuditEntry.RiskFlag] = []
        if scope != .userAgent, let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != 0 {
            flags.append(.plistNotOwnedByRoot)
        }
        if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o002 != 0 {
            flags.append(.plistWorldWritable)
        }
        return flags
    }

    /// Temporary and shared folders, or any hidden folder (a name starting with ".") along the path,
    /// for example `~/Library/Application Support/.helper/agent`.
    static func isUserWritableLocation(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let shared = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/Users/Shared", "/var/folders", "/private/var/folders"]
        if shared.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) { return true }
        return standardized.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    // MARK: - Legacy startup items

    static func legacyEntry(folder: URL) -> StartupAuditEntry? {
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
        let name = folder.lastPathComponent
        let program = folder.appending(path: name).path
        let parameters = folder.appending(path: "StartupParameters.plist")
        let exists = FileManager.default.fileExists(atPath: program)
        let signature = exists ? CodeSignatureInspector.inspect(URL(fileURLWithPath: program)) : nil
        var flags: [StartupAuditEntry.RiskFlag] = exists ? [] : [.orphaned]
        flags += signatureFlags(signature)
        if isUserWritableLocation(program) { flags.append(.userWritableLocation) }
        flags += propertyListFlags(folder, scope: .legacyStartupItem)
        return StartupAuditEntry(
            label: name, plistURL: FileManager.default.fileExists(atPath: parameters.path) ? parameters : folder,
            scope: .legacyStartupItem, programPath: program, programExists: exists, signature: signature,
            runsAtLoad: true, keepAlive: false, isScheduled: false, associatedBundleIdentifiers: [], disabled: nil,
            flags: flags,
            notes: ["macOS has not run legacy startup items since OS X Yosemite (10.10). This is most likely left over from old software."])
    }

    // MARK: - launchctl print-disabled

    static func queryDisabledStates() -> DisabledStates {
        let user = SystemDataScanner.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: 10)
        let system = SystemDataScanner.run("/bin/launchctl", ["print-disabled", "system"], timeout: 10)
        return DisabledStates(user: user.status == 0 ? parseDisabled(user.output) : nil,
                              system: system.status == 0 ? parseDisabled(system.output) : nil)
    }

    /// Parses `"label" => disabled|enabled` lines (macOS 11 and later) and `"label" => true|false`
    /// (older releases, where true means disabled). Unrecognized lines are ignored.
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), let arrow = text.range(of: "=>") else { continue }
            let key = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            guard key.count >= 2, key.hasSuffix("\"") else { continue }
            let label = String(key.dropFirst().dropLast())
            switch text[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased() {
            case "disabled", "true": states[label] = true
            case "enabled", "false": states[label] = false
            default: continue
            }
        }
        return states
    }

    // MARK: - System extensions

    /// Installed system extensions; nil when `systemextensionsctl` failed or timed out (not the same as none).
    static func systemExtensions() -> [SystemExtensionInfo]? {
        let result = SystemDataScanner.run("/usr/bin/systemextensionsctl", ["list"], timeout: 10)
        guard result.status == 0 else { return nil }
        return parseSystemExtensions(result.output)
    }

    /// Parses `systemextensionsctl list`: `--- <category>` headers, a column header row, then tab-separated rows
    /// `enabled  active  teamID  bundleID (version)  name  [state]` where enabled and active are `*` or empty.
    static func parseSystemExtensions(_ output: String) -> [SystemExtensionInfo] {
        var category = ""
        var results: [SystemExtensionInfo] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") {
                category = trimmed.drop(while: { $0 == "-" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard trimmed.hasSuffix("]"), let open = trimmed.range(of: "[", options: .backwards),
                  !trimmed.hasPrefix("enabled") else { continue }
            let state = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            let columns = line.components(separatedBy: "\t")
            var enabled = state.contains("enabled")
            var active = state.contains("activated")
            let fields: [String]
            if columns.count >= 6 {
                enabled = columns[0].contains("*")
                active = columns[1].contains("*")
                fields = Array(columns[2...]).map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                // Space-separated fallback: drop the `*` markers and keep team, bundle and name.
                let body = trimmed[..<open.lowerBound].split(separator: " ", omittingEmptySubsequences: true)
                    .drop(while: { $0 == "*" }).joined(separator: " ")
                guard let team = body.split(separator: " ").first else { continue }
                let rest = body.dropFirst(team.count).trimmingCharacters(in: .whitespaces)
                guard let close = rest.range(of: ")") else { continue }
                fields = [String(team), String(rest[..<close.upperBound]),
                          rest[close.upperBound...].trimmingCharacters(in: .whitespaces)]
            }
            guard fields.count >= 3 else { continue }
            let team = fields[0]
            let bundleColumn = fields[1]
            var bundleID = bundleColumn
            var version: String?
            if let paren = bundleColumn.range(of: " (") , bundleColumn.hasSuffix(")") {
                bundleID = String(bundleColumn[..<paren.lowerBound])
                version = String(bundleColumn[paren.upperBound..<bundleColumn.index(before: bundleColumn.endIndex)])
            }
            guard !bundleID.isEmpty else { continue }
            results.append(SystemExtensionInfo(
                category: category, enabled: enabled, active: active,
                teamID: team.isEmpty || team == "-" ? nil : team, bundleID: bundleID, version: version,
                name: fields[2], state: state))
        }
        return results
    }
}
