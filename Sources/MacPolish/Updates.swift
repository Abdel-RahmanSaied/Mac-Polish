import AppKit
import SwiftUI

struct AppVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var numbers: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(field) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct PublishedRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let state: String }
    var version: AppVersion? { AppVersion(tag_name) }
    var page: URL {
        URL(string: "https://github.com/Abdel-RahmanSaied/Mac-Polish/releases/tag/" + tag_name)!
    }
    static func newest(_ releases: [Self], after current: AppVersion, previews: Bool) -> Self? {
        releases.filter {
            guard let version = $0.version, version > current, !$0.draft, previews || !$0.prerelease else { return false }
            let number = $0.tag_name.hasPrefix("v") ? String($0.tag_name.dropFirst()) : $0.tag_name
            return $0.assets.contains { $0.name == "Mac-Polish-\(number)-macos-arm64.zip" && $0.state == "uploaded" }
        }.max { $0.version! < $1.version! }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var available: PublishedRelease?
    @Published var checking = false
    @Published var status = "Not checked yet"
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdates") }
    }
    @Published var previews = UserDefaults.standard.object(forKey: "previewUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(previews, forKey: "previewUpdates")
            available = nil
            status = "Channel changed — check for updates"
        }
    }
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var task: Task<Void, Never>?
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.automatic { await self.check() }
                do { try await Task.sleep(for: .seconds(21_600)) } catch { return }
            }
        }
    }
    func check() async {
        guard !checking else { return }
        guard let installed, let current = AppVersion(installed) else {
            status = "Build the .app bundle to check its installed version."
            return
        }
        checking = true
        defer { checking = false }
        let channel = previews
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Abdel-RahmanSaied/Mac-Polish/releases?per_page=100")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = "Could not check GitHub. Try again later (network or rate limit)."
                return
            }
            let releases = try JSONDecoder().decode([PublishedRelease].self, from: data)
            guard channel == previews else { return }
            available = PublishedRelease.newest(releases, after: current, previews: channel)
            status = available.map { "Update available: \($0.tag_name)" } ?? "You're up to date (\(installed))."
        } catch {
            status = "Update check failed. Check your connection and try again."
        }
    }
    func openRelease() {
        guard let available else { return }
        NSWorkspace.shared.open(available.page)
    }
}

struct UpdateControls: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updates.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(updates.checking ? "Checking…" : "Check for Updates") { Task { await updates.check() } }
                    .disabled(updates.checking)
                if let release = updates.available {
                    Button("Get \(release.tag_name)") { updates.openRelease() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct UpdateBanner: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        if let release = updates.available {
            HStack {
                Label("Mac Polish \(release.tag_name) is available" + (release.prerelease ? " · Preview" : ""), systemImage: "arrow.down.circle")
                Spacer()
                Button("View Update") { updates.openRelease() }
            }.padding(12).background(.blue.opacity(0.12))
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        Section("Updates") {
            Toggle("Automatically check every 6 hours", isOn: $updates.automatic)
            Toggle("Include preview releases", isOn: $updates.previews)
            UpdateControls(updates: updates)
            Text("Checks public GitHub releases. Downloads and installation are manual.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
