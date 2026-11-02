import Foundation
import Darwin
import SwiftUI
import AppKit

struct SystemDataArea: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let note: String
    let bytes: Int64?
    let partial: Bool
    let children: [SystemDataChild]
    var diagnostic: String = ""
}

struct SystemDataChild: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let bytes: Int64
}

struct SystemDataReport: Sendable {
    let areas: [SystemDataArea]
    let dockerOutput: String
    let date: Date
    var measuredBytes: Int64 { areas.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

/// Uses allocated disk blocks (du), not the logical capacity of sparse VM disks.
struct SystemDataScanner: Sendable {
    static var dockerExecutable: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cleanDockerBuildCache() -> String {
        guard let executable = dockerExecutable else { return "Docker CLI not found. Install or start Docker Desktop." }
        let result = run(executable, ["--context", "desktop-linux", "buildx", "prune", "--builder", "desktop-linux", "--all", "--force"], timeout: 300, captureErrors: true)
        if result.status == -1 {
            return "The cleanup could not be confirmed or timed out. Some cache may have been removed. Refresh Docker details before retrying."
        }
        guard result.status == 0 else {
            return "Docker cleanup failed: " + String(result.output.suffix(1500))
        }
        let total = result.output.split(separator: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Total:") })
        return "Build cache cleanup completed. " + (total.map(String.init) ?? "")
            + "\nVolumes were not targeted. Deleted cache cannot be restored from Trash; Docker recreates it on future builds. macOS free space may update later."
    }
    func scan() -> SystemDataReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let specs: [(String, URL, String)] = [
            ("Docker virtual disk", home.appending(path: "Library/Containers/com.docker.docker"), "Includes images, build cache and volume data. Use Docker to manage its contents."),
            ("Claude", home.appending(path: "Library/Application Support/Claude"), "Virtual machine bundles, app data and caches."),
            ("Cursor", home.appending(path: "Library/Application Support/Cursor"), "Project snapshots, extensions and app data. Snapshots may contain useful history."),
            ("Docker installer data", home.appending(path: "Library/Application Support/com.docker.install"), "Installation resources; inspect before removing."),
            ("User caches", home.appending(path: "Library/Caches"), "Application caches; running apps may recreate these."),
            ("Developer files", home.appending(path: "Library/Developer"), "Xcode builds, archives, device support and simulators."),
            ("Device backups", home.appending(path: "Library/Application Support/MobileSync/Backup"), "iPhone and iPad backups. These can contain your only recovery copy."),
            ("Go packages", home.appending(path: "go/pkg"), "Managed package cache. Do not remove individual duplicate source files."),
            ("npm & npx", home.appending(path: ".npm"), "JavaScript packages and cached tools."),
            ("Claude Code", home.appending(path: ".claude"), "Plugins, project sessions and file history."),
            ("Codex", home.appending(path: ".codex"), "Local app resources, sessions and configuration."),
            ("Development caches", home.appending(path: ".cache"), "Cached runtimes and development tools."),
            ("VS Code", home.appending(path: "Library/Application Support/Code"), "Editor data, extensions and caches."),
            ("Notion", home.appending(path: "Library/Application Support/Notion"), "Local application data and caches."),
            ("Figma", home.appending(path: "Library/Application Support/Figma"), "Local application data and caches."),
            ("System temporary data", URL(fileURLWithPath: "/private/var/folders"), "macOS and app temporary directories. Some areas are protected."),
            ("System databases", URL(fileURLWithPath: "/private/var/db"), "Managed by macOS; not a general cleanup target."),
            ("Swap", URL(fileURLWithPath: "/private/var/vm"), "Virtual memory managed by macOS. Do not delete while the system is running."),
            ("Shared Library", URL(fileURLWithPath: "/Library"), "Shared support files, developer tools, audio assets and logs.")
        ]
        let areas = specs.map { Self.measure(name: $0.0, url: $0.1, note: $0.2) }
            .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        let docker: String
        if let executable = Self.dockerExecutable {
            let result = Self.run(executable, ["--context", "desktop-linux", "system", "df"], timeout: 25)
            docker = result.status == 0 ? result.output : "Docker details unavailable. Start Docker Desktop and refresh. The disk measurement above is still available."
        } else {
            docker = "Docker CLI is not installed. The disk measurement above is still available."
        }
        return SystemDataReport(areas: areas, dockerOutput: docker, date: Date())
    }

    static func measure(name: String, url: URL, note: String) -> SystemDataArea {
        let result = run("/usr/bin/du", ["-x", "-k", "-d", "1", url.path], timeout: 45, captureErrors: true)
        let rows = parseDU(result.output)
        let total = rows.first { $0.url.path == url.path }?.bytes
        let diagnostic = measurementStatus(status: result.status, output: result.output, hasTotal: total != nil)
        return SystemDataArea(name: name, url: url, note: note, bytes: total,
                              partial: result.status != 0 || total == nil,
                              children: Array(rows.filter { $0.url.path != url.path && $0.bytes > 0 }
                                .sorted { $0.bytes > $1.bytes }.prefix(6)), diagnostic: diagnostic)
    }

    static func measurementStatus(status: Int32, output: String, hasTotal: Bool) -> String {
        if status == -1 { return "Scan timed out or could not start; measurement is incomplete." }
        if status == 0 && hasTotal { return "Measured" }
        let lower = output.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return "Access restricted. Review Full Disk Access for Mac Polish in System Settings, then scan again."
        }
        if lower.contains("no such file or directory") { return "Location missing or changed during scan." }
        return "Measurement incomplete or unavailable; this does not mean the folder is empty."
    }

    /// Parse only the build-cache size column; volumes and image totals are never cleanup permission.
    static func dockerBuildCacheBytes(_ output: String) -> Int64? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Build Cache") }) else { return nil }
        let columns = line.split(whereSeparator: { $0.isWhitespace })
        guard columns.count >= 6 else { return nil }
        let token = String(columns[4])
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (unit, factor) in units where token.hasSuffix(unit) {
            guard let value = Double(token.dropLast(unit.count)), value.isFinite, value >= 0,
                  value * factor < Double(Int64.max) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }

    static func parseDU(_ output: String) -> [SystemDataChild] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let blocks = Int64(parts[0]), blocks >= 0,
                  blocks <= Int64.max / 1024 else { return nil }
            return SystemDataChild(url: URL(fileURLWithPath: String(parts[1])), bytes: blocks * 1024)
        }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, captureErrors: Bool = false) -> (output: String, status: Int32) {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "MacPolish-measure-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }
            let outputURL = directory.appending(path: "output")
            fm.createFile(atPath: outputURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            process.standardOutput = handle
            process.standardError = captureErrors ? handle : FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let killDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if !process.isRunning { process.waitUntilExit() }
            }
            let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            return (output, timedOut ? -1 : process.terminationStatus)
        } catch { return (error.localizedDescription, -1) }
    }
}

struct SystemDataView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("System Data").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("See the files behind the storage category.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.systemDataLoading ? "Analyzing…" : "Refresh") { model.analyzeSystemData() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.systemDataLoading || model.dockerCleaning)
            }.padding(30)
            if model.systemDataLoading {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Measuring allocated disk space and querying Docker…").font(.caption)
                }.padding(12)
            }
            if let report = model.systemDataReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("MEASURED LOCATIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(report.measuredBytes.formattedBytes).font(.system(size: 32, weight: .bold, design: .rounded))
                            }
                            Spacer()
                            Text(report.date, style: .time).foregroundStyle(.secondary)
                        }
                        Text("These selected locations are not an exact match for macOS System Data. Other app data and snapshots may be missing. Protected or timed-out locations show partial measurements.")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Inside Docker", systemImage: "shippingbox").font(.headline)
                            HStack {
                                Text("Docker Desktop · local build cache").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if model.dockerCleaning { ProgressView().controlSize(.small) }
                                Button(model.dockerCleaning ? "Cleaning…" : "Clean Docker Build Cache") {
                                    model.confirmsDockerCleanup = true
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.dockerCleaning || model.systemDataLoading || SystemDataScanner.dockerExecutable == nil || (SystemDataScanner.dockerBuildCacheBytes(report.dockerOutput) ?? 0) == 0)
                            }
                            if let message = model.dockerCleanupMessage {
                                Text(message).font(.caption).textSelection(.enabled)
                            }
                            ScrollView(.horizontal) {
                                Text(report.dockerOutput).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                            Text("Docker figures are inside its virtual disk—do not add them to the measured total. Reclaimable volumes may still contain databases or project data.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        ForEach(report.areas) { area in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(area.diagnostic).font(.caption).foregroundStyle(area.partial ? .orange : .secondary)
                                    Text(area.note).font(.caption).foregroundStyle(.secondary)
                                    Text(area.url.path).font(.caption).textSelection(.enabled)
                                    ForEach(area.children) { child in
                                        HStack {
                                            Text(child.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(child.bytes.formattedBytes).monospacedDigit()
                                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                                                .buttonStyle(.borderless)
                                        }.font(.caption)
                                    }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([area.url]) }
                                }.padding(.top, 12)
                            } label: {
                                HStack {
                                    Text(area.name).font(.headline)
                                    Spacer()
                                    if area.partial { Text(area.bytes == nil ? "Unavailable" : "Partial").font(.caption).foregroundStyle(.orange) }
                                    Text(area.bytes?.formattedBytes ?? "—").monospacedDigit()
                                }
                            }
                            .padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 30)
                }
            } else {
                ContentUnavailableView("Understanding your storage", systemImage: "internaldrive", description: Text("The analysis runs in the background. You can continue using other tools."))
            }
        }
        .task { if model.systemDataReport == nil { model.analyzeSystemData() } }
        .alert("Clean Docker build cache?", isPresented: $model.confirmsDockerCleanup) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Build Cache", role: .destructive) { model.cleanDockerBuildCache() }
        } message: {
            Text("Permanently remove unused build cache from the local Docker Desktop builder. Volumes and project databases are not targeted. The next builds may take longer. This does not move files to Trash.")
        }
    }
}
