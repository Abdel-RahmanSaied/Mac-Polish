import Foundation

struct DiskScanFailure: Error, Sendable {
    let message: String
    var timedOut = false
}

/// Items from the sections that finished, and the sections that did not.
struct DiskScanOutcome: Sendable {
    let items: [ScanItem]
    let incomplete: [DiskScanner.Section]

    var warning: String? {
        guard !incomplete.isEmpty else { return nil }
        let names = incomplete.map(\.displayName).joined(separator: ", ")
        return "Some locations could not be read: \(names). Results from the other locations are shown. "
            + "A folder, cloud provider or macOS access request may be waiting; review scan permissions and scan again."
    }
}

/// Collects results written from concurrent iterations.
final class LockedResults<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: Value) { lock.lock(); defer { lock.unlock() }; storage[index] = value }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage.map { $0! } }
}

/// Read-only filesystem workers have a deadline, including if a provider or macOS access request stalls.
enum DiskScanService {
    typealias SectionReader = @Sendable (DiskScanner.Section) -> Result<[ScanItem], DiskScanFailure>

    /// Scans each section in its own worker, concurrently, so one stalled location cannot discard the rest.
    /// Fails only when no section could be read.
    static func scan(includeLargeFiles: Bool = true, timeout: TimeInterval = 60,
                     reader: SectionReader? = nil) -> Result<DiskScanOutcome, DiskScanFailure> {
        let read = reader ?? { section in
            Self.read(ScanItem.self, mode: "basic", arguments: ["--section", section.rawValue], timeout: timeout)
        }
        let sections = DiskScanner.Section.allCases.filter { includeLargeFiles || !$0.isLargeFileFolder }
        let results = concurrentMap(sections, read)

        var items: [ScanItem] = []
        var incomplete: [DiskScanner.Section] = []
        var failures: [DiskScanFailure] = []
        for (section, result) in zip(sections, results) {
            switch result {
            case .success(let found): items += found
            case .failure(let failure): incomplete.append(section); failures.append(failure)
            }
        }
        guard incomplete.count < sections.count else {
            return .failure(failures.first(where: \.timedOut) ?? failures.first
                ?? DiskScanFailure(message: "Reading files could not finish. Review scan permissions and try again."))
        }
        return .success(DiskScanOutcome(items: DiskScanner.sorted(items), incomplete: incomplete))
    }

    /// Runs blocking work for every input at once on GCD and returns results in input order.
    /// Each input gets its own `global().async` job: unlike `concurrentPerform`, which never uses
    /// more threads than cores, GCD adds threads while these jobs wait on child processes.
    static func concurrentMap<Input: Sendable, Output: Sendable>(_ inputs: [Input],
                                                                 _ transform: @escaping @Sendable (Input) -> Output) -> [Output] {
        let results = LockedResults<Output>(count: inputs.count)
        let group = DispatchGroup()
        for (index, input) in inputs.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                results.set(index, transform(input))
            }
        }
        group.wait()
        return results.values
    }

    static func read<Item: Decodable & Sendable>(_ type: Item.Type, mode: String,
                                                arguments: [String] = [], timeout: TimeInterval = 60) -> Result<[Item], DiskScanFailure> {
        readValue([Item].self, mode: mode, arguments: arguments, timeout: timeout)
    }

    /// Runs the read-only worker in `mode` and decodes the one JSON value it writes.
    static func readValue<Value: Decodable & Sendable>(_ type: Value.Type, mode: String,
                                                       arguments: [String] = [], timeout: TimeInterval = 60) -> Result<Value, DiskScanFailure> {
        guard let executable = Bundle.main.executableURL?.path else {
            return .failure(DiskScanFailure(message: "The scan worker is unavailable. Reopen the app and try again."))
        }
        let output = SystemDataScanner.run(executable, ["--scan-worker", mode] + arguments, timeout: timeout)
        guard output.status == 0, let data = output.output.data(using: .utf8),
              let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return .failure(DiskScanFailure(message: output.status == -1
                ? "Reading files reached its time limit. A folder, cloud provider or access request may be waiting. Review scan permissions and try again."
                : "Reading files could not finish. Review scan permissions and try again.", timedOut: output.status == -1))
        }
        return .success(value)
    }
}
