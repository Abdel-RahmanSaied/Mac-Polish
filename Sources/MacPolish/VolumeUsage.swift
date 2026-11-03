import Darwin
import Foundation

/// How the startup disk's APFS container is divided between volumes, as macOS reports it.
struct VolumeUsage: Sendable, Equatable {
    struct Volume: Sendable, Equatable {
        let name: String
        let role: String
        let bytes: Int64
        var deviceIdentifier: String = ""
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    let capacity: Int64
    let free: Int64
    let volumes: [Volume]
    var dataDevice: String? = nil
    var snapshotCount = 0
    /// Space macOS can free on demand (caches, optimized storage); already counted as used.
    var purgeable: Int64?

    var used: Int64 { capacity - free }
    var dataBytes: Int64? { volumes.first { $0.role == "Data" && (dataDevice == nil || $0.deviceIdentifier == dataDevice) }?.bytes }
    /// The sealed system volume and the volumes that start and update macOS.
    var macOSBytes: Int64 { volumes.filter { ["System", "Preboot", "Recovery", "Update"].contains($0.role) }.reduce(0) { $0 + $1.bytes } }
    var virtualMemoryBytes: Int64 { volumes.filter { $0.role == "VM" }.reduce(0) { $0 + $1.bytes } }
    var otherBytes: Int64 { used - (dataBytes ?? 0) - macOSBytes - virtualMemoryBytes }

    /// Picks the container holding `dataDevice` (for example "disk3s5") from `diskutil apfs list -plist`.
    static func parse(apfsList data: Data, dataDevice: String) -> Result<VolumeUsage, Failure> {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else {
            return .failure(Failure(message: "macOS did not describe the disk layout."))
        }
        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            guard volumes.contains(where: { $0["DeviceIdentifier"] as? String == dataDevice }),
                  let capacity = (container["CapacityCeiling"] as? NSNumber)?.int64Value,
                  let free = (container["CapacityFree"] as? NSNumber)?.int64Value else { continue }
            let parsed = volumes.map { volume in
                Volume(name: volume["Name"] as? String ?? "Volume",
                       role: (volume["Roles"] as? [String])?.first ?? "",
                       bytes: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0,
                       deviceIdentifier: volume["DeviceIdentifier"] as? String ?? "")
            }
            return .success(VolumeUsage(capacity: capacity, free: free, volumes: parsed, dataDevice: dataDevice))
        }
        return .failure(Failure(message: "The data volume was not found in the disk layout."))
    }

    static func deviceIdentifier(fromMountSource source: String) -> String {
        source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : source
    }

    /// Reads the startup disk layout with diskutil (read-only, bounded).
    static func read(dataRoot: String = "/System/Volumes/Data") -> Result<VolumeUsage, Failure> {
        var info = statfs()
        guard statfs(dataRoot, &info) == 0 else { return .failure(Failure(message: "The data volume is unavailable.")) }
        let source = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let list = SystemDataScanner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 15)
        guard list.status == 0 else { return .failure(Failure(message: "macOS did not describe the disk layout in time.")) }
        return parse(apfsList: Data(list.output.utf8), dataDevice: deviceIdentifier(fromMountSource: source)).map { usage in
            var usage = usage
            let snapshots = SystemDataScanner.run("/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", dataRoot], timeout: 15)
            if snapshots.status == 0,
               let plist = try? PropertyListSerialization.propertyList(from: Data(snapshots.output.utf8), format: nil) as? [String: Any] {
                usage.snapshotCount = (plist["Snapshots"] as? [Any])?.count ?? 0
            }
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let values = try? URL(fileURLWithPath: dataRoot).resourceValues(forKeys: keys),
               let available = values.volumeAvailableCapacity,
               let important = values.volumeAvailableCapacityForImportantUsage {
                usage.purgeable = max(0, important - Int64(available))
            }
            return usage
        }
    }
}

/// Compares what the scan found with the space macOS reports for the data volume.
struct StorageReconciliation: Sendable, Equatable {
    let dataUsed: Int64
    let found: Int64
    let uncertain: Int64
    let unreadable: Int
    let notScanned: Int

    /// Share of the used space the scan explains, at most 100%.
    var coverage: Double { dataUsed > 0 ? min(1, Double(found) / Double(dataUsed)) : 0 }
    var meetsTarget: Bool { coverage >= 0.95 }
    /// Used space no listed item explains: unreadable folders, snapshots, file system overhead.
    var unexplained: Int64 { max(0, dataUsed - found) }
    /// Found more than macOS reports: modified clones counted in more than one place.
    var overcount: Int64 { max(0, found - dataUsed) }
}
