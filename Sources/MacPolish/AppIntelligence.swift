import AppKit
import CoreServices
import Darwin
import Foundation

// MARK: - Application insight

/// What an app is built for, who signed it and when it was last opened. Read-only.
struct ApplicationInsight: Codable, Sendable, Hashable {
    let path: String
    /// Slices of the main executable, for example ["x86_64", "arm64"]. Empty when it could not be read.
    let architectures: [String]
    /// True when the executable has slices but none for Apple silicon. Only meaningful on an Apple silicon Mac.
    let needsRosetta: Bool
    /// The app carries a Mac App Store receipt (`Contents/_MASReceipt/receipt`).
    let isAppStore: Bool
    let signature: CodeSignatureSummary
    /// Spotlight's last-used date; nil when Spotlight has no record (indexing off, excluded volume, never opened
    /// through Launch Services). nil never means "unused".
    let lastUsed: Date?

    var hasAppleSilicon: Bool { architectures.contains { $0 == "arm64" || $0 == "arm64e" } }
    var hasIntel: Bool { architectures.contains { $0 == "x86_64" || $0 == "x86_64h" || $0 == "i386" } }
    var isUniversal: Bool { hasAppleSilicon && hasIntel }

    /// True only when Spotlight recorded a last use older than `days`. Unknown use is never unused.
    func isUnused(now: Date = Date(), days: Int) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) > TimeInterval(days) * 86_400
    }

    /// Whole days since the recorded last use; nil when unknown.
    func daysSinceLastUse(now: Date = Date()) -> Int? {
        lastUsed.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }

    static let hostIsAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
}

enum ApplicationInsightScanner {
    /// Entry point for `--scan-worker app-insights --paths <json array>`; nil when `--paths` is missing or invalid.
    static func workerRun(arguments: [String]) -> [ApplicationInsight]? {
        guard let index = arguments.firstIndex(of: "--paths"), arguments.indices.contains(index + 1),
              let paths = try? JSONDecoder().decode([String].self, from: Data(arguments[index + 1].utf8)) else { return nil }
        return scan(paths: paths)
    }

    /// Insights for absolute `.app` paths that exist, in input order. Four apps are inspected at a time.
    static func scan(paths: [String]) -> [ApplicationInsight] {
        let apps = paths.filter { path in
            var isDirectory: ObjCBool = false
            return path.hasPrefix("/") && path.lowercased().hasSuffix(".app")
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return SystemDataScanner.measureAll(apps, width: 4) { insight(for: URL(fileURLWithPath: $0)) }
    }

    static func insight(for appURL: URL) -> ApplicationInsight {
        let architectures = executableURL(of: appURL).flatMap(readHeader).map(architectures(ofMachO:)) ?? []
        return ApplicationInsight(
            path: appURL.path,
            architectures: architectures,
            needsRosetta: !architectures.isEmpty && !architectures.contains { $0 == "arm64" || $0 == "arm64e" },
            isAppStore: FileManager.default.fileExists(atPath: appURL.appending(path: "Contents/_MASReceipt/receipt").path),
            signature: CodeSignatureInspector.inspect(appURL),
            lastUsed: lastUsedDate(appURL.path))
    }

    /// `Contents/MacOS/<CFBundleExecutable>`; nil when the Info.plist does not name a plain file.
    static func executableURL(of appURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return appURL.appending(path: "Contents/MacOS/" + name)
    }

    /// The first 4 KB: enough for a fat header of 30 slices or a thin Mach-O header.
    private static func readHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 4_096)
    }

    /// Architectures named by a Mach-O header: thin (MH_MAGIC/MH_CIGAM, 32 or 64-bit) or fat
    /// (FAT_MAGIC/FAT_CIGAM, FAT_MAGIC_64/FAT_CIGAM_64). Empty for anything else, including truncated
    /// headers and Java class files (which share 0xCAFEBABE but have no plausible slice count).
    static func architectures(ofMachO data: Data) -> [String] {
        let bytes = [UInt8](data.prefix(4_096))
        func word(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let b = bytes[offset..<(offset + 4)].map(UInt32.init)
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        guard let magic = word(0, bigEndian: true) else { return [] }
        switch magic {
        case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE:
            // MH_MAGIC(_64) read big-endian means the header is big-endian; the byte-swapped forms are little-endian.
            let bigEndian = magic == 0xFEED_FACE || magic == 0xFEED_FACF
            guard let type = word(4, bigEndian: bigEndian), let subtype = word(8, bigEndian: bigEndian) else { return [] }
            return [architectureName(cpuType: type, subtype: subtype)]
        case 0xCAFE_BABE, 0xCAFE_BABF, 0xBEBA_FECA, 0xBFBA_FECA:
            let bigEndian = magic == 0xCAFE_BABE || magic == 0xCAFE_BABF
            let entrySize = (magic == 0xCAFE_BABF || magic == 0xBFBA_FECA) ? 32 : 20
            guard let count = word(4, bigEndian: bigEndian), count > 0, count <= 30 else { return [] }
            var names: [String] = []
            for slice in 0..<Int(count) {
                let offset = 8 + slice * entrySize
                guard offset + entrySize <= bytes.count, let type = word(offset, bigEndian: bigEndian),
                      let subtype = word(offset + 4, bigEndian: bigEndian) else { return [] }
                let name = architectureName(cpuType: type, subtype: subtype)
                if !names.contains(name) { names.append(name) }
            }
            return names
        default:
            return []
        }
    }

    static func architectureName(cpuType: UInt32, subtype: UInt32) -> String {
        let plainSubtype = subtype & 0x00FF_FFFF // without CPU_SUBTYPE_MASK capability bits
        switch cpuType {
        case 0x0100_000C: return plainSubtype == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: return plainSubtype == 8 ? "x86_64h" : "x86_64"
        case 0x0200_000C: return "arm64_32"
        case 7: return "i386"
        case 12: return "arm"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return "cpu-0x" + String(cpuType, radix: 16)
        }
    }

    /// Spotlight's `kMDItemLastUsedDate`; nil when Spotlight has no record.
    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Leftover locations used by ApplicationScanner

enum AppLeftoverLocations {
    /// `Preferences/ByHost/<id>.<host>.plist`. The host part must be a hardware UUID or MAC-style hex string,
    /// so a helper's preferences such as `<id>.helper.<host>.plist` are not counted as the app's own.
    static func byHostPreferences(_ bundleIdentifier: String, library: URL) -> [URL] {
        let folder = library.appending(path: "Preferences/ByHost")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let prefix = bundleIdentifier + "."
        let hostCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return names.sorted().filter { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".plist"), name.count > prefix.count + ".plist".count else { return false }
            let host = name.dropFirst(prefix.count).dropLast(".plist".count)
            return !host.isEmpty && host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
        }.map { folder.appending(path: $0) }
    }

    /// `Group Containers/group.<id>` and `Group Containers/<TEAMID>.<id>`: the name minus its first component must
    /// equal the bundle identifier exactly. A team-only container (`<TEAMID>.shared`) is shared by a developer's apps
    /// and never matches. Apple's group containers are never returned.
    static func groupContainers(_ bundleIdentifier: String, library: URL) -> [URL] {
        guard !bundleIdentifier.lowercased().hasPrefix("com.apple.") else { return [] }
        let folder = library.appending(path: "Group Containers")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().filter { name in
            guard let dot = name.firstIndex(of: "."), name[name.index(after: dot)...] == bundleIdentifier else { return false }
            let owner = String(name[..<dot])
            guard owner == "group" || isTeamIdentifier(owner) else { return false }
            let values = try? folder.appending(path: name).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.map { folder.appending(path: $0) }
    }

    /// Apple team identifiers are ten uppercase letters or digits.
    static func isTeamIdentifier(_ text: String) -> Bool {
        text.count == 10 && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}

// MARK: - Installed applications

enum InstalledApplications {
    struct Snapshot: Sendable {
        /// Lower-cased bundle identifiers of the apps and their helpers, login items and extensions.
        var bundleIdentifiers: Set<String> = []
        /// App groups those bundles declare in their entitlements, for example group.net.whatsapp.family.
        var applicationGroups: Set<String> = []
    }

    /// Apps in the folders `ApplicationScanner` lists (/Applications, /System/Applications, ~/Applications and
    /// their sub-folders), with the helpers, login items and extensions inside them. Reads only Info.plist files
    /// and entitlements: `ApplicationScanner.scan()` also measures every app and its leftovers, which is far
    /// slower and not needed for identifiers.
    static func snapshot(roots: [URL]? = nil, includeGroups: Bool = true) -> Snapshot {
        let fm = FileManager.default
        let roots = roots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                              URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                              fm.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)]
        var snapshot = Snapshot()
        func add(_ bundle: URL) {
            if let identifier = bundleIdentifier(ofApp: bundle) { snapshot.bundleIdentifiers.insert(identifier.lowercased()) }
            if includeGroups { snapshot.applicationGroups.formUnion(CodeSignatureInspector.applicationGroups(bundle)) }
        }
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                add(url)
                for folder in ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/Helpers"] {
                    let nested = url.appending(path: folder)
                    for name in (try? fm.contentsOfDirectory(atPath: nested.path)) ?? []
                    where name.hasSuffix(".app") || name.hasSuffix(".appex") {
                        add(nested.appending(path: name))
                    }
                }
            }
        }
        return snapshot
    }

    static func bundleIdentifiers(roots: [URL]? = nil) -> Set<String> {
        snapshot(roots: roots, includeGroups: false).bundleIdentifiers
    }

    static func bundleIdentifier(ofApp url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}

// MARK: - Orphaned app data

/// A folder or file in ~/Library named after an app that is no longer installed. Review-only: never preselected.
struct OrphanedDataItem: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let url: URL
    let bundleIdentifier: String
    /// The ~/Library folder it is directly inside, for example "Application Support".
    let location: String
    let size: Int64
    let newestContentModifiedAt: Date?
    let modifiedAt: Date?
    let isMeasurementComplete: Bool
    /// An installed app from the same developer prefix (for example com.microsoft.word for com.microsoft.office):
    /// the data may be shared by that developer's apps.
    var sameVendorApp: String? = nil
    var isSelected = false
}

enum OrphanedDataScanner {
    /// The ~/Library folders whose direct children are named after bundle identifiers.
    static let locations = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                            "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Application Scripts"]

    /// Data that belongs to something other than an app with the same identifier, so "no such app" does not mean
    /// "left behind". Matched as the identifier itself or a parent of it.
    static let knownNonAppOwners: [String] = [
        "org.swift.swiftpm",                     // Swift Package Manager, a command-line tool: package caches
        "org.carthage.carthagekit",              // Carthage, a command-line tool: dependency caches
        "com.plausiblelabs.crashreporter.data",  // PLCrashReporter framework: crash data kept per host app
        "com.crashlytics",                       // Firebase Crashlytics SDK: data kept per host app
        "com.google.keystone",                   // Google Software Update agent (a .bundle, not an app), shared by Google apps
        "com.google.softwareupdate",             // the same updater's older identifier
        "com.google.googleupdater",              // Google's current updater, installed inside Application Support
        "com.microsoft.autoupdate",              // Microsoft AutoUpdate helpers, shared by all Microsoft apps
        "com.microsoft.autoupdate2",             // Microsoft AutoUpdate, which lives in /Library/Application Support
        "org.cups",                              // the macOS printing system (CUPS)
        "com.openssh",                           // OpenSSH bundled with macOS (ssh-agent)
        "is.workflow",                           // Apple Shortcuts, which kept the identifiers of Workflow, the app Apple bought
        "com.vercel.cli",                        // Vercel's command-line tool: its sign-in and settings, not an app's
        "com.asaied.macpolish",                  // Mac Polish itself, including development builds outside Applications
    ]

    /// Developer prefixes shared by unrelated projects, so a match says nothing about common ownership.
    static let genericVendorPrefixes: Set<String> = ["com.github", "io.github", "com.electron", "org.chromium"]

    /// Entry point for `--scan-worker orphans`.
    static func workerRun(arguments: [String] = []) -> ScanReport<OrphanedDataItem> {
        let installed = InstalledApplications.snapshot()
        return scan(home: FileManager.default.homeDirectoryForCurrentUser, installedBundleIDs: installed.bundleIdentifiers,
                    installedGroups: installed.applicationGroups)
    }

    /// `installedGroups`: app groups declared by installed apps. Group folders are named after groups, not bundle
    /// identifiers (WhatsApp uses group.com.facebook.family), so they are matched against these as well.
    static func scan(home: URL, installedBundleIDs: Set<String>, installedGroups: Set<String> = [],
                     isRegistered: (String) -> Bool = isRegisteredWithLaunchServices) -> ScanReport<OrphanedDataItem> {
        let installed = Set(installedBundleIDs.map { $0.lowercased() })
        let groups = groupKeys(installedGroups)
        let library = home.appending(path: "Library")
        let denied = DeniedFolders()
        var items: [OrphanedDataItem] = []
        for location in locations {
            let folder = library.appending(path: location)
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
            guard let children = denied.contents(of: folder, keys: keys) else { continue }
            for url in children.sorted(by: { $0.path < $1.path }) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isSymbolicLink != true,
                      let identifier = bundleIdentifier(forName: url.lastPathComponent, location: location),
                      location != "Preferences" || values?.isRegularFile == true,
                      !groups.contains(identifier.lowercased()),
                      !isInstalled(identifier, installed: installed, isRegistered: isRegistered) else { continue }
                let measurement = FileSizeCalculator.measure(url) { path, code in
                    denied.note(path, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
                }
                // Like the cleanup scan: an empty item frees nothing. One that could not be read stays listed.
                guard measurement.bytes > 0 || measurement.unreadableFolders > 0 else { continue }
                items.append(OrphanedDataItem(
                    id: UUID(), url: url, bundleIdentifier: identifier, location: location, size: measurement.bytes,
                    newestContentModifiedAt: measurement.newestModification, modifiedAt: values?.contentModificationDate,
                    isMeasurementComplete: measurement.unreadableFolders == 0,
                    sameVendorApp: sameVendorApp(identifier, installed: installed)))
            }
        }
        items.sort { $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path }
        return ScanReport(items: items, deniedPaths: denied.paths)
    }

    /// The bundle identifier a ~/Library child is named after, or nil when it is not an app's reverse-DNS name,
    /// belongs to Apple, or belongs to a known non-app owner.
    static func bundleIdentifier(forName name: String, location: String) -> String? {
        var identifier = name
        switch location {
        case "Preferences":
            guard name.hasSuffix(".plist") else { return nil }
            identifier = String(name.dropLast(".plist".count))
        case "Saved Application State":
            guard name.hasSuffix(".savedState") else { return nil }
            identifier = String(name.dropLast(".savedState".count))
        case "HTTPStorages":
            if name.hasSuffix(".binarycookies") { identifier = String(name.dropLast(".binarycookies".count)) }
        case "Group Containers":
            guard let remainder = groupRemainder(name) else { return nil }
            identifier = remainder
        case "Application Scripts":
            // Holds folders for app groups too (group.<id>, <TEAMID>.<id>), next to bundle identifiers.
            if let remainder = groupRemainder(name) { identifier = remainder }
        default:
            break
        }
        let lower = name.lowercased()
        // Apple's groups do not always start with it, for example 243LU875E5.groups.com.apple.podcasts.
        let appleGroup = isGroupNamed(name, location: location) && lower.contains("com.apple.")
        guard looksLikeBundleIdentifier(identifier), !lower.hasPrefix("systemgroup."), !lower.hasPrefix("group.com.apple."),
              !appleGroup, !identifier.lowercased().hasPrefix("com.apple."), !isKnownNonAppOwner(identifier) else { return nil }
        return identifier
    }

    /// The identifier inside an app-group name: `group.<id>` or `<TEAMID>.<id>`; nil for other names.
    static func groupRemainder(_ name: String) -> String? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let owner = String(name[..<dot])
        guard owner == "group" || AppLeftoverLocations.isTeamIdentifier(owner) else { return nil }
        return String(name[name.index(after: dot)...])
    }

    static func isGroupNamed(_ name: String, location: String) -> Bool {
        location == "Group Containers" || (location == "Application Scripts" && groupRemainder(name) != nil)
    }

    /// Installed app groups in the form folders are compared in: the whole group and its identifier part, lower-cased.
    static func groupKeys(_ groups: Set<String>) -> Set<String> {
        Set(groups.flatMap { [$0.lowercased(), groupRemainder($0)?.lowercased()].compactMap { $0 } })
    }

    /// At least three dot-separated parts of letters, digits and hyphens, for example com.vendor.app.
    static func looksLikeBundleIdentifier(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
        }
    }

    static func isKnownNonAppOwner(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        let own = Bundle.main.bundleIdentifier?.lowercased()
        return (knownNonAppOwners + [own].compactMap { $0 }).contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    /// Installed when an installed app has this identifier, extends it (`<id>.helper`) or is extended by it
    /// (data of `<installed>.helper`), or when Launch Services knows an app with this identifier or a parent of it.
    static func isInstalled(_ identifier: String, installed: Set<String>, isRegistered: (String) -> Bool) -> Bool {
        let lower = identifier.lowercased()
        if installed.contains(lower) { return true }
        if installed.contains(where: { $0.hasPrefix(lower + ".") || lower.hasPrefix($0 + ".") }) { return true }
        var parts = identifier.split(separator: ".")
        while parts.count >= 3 {
            if isRegistered(parts.joined(separator: ".")) { return true }
            parts.removeLast()
        }
        return false
    }

    /// True when Launch Services knows any app with this bundle identifier, on any mounted volume.
    static func isRegisteredWithLaunchServices(_ identifier: String) -> Bool {
        !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).isEmpty
    }

    static func sameVendorApp(_ identifier: String, installed: Set<String>) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = parts.prefix(2).joined(separator: ".")
        guard !genericVendorPrefixes.contains(vendor) else { return nil }
        return installed.filter { $0.hasPrefix(vendor + ".") }.sorted().first
    }
}

/// Moves reviewed orphaned app data to Trash after checking that nothing about it changed since the scan.
struct OrphanedDataCleaner: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Checks installed apps at clean time: the Applications folders and their app groups once, then Launch
    /// Services per identifier. For a group folder the identifier is the group's, so groups are checked too.
    static func live() -> (String) -> Bool {
        let installed = InstalledApplications.snapshot()
        let groups = OrphanedDataScanner.groupKeys(installed.applicationGroups)
        return { identifier in
            groups.contains(identifier.lowercased())
                || OrphanedDataScanner.isInstalled(identifier, installed: installed.bundleIdentifiers,
                                                   isRegistered: OrphanedDataScanner.isRegisteredWithLaunchServices)
        }
    }

    func clean(_ items: [OrphanedDataItem],
               installedCheck: (String) -> Bool = OrphanedDataCleaner.live(),
               trashItem: (URL) throws -> Void = { url in _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil) }) -> CleanupResult {
        var removed: Set<UUID> = []
        var bytes: Int64 = 0
        var issues: [CleanupIssue] = []
        for item in items where item.isSelected {
            if let issue = validate(item, installedCheck: installedCheck) {
                issues.append(issue)
                continue
            }
            // Measured again now: the recorded size may be stale, and partial access was refused above.
            let measurement = FileSizeCalculator.measure(item.url)
            do {
                try trashItem(item.url)
                removed.insert(item.id)
                bytes += measurement.bytes
            } catch {
                // Other apps' containers can be refused by macOS (App Management / data of other apps).
                issues.append(TrashValidation.issue(for: error as NSError, url: item.url))
            }
        }
        return CleanupResult(removedCount: removed.count, reclaimedBytes: bytes, failures: issues.map(\.message),
                             removedItemIDs: removed, issues: issues)
    }

    /// Every check the scan made, made again: path, place, name, ownership, permissions and content.
    func validate(_ item: OrphanedDataItem, installedCheck: (String) -> Bool) -> CleanupIssue? {
        let url = item.url
        guard TrashValidation.isUnredirected(url) else {
            return CleanupIssue(url: url, kind: .unsafe, detail: "A symbolic link or redirected folder changed the path. The item was skipped.")
        }
        let library = home.appending(path: "Library").standardizedFileURL
        guard OrphanedDataScanner.locations.contains(item.location),
              url.standardizedFileURL.deletingLastPathComponent().path == library.appending(path: item.location).standardizedFileURL.path else {
            return CleanupIssue(url: url, kind: .unsafe,
                                detail: "This item is not directly inside ~/Library/\(item.location), so Mac Polish will not move it.")
        }
        guard OrphanedDataScanner.bundleIdentifier(forName: url.lastPathComponent, location: item.location) == item.bundleIdentifier else {
            return CleanupIssue(url: url, kind: .unsafe, detail: "The name no longer matches \(item.bundleIdentifier). The item was skipped.")
        }
        guard !installedCheck(item.bundleIdentifier) else {
            return CleanupIssue(url: url, kind: .changed,
                                detail: "An app using \(item.bundleIdentifier) is installed now, so this data is not left over. It was kept.")
        }
        if let issue = TrashValidation.preflight(url) { return issue }
        let current = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        guard current == item.modifiedAt else {
            return CleanupIssue(url: url, kind: .changed, detail: "The item changed after scanning. Scan again before moving it.")
        }
        let measurement = FileSizeCalculator.measure(url)
        guard item.isMeasurementComplete, measurement.unreadableFolders == 0 else {
            if item.location == "Containers" || item.location == "Group Containers" {
                // macOS protects other apps' containers; the same advice as a refused move.
                return TrashValidation.issue(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), url: url)
            }
            return CleanupIssue(url: url, kind: .changed,
                                detail: "Could not verify all content inside this item. Check folder access and scan again before moving it.")
        }
        if let newest = measurement.newestModification, newest > (item.newestContentModifiedAt ?? .distantPast) {
            return CleanupIssue(url: url, kind: .changed, detail: "Content inside this item changed after scanning. Scan again before moving it.")
        }
        return nil
    }
}
