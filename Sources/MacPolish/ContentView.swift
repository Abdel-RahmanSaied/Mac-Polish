import AppKit
import SwiftUI

extension SidebarDestination {
    var color: Color {
        switch self {
        case .overview, .cleanup, .optimize: .teal
        case .largeFiles, .storage, .systemData, .memory: .blue
        case .duplicates, .applications: .purple
        case .developer: .orange
        case .oldFiles: .pink
        case .startup: .mint
        }
    }
}

@MainActor
private final class ResultsPresentation: ObservableObject {
    @Published var search = ""
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.destination)
                .navigationSplitViewColumnWidth(min: 225, ideal: 240, max: 280)
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color.teal.opacity(0.055)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                switch model.destination {
                case .overview:
                    OverviewView()
                case .optimize:
                    OptimizeView(optimizer: model.optimizer)
                case .memory:
                    MemoryView(monitor: model.memory)
                case .cleanup:
                    ResultsView(title: "Cleanup", items: model.cleanableItems)
                case .largeFiles:
                    ResultsView(title: "Large Files", items: model.largeFileItems)
                case .duplicates:
                    DuplicatesView()
                case .storage:
                    StorageMapView()
                case .systemData:
                    SystemDataView()
                case .developer:
                    ResultsView(title: "Developer Cleanup", items: model.developerItems)
                case .oldFiles:
                    ResultsView(title: "Old Files", items: model.oldFileItems)
                case .applications:
                    ApplicationsView()
                case .startup:
                    StartupItemsView()
                }
            }
        }
        .modifier(AccessSetupPresenter(access: model.access))
        .sheet(isPresented: $model.showsCleanupDetails) {
            if let outcome = model.cleanupOutcome {
                CleanupDetailsView(outcome: outcome, onPermissions: model.reviewCleanupPermissions,
                                   onClose: { model.showsCleanupDetails = false })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) { UpdateBanner(updates: model.updates) }
        .tint(.cyan)
        .alert(model.operationIssues.contains(where: \.needsAccess) ? "File access required" : "Mac Polish", isPresented: Binding(
            get: { model.operationMessage != nil },
            set: { if !$0 { model.operationMessage = nil } }
        )) {
            if model.operationIssues.contains(where: \.needsAccess) {
                Button("Review Permissions…") { model.reviewCleanupPermissions() }
            }
            Button("View Details…") { model.reviewCleanupDetails() }
            Button("OK", role: .cancel) { model.operationMessage = nil }
        } message: {
            Text(model.operationMessage ?? "")
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: SidebarDestination

    var body: some View {
        List(selection: $selection) {
            sidebarSection("WORKSPACE", items: [.overview, .optimize, .memory, .storage, .systemData])
            sidebarSection("FREE UP SPACE", items: [.cleanup, .largeFiles, .duplicates, .oldFiles])
            sidebarSection("MANAGE", items: [.applications, .developer, .startup])
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if model.cleanupOutcome != nil {
                    Button { model.reviewCleanupDetails() } label: {
                        Label("Last Cleanup", systemImage: "checklist").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.vertical, 5)
                }
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
                Divider()
                HStack(spacing: 9) {
                    Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your Mac. A little lighter.").font(.caption.weight(.medium))
                        Text("Mac Polish · Personal edition").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }.padding(16)
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                    .flatMap { NSImage(contentsOf: $0) } ?? NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit()
                    .scaleEffect(1.25)
                    .frame(width: 44, height: 44)
                    .clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Polish")
                        .font(.headline)
                    Text("A little space. A fresh start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 22)
        }
    }

    private func sidebarSection(_ title: String, items: [SidebarDestination]) -> some View {
        Section {
            ForEach(items) { item in
                Label {
                    Text(item.rawValue).font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: item.icon).foregroundStyle(item.color)
                }
                .padding(.vertical, 6)
                .tag(item)
            }
        } header: {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.3)
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                scanCard
                summaryCards
                tools
            }
            .padding(34)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Good \(greeting)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("More room for what matters.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("On-device scanning", systemImage: "desktopcomputer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }

    private var scanCard: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                Text("SMART SCAN").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.teal)
                Text(model.state == .finished ? "A clearer view of your Mac." : "Make space for\nyour next big thing.")
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Optimize") { model.destination = .optimize }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(action: model.startScan) {
                        Label(model.state == .scanning ? "Scanning…" : "Scan My Mac", systemImage: "sparkle.magnifyingglass")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.state == .scanning || model.state == .cleaning)
                    if !model.items.isEmpty {
                        Button("Review results") { model.destination = .cleanup }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                if case .failed = model.state {
                    Button("Review Scan Permissions…") { model.access.presented = true }
                        .buttonStyle(.bordered)
                }
                Text("Caches · Developer files · Large files")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle()
                    .stroke(.cyan.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: model.state == .scanning ? 0.72 : (model.items.isEmpty ? 0.78 : 1))
                    .stroke(
                        AngularGradient(colors: [.mint, .cyan, .blue, .mint], center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.7), value: model.state)

                VStack(spacing: 8) {
                    if model.state == .scanning {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning…")
                            .font(.headline)
                    } else if case .failed = model.state {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                        Text("Incomplete").font(.headline)
                        Text("Review access and retry").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: model.items.isEmpty ? "sparkles" : "externaldrive")
                            .font(.title2).foregroundStyle(.teal)
                        Text(model.items.isEmpty ? "Ready" : model.selectedSize.formattedBytes)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Text(model.items.isEmpty ? "for a fresh start" : "selected for review")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 200, height: 200)

        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [.teal.opacity(0.12), .blue.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.teal.opacity(0.16)))
    }

    private var summaryCards: some View {
        HStack(spacing: 16) {
            SummaryCard(title: "Cleanup", value: model.cleanableItems.reduce(0) { $0 + $1.size }.formattedBytes, icon: "wand.and.stars", tint: .cyan)
            SummaryCard(title: "Large files", value: "\(model.largeFileItems.count)", icon: "externaldrive", tint: .purple)
            SummaryCard(title: "Items found", value: "\(model.items.count)", icon: "doc.on.doc", tint: .orange)
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("A place for every task").font(.title3.weight(.semibold))
                Spacer()
                Text("EXPLORE YOUR TOOLS").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                toolCard(.applications, subtitle: "Apps, versions & related files")
                toolCard(.developer, subtitle: "Xcode builds, archives & caches")
                toolCard(.duplicates, subtitle: "Find matching copies of your files")
                toolCard(.storage, subtitle: "See where your space goes")
            }
        }
    }

    private func toolCard(_ destination: SidebarDestination, subtitle: String) -> some View {
        Button { model.destination = destination } label: {
            HStack(spacing: 13) {
                Image(systemName: destination.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(destination.color)
                    .frame(width: 42, height: 42)
                    .background(destination.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(destination.rawValue).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17))
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "morning" }
        if hour < 18 { return "afternoon" }
        return "evening"
    }

    private var statusText: String {
        switch model.state {
        case .idle: "A quick scan will find safe cleanup opportunities."
        case .scanning: "Looking through caches, logs, and large personal files."
        case .finished: model.items.isEmpty ? "Your Mac looks tidy." : "Review the results before cleaning."
        case .cleaning: "Moving selected items to Trash…"
        case .failed(let message): message
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var presentation = ResultsPresentation()
    let title: String
    let items: [ScanItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(items.isEmpty ? "Discover files you may no longer need." : "Review the paths and choose what to keep.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan", action: model.startScan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.state == .scanning || model.state == .cleaning)
            }
            .padding(30)

            if case .failed(let message) = model.state {
                ContentUnavailableView("Scan incomplete", systemImage: "exclamationmark.triangle", description: Text(message))
                Button("Review Scan Permissions…") { model.access.presented = true }
                    .buttonStyle(.borderedProminent).padding(.bottom, 24)
            } else if model.state == .scanning {
                VStack(spacing: 15) {
                    ProgressView().controlSize(.large)
                    Text("Finding files to review…").font(.headline)
                    Text("You can explore other tools while the scan runs.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(model.state == .finished ? "No matching files" : "Ready when you are", systemImage: "sparkle.magnifyingglass", description: Text(model.state == .finished ? "This scan found no files in this category." : "Choose Scan to inspect your Mac and review the results here."))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter by name or path", text: $presentation.search)
                        .textFieldStyle(.plain)
                    Spacer()
                    Text("\(filteredItems.count) items").font(.caption).foregroundStyle(.secondary)
                    Button("Deselect all") {
                        let ids = Set(filteredItems.map(\.id))
                        for index in model.items.indices where ids.contains(model.items[index].id) {
                            model.items[index].isSelected = false
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 30)
                .padding(.bottom, 14)
                List {
                    ForEach(categories, id: \.self) { category in
                        Section {
                            ForEach(filteredItems.filter { $0.category == category }) { item in
                                ScanItemRow(item: item)
                            }
                        } header: {
                            Text(category.rawValue).font(.caption.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if filteredItems.isEmpty {
                        ContentUnavailableView.search(text: presentation.search)
                    }
                }

                HStack {
                    Text("\(visibleSelectedItems.count) selected · \(visibleSelectedSize.formattedBytes)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Move Selected to Trash") {
                        model.cleanSelected(itemIDs: Set(filteredItems.map(\.id)))
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(visibleSelectedItems.isEmpty || model.state == .cleaning)
                }
                .padding(20)
                .background(.bar)
            }
        }
    }

    private var visibleSelectedItems: [ScanItem] {
        filteredItems.filter(\.isSelected)
    }

    private var filteredItems: [ScanItem] {
        items.filter { presentation.search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(presentation.search) }
    }

    private var categories: [ScanCategory] {
        ScanCategory.allCases.filter { category in filteredItems.contains { $0.category == category } }
    }

    private var visibleSelectedSize: Int64 {
        visibleSelectedItems.reduce(0) { $0 + $1.size }
    }
}

private struct ScanItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: ScanItem

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: binding)
                .labelsHidden()
            Image(systemName: item.category.icon)
                .foregroundStyle(.cyan)
                .frame(width: 40, height: 40)
                .background(.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(item.size.formattedBytes)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(width: 90, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { model.items.first(where: { $0.id == item.id })?.isSelected ?? false },
            set: { newValue in
                guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return }
                model.items[index].isSelected = newValue
            }
        )
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Include files larger than 100 MB", isOn: $model.includeLargeFiles)
                Text("Large personal files are never selected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AccessSettings(access: model.access)
            UpdateSettings(updates: model.updates)
            Section("Safety") {
                Label("File cleanup moves items to Trash. Optional Docker build-cache removal is permanent and asks for confirmation.", systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
