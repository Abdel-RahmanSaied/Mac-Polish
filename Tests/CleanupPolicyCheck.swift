import Foundation

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
}

/// Pre-selection and Optimize suggestions must reflect the newest content inside a folder,
/// skip stateful caches and Trash contents, and only treat real Xcode bundles as old Xcode copies.
@main
enum CleanupPolicyCheck {
    static func main() throws {
        let fm = FileManager.default
        // Fixtures live under the real ~/Library/Caches so SafeCleaner's allow-list applies to them.
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-policy-check-" + UUID().uuidString)
        let home = root.appending(path: "home")
        let caches = home.appending(path: "Library/Caches")
        let applications = root.appending(path: "Applications")
        defer { try? fm.removeItem(at: root) }
        let old = Date().addingTimeInterval(-30 * 86400)

        func write(_ url: URL, _ text: String = "fixture") throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func age(_ urls: URL...) throws {
            // Deepest first: changing a child's date never touches its parent.
            for url in urls { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        func makeApp(_ name: String, identifier: String, version: String) throws {
            let contents = applications.appending(path: "\(name).app/Contents")
            try write(contents.appending(path: "MacOS/binary"))
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                        "CFBundlePackageType": "APPL", "CFBundleExecutable": "binary"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
        }

        // An active cache: the folder entry is old, but a file deep inside was just written.
        let active = caches.appending(path: "com.example.active")
        try write(active.appending(path: "sub/data.bin"))
        try age(active.appending(path: "sub/data.bin"), active.appending(path: "sub"), active)
        try Data("written moments ago".utf8).write(to: active.appending(path: "sub/data.bin"))

        // A cache whose whole content is old.
        let stale = caches.appending(path: "com.example.stale")
        try write(stale.appending(path: "sub/data.bin"))
        try age(stale.appending(path: "sub/data.bin"), stale.appending(path: "sub"), stale)

        // Poetry keeps virtual environments inside its cache folder.
        let poetry = caches.appending(path: "pypoetry")
        try write(poetry.appending(path: "virtualenvs/project/bin/python"))
        try age(poetry.appending(path: "virtualenvs/project/bin/python"), poetry.appending(path: "virtualenvs/project/bin"),
                poetry.appending(path: "virtualenvs/project"), poetry.appending(path: "virtualenvs"), poetry)

        let trashed = home.appending(path: ".Trash/already-trashed.bin")
        try write(trashed)

        try makeApp("Xcode", identifier: "com.apple.dt.Xcode", version: "16.0")
        try makeApp("Xcode-15", identifier: "com.apple.dt.Xcode", version: "15.4")
        try makeApp("Xcodes", identifier: "com.robotsandpencils.XcodesApp", version: "2.4.1")

        // A fresh file hidden behind an unreadable directory must never look stale.
        let partial = caches.appending(path: "com.example.partial")
        let vault = partial.appending(path: "vault")
        try write(partial.appending(path: "old.bin"))
        try write(vault.appending(path: "active.bin"))
        try age(partial.appending(path: "old.bin"), vault.appending(path: "active.bin"), vault, partial)
        let handle = try FileHandle(forWritingTo: vault.appending(path: "active.bin"))
        try handle.write(contentsOf: Data("active".utf8))
        try handle.close()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path) }

        let items = DiskScanner(home: home, applicationsRoot: applications).scan(includeLargeFiles: false)
        func item(_ url: URL) -> ScanItem {
            guard let found = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
                preconditionFailure("Scanner did not list \(url.path)")
            }
            return found
        }

        // Break caught: judging a folder only by its own modification date.
        precondition(!item(active).isSelected, "An actively written cache must not be pre-selected")
        precondition(OptimizePolicy.candidate(item(active)) == nil, "Optimize must not call an actively written cache old")
        precondition(item(stale).isSelected, "A cache whose content is all old stays pre-selected")
        precondition(OptimizePolicy.candidate(item(stale)) != nil, "Optimize still suggests a cache whose content is all old")

        precondition(!item(partial).isMeasurementComplete && !item(partial).isSelected)
        precondition(OptimizePolicy.candidate(item(partial)) == nil)
        var selectedPartial = item(partial)
        selectedPartial.isSelected = true
        let deniedCalls = CallRecorder()
        let denied = SafeCleaner().clean([selectedPartial]) { deniedCalls.add($0) }
        precondition(denied.removedCount == 0 && deniedCalls.count == 0 && !denied.issues.isEmpty)

        // Also catch access lost after an otherwise complete scan.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stale.appending(path: "sub").path)
        let lostAccess = SafeCleaner().clean([item(stale)]) { deniedCalls.add($0) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stale.appending(path: "sub").path)
        precondition(lostAccess.removedCount == 0 && deniedCalls.count == 0 && !lostAccess.issues.isEmpty)
        let encoded = try JSONEncoder().encode(selectedPartial)
        let decoded = try JSONDecoder().decode(ScanItem.self, from: encoded)
        precondition(!decoded.isMeasurementComplete)

        // Break caught: treating stateful tool folders like disposable caches.
        precondition(!item(poetry).isSelected, "Poetry virtual environments must not be pre-selected")
        precondition(OptimizePolicy.candidate(item(poetry)) == nil, "Optimize must not suggest Poetry virtual environments")

        // Break caught: "moving to Trash" something that is already there.
        precondition(!item(trashed).isSelected, "Items already in Trash must not be pre-selected")
        let trashCalls = CallRecorder()
        let trashResult = SafeCleaner().clean([item(trashed)].map { var copy = $0; copy.isSelected = true; return copy }) { trashCalls.add($0) }
        precondition(trashCalls.count == 0 && trashResult.removedCount == 0 && trashResult.issues.count == 1,
                     "Cleaning an item already in Trash must report it instead of moving it")
        let realTrash = fm.homeDirectoryForCurrentUser.appending(path: ".Trash/anything")
        precondition(!SafeCleaner().isAllowed(realTrash), "Paths inside Trash are not cleanup targets")

        // Break caught: missing a change made deep inside a folder between scan and cleanup.
        let unchanged = SafeCleaner().clean([item(stale)]) { _ in }
        precondition(unchanged.removedCount == 1 && unchanged.issues.isEmpty, "An unchanged scanned cache can be cleaned")
        try Data("new content after scanning".utf8).write(to: stale.appending(path: "sub/data.bin"))
        let changed = SafeCleaner().clean([item(stale)]) { _ in }
        precondition(changed.removedCount == 0 && changed.issues.map(\.kind) == [.changed],
                     "A cache whose nested content changed after scanning must be skipped")

        // Break caught: matching "Xcode" by file name instead of bundle identity.
        let xcodeCopies = items.filter { $0.category == .oldXcode }.map(\.url.lastPathComponent)
        precondition(xcodeCopies == ["Xcode-15.app"], "Only older real Xcode bundles are old copies, got \(xcodeCopies)")
        precondition(!item(applications.appending(path: "Xcode-15.app")).isSelected, "Old Xcode copies are never pre-selected")

        // Break caught: listing Xcode copies by bundle identity but allowing their cleanup by file name.
        // These apps sit outside every cleanup root, so only the Xcode rule can allow them.
        let appSupport = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MacPolish-xcode-check-" + UUID().uuidString)
        defer { try? fm.removeItem(at: appSupport) }
        let xcodeRoot = appSupport.appending(path: "Applications")
        func makeXcode(_ name: String, identifier: String, version: String) throws {
            let contents = xcodeRoot.appending(path: "\(name).app/Contents")
            try write(contents.appending(path: "MacOS/binary"))
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        }
        try makeXcode("Xcode", identifier: "com.apple.dt.Xcode", version: "16.0")
        try makeXcode("Beta Dev", identifier: "com.apple.dt.Xcode", version: "15.0")
        try makeXcode("Xcodes", identifier: "com.robotsandpencils.XcodesApp", version: "2.4.1")
        let renamed = DiskScanner(home: home, applicationsRoot: xcodeRoot).scan(section: .developer).filter { $0.category == .oldXcode }
        precondition(renamed.map(\.url.lastPathComponent) == ["Beta Dev.app"], "A renamed real Xcode is still an old copy")
        let cleaner = SafeCleaner(applicationsRoot: xcodeRoot)
        let moved = CallRecorder()
        let renamedResult = cleaner.clean(renamed.map { var copy = $0; copy.isSelected = true; return copy }) { moved.add($0) }
        precondition(moved.count == 1 && renamedResult.issues.isEmpty, "A listed Xcode copy must be cleanable, got \(renamedResult.issues.map(\.detail))")
        let impostor = ScanItem(url: xcodeRoot.appending(path: "Xcodes.app"), size: 1, category: .oldXcode, modifiedAt: nil, isSelected: true)
        precondition(cleaner.clean([impostor]) { moved.add($0) }.issues.map(\.kind) == [.unsafe] && moved.count == 1,
                     "Only real Xcode bundles may be removed as old Xcode copies")

        print("PASS: newest-content age, stateful cache protection, Trash items, nested-change detection, Xcode bundle identity")
    }
}
