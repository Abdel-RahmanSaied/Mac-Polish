import Foundation

/// Records the URLs a cleaner would move to Trash; nothing is moved.
private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return urls.map(\.standardizedFileURL.path) }
}

@MainActor
private final class OutcomeBox {
    var outcome: CleanupOutcome?
}

/// Project artifact detection, walk limits, and revalidation before Trash, on isolated fixtures only.
@main
enum ProjectArtifactsCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/MacPolish-artifacts-" + UUID().uuidString)
        let home = root.appending(path: "home")
        let outside = root.appending(path: "outside")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func write(_ relative: String, in base: URL? = nil, bytes: Int = 4_096) throws {
            let url = (base ?? home).appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        }
        func path(_ relative: String, in base: URL? = nil) -> String { (base ?? home).appending(path: relative).path }
        func setDate(_ relative: String, daysAgo: Double, in base: URL? = nil) throws {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: path(relative, in: base))
        }
        /// Sets the folder and everything inside it to an old date, so later changes are always newer.
        func age(_ relative: String, daysAgo: Double = 100, in base: URL? = nil) throws {
            let top = path(relative, in: base)
            let inner = (fm.enumerator(atPath: top)?.allObjects as? [String] ?? []).map { top + "/" + $0 }
            for item in inner + [top] {
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: item)
            }
        }

        // Recognized: each folder next to the project file that owns it.
        try write("web/package.json")
        try write("web/src/app.js")
        try write("web/node_modules/dep/index.js")
        try write("web/node_modules/dep/package.json")
        try write("web/node_modules/dep/node_modules/inner/index.js")
        try write("rs/Cargo.toml")
        try write("rs/target/debug/app")
        try write("mvn/pom.xml")
        try write("mvn/target/classes/A.class")
        try write("py1/pyproject.toml")
        try write("py1/.venv/pyvenv.cfg")
        try write("py1/.venv/lib/site.py")
        try write("mono/package.json")
        try write("mono/node_modules/a/index.js")
        try write("mono/packages/kit/Package.swift")
        try write("mono/packages/kit/.build/debug/kit.o")
        try write("deep/a/b/c/proj/package.json")
        try write("deep/a/b/c/proj/node_modules/x/index.js")
        // Not recognized: no project file, hand-made venv, Library, hidden folders, packages, symbolic links.
        try write("notrust/target/out.bin")
        try write("notrust/README.md")
        try write("nobuild/build/out.bin")
        try write("py2/requirements.txt")
        try write("py2/venv/lib/site.py")
        try write("Library/libproj/package.json")
        try write("Library/libproj/node_modules/x/index.js")
        try write(".hidden/hp/package.json")
        try write(".hidden/hp/node_modules/x/index.js")
        try write("Tool.app/Contents/ap/package.json")
        try write("Tool.app/Contents/ap/node_modules/x/index.js")
        try write("real-modules/x/index.js", in: outside)
        try write("linked/package.json")
        try fm.createSymbolicLink(atPath: path("linked/node_modules"), withDestinationPath: path("real-modules", in: outside))
        try write("proj/package.json", in: outside)
        try write("proj/node_modules/x/index.js", in: outside)
        try fm.createSymbolicLink(atPath: path("linkproj"), withDestinationPath: path("proj", in: outside))
        // Project activity: the newest of the project folder, its direct entries and .git/index or HEAD.
        try write("act/package.json")
        try write("act/src/main.js")
        try write("act/.git/index")
        try write("act/.git/HEAD")
        try write("act/node_modules/x/index.js")
        try write("act2/package.json")
        try write("act2/.git/index")
        try write("act2/node_modules/x/index.js")
        for project in ["act", "act2"] { try age(project, daysAgo: 400) }
        try setDate("act/.git/index", daysAgo: 20)
        try setDate("act2/package.json", daysAgo: 10)
        try setDate("act2/.git/index", daysAgo: 30)
        // Fresh content inside an artifact is not project activity.
        try write("act/node_modules/x/fresh.js")
        // Cleaner fixtures, aged so any later change is newer than what the scan recorded.
        for name in ["chg", "mk", "sw", "own", "lk"] {
            try write("\(name)/package.json")
            try write("\(name)/node_modules/x/index.js")
            try age(name)
        }
        try age("web")
        try age("py1")
        try write("op/package.json", in: outside)
        try write("op/node_modules/x/index.js", in: outside)

        let scanner = ProjectArtifactScanner(roots: [home], home: home, minimumSize: 1)
        let report = scanner.report()
        let paths = report.items.map(\.url.standardizedFileURL.path)
        func found(_ relative: String, as kind: ProjectArtifactKind) -> Bool {
            report.items.contains { $0.url.standardizedFileURL.path == path(relative) && $0.kind == kind }
        }
        precondition(found("web/node_modules", as: .nodeModules), "node_modules next to package.json")
        precondition(found("rs/target", as: .rustTarget), "target next to Cargo.toml is Rust")
        precondition(found("mvn/target", as: .mavenTarget), "target next to pom.xml is Maven")
        precondition(found("py1/.venv", as: .pythonVenv), "a venv with pyvenv.cfg")
        precondition(found("mono/node_modules", as: .nodeModules) && found("mono/packages/kit/.build", as: .swiftPMBuild),
                     "monorepo sub-projects are found")
        precondition(found("deep/a/b/c/proj/node_modules", as: .nodeModules), "projects within the depth limit are found")
        precondition(!ProjectArtifactKind.pythonVenv.isSafelyRegenerable && ProjectArtifactKind.nodeModules.isSafelyRegenerable)
        for ignored in ["notrust/target", "nobuild/build", "py2/venv", "Library/libproj/node_modules", ".hidden/hp/node_modules",
                        "Tool.app/Contents/ap/node_modules", "linked/node_modules", "linkproj/node_modules",
                        "web/node_modules/dep/node_modules"] {
            precondition(!paths.contains(path(ignored)), "\(ignored) must not be reported, got \(paths)")
        }
        precondition(!paths.contains { $0.hasPrefix(outside.path) }, "symbolic links are not followed out of the root")
        precondition(report.items.allSatisfy { !$0.isSelected }, "nothing is preselected")
        precondition(zip(report.items, report.items.dropFirst()).allSatisfy { $0.size >= $1.size }, "largest first")
        precondition(report.items.allSatisfy { $0.isMeasurementComplete && $0.projectURL.path == $0.url.deletingLastPathComponent().path })
        precondition(!report.incomplete && report.deniedPaths.isEmpty, "the fixture walk completes")
        precondition(ProjectArtifactScanner(roots: [home], home: home).report().items.isEmpty, "folders under 1 MB are not listed")

        // Project activity: .git/index is newest in act, package.json in act2; artifact content never counts.
        func activity(_ relative: String) -> Date? {
            report.items.first { $0.url.standardizedFileURL.path == path(relative) }?.projectLastActivity
        }
        precondition(activity("act/node_modules") == FileAttributes.read(path: path("act/.git/index"))?.modified,
                     "act's activity is its .git/index date")
        precondition(activity("act2/node_modules") == FileAttributes.read(path: path("act2/package.json"))?.modified,
                     "act2's activity is its project file's date")

        // Limits: depth and deadline keep what was verified and say the scan is incomplete.
        let shallow = ProjectArtifactScanner(roots: [home], home: home, maxDepth: 2, minimumSize: 1).report()
        precondition(shallow.incomplete && !shallow.items.contains { $0.url.path.contains("/deep/") }, "depth limit marks incomplete")
        precondition(shallow.items.contains { $0.url.standardizedFileURL.path == path("web/node_modules") })
        let expired = scanner.report(deadline: .distantPast)
        precondition(expired.incomplete && expired.items.isEmpty, "an expired deadline marks incomplete")
        precondition(ProjectArtifactsModel.warning(for: shallow)?.contains("time limit") == true)

        // The worker's JSON keeps dates exactly, so the cleaner compares like for like.
        let decoded = try JSONDecoder().decode(ScanReport<ProjectArtifact>.self, from: JSONEncoder().encode(report))
        func item(_ relative: String) -> ProjectArtifact {
            var value = decoded.items.first { $0.url.standardizedFileURL.path == path(relative) }!
            value.isSelected = true
            return value
        }
        let recorder = TrashRecorder()
        let cleaner = ProjectArtifactCleaner(home: home)
        func clean(_ value: ProjectArtifact) -> CleanupResult { cleaner.clean([value], trashItem: { recorder.record($0) }) }

        let valid = clean(item("web/node_modules"))
        precondition(valid.removedCount == 1 && valid.issues.isEmpty && recorder.paths == [path("web/node_modules")],
                     "a valid node_modules is accepted, got \(valid.issues.map(\.message))")
        precondition(clean(item("py1/.venv")).removedCount == 1, "a venv the user selected is accepted")
        var unselected = item("rs/target")
        unselected.isSelected = false
        precondition(cleaner.clean([unselected], trashItem: { recorder.record($0) }).removedCount == 0, "only selected folders move")

        let changedItem = item("chg/node_modules")
        try write("chg/node_modules/x/new.js")
        precondition(clean(changedItem).issues.first?.kind == .changed, "content changed deep inside after the scan")
        let ownItem = item("own/node_modules")
        try write("own/node_modules/added.js")
        precondition(clean(ownItem).issues.first?.kind == .changed, "the folder's own date changed")
        let markerItem = item("mk/node_modules")
        try fm.removeItem(atPath: path("mk/package.json"))
        let marker = clean(markerItem)
        precondition(marker.removedCount == 0 && marker.issues.first?.kind == .changed, "the project file was removed")
        let swapItem = item("sw/node_modules")
        try fm.moveItem(atPath: path("sw/node_modules"), toPath: path("sw-moved", in: outside))
        try fm.createSymbolicLink(atPath: path("sw/node_modules"), withDestinationPath: path("sw-moved", in: outside))
        let swap = clean(swapItem)
        precondition(swap.removedCount == 0 && swap.issues.first?.kind == .unsafe, "a symbolic link replaced the folder")
        try fm.setAttributes([.immutable: true], ofItemAtPath: path("lk/node_modules"))
        let locked = clean(item("lk/node_modules"))
        try fm.setAttributes([.immutable: false], ofItemAtPath: path("lk/node_modules"))
        precondition(locked.issues.first?.kind == .locked, "a locked folder is refused before Trash")

        let outsideReport = ProjectArtifactScanner(roots: [outside], home: home, minimumSize: 1).report()
        guard var outsideItem = outsideReport.items.first(where: { $0.url.standardizedFileURL.path == path("op/node_modules", in: outside) }) else {
            preconditionFailure("the outside fixture is an artifact by itself")
        }
        outsideItem.isSelected = true
        precondition(clean(outsideItem).issues.first?.kind == .unsafe, "a folder outside the home folder is refused")

        let nestedURL = home.appending(path: "web/node_modules/dep/node_modules")
        let nestedInfo = FileAttributes.read(path: nestedURL.path)
        let nestedMeasure = FileSizeCalculator.measure(nestedURL)
        let nested = ProjectArtifact(url: nestedURL, projectURL: nestedURL.deletingLastPathComponent(), kind: .nodeModules,
                                     size: nestedMeasure.bytes, modifiedAt: nestedInfo?.modified,
                                     newestContentModifiedAt: nestedMeasure.newestModification, projectLastActivity: nil,
                                     isMeasurementComplete: true, isSelected: true)
        precondition(clean(nested).issues.first?.kind == .managedCache, "a folder inside node_modules is refused")
        var partial = item("rs/target")
        partial = ProjectArtifact(id: partial.id, url: partial.url, projectURL: partial.projectURL, kind: partial.kind, size: partial.size,
                                  modifiedAt: partial.modifiedAt, newestContentModifiedAt: partial.newestContentModifiedAt,
                                  projectLastActivity: partial.projectLastActivity, isMeasurementComplete: false, isSelected: true)
        precondition(clean(partial).issues.first?.kind == .changed, "a partly unreadable folder is refused")
        precondition(recorder.paths == [path("web/node_modules"), path("py1/.venv")], "only accepted folders reached Trash, got \(recorder.paths)")

        // Toolchain caches: only existing ones, each with its tool's command; nothing offers removal.
        try write(".npm/_cacache/index-v5/aa")
        try write("Library/Caches/pip/http/bb")
        let caches = ToolchainCacheSpec.measureExisting(home: home, reader: DiskMapService.inProcessReader)
        precondition(Set(caches.map(\.name)) == ["npm cache", "pip cache"], "missing caches are not shown, got \(caches.map(\.name))")
        precondition(caches.allSatisfy { ($0.bytes ?? 0) > 0 })

        // Model: scans only when allowed, preselects nothing, selects inactive regenerable folders only.
        let modelTrash = TrashRecorder()
        let model = ProjectArtifactsModel(reader: { _ in .success(decoded) },
                                          cacheMeasurer: { _ in ToolchainCacheSpec.measureExisting(home: home, reader: DiskMapService.inProcessReader) },
                                          cleaner: cleaner, trashItem: { modelTrash.record($0) })
        model.authorizeScan = { false }
        model.scan()
        precondition(model.state == .idle, "a scan waits for authorization")
        model.authorizeScan = { true }
        model.scan()
        try await waitUntil { model.state == .ready && !model.toolchainLoading }
        precondition(model.artifacts.count == decoded.items.count && model.selectedCount == 0, "nothing preselected")
        precondition(model.toolchainCaches.compactMap { model.spec(for: $0)?.command }.sorted() == ["npm cache clean --force", "pip cache purge"])
        model.selectInactive(days: 90)
        // Aged 100 days before the scan: web and the cleaner fixtures. py1 is a venv; act, act2 and the rest are recent.
        let inactive = Set(model.selected.map(\.projectURL.lastPathComponent))
        precondition(inactive == ["web", "chg", "own", "mk", "sw", "lk"], "only inactive regenerable projects are selected, got \(inactive)")
        model.selectInactive(days: 90, now: Date().addingTimeInterval(1_000 * 86_400))
        precondition(model.selectedCount == model.artifacts.filter(\.kind.isSafelyRegenerable).count
                     && !model.selected.contains { $0.kind == .pythonVenv }, "venvs are never selected by age")
        model.selectNone()
        precondition(model.selectedCount == 0)
        let web = model.artifacts.first { $0.url.standardizedFileURL.path == path("web/node_modules") }!
        model.setSelection(true, id: web.id)
        model.requestCleanup()
        precondition(model.confirmsCleanup && model.confirmationMessage.contains("Trash") && model.confirmationMessage.contains("npm install"))
        let box = OutcomeBox()
        model.onOutcome = { box.outcome = $0 }
        model.cleanSelected()
        try await waitUntil { !model.cleaning }
        precondition(box.outcome?.movedCount == 1 && !model.artifacts.contains { $0.id == web.id }
                     && modelTrash.paths == [path("web/node_modules")], "the model moves only the reviewed folder")
        print("PASS: project artifacts need their project file (venvs their pyvenv.cfg), skip Library, hidden folders, packages and links, stay out of found and managed folders, honor depth and deadline, date activity from the project, and are checked again (path, link, project file, dates, content, rights) before Trash; toolchain caches are read-only")
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "timed out waiting for the model")
    }
}
