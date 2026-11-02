import Foundation

if let index = CommandLine.arguments.firstIndex(of: "--scan-worker"), CommandLine.arguments.indices.contains(index + 1) {
    func write<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try JSONEncoder().encode(value))
    }
    do {
        switch CommandLine.arguments[index + 1] {
        case "basic": try write(DiskScanner().scan(includeLargeFiles: CommandLine.arguments.contains("--include-large-files")))
        case "duplicates": try write(DuplicateScanner().scan())
        case "applications": try write(ApplicationScanner().scan())
        case "storage": try write(StorageScanner().scan())
        case "startup": try write(StartupScanner().scan())
        case "access": try write(FolderAccessCheck.locations().map { FolderAccessCheck.check(name: $0.0, url: $0.1) })
        default: exit(2)
        }
        exit(0)
    } catch { exit(2) }
} else {
    MacPolishApp.main()
}
