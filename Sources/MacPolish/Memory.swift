import AppKit
import SwiftUI
import Charts
import Darwin

struct MemorySample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let total: UInt64
    let used: UInt64
    let compressed: UInt64
    let swap: UInt64?
    let pressure: Int?
    var percent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
    var pressureName: String {
        switch pressure { case 1: "Normal"; case 2: "Warning"; case 4: "Critical"; default: "Unavailable" }
    }
    var color: Color {
        switch pressure { case 1: .green; case 2: .orange; case 4: .red; default: .secondary }
    }
}

struct MemoryApp: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let bytes: UInt64
    let app: NSRunningApplication
}

enum MemoryReader {
    static func sample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        let resident = UInt64(stats.active_count) + UInt64(stats.inactive_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let reclaimable = UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)
        let used = min(total, (resident > reclaimable ? resident - reclaimable : 0) * UInt64(pageSize))
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        return MemorySample(date: Date(), total: total, used: used,
                            compressed: UInt64(stats.compressor_page_count) * UInt64(pageSize),
                            swap: swapOK ? swap.xsu_used : nil,
                            pressure: pressureOK ? Int(pressure) : nil)
    }

    static func residentSizes() -> [Int32: UInt64] {
        let result = SystemDataScanner.run("/bin/ps", ["-axo", "pid=,rss="], timeout: 3)
        guard result.status == 0 else { return [:] }
        var sizes: [Int32: UInt64] = [:]
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, let pid = Int32(fields[0]), let kb = UInt64(fields[1]), kb <= UInt64.max / 1024 {
                sizes[pid] = kb * 1024
            }
        }
        return sizes
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published var sample: MemorySample?
    @Published var history: [MemorySample] = []
    @Published var apps: [MemoryApp] = []
    @Published var selected: Set<Int32> = []
    @Published var confirmsQuit = false
    @Published var message: String?
    @Published var error: String?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let data = await Task.detached(priority: .utility) {
                    (MemoryReader.sample(), MemoryReader.residentSizes())
                }.value
                guard let self else { return }
                if let sample = data.0 {
                    self.sample = sample
                    self.history.append(sample)
                    if self.history.count > 120 { self.history.removeFirst(self.history.count - 120) }
                    self.error = nil
                } else { self.error = "Memory statistics unavailable. Retrying…" }
                self.apps = NSWorkspace.shared.runningApplications.compactMap { app in
                    guard app.activationPolicy == .regular, !app.isTerminated,
                          let bytes = data.1[app.processIdentifier] else { return nil }
                    return MemoryApp(pid: app.processIdentifier, name: app.localizedName ?? "Application", bytes: bytes, app: app)
                }.sorted { $0.bytes > $1.bytes }
                self.selected.formIntersection(Set(self.apps.map(\.pid)))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func canQuit(_ app: MemoryApp) -> Bool {
        app.pid != ProcessInfo.processInfo.processIdentifier && app.app.bundleIdentifier != "com.apple.finder"
    }

    func requestQuit() {
        let targets = apps.filter { selected.contains($0.pid) && canQuit($0) }
        var requested = 0
        var failed: [String] = []
        for target in targets {
            if !target.app.isTerminated && target.app.terminate() { requested += 1 }
            else { failed.append(target.name) }
        }
        selected = []
        message = "Sent normal quit requests to \(requested) app(s). Save any open documents when prompted. Apps may decline or delay closing; memory readings will update automatically."
            + (failed.isEmpty ? "" : "\nCould not request quit: " + failed.joined(separator: ", "))
    }
}

private func memoryBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

struct MemoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Live readings · updates about every 5 seconds").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }.padding(30)
            if let sample = monitor.sample {
                HStack(spacing: 20) {
                    metric("Estimated used", memoryBytes(sample.used))
                    metric("Available estimate", memoryBytes(sample.total - sample.used))
                    metric("Compressed", memoryBytes(sample.compressed))
                    metric("Swap", sample.swap.map(memoryBytes) ?? "Unavailable")
                }.padding(.horizontal, 30)
                HStack {
                    Label("Pressure: " + sample.pressureName, systemImage: "circle.fill").foregroundStyle(sample.color)
                    Spacer()
                    Text("Installed: " + memoryBytes(sample.total)).foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 30).padding(.top, 15)
                Chart(monitor.history) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Used %", point.percent))
                        .foregroundStyle(.cyan.opacity(0.12))
                    LineMark(x: .value("Time", point.date), y: .value("Used %", point.percent))
                        .foregroundStyle(.cyan)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 120).padding(.horizontal, 30).padding(.vertical, 15)
            } else { ProgressView("Reading memory…").padding() }
            if let error = monitor.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Text("Running applications").font(.headline)
                Spacer()
                Text("Main-process resident memory (RSS)").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 30).padding(.vertical, 10)
            List(monitor.apps) { app in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { monitor.selected.contains(app.pid) },
                        set: { if $0 { monitor.selected.insert(app.pid) } else { monitor.selected.remove(app.pid) } }
                    )).labelsHidden().disabled(!monitor.canQuit(app))
                    if let icon = app.app.icon {
                        Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                    }
                    Text(app.name).font(.headline)
                    Spacer()
                    Text(memoryBytes(app.bytes)).monospacedDigit()
                }.padding(.vertical, 5)
            }.listStyle(.inset)
            Text("App figures exclude helper processes and can include shared memory. They do not add up to system usage. The graph shows estimated usage, not memory pressure.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 25).padding(.vertical, 8)
            HStack {
                Text("\(monitor.selected.count) apps selected").foregroundStyle(.secondary)
                Spacer()
                Button("Optimize Memory…") { monitor.confirmsQuit = true }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(monitor.selected.isEmpty)
            }.padding(20).background(.bar)
        }
        .task { monitor.start() }
        .alert("Quit selected applications?", isPresented: $monitor.confirmsQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Request Quit") { monitor.requestQuit() }
        } message: {
            Text("Ask \(monitor.selected.count) selected app(s) to close normally. Save your work first; apps may display a save prompt or refuse to close. No force quit is used.")
        }
        .alert("Memory optimization", isPresented: Binding(get: { monitor.message != nil }, set: { if !$0 { monitor.message = nil } })) {
            Button("OK") { monitor.message = nil }
        } message: { Text(monitor.message ?? "") }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MemoryMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: MemoryMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Mac Polish", systemImage: "memorychip").font(.headline)
            if let sample = monitor.sample {
                Text(memoryBytes(sample.used) + " / " + memoryBytes(sample.total)).font(.title2.bold())
                ProgressView(value: sample.percent, total: 100).tint(sample.color)
                Label("Pressure: " + sample.pressureName, systemImage: "circle.fill").foregroundStyle(sample.color)
                Text("Swap: " + (sample.swap.map(memoryBytes) ?? "Unavailable")).foregroundStyle(.secondary)
                Text("Updated " + sample.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            } else { ProgressView("Reading memory…") }
            Divider()
            ForEach(monitor.apps.prefix(3)) { app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(memoryBytes(app.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
            }
            Button("Open Memory Dashboard") {
                model.destination = .memory
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderedProminent)
            Button("Quit Mac Polish") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }.padding(20).frame(width: 310)
        .task { monitor.start() }
    }
}
