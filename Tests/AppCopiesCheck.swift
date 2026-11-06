import Foundation

/// macOS keeps one permission entry per bundle identifier. Another copy of Mac Polish signed differently,
/// once opened or added in Full Disk Access, takes the permission away from the copy in use, so setup lists it.
@main
enum AppCopiesCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-copies-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func run(_ tool: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "\(tool) \(arguments) failed")
        }
        /// A signed Mac Polish bundle; a different build number gives a different ad-hoc signature.
        func bundle(_ folder: String, build: String) throws -> URL {
            let app = root.appending(path: folder + "/Mac Polish.app")
            try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(atPath: CommandLine.arguments[0], toPath: app.appending(path: "Contents/MacOS/MacPolish").path)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.asaied.macpolish", "CFBundleExecutable": "MacPolish",
                                        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.9." + build,
                                        "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            return app
        }
        let running = try bundle("running", build: "1")
        let other = try bundle("other", build: "2")
        let trashed = try bundle(".Trash", build: "3")
        let identical = root.appending(path: "identical/Mac Polish.app")
        try fm.createDirectory(at: identical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [running.path, identical.path])
        let missing = root.appending(path: "gone/Mac Polish.app")

        // Real signing checks: a byte-identical copy meets the requirement, a differently signed copy does not.
        guard let requirement = AppCopies.requirement(of: running) else { preconditionFailure("The fixture has a requirement") }
        precondition(requirement.hasPrefix("cdhash"), "Ad-hoc fixture: \(requirement)")
        precondition(AppCopies.satisfies(running, requirement: requirement))
        precondition(AppCopies.satisfies(identical, requirement: requirement), "An identical copy has the same signature")
        precondition(!AppCopies.satisfies(other, requirement: requirement), "A different build signed ad hoc does not")

        // Only existing copies outside the Trash, other than the running one, are listed.
        let found = AppCopies.others(running: running, requirement: requirement,
                                     registered: [running, URL(fileURLWithPath: running.path + "/"), other, trashed, identical, missing])
        precondition(found.map(\.url.lastPathComponent) == ["Mac Polish.app", "Mac Polish.app"], "Two other copies, got \(found.map(\.url.path))")
        precondition(found.first { $0.url.standardizedFileURL == other.standardizedFileURL }?.sameSignature == false)
        precondition(found.first { $0.url.standardizedFileURL == identical.standardizedFileURL }?.sameSignature == true)
        precondition(found.first { $0.url.standardizedFileURL == other.standardizedFileURL }?.version == "0.9.2")

        // Launch: a differently signed copy opens setup once; the same copies do not reopen it after Continue.
        let suite = "MacPolish-copies-test-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: AccessSetupModel.completedKey)
        let conflicting = found.filter { !$0.sameSignature }
        let first = AccessSetupModel(defaults: store, probe: { .accessible }, copies: { conflicting })
        await first.verifyOnLaunch()
        precondition(first.presented && first.conflictingCopies == conflicting, "A differently signed copy opens setup")
        first.results = FolderAccessCheck.locations().map { FolderAccessResult(name: $0.0, url: $0.1, status: .readable) }
        first.checkedAt = Date()
        if first.fullDiskAccess == nil { first.fullDiskAccess = .unknown }
        first.finish()
        let again = AccessSetupModel(defaults: store, probe: { .accessible }, copies: { conflicting })
        await again.verifyOnLaunch()
        precondition(!again.presented && again.otherCopies == conflicting, "Dismissed copies stay listed without reopening setup")
        let newCopy = AppCopy(url: root.appending(path: "new/Mac Polish.app"), version: "0.9.9", sameSignature: false)
        let changed = AccessSetupModel(defaults: store, probe: { .accessible }, copies: { conflicting + [newCopy] })
        await changed.verifyOnLaunch()
        precondition(changed.presented, "A newly found differently signed copy opens setup again")
        let harmless = found.filter(\.sameSignature)
        let sameSigned = AccessSetupModel(defaults: UserDefaults(suiteName: suite + "-same")!, probe: { .accessible }, copies: { harmless })
        defer { UserDefaults().removePersistentDomain(forName: suite + "-same") }
        sameSigned.results = FolderAccessCheck.locations().map { FolderAccessResult(name: $0.0, url: $0.1, status: .readable) }
        sameSigned.checkedAt = Date()
        if sameSigned.fullDiskAccess == nil { sameSigned.fullDiskAccess = .unknown }
        sameSigned.finish()
        await sameSigned.verifyOnLaunch()
        precondition(!sameSigned.presented && sameSigned.otherCopies == harmless, "Same-signature copies are listed but do not open setup")

        // This Mac, through Launch Services: only reports, never changes anything.
        print("  this Mac: \(AppCopies.others(running: root).count) other registered copies of Mac Polish")
        print("PASS: other copies are found by signature, Trash and missing paths are ignored, a differently signed copy opens setup once per set")
    }
}
