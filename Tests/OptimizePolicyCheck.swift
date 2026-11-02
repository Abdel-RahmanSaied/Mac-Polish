import Foundation

@main
enum OptimizePolicyCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "MacPolish-policy-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appending(path: "old-cache")
        try Data("fixture".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: file.path)
        func item(_ category: ScanCategory, _ url: URL) -> ScanItem {
            ScanItem(url: url, size: 7, category: category, modifiedAt: nil)
        }
        let candidate = OptimizePolicy.candidate(item(.cache, file))
        precondition(candidate != nil)
        precondition(OptimizePolicy.unchanged(candidate!))
        precondition(OptimizePolicy.candidate(item(.deviceBackup, file)) == nil)
        precondition(OptimizePolicy.candidate(item(.largeFile, file)) == nil)
        precondition(OptimizePolicy.candidate(item(.xcodeArchive, file)) == nil)
        let link = root.appending(path: "linked-cache")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(OptimizePolicy.candidate(item(.cache, link)) == nil)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        precondition(!OptimizePolicy.unchanged(candidate!))
        precondition(OptimizePolicy.candidate(item(.cache, file)) == nil)
        print("PASS: old cache, personal-file exclusions, symlink rejection and changed-file revalidation")
    }
}
