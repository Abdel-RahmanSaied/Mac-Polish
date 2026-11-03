import Foundation

@main
enum VolumeUsageCheck {
    static func volume(_ name: String, _ role: String?, _ device: String, _ bytes: Int64) -> [String: Any] {
        var volume: [String: Any] = ["Name": name, "DeviceIdentifier": device, "CapacityInUse": bytes]
        volume["Roles"] = role.map { [$0] } ?? []
        return volume
    }

    static func main() throws {
        // Trimmed from `diskutil apfs list -plist` on the developer's Mac (2026-11-03).
        let containers: [[String: Any]] = [
            ["ContainerReference": "disk1", "CapacityCeiling": Int64(524_288_000), "CapacityFree": Int64(500_000_000),
             "Volumes": [volume("iSCPreboot", "Preboot", "disk1s1", 7_000_000)]],
            ["ContainerReference": "disk3", "CapacityCeiling": Int64(494_384_795_648), "CapacityFree": Int64(59_510_517_760),
             "Volumes": [volume("Macintosh HD", "System", "disk3s1", 13_765_709_824),
                         volume("Preboot", "Preboot", "disk3s2", 9_764_888_576),
                         volume("Recovery", "Recovery", "disk3s3", 1_526_517_760),
                         volume("Update", "Update", "disk3s4", 83_292_160),
                         volume("Data", "Data", "disk3s5", 389_170_425_856),
                         volume("VM", "VM", "disk3s6", 20_403_077_120)]]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Containers": containers], format: .xml, options: 0)

        let usage = try VolumeUsage.parse(apfsList: plist, dataDevice: "disk3s5").get()
        precondition(usage.capacity == 494_384_795_648 && usage.free == 59_510_517_760)
        precondition(usage.used == 494_384_795_648 - 59_510_517_760)
        precondition(usage.volumes.count == 6 && usage.dataBytes == 389_170_425_856)
        precondition(usage.macOSBytes == 13_765_709_824 + 9_764_888_576 + 1_526_517_760 + 83_292_160)
        precondition(usage.virtualMemoryBytes == 20_403_077_120)
        precondition((try? VolumeUsage.parse(apfsList: plist, dataDevice: "disk9s9").get()) == nil)
        precondition((try? VolumeUsage.parse(apfsList: Data("not a plist".utf8), dataDevice: "disk3s5").get()) == nil)
        precondition(VolumeUsage.deviceIdentifier(fromMountSource: "/dev/disk3s5") == "disk3s5")

        // Both Data volumes share one container, but only disk3s5 is the startup Data volume.
        let dualBoot: [String: Any] = ["Containers": [[
            "CapacityCeiling": 1000, "CapacityFree": 200,
            "Volumes": [volume("Old Data", "Data", "disk3s1", 100),
                        volume("Current Data", "Data", "disk3s5", 700)]
        ]]]
        let dualPlist = try PropertyListSerialization.data(fromPropertyList: dualBoot, format: .xml, options: 0)
        let current = try VolumeUsage.parse(apfsList: dualPlist, dataDevice: "disk3s5").get()
        precondition(current.dataBytes == 700 && current.otherBytes == 100)
        let oldBoot = try VolumeUsage.parse(apfsList: dualPlist, dataDevice: "disk3s1").get()
        precondition(oldBoot.dataBytes == 100 && oldBoot.otherBytes == 700)

        let good = StorageReconciliation(dataUsed: 389_000_000_000, found: 380_000_000_000, uncertain: 6_000_000_000,
                                         unreadable: 2, notScanned: 0)
        precondition(abs(good.coverage - 380.0 / 389.0) < 1e-9 && good.meetsTarget)
        precondition(good.unexplained == 9_000_000_000)
        let over = StorageReconciliation(dataUsed: 389, found: 400, uncertain: 15, unreadable: 0, notScanned: 0)
        precondition(over.coverage == 1 && over.unexplained == 0 && over.overcount == 11)
        let poor = StorageReconciliation(dataUsed: 389, found: 296, uncertain: 0, unreadable: 368, notScanned: 1)
        precondition(!poor.meetsTarget && poor.unexplained == 93)
        precondition(StorageReconciliation(dataUsed: 0, found: 5, uncertain: 0, unreadable: 0, notScanned: 0).coverage == 0)

        print("PASS: APFS container and volume parsing, data device selection, reconciliation coverage and overcount")
    }
}
