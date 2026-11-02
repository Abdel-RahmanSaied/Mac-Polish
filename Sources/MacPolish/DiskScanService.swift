import Foundation

struct DiskScanFailure: Error, Sendable {
    let message: String
}

/// Read-only filesystem workers have a deadline, including if a provider or macOS access request stalls.
enum DiskScanService {
    static func scan(includeLargeFiles: Bool = true, timeout: TimeInterval = 60) -> Result<[ScanItem], DiskScanFailure> {
        read(ScanItem.self, mode: "basic", arguments: includeLargeFiles ? ["--include-large-files"] : [], timeout: timeout)
    }

    static func read<Item: Decodable & Sendable>(_ type: Item.Type, mode: String,
                                                arguments: [String] = [], timeout: TimeInterval = 60) -> Result<[Item], DiskScanFailure> {
        guard let executable = Bundle.main.executableURL?.path else {
            return .failure(DiskScanFailure(message: "The scan worker is unavailable. Reopen the app and try again."))
        }
        let output = SystemDataScanner.run(executable, ["--scan-worker", mode] + arguments, timeout: timeout)
        guard output.status == 0, let data = output.output.data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return .failure(DiskScanFailure(message: output.status == -1
                ? "Reading files reached its time limit. A folder, cloud provider or access request may be waiting. Review scan permissions and try again."
                : "Reading files could not finish. Review scan permissions and try again."))
        }
        return .success(items)
    }
}
