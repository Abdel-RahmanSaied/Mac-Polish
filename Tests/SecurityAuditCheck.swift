import Foundation

/// Startup audit, code signatures, Mach-O architectures, expanded uninstall leftovers and orphaned app data.
/// Fixtures live in a unique folder under ~/Library/Caches (temporary folders count as user-writable
/// locations, which would flag every fixture program). Nothing outside it is changed; Trash is never used.
@main
enum SecurityAuditCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-security-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // MARK: Code signatures on real and generated binaries
        let bin = root.appending(path: "bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let adHoc = bin.appending(path: "adhoc-tool")
        try fm.copyItem(atPath: "/bin/ls", toPath: adHoc.path)
        precondition(SystemDataScanner.run("/usr/bin/codesign", ["-s", "-", "-f", adHoc.path], timeout: 60).status == 0, "ad-hoc signing")
        let source = bin.appending(path: "tool.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let unsigned = bin.appending(path: "unsigned-tool")
        precondition(SystemDataScanner.run("/usr/bin/cc", [source.path, "-o", unsigned.path], timeout: 120).status == 0, "compile fixture")
        precondition(SystemDataScanner.run("/usr/bin/codesign", ["--remove-signature", unsigned.path], timeout: 60).status == 0, "remove signature")

        let lsSignature = CodeSignatureInspector.inspect(URL(fileURLWithPath: "/bin/ls"))
        precondition(lsSignature.trust == .apple, "/bin/ls is Apple-signed, got \(lsSignature)")
        let adHocSignature = CodeSignatureInspector.inspect(adHoc)
        precondition(adHocSignature.trust == .adHoc && adHocSignature.teamID == nil, "Ad-hoc copy, got \(adHocSignature)")
        precondition(CodeSignatureInspector.inspect(unsigned).trust == .unsigned, "Signature removed")
        precondition(CodeSignatureInspector.inspect(bin.appending(path: "nothing-here")).trust == .missing)
        precondition(CodeSignatureInspector.summary(forFailure: errSecCSUnsigned).trust == .unsigned)
        precondition(CodeSignatureInspector.summary(forFailure: errSecCSSignatureFailed).trust == .invalid)

        // MARK: Launch property lists
        let userAgents = root.appending(path: "user/LaunchAgents")
        let globalAgents = root.appending(path: "global/LaunchAgents")
        let daemons = root.appending(path: "global/LaunchDaemons")
        let legacy = root.appending(path: "global/StartupItems")
        for folder in [userAgents, globalAgents, daemons, legacy.appending(path: "OldItem")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let hidden = root.appending(path: "Application Support/.cache-helper")
        try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/ls", toPath: hidden.appending(path: "agent").path)
        let scripts = root.appending(path: ".scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: scripts.appending(path: "run.sh"))
        let app = root.appending(path: "Apps/Test.app")
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/ls", toPath: app.appending(path: "Contents/MacOS/helper").path)

        func plist(_ folder: URL, _ name: String, _ values: [String: Any]) throws -> URL {
            let url = folder.appending(path: name + ".plist")
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
            return url
        }
        _ = try plist(userAgents, "com.test.orphan", ["Label": "com.test.orphan", "Program": root.appending(path: "missing/tool").path])
        _ = try plist(globalAgents, "com.test.apple", ["Label": "com.test.apple", "ProgramArguments": ["/bin/ls", "-l"], "RunAtLoad": true])
        _ = try plist(userAgents, "com.test.adhoc", ["Label": "com.test.adhoc", "Program": adHoc.path])
        _ = try plist(daemons, "com.test.unsigned", ["Label": "com.test.unsigned", "Program": unsigned.path, "RunAtLoad": true])
        _ = try plist(userAgents, "com.test.hidden", ["Label": "com.test.hidden", "Program": hidden.appending(path: "agent").path])
        _ = try plist(userAgents, "com.test.keepalive", ["Label": "com.test.keepalive", "ProgramArguments": ["ls"],
                                                          "KeepAlive": ["SuccessfulExit": false], "StartCalendarInterval": ["Hour": 3]])
        _ = try plist(userAgents, "com.test.always", ["Label": "com.test.always", "Program": "/bin/ls", "KeepAlive": true])
        _ = try plist(userAgents, "com.test.bundle", ["Label": "com.test.bundle", "BundleProgram": "Contents/MacOS/helper",
                                                       "AssociatedBundleIdentifiers": "com.test.app"])
        _ = try plist(userAgents, "com.test.bundle-gone", ["Label": "com.test.bundle-gone", "BundleProgram": "Contents/MacOS/helper",
                                                            "AssociatedBundleIdentifiers": ["com.test.gone"]])
        _ = try plist(userAgents, "com.test.escape", ["Label": "com.test.escape", "BundleProgram": "../../../bin/ls",
                                                       "AssociatedBundleIdentifiers": ["com.test.app"]])
        _ = try plist(userAgents, "com.test.script", ["Label": "com.test.script",
                                                       "ProgramArguments": ["/bin/sh", scripts.appending(path: "run.sh").path]])
        let open = try plist(userAgents, "com.test.open", ["Label": "com.test.open", "Program": "/bin/ls"])
        try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: open.path)
        _ = try plist(userAgents, "com.test.empty", [:])
        try Data("not a property list".utf8).write(to: userAgents.appending(path: "com.test.broken.plist"))

        let report = StartupAuditor.audit(
            home: root.appending(path: "user"),
            roots: [StartupAuditor.Root(url: userAgents, scope: .userAgent),
                    StartupAuditor.Root(url: globalAgents, scope: .globalAgent),
                    StartupAuditor.Root(url: daemons, scope: .systemDaemon),
                    StartupAuditor.Root(url: legacy, scope: .legacyStartupItem),
                    StartupAuditor.Root(url: root.appending(path: "absent"), scope: .systemDaemon)],
            disabledStates: StartupAuditor.DisabledStates(user: ["com.test.keepalive": true], system: nil),
            appLocator: { $0 == "com.test.app" ? app : nil })
        precondition(report.deniedPaths.isEmpty, "A missing folder is not a denial, got \(report.deniedPaths)")
        func entry(_ label: String) -> StartupAuditEntry {
            guard let found = report.items.first(where: { $0.label == label }) else {
                preconditionFailure("\(label) is listed, got \(report.items.map(\.label))")
            }
            return found
        }
        let orphan = entry("com.test.orphan")
        precondition(!orphan.programExists && orphan.flags == [.orphaned] && orphan.riskLevel == .low && orphan.signature == nil)
        let apple = entry("com.test.apple")
        precondition(apple.signature?.trust == .apple && apple.runsAtLoad && apple.programPath == "/bin/ls")
        precondition(apple.flags == [.plistNotOwnedByRoot], "A fixture in /Library would not be owned by root: \(apple.flags)")
        let adHocEntry = entry("com.test.adhoc")
        precondition(adHocEntry.flags == [.adHocSigned] && adHocEntry.riskLevel == .low, "\(adHocEntry.flags)")
        let unsignedEntry = entry("com.test.unsigned")
        precondition(unsignedEntry.signature?.trust == .unsigned && unsignedEntry.flags.contains(.unsigned)
                     && unsignedEntry.flags.contains(.plistNotOwnedByRoot) && unsignedEntry.riskLevel == .high,
                     "An unsigned root daemon is high risk: \(unsignedEntry.flags)")
        precondition(unsignedEntry.disabled == nil, "Unknown system overrides leave the daemon's state unknown")
        let hiddenEntry = entry("com.test.hidden")
        precondition(hiddenEntry.flags.contains(.userWritableLocation) && hiddenEntry.riskLevel == .medium, "\(hiddenEntry.flags)")
        let keepAlive = entry("com.test.keepalive")
        precondition(keepAlive.keepAlive && keepAlive.isScheduled && !keepAlive.flags.contains(.keepAliveAlways))
        precondition(keepAlive.programPath == "/bin/ls" && keepAlive.programExists, "Bare names resolve like launchd: \(keepAlive.programPath ?? "nil")")
        precondition(keepAlive.disabled == true && orphan.disabled == false, "launchctl overrides apply by label")
        precondition(entry("com.test.always").flags == [.keepAliveAlways])
        let bundle = entry("com.test.bundle")
        precondition(bundle.programPath == app.appending(path: "Contents/MacOS/helper").standardizedFileURL.path && bundle.programExists
                     && bundle.associatedBundleIdentifiers == ["com.test.app"] && !bundle.flags.contains(.orphaned), "BundleProgram resolves in its app")
        precondition(entry("com.test.bundle-gone").flags == [.orphaned], "The associated app is gone")
        let escape = entry("com.test.escape")
        precondition(escape.programPath == nil && !escape.programExists, "BundleProgram may not climb out of its app")
        let script = entry("com.test.script")
        precondition(script.signature?.trust == .apple && script.scriptPath == scripts.appending(path: "run.sh").path
                     && script.flags.contains(.userWritableLocation) && script.findings.contains { $0.contains("Runs through sh") },
                     "The hidden script, not the Apple interpreter, decides: \(script.findings)")
        let openEntry = entry("com.test.open")
        precondition(openEntry.flags.contains(.plistWorldWritable) && openEntry.riskLevel == .high)
        let empty = entry("com.test.empty")
        precondition(empty.flags == [.orphaned] && empty.findings.contains { $0.contains("No program") })
        precondition(entry("com.test.broken").findings.contains { $0.contains("could not be parsed") })
        let oldItem = entry("OldItem")
        precondition(oldItem.scope == .legacyStartupItem && oldItem.flags.contains(.orphaned) && oldItem.disabled == nil)
        precondition(report.items.first?.riskLevel == .high, "Highest risk first")
        precondition(report.items.allSatisfy { $0.riskLevel == .none || !$0.findings.isEmpty }, "Every risk is explained")

        precondition(StartupAuditor.isUserWritableLocation("/tmp/x") && StartupAuditor.isUserWritableLocation("/private/tmp/a/b")
                     && StartupAuditor.isUserWritableLocation("/Users/Shared/tool")
                     && StartupAuditor.isUserWritableLocation("/Users/me/Library/Application Support/.helper/run"))
        precondition(!StartupAuditor.isUserWritableLocation("/Applications/Foo.app/Contents/MacOS/foo")
                     && !StartupAuditor.isUserWritableLocation("/Library/Application Support/Logitech.localized/agent")
                     && !StartupAuditor.isUserWritableLocation("/tmpfiles/tool"))

        // MARK: launchctl print-disabled, both output styles
        let modern = "\tdisabled services = {\n\t\t\"com.foo.bar\" => disabled\n\t\t\"com.foo.baz\" => enabled\n\t}\n\tlogin item associations = {\n\t}\n"
        precondition(StartupAuditor.parseDisabled(modern) == ["com.foo.bar": true, "com.foo.baz": false])
        let older = "{\n\t\"com.old.one\" => true\n\t\"com.old.two\" => false\n\t\"broken => true\n}\n"
        precondition(StartupAuditor.parseDisabled(older) == ["com.old.one": true, "com.old.two": false])
        precondition(StartupAuditor.parseDisabled("").isEmpty)
        if StartupAuditor.queryDisabledStates().user == nil { print("  note: launchctl print-disabled was not readable here") }

        // MARK: systemextensionsctl list
        let extensionsOutput = """
        3 extension(s)
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tVQ6V6Z8RN4\tcom.example.vpn.tunnel (1.2.3/45)\tExample VPN\t[activated enabled]
        --- com.apple.system_extension.endpoint_security
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\tABCDE12345\tcom.foo.es (2.0/7)\tFoo Security\t[activated waiting for user]
        \t\tABCDE12345\tcom.foo.es (1.0/1)\tFoo Security\t[terminated waiting to uninstall on reboot]
        """
        let extensions = StartupAuditor.parseSystemExtensions(extensionsOutput)
        precondition(extensions.count == 3, "Three extensions, got \(extensions)")
        precondition(extensions[0] == SystemExtensionInfo(category: "com.apple.system_extension.network_extension", enabled: true, active: true,
                                                          teamID: "VQ6V6Z8RN4", bundleID: "com.example.vpn.tunnel", version: "1.2.3/45",
                                                          name: "Example VPN", state: "activated enabled"), "\(extensions[0])")
        precondition(!extensions[1].enabled && extensions[1].active && extensions[1].state == "activated waiting for user"
                     && extensions[1].categoryName == "Endpoint security")
        precondition(!extensions[2].active && extensions[2].version == "1.0/1")
        precondition(StartupAuditor.parseSystemExtensions("0 extension(s)\n").isEmpty)

        // MARK: Mach-O headers
        func bytes(_ words: [UInt32], bigEndian: Bool) -> Data {
            Data(words.flatMap { word in
                let le = [UInt8(word & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word >> 16 & 0xFF), UInt8(word >> 24)]
                return bigEndian ? le.reversed() : le
            })
        }
        let arm64: UInt32 = 0x0100_000C, x86: UInt32 = 0x0100_0007
        // Thin headers are written little-endian: the magic reads as MH_MAGIC_64 on the host.
        precondition(ApplicationInsightScanner.architectures(ofMachO: bytes([0xFEED_FACF, arm64, 0, 2, 0, 0, 0, 0], bigEndian: false)) == ["arm64"])
        precondition(ApplicationInsightScanner.architectures(ofMachO: bytes([0xFEED_FACF, x86, 3, 2, 0, 0, 0, 0], bigEndian: false)) == ["x86_64"])
        precondition(ApplicationInsightScanner.architectures(ofMachO: bytes([0xFEED_FACF, arm64, 0x8000_0002, 2], bigEndian: false)) == ["arm64e"])
        precondition(ApplicationInsightScanner.architectures(ofMachO: bytes([0xFEED_FACE, 7, 3, 2], bigEndian: true)) == ["i386"], "Big-endian thin")
        let fat = bytes([0xCAFE_BABE, 2, x86, 3, 0x4000, 0x1000, 14, arm64, 0, 0x8000, 0x1000, 14], bigEndian: true)
        precondition(ApplicationInsightScanner.architectures(ofMachO: fat) == ["x86_64", "arm64"], "Fat binary")
        let fat64 = bytes([0xCAFE_BABF, 1, arm64, 0, 0, 0x4000, 0, 0x1000, 14, 0], bigEndian: true)
        precondition(ApplicationInsightScanner.architectures(ofMachO: fat64) == ["arm64"], "FAT_MAGIC_64")
        let swappedFat = bytes([0xCAFE_BABE, 1, arm64, 0, 0x4000, 0x1000, 14], bigEndian: false)
        precondition(ApplicationInsightScanner.architectures(ofMachO: swappedFat) == ["arm64"], "FAT_CIGAM")
        precondition(ApplicationInsightScanner.architectures(ofMachO: Data("hello, world".utf8)).isEmpty, "Garbage")
        precondition(ApplicationInsightScanner.architectures(ofMachO: fat.prefix(30)).isEmpty, "Truncated fat table")
        precondition(ApplicationInsightScanner.architectures(ofMachO: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00])).isEmpty, "Truncated thin")
        precondition(ApplicationInsightScanner.architectures(ofMachO: Data()).isEmpty)
        precondition(ApplicationInsightScanner.architectures(ofMachO: bytes([0xCAFE_BABE, 52, 0, 0], bigEndian: true)).isEmpty, "Java class file")
        let lsHeader = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/bin/ls")).read(upToCount: 4_096) ?? Data()
        let lsArchitectures = ApplicationInsightScanner.architectures(ofMachO: lsHeader)
        precondition(lsArchitectures.contains { $0.hasPrefix("arm64") }, "/bin/ls has an Apple silicon slice, got \(lsArchitectures)")

        // MARK: Application insight on a fixture app
        let info: [String: Any] = ["CFBundleExecutable": "helper", "CFBundleIdentifier": "com.test.app"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        try fm.createDirectory(at: app.appending(path: "Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: app.appending(path: "Contents/_MASReceipt/receipt"))
        guard let insight = ApplicationInsightScanner.workerRun(arguments: ["--paths", "[\"\(app.path)\", \"relative.app\", \"/nowhere/Gone.app\"]"])?.first else {
            preconditionFailure("The worker entry point returns the fixture app")
        }
        precondition(insight.path == app.path && insight.isAppStore && insight.hasAppleSilicon && !insight.needsRosetta)
        precondition(ApplicationInsightScanner.workerRun(arguments: ["--paths", "not json"]) == nil)
        precondition(ApplicationInsightScanner.workerRun(arguments: []) == nil)
        let unknownUse = ApplicationInsight(path: "/x.app", architectures: ["x86_64"], needsRosetta: true, isAppStore: false,
                                            signature: CodeSignatureSummary(trust: .developerID, teamID: "ABCDE12345"), lastUsed: nil)
        precondition(!unknownUse.isUnused(days: 1), "No Spotlight record is never 'unused'")
        let now = Date()
        let oldUse = ApplicationInsight(path: "/x.app", architectures: ["arm64"], needsRosetta: false, isAppStore: false,
                                        signature: CodeSignatureSummary(trust: .apple), lastUsed: now.addingTimeInterval(-200 * 86_400))
        precondition(oldUse.isUnused(now: now, days: 90) && !oldUse.isUnused(now: now, days: 365) && oldUse.daysSinceLastUse(now: now) == 200)

        // Installed apps and the app groups their entitlements declare (read from a re-signed fixture bundle).
        let entitlements = root.appending(path: "groups.entitlements")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": ["group.com.test.shared"]],
                                           format: .xml, options: 0).write(to: entitlements)
        precondition(SystemDataScanner.run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", entitlements.path, app.path],
                                           timeout: 60).status == 0, "sign fixture app with entitlements")
        let installedSnapshot = InstalledApplications.snapshot(roots: [app.deletingLastPathComponent()])
        precondition(installedSnapshot.bundleIdentifiers == ["com.test.app"] && installedSnapshot.applicationGroups == ["group.com.test.shared"],
                     "Snapshot: \(installedSnapshot)")

        // MARK: Expanded uninstall leftovers
        let library = root.appending(path: "home/Library")
        let id = "com.vendor.app"
        for folder in ["Group Containers/ABCDE12345.\(id)", "Group Containers/group.\(id)", "Group Containers/ABCDE12345",
                       "Group Containers/ABCDE12345.shared", "Group Containers/group.com.vendor.other",
                       "Group Containers/ABCDE12345.\(id).helper", "Group Containers/group.com.apple.notes",
                       "HTTPStorages/\(id)", "WebKit/\(id)", "Logs/\(id)", "Logs/Vendor App", "Application Scripts/\(id)",
                       "Preferences/ByHost", "Cookies"] {
            try fm.createDirectory(at: library.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["Preferences/ByHost/\(id).0A1B2C3D-4E5F-6789-ABCD-EF0123456789.plist", "Preferences/ByHost/\(id).helper.0A1B2C3D.plist",
                     "Preferences/ByHost/com.vendor.other.0A1B2C3D.plist", "Cookies/\(id).binarycookies", "HTTPStorages/\(id).binarycookies"] {
            try Data("x".utf8).write(to: library.appending(path: file))
        }
        let leftovers = Set(ApplicationScanner.leftovers(appName: "Vendor App", bundleIdentifier: id, library: library)
            .map { $0.path.replacingOccurrences(of: library.path + "/", with: "") })
        let expected: Set<String> = ["Group Containers/ABCDE12345.\(id)", "Group Containers/group.\(id)", "HTTPStorages/\(id)",
                                     "HTTPStorages/\(id).binarycookies", "WebKit/\(id)", "Logs/\(id)", "Logs/Vendor App",
                                     "Application Scripts/\(id)", "Cookies/\(id).binarycookies",
                                     "Preferences/ByHost/\(id).0A1B2C3D-4E5F-6789-ABCD-EF0123456789.plist"]
        precondition(leftovers == expected, "Leftovers: extra \(leftovers.subtracting(expected)), missing \(expected.subtracting(leftovers))")
        let appleLeftovers = ApplicationScanner.leftovers(appName: "Notes", bundleIdentifier: "com.apple.notes", library: library)
        precondition(!appleLeftovers.contains { $0.path.contains("Group Containers") }, "Apple group containers are never leftovers")
        precondition(ApplicationScanner.leftovers(appName: "../Logs", bundleIdentifier: "../Group Containers", library: library).isEmpty)

        // MARK: Orphaned app data on a fake home
        let home = root.appending(path: "orphans-home")
        let lib = home.appending(path: "Library")
        for folder in ["Application Support/com.vendor.gone/data", "Caches/com.vendor.gone/sub", "Application Support/com.apple.x",
                       "Application Support/com.vendor.present", "Caches/com.vendor.present.helper", "Caches/org.swift.swiftpm",
                       "Caches/com.vendor.registered", "Caches/com.vendor.registered.sub", "Application Support/NotAnIdentifier",
                       "Preferences/com.vendor.folder", "Group Containers/group.com.vendor.gone", "Group Containers/ABCDE12345.com.vendor.present",
                       "Group Containers/systemgroup.com.vendor.gone", "Saved Application State/com.vendor.gone.savedState",
                       "Containers/com.apple.Safari", "Documents/com.vendor.gone", "elsewhere"] {
            try fm.createDirectory(at: lib.appending(path: folder), withIntermediateDirectories: true)
        }
        // App-group folders are named after groups, not apps, and also appear in Application Scripts.
        for folder in ["Group Containers/group.com.facebook.family", "Group Containers/group.is.workflow.shortcuts",
                       "Application Scripts/group.com.vendor.shared", "Application Scripts/243LU875E5.groups.com.apple.podcasts",
                       "Application Scripts/group.com.vendor.gone", "Caches/com.vendor.empty"] {
            try fm.createDirectory(at: lib.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data(count: 65_536).write(to: lib.appending(path: "Application Support/com.vendor.gone/data/store.db"))
        try Data(count: 2_048).write(to: lib.appending(path: "Caches/com.vendor.gone/sub/cache.bin"))
        for file in ["Preferences/com.vendor.gone.plist", "Preferences/com.vendor.present.plist",
                     "Group Containers/group.com.vendor.gone/shared.db", "Saved Application State/com.vendor.gone.savedState/window.data",
                     "Group Containers/group.com.facebook.family/x", "Group Containers/group.is.workflow.shortcuts/x",
                     "Application Scripts/group.com.vendor.shared/x", "Application Scripts/243LU875E5.groups.com.apple.podcasts/x",
                     "Application Scripts/group.com.vendor.gone/script.scpt"] {
            try Data("data".utf8).write(to: lib.appending(path: file))
        }
        try fm.createSymbolicLink(at: lib.appending(path: "Caches/com.vendor.link"), withDestinationURL: lib.appending(path: "elsewhere"))
        let orphans = OrphanedDataScanner.scan(home: home, installedBundleIDs: ["com.Vendor.Present"],
                                               installedGroups: ["group.com.facebook.family", "ABCDE12345.com.vendor.shared"],
                                               isRegistered: { $0 == "com.vendor.registered" })
        let found = Set(orphans.items.map { "\($0.location)/\($0.url.lastPathComponent)" })
        let expectedOrphans: Set<String> = ["Application Support/com.vendor.gone", "Caches/com.vendor.gone", "Preferences/com.vendor.gone.plist",
                                            "Group Containers/group.com.vendor.gone", "Saved Application State/com.vendor.gone.savedState",
                                            "Application Scripts/group.com.vendor.gone"]
        precondition(found == expectedOrphans, "Orphans: extra \(found.subtracting(expectedOrphans)), missing \(expectedOrphans.subtracting(found))")
        precondition(orphans.items.allSatisfy { !$0.isSelected && $0.bundleIdentifier == "com.vendor.gone" && $0.isMeasurementComplete })
        precondition(orphans.items.allSatisfy { $0.sameVendorApp == "com.vendor.present" }, "Same-developer hint")
        precondition(orphans.items.first?.location == "Application Support", "Largest first")

        // MARK: Orphan cleaner revalidation
        func item(_ location: String) -> OrphanedDataItem {
            guard var found = orphans.items.first(where: { $0.location == location }) else { preconditionFailure(location) }
            found.isSelected = true
            return found
        }
        final class Trashed { var urls: [URL] = [] }
        let trashed = Trashed()
        let cleaner = OrphanedDataCleaner(home: home)
        let never: (String) -> Bool = { _ in false }
        let record: (URL) throws -> Void = { trashed.urls.append($0) }

        // Content deep inside changed: the folder's own date does not move, the newest content date does.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)],
                             ofItemAtPath: lib.appending(path: "Caches/com.vendor.gone/sub/cache.bin").path)
        let changed = cleaner.clean([item("Caches")], installedCheck: never, trashItem: record)
        precondition(changed.removedCount == 0 && changed.issues.map(\.kind) == [.changed], "Changed content is kept: \(changed.issues)")

        // The app was installed again after the scan.
        let reinstalled = cleaner.clean([item("Preferences")], installedCheck: { $0 == "com.vendor.gone" }, trashItem: record)
        precondition(reinstalled.removedCount == 0 && reinstalled.issues.first?.detail.contains("installed now") == true)

        // The folder was swapped for a symbolic link after the scan.
        let savedState = lib.appending(path: "Saved Application State/com.vendor.gone.savedState")
        try fm.removeItem(at: savedState)
        try fm.createSymbolicLink(at: savedState, withDestinationURL: lib.appending(path: "elsewhere"))
        let swapped = cleaner.clean([item("Saved Application State")], installedCheck: never, trashItem: record)
        precondition(swapped.removedCount == 0 && swapped.issues.map(\.kind) == [.unsafe], "Symlink swap: \(swapped.issues)")

        // A crafted item outside the recorded Library folder.
        let outside = OrphanedDataItem(id: UUID(), url: lib.appending(path: "Documents/com.vendor.gone"), bundleIdentifier: "com.vendor.gone",
                                   location: "Application Support", size: 0, newestContentModifiedAt: nil, modifiedAt: nil,
                                   isMeasurementComplete: true, isSelected: true)
        let escaped = cleaner.clean([outside, OrphanedDataItem(id: UUID(), url: home.appending(path: "com.vendor.gone"),
                                                               bundleIdentifier: "com.vendor.gone", location: "..", size: 0,
                                                               newestContentModifiedAt: nil, modifiedAt: nil, isMeasurementComplete: true,
                                                               isSelected: true)],
                                    installedCheck: never, trashItem: record)
        precondition(escaped.removedCount == 0 && escaped.issues.map(\.kind) == [.unsafe, .unsafe], "Outside Library: \(escaped.issues)")
        precondition(trashed.urls.isEmpty, "Nothing refused reached Trash")

        // A valid, selected item moves; an unselected one is ignored.
        var unselected = item("Group Containers")
        unselected.isSelected = false
        let valid = cleaner.clean([item("Application Support"), unselected], installedCheck: never, trashItem: record)
        precondition(valid.removedCount == 1 && valid.issues.isEmpty && valid.reclaimedBytes > 0, "Valid item: \(valid.issues)")
        precondition(trashed.urls.map(\.lastPathComponent) == ["com.vendor.gone"]
                     && trashed.urls.first?.deletingLastPathComponent().lastPathComponent == "Application Support")

        // A refused move is reported with the real reason, not as success.
        let refused = cleaner.clean([item("Group Containers")], installedCheck: never,
                                    trashItem: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) })
        precondition(refused.removedCount == 0 && refused.issues.first?.kind == .permission && refused.issues.first?.needsAccess == true)

        // MARK: Models: review-only results, honest outcome
        let model = OrphanedDataModel()
        let preselected = orphans.items.map { var copy = $0; copy.isSelected = true; return copy }
        model.reader = { _ in .success(ScanReport(items: preselected, deniedPaths: [])) }
        var blocked = true
        model.authorizeScan = { !blocked }
        model.scan()
        precondition(model.state == .idle, "An unauthorized scan does not start")
        blocked = false
        model.scan()
        while model.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.state == .ready && model.items.count == preselected.count && model.selectedItems.isEmpty, "Nothing starts selected")
        let target = model.items[0]
        model.setSelection(true, id: target.id)
        model.cleaner = { selected in
            CleanupResult(removedCount: 1, reclaimedBytes: selected[0].size, failures: [], removedItemIDs: [selected[0].id],
                          issues: [CleanupIssue(url: selected[0].url, kind: .changed, detail: "fixture")])
        }
        var outcome: CleanupOutcome?
        model.onOutcome = { outcome = $0 }
        model.cleanSelected()
        while model.cleaning { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(outcome?.movedCount == 1 && outcome?.issues.count == 1 && !model.items.contains { $0.id == target.id })
        precondition(model.lastResult?.contains("Trash") == true)

        let audit = StartupAuditModel()
        audit.reader = { _ in .success(report) }
        audit.extensionReader = { nil }
        audit.scan()
        while audit.state == .loading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(audit.entries.count == report.items.count && audit.extensionsUnavailable, "Unreadable extensions are not 'none'")
        audit.filter = .orphaned
        precondition(audit.filteredEntries.allSatisfy { $0.flags.contains(.orphaned) } && !audit.filteredEntries.isEmpty)
        audit.filter = .disabled
        precondition(audit.filteredEntries.map(\.label) == ["com.test.keepalive"])

        print("PASS: signatures (Apple, ad-hoc, unsigned, missing), startup risks (orphaned, unsigned root daemon, hidden program and script, KeepAlive, BundleProgram, plist ownership and permissions), launchctl and systemextensionsctl parsers, Mach-O thin/fat/garbage/truncated, exact-match group container and ByHost leftovers, orphaned data detection and cleaner revalidation, review-only models")
    }
}
