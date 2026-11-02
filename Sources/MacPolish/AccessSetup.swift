import AppKit
import Foundation
import SwiftUI

struct FolderAccessResult: Identifiable, Sendable {
    enum Status: String, Sendable {
        case readable = "Readable"
        case restricted = "Access restricted"
        case missing = "Not present"
        case unavailable = "Could not verify"
    }
    var id: String { url.path }
    let name: String
    let url: URL
    let status: Status
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

    static func classify(_ error: NSError) -> FolderAccessResult.Status {
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoPermissionError { return .restricted }
            if error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return .missing }
        }
        if error.domain == NSPOSIXErrorDomain {
            if error.code == Int(EACCES) || error.code == Int(EPERM) { return .restricted }
            if error.code == Int(ENOENT) { return .missing }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying)
        }
        return .unavailable
    }

    static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(String, URL)] {
        [ ("Desktop", home.appending(path: "Desktop")),
          ("Documents", home.appending(path: "Documents")),
          ("Downloads", home.appending(path: "Downloads")),
          ("User caches", home.appending(path: "Library/Caches")),
          ("Developer files", home.appending(path: "Library/Developer")),
          ("Trash", home.appending(path: ".Trash")) ]
    }
}

@MainActor
final class AccessSetupModel: ObservableObject {
    static let completedKey = "accessSetupCompletedV1"
    private let defaults: UserDefaults
    @Published var presented: Bool
    @Published var settingsPresented = false
    @Published var checking = false
    @Published var results: [FolderAccessResult] = []
    @Published var checkedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presented = !defaults.bool(forKey: Self.completedKey)
    }

    func check() {
        guard !checking else { return }
        checking = true
        results = []
        Task {
            let measured = await Task.detached(priority: .utility) {
                FolderAccessCheck.locations().map { FolderAccessCheck.check(name: $0.0, url: $0.1) }
            }.value
            results = measured
            checkedAt = Date()
            checking = false
        }
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        presented = false
        settingsPresented = false
    }

    func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

struct AccessSetupView: View {
    @ObservedObject var access: AccessSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Prepare your scan", systemImage: "lock.shield").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Set up file access once, before scanning.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Enable Full Disk Access for a broader scan").font(.headline)
                        Text("This allows Mac Polish to read protected files, including data belonging to other apps. Choose whether to allow it in System Settings → Privacy & Security → Full Disk Access.")
                        Text("Enable Mac Polish there. If it is missing, use + to add this application. Follow any macOS request to quit and reopen it, then return here to verify access.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Open Full Disk Access") { access.openFullDiskAccess() }
                            Button("Show This App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        }
                    }.padding(16).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2 · Check folder access together").font(.headline)
                        Text("Check Desktop, Documents, Downloads, caches, developer files and Trash. macOS may ask about individual folders; respond to its prompts to prepare them before the scan.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(access.checkedAt == nil ? "Check & Request Folder Access" : "Recheck Folder Access") { access.check() }
                                .buttonStyle(.borderedProminent).disabled(access.checking)
                            if access.checking { ProgressView().controlSize(.small) }
                        }
                        ForEach(access.results) { result in
                            HStack {
                                Text(result.name)
                                Spacer()
                                Label(result.status.rawValue, systemImage: result.status == .readable ? "checkmark.circle.fill" : "info.circle")
                                    .foregroundStyle(result.status == .readable ? Color.green : Color.secondary)
                            }.font(.callout)
                        }
                        if let checkedAt = access.checkedAt {
                            Text("Checked at " + checkedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Checks verify directory reading, not permission to delete every file or a system-wide Full Disk Access grant. Protected areas may still be unavailable. You can continue with a limited scan and revisit this setup in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Memory monitoring works without additional permissions.", systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("You control access in macOS.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Continue to Mac Polish") { access.finish() }
                    .buttonStyle(.borderedProminent).disabled(access.checking)
            }
        }.padding(28).frame(width: 650, height: 620)
            .interactiveDismissDisabled(access.checking)
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
            Button("Review Scan Permissions…") { access.settingsPresented = true }
            Text("Prepare folder access and Full Disk Access before scanning.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $access.settingsPresented) { AccessSetupView(access: access) }
    }
}
