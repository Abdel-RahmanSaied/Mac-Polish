import Darwin
import Foundation

/// Build and dependency folders that a project's own tool recreates. A folder is only recognized next to the
/// project file that owns it (for example `node_modules` next to `package.json`), never by its name alone.
enum ProjectArtifactKind: String, Codable, Sendable, CaseIterable {
    case nodeModules, rustTarget, mavenTarget, swiftPMBuild, gradleBuild, gradleCache, cocoaPods, nextBuild, nuxtBuild,
         svelteKit, turboCache, parcelCache, angularCache, pythonVenv, pytestCache, mypyCache, toxEnv, dartTool,
         flutterBuild, terraform, zigCache, elixirBuild, haskellStack, cabalBuild, cmakeBuild

    /// Folder names this kind uses. A trailing `*` matches a prefix (`cmake-build-debug`).
    var folderNames: [String] {
        switch self {
        case .nodeModules: ["node_modules"]
        case .rustTarget, .mavenTarget: ["target"]
        case .swiftPMBuild: [".build"]
        case .gradleBuild, .flutterBuild: ["build"]
        case .gradleCache: [".gradle"]
        case .cocoaPods: ["Pods"]
        case .nextBuild: [".next"]
        case .nuxtBuild: [".nuxt"]
        case .svelteKit: [".svelte-kit"]
        case .turboCache: [".turbo"]
        case .parcelCache: [".parcel-cache"]
        case .angularCache: [".angular"]
        case .pythonVenv: [".venv", "venv"]
        case .pytestCache: [".pytest_cache"]
        case .mypyCache: [".mypy_cache"]
        case .toxEnv: [".tox"]
        case .dartTool: [".dart_tool"]
        case .terraform: [".terraform"]
        case .zigCache: [".zig-cache", "zig-cache"]
        case .elixirBuild: ["_build"]
        case .haskellStack: [".stack-work"]
        case .cabalBuild: ["dist-newstyle"]
        case .cmakeBuild: ["cmake-build-*"]
        }
    }

    /// Project files, next to the folder, of which at least one must exist. A leading `*` matches a suffix (`*.tf`).
    /// Empty when the folder identifies itself by its content instead (see `requiredContent`).
    var siblingMarkers: [String] {
        let python = ["pyproject.toml", "setup.py", "setup.cfg", "tox.ini", "requirements.txt", "Pipfile"]
        switch self {
        case .nodeModules, .nextBuild, .nuxtBuild, .svelteKit, .parcelCache: return ["package.json"]
        case .turboCache: return ["turbo.json", "package.json"]
        case .angularCache: return ["angular.json"]
        case .rustTarget: return ["Cargo.toml"]
        case .mavenTarget: return ["pom.xml"]
        case .swiftPMBuild: return ["Package.swift"]
        case .gradleBuild, .gradleCache: return ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        case .cocoaPods: return ["Podfile"]
        case .pythonVenv: return []
        case .pytestCache: return python + ["pytest.ini", "conftest.py"]
        case .mypyCache: return python + ["mypy.ini", ".mypy.ini"]
        case .toxEnv: return ["tox.ini", "pyproject.toml", "setup.cfg"]
        case .dartTool, .flutterBuild: return ["pubspec.yaml"]
        case .terraform: return ["*.tf"]
        case .zigCache: return ["build.zig"]
        case .elixirBuild: return ["mix.exs"]
        case .haskellStack: return ["stack.yaml"]
        case .cabalBuild: return ["cabal.project", "*.cabal"]
        case .cmakeBuild: return ["CMakeLists.txt"]
        }
    }

    /// A file that must exist inside the folder itself: `venv` is a common name for hand-made folders.
    var requiredContent: String? { self == .pythonVenv ? "pyvenv.cfg" : nil }

    var displayName: String {
        switch self {
        case .nodeModules: "node_modules"
        case .rustTarget: "Rust target"
        case .mavenTarget: "Maven target"
        case .swiftPMBuild: "SwiftPM .build"
        case .gradleBuild: "Gradle build"
        case .gradleCache: "Gradle project cache"
        case .cocoaPods: "CocoaPods Pods"
        case .nextBuild: "Next.js .next"
        case .nuxtBuild: "Nuxt .nuxt"
        case .svelteKit: "SvelteKit .svelte-kit"
        case .turboCache: "Turborepo .turbo"
        case .parcelCache: "Parcel cache"
        case .angularCache: "Angular cache"
        case .pythonVenv: "Python virtual environment"
        case .pytestCache: "pytest cache"
        case .mypyCache: "mypy cache"
        case .toxEnv: "tox environments"
        case .dartTool: "Dart .dart_tool"
        case .flutterBuild: "Flutter build"
        case .terraform: "Terraform .terraform"
        case .zigCache: "Zig cache"
        case .elixirBuild: "Elixir _build"
        case .haskellStack: "Stack .stack-work"
        case .cabalBuild: "Cabal dist-newstyle"
        case .cmakeBuild: "CMake build (CLion)"
        }
    }

    var ecosystem: String {
        switch self {
        case .nodeModules, .nextBuild, .nuxtBuild, .svelteKit, .turboCache, .parcelCache, .angularCache: "JavaScript"
        case .rustTarget: "Rust"
        case .mavenTarget: "Maven"
        case .swiftPMBuild: "Swift"
        case .gradleBuild, .gradleCache: "Gradle"
        case .cocoaPods: "CocoaPods"
        case .pythonVenv, .pytestCache, .mypyCache, .toxEnv: "Python"
        case .dartTool, .flutterBuild: "Dart/Flutter"
        case .terraform: "Terraform"
        case .zigCache: "Zig"
        case .elixirBuild: "Elixir"
        case .haskellStack, .cabalBuild: "Haskell"
        case .cmakeBuild: "C/C++"
        }
    }

    /// The command, run in the project folder, that recreates this folder.
    var regenerateHint: String {
        switch self {
        case .nodeModules: "npm install (or pnpm, yarn or bun install)"
        case .rustTarget: "cargo build"
        case .mavenTarget: "mvn package"
        case .swiftPMBuild: "swift build"
        case .gradleBuild, .gradleCache: "./gradlew build"
        case .cocoaPods: "pod install"
        case .nextBuild: "next build or next dev"
        case .nuxtBuild: "nuxt build or nuxt dev"
        case .svelteKit: "svelte-kit sync or vite dev"
        case .turboCache: "the next turbo run"
        case .parcelCache: "the next parcel build"
        case .angularCache: "the next ng build"
        case .pythonVenv: "python3 -m venv, then reinstall its packages (for example pip install -r requirements.txt)"
        case .pytestCache: "the next pytest run"
        case .mypyCache: "the next mypy run"
        case .toxEnv: "tox"
        case .dartTool: "dart pub get or flutter pub get"
        case .flutterBuild: "flutter build"
        case .terraform: "terraform init (select your workspace again if you use workspaces)"
        case .zigCache: "zig build"
        case .elixirBuild: "mix compile"
        case .haskellStack: "stack build"
        case .cabalBuild: "cabal build"
        case .cmakeBuild: "reloading the CMake project in CLion"
        }
    }

    /// False when the folder may hold something its tool cannot recreate: a virtual environment can contain
    /// packages installed by hand that no requirements file lists.
    var isSafelyRegenerable: Bool { self != .pythonVenv }

    func matchesName(_ name: String) -> Bool {
        folderNames.contains { pattern in
            pattern.hasSuffix("*") ? name.hasPrefix(pattern.dropLast()) && name.count > pattern.count - 1 : name == pattern
        }
    }

    /// True when one of `siblingMarkers` is among `files` (the names of the regular files next to the folder).
    func hasMarker(in files: Set<String>) -> Bool {
        guard !siblingMarkers.isEmpty else { return true }
        return siblingMarkers.contains { marker in
            guard marker.hasPrefix("*") else { return files.contains(marker) }
            let suffix = String(marker.dropFirst())
            return files.contains { $0.hasSuffix(suffix) && $0.count > suffix.count }
        }
    }

    /// The kind of the folder `name` inside `projectPath`, or nil when it is not a recognized artifact there.
    /// `files` are the regular files directly inside `projectPath`.
    static func match(name: String, projectPath: String, files: Set<String>) -> ProjectArtifactKind? {
        allCases.first { kind in
            guard kind.matchesName(name), kind.hasMarker(in: files) else { return false }
            guard let content = kind.requiredContent else { return true }
            return FileAttributes.read(path: ProjectArtifactScanner.join(projectPath, name) + "/" + content)?.kind == .file
        }
    }
}

struct ProjectArtifact: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let url: URL
    /// The folder holding the project file; always `url`'s parent.
    let projectURL: URL
    let kind: ProjectArtifactKind
    let size: Int64
    /// The artifact folder's own modification date when scanned.
    let modifiedAt: Date?
    /// Newest modification date of anything inside the artifact folder when scanned.
    let newestContentModifiedAt: Date?
    /// See `ProjectArtifactScanner.projectActivity`: a heuristic, not proof that the project is unused.
    let projectLastActivity: Date?
    /// False when some folders inside could not be read: the size is partial and the folder is never moved.
    let isMeasurementComplete: Bool
    var isSelected: Bool

    init(id: UUID = UUID(), url: URL, projectURL: URL, kind: ProjectArtifactKind, size: Int64, modifiedAt: Date?,
         newestContentModifiedAt: Date?, projectLastActivity: Date?, isMeasurementComplete: Bool, isSelected: Bool = false) {
        self.id = id
        self.url = url
        self.projectURL = projectURL
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.newestContentModifiedAt = newestContentModifiedAt
        self.projectLastActivity = projectLastActivity
        self.isMeasurementComplete = isMeasurementComplete
        self.isSelected = isSelected
    }

    /// Neither the project nor the folder itself changed for more than `days`. Unknown dates are never inactive.
    /// Age alone does not show that a project is unused; this only helps the user review.
    func isInactive(days: Int, now: Date = Date()) -> Bool {
        guard let activity = projectLastActivity else { return false }
        let newest = max(activity, newestContentModifiedAt ?? activity)
        return now.timeIntervalSince(newest) > TimeInterval(days) * 86_400
    }
}

/// Finds artifact folders in code projects. Read-only: it lists folders and measures what it finds.
struct ProjectArtifactScanner: Sendable {
    var roots: [URL]
    /// `Library` and `.Trash` inside this folder are never entered.
    var home: URL
    /// Folders deeper than this below a root are not entered; the report is then marked incomplete.
    var maxDepth = 8
    var minimumSize: Int64 = 1_024 * 1_024
    /// Absolute folders not entered, for example folders another worker reads on its own.
    var excludedPaths: [String] = []

    init(roots: [URL]? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         maxDepth: Int = 8, minimumSize: Int64 = 1_024 * 1_024, excludedPaths: [String] = []) {
        self.roots = roots ?? [home]
        self.home = home
        self.maxDepth = maxDepth
        self.minimumSize = minimumSize
        self.excludedPaths = excludedPaths
    }

    /// Parts of the home folder read by separate workers. Desktop, Documents and Downloads can wait on a
    /// macOS access prompt; on their own, a prompt left unanswered costs that folder only, not the whole scan.
    static let promptingFolders = FolderAccessCheck.promptingLocations
    static let parts = ["home"] + promptingFolders

    /// The scanner for one part: the home folder without the prompting folders, or one prompting folder.
    static func scanner(part: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProjectArtifactScanner? {
        if part == "home" {
            return ProjectArtifactScanner(home: home, excludedPaths: promptingFolders.map { home.appending(path: $0).standardizedFileURL.path })
        }
        guard promptingFolders.contains(part) else { return nil }
        return ProjectArtifactScanner(roots: [home.appending(path: part)], home: home)
    }

    /// `--scan-worker artifacts --part <part>`: one part, stopping before the worker's own time limit.
    static func workerReport(arguments: [String]) -> ScanReport<ProjectArtifact>? {
        let part = arguments.firstIndex(of: "--part").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "home"
        return scanner(part: part)?.report(deadline: Date().addingTimeInterval(50))
    }

    /// Runs every part in its own worker at once and joins them. Fails only when the home part fails;
    /// a prompting folder that does not answer is reported in the warning and the other results are kept.
    static func partitionedRead(timeout: TimeInterval = 60, cancellation: ScanCancellation? = nil,
                                read: (@Sendable (String) -> Result<ScanReport<ProjectArtifact>, DiskScanFailure>)? = nil)
        -> Result<ScanReport<ProjectArtifact>, DiskScanFailure> {
        let read = read ?? { part in
            DiskScanService.readValue(ScanReport<ProjectArtifact>.self, mode: "artifacts", arguments: ["--part", part],
                                      timeout: timeout, cancellation: cancellation)
        }
        let results = DiskScanService.concurrentMap(parts, read)
        if cancellation?.isCancelled == true { return .failure(.cancelledByUser) }
        guard case .success(var combined) = results[0] else {
            if case .failure(let failure) = results[0] { return .failure(failure) }
            return .failure(DiskScanFailure(message: "Project folders could not be read."))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (part, result) in zip(parts.dropFirst(), results.dropFirst()) {
            switch result {
            case .success(let found):
                combined.items += found.items
                combined.deniedPaths += found.deniedPaths
                combined.incomplete = combined.incomplete || found.incomplete
            case .failure:
                combined.incomplete = true
                combined.unansweredPaths = (combined.unansweredPaths ?? []) + [home.appending(path: part).path]
            }
        }
        combined.items.sort { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        combined.deniedPaths = Array(Set(combined.deniedPaths)).sorted()
        return .success(combined)
    }

    /// Folder-like packages that are never entered. Directories in the bulk listing do not say whether they are packages.
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "xcodeproj", "xcworkspace", "photoslibrary",
                                                 "musiclibrary", "tvlibrary", "imovielibrary", "xcarchive", "playground",
                                                 "sparsebundle", "fcpbundle", "logicx", "plugin", "kext", "appex"]

    /// The worker's scan: the home folder, stopping cooperatively before the worker's own time limit.
    static func workerReport() -> ScanReport<ProjectArtifact> {
        workerReport(arguments: []) ?? ScanReport(items: [], deniedPaths: [])
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    func report(deadline: Date? = nil) -> ScanReport<ProjectArtifact> {
        let denied = DeniedFolders()
        let homePath = home.standardizedFileURL.path
        let excluded = Set([Self.join(homePath, "Library"), Self.join(homePath, ".Trash")] + excludedPaths)
        var found: [ProjectArtifact] = []
        var foundPaths: Set<String> = []
        var incomplete = false
        func expired() -> Bool { deadline.map { Date() >= $0 } ?? false }
        func noteError(_ path: String, _ code: Int32) {
            denied.note(URL(fileURLWithPath: path), NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }

        let rootPaths = roots.map { $0.standardizedFileURL.path }
        var walked: [String] = []
        walk: for rootPath in rootPaths {
            // A root inside one already walked adds nothing.
            guard !walked.contains(where: { rootPath == $0 || rootPath.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { continue }
            walked.append(rootPath)
            guard let root = FileAttributes.read(path: rootPath) else {
                noteError(rootPath, errno)
                continue
            }
            guard root.kind == .folder else { continue }
            var pending: [(path: String, depth: Int)] = [(rootPath, 0)]
            while let (folder, depth) = pending.popLast() {
                if expired() { incomplete = true; break walk }
                let listing = BulkDirectoryReader.entries(of: folder)
                if let error = listing.error { noteError(folder, error) }
                var entries: [FileAttributes] = []
                for entry in listing.entries {
                    if entry.error != 0 { noteError(Self.join(folder, entry.name), entry.error) } else { entries.append(entry) }
                }
                let files = Set(entries.filter { $0.kind == .file }.map(\.name))
                var artifacts: [(entry: FileAttributes, kind: ProjectArtifactKind)] = []
                // Symbolic links are never followed; other volumes and mount points are never entered.
                for entry in entries where entry.kind == .folder && entry.device == root.device && !entry.isMountPoint {
                    let path = Self.join(folder, entry.name)
                    if let kind = ProjectArtifactKind.match(name: entry.name, projectPath: folder, files: files) {
                        // Not entered: nested dependency folders belong to this one.
                        artifacts.append((entry, kind))
                        continue
                    }
                    guard shouldEnter(name: entry.name, parent: folder, path: path, excluded: excluded) else { continue }
                    guard depth < maxDepth else { incomplete = true; continue }
                    pending.append((path, depth + 1))
                }
                guard !artifacts.isEmpty else { continue }
                let activity = Self.projectActivity(folder: folder, entries: entries,
                                                    artifactNames: Set(artifacts.map(\.entry.name)))
                for (entry, kind) in artifacts {
                    if expired() { incomplete = true; break walk }
                    let path = Self.join(folder, entry.name)
                    guard foundPaths.insert(path).inserted else { continue }
                    let measurement = FileSizeCalculator.measure(URL(fileURLWithPath: path)) { url, code in
                        denied.note(url, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
                    }
                    guard measurement.bytes >= max(minimumSize, 1) else { continue }
                    found.append(ProjectArtifact(
                        url: URL(fileURLWithPath: path, isDirectory: true),
                        projectURL: URL(fileURLWithPath: folder, isDirectory: true),
                        kind: kind,
                        size: measurement.bytes,
                        modifiedAt: entry.modified,
                        newestContentModifiedAt: measurement.newestModification,
                        projectLastActivity: activity,
                        isMeasurementComplete: measurement.unreadableFolders == 0,
                        isSelected: false
                    ))
                }
            }
        }
        found.sort { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        return ScanReport(items: found, deniedPaths: denied.paths, incomplete: incomplete)
    }

    /// Hidden folders, packages, Library and Trash, and managed dependency stores are never entered.
    private func shouldEnter(name: String, parent: String, path: String, excluded: Set<String>) -> Bool {
        guard !name.hasPrefix("."), !excluded.contains(path) else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty && Self.packageExtensions.contains(ext) { return false }
        if name == "node_modules" || name == "gomodcache" { return false }
        if name == "mod" && (parent as NSString).lastPathComponent == "pkg" { return false }
        return true
    }

    /// When the project was last worked on, as far as cheap evidence shows. This is a heuristic, not proof of disuse:
    /// it is the newest modification date among the project folder itself, its direct entries other than its artifact
    /// folders (this includes the project file, such as `package.json`), and `.git/index` and `.git/HEAD` when present.
    /// An edit deep inside a source folder may not change any of these dates, and an old date does not mean the
    /// project is no longer needed.
    static func projectActivity(folder: String, entries: [FileAttributes], artifactNames: Set<String>) -> Date? {
        var dates: [Date] = []
        if let own = FileAttributes.read(path: folder)?.modified { dates.append(own) }
        for entry in entries where !artifactNames.contains(entry.name) && entry.name != ".DS_Store"
            && (entry.kind == .file || entry.kind == .folder) {
            if let modified = entry.modified { dates.append(modified) }
        }
        for name in [".git/index", ".git/HEAD"] {
            if let git = FileAttributes.read(path: join(folder, name)), git.kind == .file, let modified = git.modified {
                dates.append(modified)
            }
        }
        return dates.max()
    }
}

/// Moves reviewed artifact folders to Trash after checking each one again. Never deletes permanently.
struct ProjectArtifactCleaner: Sendable {
    /// Artifacts must be inside this folder, and not inside its `Library` or `.Trash`.
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    func clean(_ items: [ProjectArtifact], trashItem: @Sendable (URL) throws -> Void = { url in
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) -> CleanupResult {
        var removed: Set<UUID> = []
        var bytes: Int64 = 0
        var issues: [CleanupIssue] = []
        for item in items where item.isSelected {
            if let issue = validate(item) {
                issues.append(issue)
                continue
            }
            do {
                try trashItem(item.url)
                removed.insert(item.id)
                bytes += item.size
            } catch {
                issues.append(TrashValidation.issue(for: error as NSError, url: item.url))
            }
        }
        return CleanupResult(removedCount: removed.count, reclaimedBytes: bytes, failures: issues.map(\.message),
                             removedItemIDs: removed, issues: issues)
    }

    /// Why `item` must not be moved now, or nil when it is still the folder the scan found and reviewed.
    func validate(_ item: ProjectArtifact) -> CleanupIssue? {
        let url = item.url.standardizedFileURL
        let path = url.path
        let parent = url.deletingLastPathComponent()
        func issue(_ kind: CleanupIssue.Kind, _ detail: String) -> CleanupIssue {
            CleanupIssue(url: item.url, kind: kind, detail: detail)
        }

        guard TrashValidation.isUnredirected(url) else {
            return issue(.unsafe, "A symbolic link or redirected folder changed the path. The folder was skipped.")
        }
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/"),
              !path.hasPrefix(ProjectArtifactScanner.join(homePath, "Library") + "/"),
              !path.hasPrefix(ProjectArtifactScanner.join(homePath, ".Trash") + "/") else {
            return issue(.unsafe, "Only project folders in your home folder, outside Library and Trash, are moved. The folder was skipped.")
        }
        guard parent.path == item.projectURL.standardizedFileURL.path, item.kind.matchesName(url.lastPathComponent) else {
            return issue(.unsafe, "The folder no longer matches the scanned project. Scan again.")
        }
        // A dependency folder inside another dependency folder or the Go module cache belongs to its package manager.
        if parent.pathComponents.contains("node_modules") || TrashValidation.isGoModuleCache(parent) {
            return issue(.managedCache, "This folder is inside a package manager's dependency folder. Use the package manager to change it.")
        }
        guard let info = FileAttributes.read(path: path) else {
            return TrashValidation.issue(for: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), url: item.url)
        }
        guard info.kind == .folder else {
            return issue(.changed, "This is no longer a folder. Scan again before cleaning it.")
        }
        if let content = item.kind.requiredContent {
            guard FileAttributes.read(path: path + "/" + content)?.kind == .file else {
                return issue(.changed, "\(content) is no longer inside this folder, so it is not recognized as a \(item.kind.displayName). Scan again.")
            }
        }
        let listing = BulkDirectoryReader.entries(of: parent.path)
        let files = Set(listing.entries.filter { $0.error == 0 && $0.kind == .file }.map(\.name))
        guard listing.error == nil, item.kind.hasMarker(in: files) else {
            let markers = item.kind.siblingMarkers.joined(separator: " or ")
            return issue(.changed, "The project file (\(markers)) next to this folder is gone, so it may no longer be regenerable. Scan again.")
        }
        if let rights = Self.removalIssue(url) { return rights }
        guard let expected = item.modifiedAt, info.modified == expected else {
            return issue(.changed, "The folder changed after scanning. Scan again before cleaning it.")
        }
        // A folder's own date misses edits deep inside; compare the newest content date the scan recorded.
        let measurement = FileSizeCalculator.measure(url)
        guard item.isMeasurementComplete, measurement.unreadableFolders == 0,
              let current = measurement.newestModification, let recorded = item.newestContentModifiedAt else {
            return issue(.changed, "Could not verify all content inside this folder. Check folder access and scan again before cleaning it.")
        }
        guard current <= recorded else {
            return issue(.changed, "Content inside this folder changed after scanning. A build or install may be running. Scan again before cleaning it.")
        }
        return nil
    }

    /// The checks of `TrashValidation.preflight` other than its managed-dependency refusal, which is right for
    /// single duplicate files but would refuse every `node_modules` folder here.
    static func removalIssue(_ url: URL) -> CleanupIssue? {
        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.immutable] as? Bool == true {
                return CleanupIssue(url: url, kind: .locked, detail: "This folder is locked. Review it in Finder before trying again.")
            }
            let parent = try fileManager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            if parent[.immutable] as? Bool == true {
                return CleanupIssue(url: url, kind: .locked, detail: "The project folder is locked. Review it in Finder before trying again.")
            }
            if let mode = parent[.posixPermissions] as? NSNumber, mode.intValue & 0o222 == 0 {
                return CleanupIssue(url: url, kind: .readOnly,
                                    detail: "The project folder is read-only. Full Disk Access does not change filesystem permissions.")
            }
            // Moving a folder rewrites its link to the parent, so the folder itself must be writable too.
            if access(url.path, W_OK) != 0 && errno == EACCES {
                return TrashValidation.accessIssue(url: url)
            }
        } catch {
            return TrashValidation.issue(for: error as NSError, url: url)
        }
        return nil
    }
}

/// A global cache owned by a developer tool. Shown read-only: the tool's own command keeps its index consistent.
struct ToolchainCacheSpec: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    /// The owning tool's cleanup command, or nil when the tool manages it in its own interface.
    let command: String?
    let note: String

    static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ToolchainCacheSpec] {
        func spec(_ name: String, _ path: String, _ command: String?, _ note: String) -> ToolchainCacheSpec {
            ToolchainCacheSpec(name: name, url: home.appending(path: path, directoryHint: .isDirectory), command: command, note: note)
        }
        let conda = "Removes unused package tarballs and caches. Installed environments are kept."
        return [
            spec("npm cache", ".npm/_cacache", "npm cache clean --force", "Packages download again when a project needs them."),
            spec("pnpm store", "Library/pnpm/store", "pnpm store prune", "Removes packages no project references any more."),
            spec("Yarn cache", "Library/Caches/Yarn", "yarn cache clean", "Packages download again when a project needs them."),
            spec("Bun cache", ".bun/install/cache", "bun pm cache rm", "Packages download again when a project needs them."),
            spec("pip cache", "Library/Caches/pip", "pip cache purge", "Wheels download again when a package is installed."),
            spec("Cargo registry", ".cargo/registry", "cargo cache --autoclean",
                 "Needs the cargo-cache tool (cargo install cargo-cache). Crates download again on the next build."),
            spec("Gradle caches", ".gradle/caches", "gradle --stop",
                 "Stop the Gradle daemons with this command, then remove ~/.gradle/caches in Finder. Gradle downloads dependencies again on the next build."),
            spec("Maven repository", ".m2/repository", "mvn dependency:purge-local-repository",
                 "Run inside a Maven project: it removes and resolves that project's dependencies again. Removing the whole repository makes Maven download everything again, and artifacts you installed locally (mvn install) are lost."),
            spec("CocoaPods cache", "Library/Caches/CocoaPods", "pod cache clean --all", "Pods download again on the next pod install."),
            spec("Homebrew cache", "Library/Caches/Homebrew", "brew cleanup --prune=all", "Removes downloads and old versions. Installed formulae are kept."),
            spec("Go build cache", "Library/Caches/go-build", "go clean -cache", "Packages compile again on the next build."),
            spec("Go module cache", "go/pkg/mod", "go clean -modcache",
                 "Its files are read-only; use this command instead of Finder. Modules download again on the next build."),
            spec("Dart pub cache", ".pub-cache", "flutter pub cache clean",
                 "Packages download again on the next pub get. Tools installed with dart pub global activate are removed too."),
            spec("Android emulators", ".android/avd", nil,
                 "Virtual devices and their data. Manage them in Android Studio → Device Manager."),
            spec("Miniconda packages", "miniconda3/pkgs", "conda clean --all", conda),
            spec("Anaconda packages", "anaconda3/pkgs", "conda clean --all", conda),
            spec("Xcode simulators", "Library/Developer/CoreSimulator/Devices", "xcrun simctl delete unavailable",
                 "Removes simulators whose runtime is no longer installed. Manage others in Xcode → Devices and Simulators; simulators can hold app data.")
        ]
    }

    /// Measures the caches that exist. A missing cache is not shown and is not an error.
    static func measureExisting(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                reader: @escaping DiskMapService.TreeReader = DiskMapService.workerReader) -> [SystemDataArea] {
        let specs = all(home: home).filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let missingStatus = SystemDataScanner.status(for: DiskTreeResult(root: DiskNode(name: "", kind: .notScanned), missing: true))
        return SystemDataScanner.measureAll(specs) {
            SystemDataScanner.measure(name: $0.name, url: $0.url, note: $0.note, reader: reader)
        }
        // A cache removed between the existence check and the measurement is not shown either.
        .filter { $0.diagnostic != missingStatus }
        .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }
}

@MainActor
final class ProjectArtifactsModel: ObservableObject {
    typealias Reader = @Sendable (ScanCancellation) -> Result<ScanReport<ProjectArtifact>, DiskScanFailure>
    typealias CacheMeasurer = @Sendable (ScanCancellation) -> [SystemDataArea]

    @Published var artifacts: [ProjectArtifact] = []
    @Published var state: ModuleState = .idle
    /// Folders macOS denied or a scan that stopped early; the artifacts found are still shown.
    @Published var warning: String?
    @Published var toolchainCaches: [SystemDataArea] = []
    @Published var toolchainLoading = false
    @Published var cleaning = false
    @Published var confirmsCleanup = false
    /// The last move to Trash, in words; nil before the first one.
    @Published var cleanupMessage: String?
    @Published var lastCleanup: CleanupResult?
    /// Asked before each scan, so the app can hold scans until folder access is set up.
    var authorizeScan: @MainActor () -> Bool = { true }
    var onOutcome: (@MainActor (CleanupOutcome) -> Void)?
    /// Every finished cleanup with the folders offered and what happened to each, for Cleanup History.
    var onCleanup: (@MainActor (_ candidates: [(id: UUID, url: URL, bytes: Int64)], _ result: CleanupResult) -> Void)?

    private let reader: Reader
    private let cacheMeasurer: CacheMeasurer
    private let cleaner: ProjectArtifactCleaner
    private let trashItem: @Sendable (URL) throws -> Void
    private let commands: [String: ToolchainCacheSpec]

    init(reader: Reader? = nil, cacheMeasurer: CacheMeasurer? = nil,
         cleaner: ProjectArtifactCleaner = ProjectArtifactCleaner(),
         trashItem: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.reader = reader ?? { ProjectArtifactScanner.partitionedRead(cancellation: $0) }
        let home = cleaner.home
        self.cacheMeasurer = cacheMeasurer ?? {
            ToolchainCacheSpec.measureExisting(home: home, reader: DiskMapService.workerReader(cancellation: $0))
        }
        self.cleaner = cleaner
        self.trashItem = trashItem
        self.commands = Dictionary(ToolchainCacheSpec.all(home: home).map { ($0.url.standardizedFileURL.path, $0) },
                                   uniquingKeysWith: { first, _ in first })
    }

    var busy: Bool { state == .loading || cleaning }
    var selected: [ProjectArtifact] { artifacts.filter(\.isSelected) }
    var selectedCount: Int { selected.count }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }

    func spec(for area: SystemDataArea) -> ToolchainCacheSpec? { commands[area.url.standardizedFileURL.path] }

    /// Scans once, or again when `force` is set. Never selects anything.
    func scan(force: Bool = false) {
        guard !busy, force || state == .idle, authorizeScan() else { return }
        let (id, cancellation) = run.begin()
        state = .loading
        warning = nil
        cleanupMessage = nil
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { [reader] in reader(cancellation) }
            guard run.finish(id) else { return }
            switch result {
            case .success(let report):
                artifacts = report.items.map { var item = $0; item.isSelected = false; return item }
                warning = Self.warning(for: report)
                state = .ready
            case .failure(let failure):
                state = failure.cancelled ? .cancelled : .failed(failure.message)
            }
        }
        measureToolchainCaches(cancellation: cancellation)
    }

    private var run = ScanRunTracker()

    /// Stops the scan's workers and the cache measurements started with it; earlier results stay on screen.
    func cancel() {
        guard run.cancel() else { return }
        state = .cancelled
    }

    func measureToolchainCaches(cancellation: ScanCancellation = ScanCancellation()) {
        guard !toolchainLoading else { return }
        toolchainLoading = true
        Task {
            let measured = await BackgroundWork.run(qos: .utility) { [cacheMeasurer] in cacheMeasurer(cancellation) }
            if !cancellation.isCancelled { toolchainCaches = measured }
            toolchainLoading = false
        }
    }

    static func warning(for report: ScanReport<ProjectArtifact>) -> String? {
        var parts: [String] = []
        if let access = AccessWarning.denied(report.deniedPaths, purpose: "checked for project folders") { parts.append(access) }
        if let unanswered = report.unansweredPaths, !unanswered.isEmpty {
            parts.append("No answer in time from \(unanswered.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")). "
                + "macOS may be waiting for you to allow access; review scan permissions and scan again.")
        } else if report.incomplete {
            parts.append("The scan stopped at its time limit or at deeply nested folders, so some projects were not checked. The folders found so far are shown.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func setSelection(_ selected: Bool, id: UUID) {
        guard !busy, let index = artifacts.firstIndex(where: { $0.id == id }),
              artifacts[index].isMeasurementComplete || !selected else { return }
        artifacts[index].isSelected = selected
    }

    /// Selects exactly the regenerable, fully measured folders whose project and content are older than `days`.
    func selectInactive(days: Int = 90, now: Date = Date()) {
        guard !busy else { return }
        for index in artifacts.indices {
            let item = artifacts[index]
            artifacts[index].isSelected = item.kind.isSafelyRegenerable && item.isMeasurementComplete && item.isInactive(days: days, now: now)
        }
    }

    func selectNone() {
        guard !busy else { return }
        for index in artifacts.indices { artifacts[index].isSelected = false }
    }

    func requestCleanup() {
        confirmsCleanup = !busy && selectedCount > 0
    }

    /// What the confirmation tells the user: count, size, Trash, and how to get the folders back.
    var confirmationMessage: String {
        let items = selected
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        var kinds: [ProjectArtifactKind] = []
        for item in items where !kinds.contains(item.kind) { kinds.append(item.kind) }
        let hints = kinds.map { "\($0.displayName): \($0.regenerateHint)" }.joined(separator: "; ")
        var message = "\(items.count) folder(s) (\(bytes.formattedBytes)) will be moved to Trash, not deleted. "
            + "Disk space is released when Trash is emptied. Each folder is checked again first; folders that changed since the scan are skipped. "
            + "To recreate them, run in the project: \(hints)."
        if kinds.contains(where: { !$0.isSafelyRegenerable }) {
            message += " Python virtual environments may contain packages installed by hand that a requirements file does not list."
        }
        return message
    }

    func cleanSelected() {
        confirmsCleanup = false
        let items = selected
        guard !busy, !items.isEmpty else { return }
        cleaning = true
        Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { [cleaner, trashItem] in
                cleaner.clean(items, trashItem: trashItem)
            }
            artifacts.removeAll { result.removedItemIDs.contains($0.id) }
            lastCleanup = result
            onCleanup?(items.map { ($0.id, $0.url, $0.size) }, result)
            let moved = "Moved \(result.removedCount) folder(s) (\(result.reclaimedBytes.formattedBytes)) to Trash. Disk space is released when Trash is emptied."
            cleanupMessage = moved + (result.issues.isEmpty ? "" : "\n\n" + CleanupIssue.summary(result.issues))
            cleaning = false
            onOutcome?(CleanupOutcome(date: Date(), movedCount: result.removedCount, movedBytes: result.reclaimedBytes, issues: result.issues))
        }
    }
}
